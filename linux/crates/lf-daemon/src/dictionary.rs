//! The custom dictionary: `$XDG_DATA_HOME/localflow/dictionary.json`.
//!
//! ```text
//! {"version":1,"entries":[{"text":"…","strength":1.0}],"ignore":["…"]}
//! ```
//!
//! - The data directory is created 0700 whether or not history is on.
//! - The file is opened with `O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC` and must
//!   be a regular file owned by the effective uid with mode exactly 0600;
//!   reads stop at [`MAX_FILE_BYTES`]. A missing file is an empty dictionary.
//! - On load: version 1, at most 1000 entries each valid (DESIGN §1.1) and
//!   stored normalized, no two with the same identity key, and at most 1000
//!   ignored keys, each a valid key (DESIGN P6), without repeats. Anything
//!   else is an error that quotes no content.
//! - A change is validated in full, written to a 0600 temporary file,
//!   synced, renamed over the file and the directory synced; only then is it
//!   published (a new [`Snapshot`]). A failed write changes nothing; if only
//!   the directory sync fails, the rename is undone, memory is set to what
//!   the file then holds, and the change is still refused (`error storage`).
//!
//! The daemon owns the file; `localflowctl dict list` reads it the same way.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use lf_asr::dictionary::{
    self as rules, DictionaryEntry, EntryError, MAX_ENTRIES, MAX_IGNORED, check_strength, fold,
};
use lf_asr::tokenizer::Tokenizer;
use serde_json::{Value, json};

pub const FILE_NAME: &str = "dictionary.json";
/// Largest dictionary file read.
pub const MAX_FILE_BYTES: u64 = 1 << 20;

/// A validated dictionary.
#[derive(Clone, Default, PartialEq)]
pub struct Dictionary {
    pub entries: Vec<DictionaryEntry>,
    /// Identity keys never suggested.
    pub ignore: Vec<String>,
}

impl std::fmt::Debug for Dictionary {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Dictionary({} entries, {} ignored)",
            self.entries.len(),
            self.ignore.len()
        )
    }
}

/// An immutable published dictionary; `revision` identifies it within this
/// process (a new one per change).
#[derive(Debug, Default)]
pub struct Snapshot {
    pub revision: u64,
    pub dictionary: Dictionary,
}

/// Why a change was refused. Nothing changed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChangeError {
    InvalidEntry(EntryError),
    Full,
    NotFound,
    /// The word is not usable as an ignore key or lookup.
    BadWord,
    /// The new dictionary could not be saved.
    Storage,
}

/// The identity key of `word` as typed: whitespace collapsed, then folded.
/// `None` when it has no words.
pub fn lookup_key(word: &str) -> Option<String> {
    let joined = rules::words(word).collect::<Vec<_>>().join(" ");
    (!joined.is_empty()).then(|| fold(&joined))
}

/// Where the daemon keeps its dictionary.
#[derive(Clone)]
pub struct Setting {
    pub dir: PathBuf,
    /// The model's vocabulary, for validating entries.
    pub tokenizer: Arc<Tokenizer>,
}

pub struct Store {
    path: PathBuf,
    tokenizer: Arc<Tokenizer>,
    current: Arc<Snapshot>,
    #[cfg(test)]
    faults: Faults,
}

static REVISION: AtomicU64 = AtomicU64::new(1);

fn next_revision() -> u64 {
    REVISION.fetch_add(1, Ordering::Relaxed)
}

impl Store {
    /// Opens the dictionary in `dir` (created 0700 if missing), removing
    /// temporary files an interrupted write left. Call it while holding the
    /// instance lock. A file that fails the checks is an error.
    pub fn open(setting: &Setting) -> Result<Store, String> {
        crate::paths::ensure_private_dir(&setting.dir)?;
        remove_stale_temporaries(&setting.dir);
        let path = setting.dir.join(FILE_NAME);
        let dictionary = read(&path, Some(&setting.tokenizer))?;
        Ok(Store {
            path,
            tokenizer: Arc::clone(&setting.tokenizer),
            current: Arc::new(Snapshot {
                revision: next_revision(),
                dictionary,
            }),
            #[cfg(test)]
            faults: Faults::default(),
        })
    }

    /// The current dictionary.
    pub fn snapshot(&self) -> Arc<Snapshot> {
        Arc::clone(&self.current)
    }

    pub fn tokenizer(&self) -> &Tokenizer {
        &self.tokenizer
    }

    /// Adds an entry, or replaces the one with the same identity key.
    pub fn add(&mut self, word: &str, strength: f32) -> Result<(), ChangeError> {
        let entry =
            rules::validate(word, strength, &self.tokenizer).map_err(ChangeError::InvalidEntry)?;
        let key = entry.key();
        let mut next = self.current.dictionary.clone();
        match next.entries.iter().position(|e| e.key() == key) {
            Some(i) => next.entries[i] = entry,
            None if next.entries.len() >= MAX_ENTRIES => return Err(ChangeError::Full),
            None => next.entries.push(entry),
        }
        self.commit(next)
    }

    pub fn remove(&mut self, word: &str) -> Result<(), ChangeError> {
        let key = lookup_key(word).ok_or(ChangeError::BadWord)?;
        let mut next = self.current.dictionary.clone();
        let before = next.entries.len();
        next.entries.retain(|e| e.key() != key);
        if next.entries.len() == before {
            return Err(ChangeError::NotFound);
        }
        self.commit(next)
    }

    /// Never suggests `word` again. Already ignored is fine.
    pub fn ignore(&mut self, word: &str) -> Result<(), ChangeError> {
        let key = lookup_key(word)
            .filter(|k| rules::valid_key(k))
            .ok_or(ChangeError::BadWord)?;
        let mut next = self.current.dictionary.clone();
        if next.ignore.contains(&key) {
            return Ok(());
        }
        if next.ignore.len() >= MAX_IGNORED {
            return Err(ChangeError::Full);
        }
        next.ignore.push(key);
        self.commit(next)
    }

    pub fn unignore(&mut self, word: &str) -> Result<(), ChangeError> {
        let key = lookup_key(word).ok_or(ChangeError::BadWord)?;
        let mut next = self.current.dictionary.clone();
        let before = next.ignore.len();
        next.ignore.retain(|k| *k != key);
        if next.ignore.len() == before {
            return Err(ChangeError::NotFound);
        }
        self.commit(next)
    }

    /// Validates, persists, then publishes `next`.
    fn commit(&mut self, next: Dictionary) -> Result<(), ChangeError> {
        let bytes = serialize(&next);
        // The same checks as loading, so what is saved always loads.
        if parse(&bytes, Some(&self.tokenizer)).as_ref() != Ok(&next) {
            crate::error!("dictionary: a change failed validation; nothing saved");
            return Err(ChangeError::Storage);
        }
        let existed = fs::symlink_metadata(&self.path).is_ok();
        if let Err(e) = replace_file(&self.path, &bytes) {
            crate::warn!("dictionary: {e}; nothing changed");
            return Err(ChangeError::Storage);
        }
        if let Err(e) = self.sync_dir() {
            // The rename may not survive a crash: undo it, and never
            // acknowledge a change that might be lost.
            crate::warn!("dictionary: cannot sync its directory ({e}); the change is undone");
            self.recover(existed);
            return Err(ChangeError::Storage);
        }
        self.publish(next);
        Ok(())
    }

    fn publish(&mut self, dictionary: Dictionary) {
        self.current = Arc::new(Snapshot {
            revision: next_revision(),
            dictionary,
        });
    }

    /// After a failed directory sync: puts the previous file back (or
    /// removes the new one if there was none), then makes memory match
    /// whatever the file now holds, so memory never claims more than disk.
    fn recover(&mut self, existed: bool) {
        let undone = if self.skip_rollback() {
            Err("skipped".to_string())
        } else if existed {
            replace_file(&self.path, &serialize(&self.current.dictionary))
        } else {
            fs::remove_file(&self.path).map_err(|e| e.to_string())
        };
        match undone {
            Ok(()) => {
                if let Err(e) = self.sync_dir() {
                    crate::warn!("dictionary: cannot sync its directory after undoing ({e})");
                }
            }
            Err(e) => crate::warn!("dictionary: cannot undo the change ({e})"),
        }
        match read(&self.path, Some(&self.tokenizer)) {
            Ok(on_disk) if on_disk != self.current.dictionary => {
                crate::warn!("dictionary: the saved change remains in place");
                self.publish(on_disk);
            }
            Ok(_) => {}
            Err(e) => crate::warn!("dictionary: cannot read it back: {e}"),
        }
    }

    fn sync_dir(&mut self) -> std::io::Result<()> {
        #[cfg(test)]
        if self.faults.dir_syncs > 0 {
            self.faults.dir_syncs -= 1;
            return Err(std::io::Error::other("injected fault"));
        }
        let dir = self.path.parent().unwrap_or(Path::new("."));
        File::open(dir)?.sync_all()
    }

    fn skip_rollback(&self) -> bool {
        #[cfg(test)]
        return self.faults.no_rollback;
        #[cfg(not(test))]
        false
    }
}

/// Failures injected into [`Store`] writes (tests only).
#[cfg(test)]
#[derive(Default)]
struct Faults {
    /// The next this many directory syncs fail.
    dir_syncs: u32,
    /// Undoing a change after a failed sync fails.
    no_rollback: bool,
}

/// A strength as its shortest decimal, so the file reads `1.41`, not
/// `1.409999966621399` (both parse back to the same f32).
fn strength_value(s: f32) -> Value {
    format!("{s}")
        .parse::<f64>()
        .map_or(Value::Null, |v| json!(v))
}

fn serialize(d: &Dictionary) -> Vec<u8> {
    let entries: Vec<Value> = d
        .entries
        .iter()
        .map(|e| json!({"text": e.text, "strength": strength_value(e.strength)}))
        .collect();
    let doc = json!({"version": 1, "entries": entries, "ignore": d.ignore});
    let mut bytes = serde_json::to_vec_pretty(&doc).unwrap_or_default();
    bytes.push(b'\n');
    bytes
}

/// Parses and validates a dictionary file's bytes. With no tokenizer (a
/// client without the model), entries are checked except for encodability.
/// Errors describe structure only.
pub fn parse(bytes: &[u8], tokenizer: Option<&Tokenizer>) -> Result<Dictionary, &'static str> {
    let doc: Value = serde_json::from_slice(bytes).map_err(|_| "is not valid JSON")?;
    let obj = doc.as_object().ok_or("has an unexpected structure")?;
    if obj
        .keys()
        .any(|k| !matches!(k.as_str(), "version" | "entries" | "ignore"))
    {
        return Err("has unexpected fields");
    }
    if doc.get("version").and_then(Value::as_u64) != Some(1) {
        return Err("has an unsupported version");
    }
    let items = doc
        .get("entries")
        .and_then(Value::as_array)
        .ok_or("has an unexpected structure")?;
    if items.len() > MAX_ENTRIES {
        return Err("has too many entries");
    }
    let mut d = Dictionary::default();
    for item in items {
        let o = item.as_object().ok_or("has an invalid entry")?;
        if o.len() != 2 {
            return Err("has an invalid entry");
        }
        let text = o
            .get("text")
            .and_then(Value::as_str)
            .ok_or("has an invalid entry")?;
        let strength = o
            .get("strength")
            .and_then(Value::as_f64)
            .ok_or("has an invalid entry")? as f32;
        let entry = match tokenizer {
            Some(t) => rules::validate(text, strength, t),
            None => rules::normalize(text).and_then(|text| {
                Ok(DictionaryEntry {
                    text,
                    strength: check_strength(strength)?,
                })
            }),
        }
        .map_err(|_| "has an invalid entry")?;
        if entry.text != text {
            return Err("has an entry that is not normalized");
        }
        // Its identity key (without a tokenizer, control characters are
        // caught here).
        if !rules::valid_key(&entry.key()) {
            return Err("has an invalid entry");
        }
        if d.entries.iter().any(|e| e.key() == entry.key()) {
            return Err("has a repeated entry");
        }
        d.entries.push(entry);
    }
    let ignore = doc
        .get("ignore")
        .and_then(Value::as_array)
        .ok_or("has an unexpected structure")?;
    if ignore.len() > MAX_IGNORED {
        return Err("has too many ignored words");
    }
    for k in ignore {
        let k = k.as_str().ok_or("has an invalid ignored word")?;
        if !rules::valid_key(k) {
            return Err("has an invalid ignored word");
        }
        if d.ignore.iter().any(|x| x == k) {
            return Err("has a repeated ignored word");
        }
        d.ignore.push(k.to_owned());
    }
    Ok(d)
}

/// Reads `path` safely (see the module docs); a missing file is empty.
pub fn read(path: &Path, tokenizer: Option<&Tokenizer>) -> Result<Dictionary, String> {
    let name = || path.display().to_string();
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Dictionary::default()),
        Err(e) => return Err(format!("cannot open {}: {e}", name())),
    };
    let meta = file.metadata().map_err(|e| format!("{}: {e}", name()))?;
    if !meta.is_file() || meta.uid() != crate::paths::euid() || meta.mode() & 0o7777 != 0o600 {
        return Err(format!(
            "{} must be a regular file owned by the current user with mode 0600",
            name()
        ));
    }
    if meta.len() > MAX_FILE_BYTES {
        return Err(format!("{} is too large", name()));
    }
    let mut bytes = Vec::new();
    (&file)
        .take(MAX_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("cannot read {}: {e}", name()))?;
    if bytes.len() as u64 > MAX_FILE_BYTES {
        return Err(format!("{} is too large", name()));
    }
    parse(&bytes, tokenizer).map_err(|why| format!("{} {why}", name()))
}

fn temporary_prefix() -> String {
    format!(".{FILE_NAME}.tmp-")
}

/// Removes temporary dictionary files left by a crash during a write.
pub fn remove_stale_temporaries(dir: &Path) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let prefix = temporary_prefix();
    for entry in entries.flatten() {
        if entry.file_name().to_string_lossy().starts_with(&prefix)
            && let Err(e) = fs::remove_file(entry.path())
        {
            crate::warn!("dictionary: cannot remove a stale temporary file: {e}");
        }
    }
}

/// Writes `bytes` to a new 0600 file next to `path`, syncs it and renames
/// it over `path`. The caller syncs the directory.
fn replace_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let dir = path.parent().ok_or("the dictionary path has no parent")?;
    let tmp = dir.join(format!(
        "{}{}-{}",
        temporary_prefix(),
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let written = (|| -> std::io::Result<()> {
        let mut f = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        drop(f);
        fs::rename(&tmp, path)
    })();
    if let Err(e) = written {
        let _ = fs::remove_file(&tmp);
        return Err(format!("cannot write {}: {e}", path.display()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::{TempDir, synthetic_tokenizer};
    use std::os::unix::fs::PermissionsExt;

    fn setting(t: &TempDir) -> Setting {
        Setting {
            dir: t.path().join("data/localflow"),
            tokenizer: Arc::new(synthetic_tokenizer()),
        }
    }

    fn file(s: &Setting) -> PathBuf {
        s.dir.join(FILE_NAME)
    }

    fn write_file(s: &Setting, body: &str) {
        crate::paths::ensure_private_dir(&s.dir).unwrap();
        fs::write(file(s), body).unwrap();
        fs::set_permissions(file(s), fs::Permissions::from_mode(0o600)).unwrap();
    }

    fn texts(store: &Store) -> Vec<(String, f32)> {
        store
            .snapshot()
            .dictionary
            .entries
            .iter()
            .map(|e| (e.text.clone(), e.strength))
            .collect()
    }

    #[test]
    fn missing_file_is_empty_and_changes_persist() {
        let t = TempDir::new("dict");
        let s = setting(&t);
        let mut store = Store::open(&s).unwrap();
        assert_eq!(fs::metadata(&s.dir).unwrap().mode() & 0o777, 0o700);
        assert_eq!(store.snapshot().dictionary, Dictionary::default());
        let r0 = store.snapshot().revision;

        store.add("  Synthetic   Word ", 1.41).unwrap();
        store.add("Kubernetes", 1.0).unwrap();
        // The same identity key replaces text and strength.
        store.add("kubernetes", 2.0).unwrap();
        store.ignore("Cooper  Netties").unwrap();
        store.ignore("cooper netties").unwrap();
        assert!(store.snapshot().revision > r0);
        assert_eq!(
            texts(&store),
            [("Synthetic Word".into(), 1.41), ("kubernetes".into(), 2.0)]
        );
        assert_eq!(store.snapshot().dictionary.ignore, ["cooper netties"]);

        assert_eq!(fs::metadata(file(&s)).unwrap().mode() & 0o777, 0o600);
        let raw = fs::read_to_string(file(&s)).unwrap();
        assert!(raw.contains("1.41") && !raw.contains("1.409"), "{raw}");
        let reopened = Store::open(&s).unwrap();
        assert_eq!(reopened.snapshot().dictionary, store.snapshot().dictionary);
        // No temporary files left behind.
        assert_eq!(fs::read_dir(&s.dir).unwrap().count(), 1);

        store.remove("SYNTHETIC word").unwrap();
        store.unignore("Cooper Netties").unwrap();
        assert_eq!(texts(&store), [("kubernetes".into(), 2.0)]);
        assert!(store.snapshot().dictionary.ignore.is_empty());
        assert_eq!(store.remove("absent"), Err(ChangeError::NotFound));
        assert_eq!(store.unignore("absent"), Err(ChangeError::NotFound));
        assert_eq!(store.remove("  "), Err(ChangeError::BadWord));
        // P6: any valid key may be ignored, but not more than 8 words.
        assert_eq!(store.ignore("a b c d e f g h i"), Err(ChangeError::BadWord));
        assert_eq!(store.ignore(" \t "), Err(ChangeError::BadWord));
    }

    #[test]
    fn invalid_entries_and_capacity() {
        let t = TempDir::new("dict-cap");
        let s = setting(&t);
        let mut store = Store::open(&s).unwrap();
        assert_eq!(
            store.add("1234", 1.0),
            Err(ChangeError::InvalidEntry(EntryError::NoLetter))
        );
        assert_eq!(
            store.add("caf\u{e9}", 1.0),
            Err(ChangeError::InvalidEntry(EntryError::Unencodable))
        );
        assert_eq!(
            store.add("word", 4.5),
            Err(ChangeError::InvalidEntry(EntryError::BadStrength))
        );
        let word = |i: usize| {
            let mut n = i;
            let mut s = String::new();
            for _ in 0..3 {
                s.push((b'a' + (n % 26) as u8) as char);
                n /= 26;
            }
            s
        };
        for i in 0..MAX_ENTRIES {
            store.add(&word(i), 1.0).unwrap();
        }
        assert_eq!(store.add("zzzz", 1.0), Err(ChangeError::Full));
        // Replacing an existing key is not growth.
        store.add(&word(0).to_uppercase(), 2.0).unwrap();
        let reopened = Store::open(&s).unwrap();
        assert_eq!(reopened.snapshot().dictionary.entries.len(), MAX_ENTRIES);
        for i in 0..MAX_IGNORED {
            store.ignore(&word(i)).unwrap();
        }
        assert_eq!(store.ignore("zzzz"), Err(ChangeError::Full));
        store.ignore(&word(5)).unwrap();
    }

    #[test]
    fn a_failed_write_changes_nothing() {
        let t = TempDir::new("dict-fail");
        let s = setting(&t);
        let mut store = Store::open(&s).unwrap();
        store.add("Synthetic", 1.0).unwrap();
        let before = fs::read(file(&s)).unwrap();
        let snap = store.snapshot();
        // The temporary file cannot be created in a read-only directory.
        fs::set_permissions(&s.dir, fs::Permissions::from_mode(0o500)).unwrap();
        assert_eq!(store.add("Other", 1.0), Err(ChangeError::Storage));
        assert_eq!(store.remove("Synthetic"), Err(ChangeError::Storage));
        assert_eq!(store.ignore("Other"), Err(ChangeError::Storage));
        fs::set_permissions(&s.dir, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(Arc::ptr_eq(&snap, &store.snapshot()), "memory unchanged");
        assert_eq!(fs::read(file(&s)).unwrap(), before, "disk unchanged");
        assert_eq!(fs::read_dir(&s.dir).unwrap().count(), 1);
    }

    #[test]
    fn unsafe_files_are_refused_without_quoting_content() {
        let t = TempDir::new("dict-unsafe");
        let s = setting(&t);
        let secret = "SyntheticSecretWord";
        let good = format!(
            "{{\"version\":1,\"entries\":[{{\"text\":\"{secret}\",\"strength\":1}}],\"ignore\":[]}}"
        );
        write_file(&s, &good);
        assert_eq!(
            Store::open(&s).unwrap().snapshot().dictionary.entries.len(),
            1
        );

        fs::set_permissions(file(&s), fs::Permissions::from_mode(0o644)).unwrap();
        let e = Store::open(&s).err().unwrap();
        assert!(e.contains("0600") && !e.contains(secret), "{e}");
        fs::set_permissions(file(&s), fs::Permissions::from_mode(0o400)).unwrap();
        assert!(Store::open(&s).is_err());

        // A symlink is not followed.
        fs::remove_file(file(&s)).unwrap();
        let target = t.path().join("elsewhere.json");
        fs::write(&target, &good).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
        std::os::unix::fs::symlink(&target, file(&s)).unwrap();
        assert!(Store::open(&s).is_err());
        fs::remove_file(file(&s)).unwrap();

        // A FIFO does not block, and is refused.
        let c = std::ffi::CString::new(file(&s).as_os_str().as_encoded_bytes()).unwrap();
        // SAFETY: valid NUL-terminated path.
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        assert!(Store::open(&s).is_err());
        fs::remove_file(file(&s)).unwrap();

        // Oversized.
        write_file(&s, &" ".repeat(MAX_FILE_BYTES as usize + 1));
        assert!(Store::open(&s).err().unwrap().contains("too large"));

        // A loose data directory is refused, not repaired.
        fs::remove_file(file(&s)).unwrap();
        fs::set_permissions(&s.dir, fs::Permissions::from_mode(0o750)).unwrap();
        assert!(Store::open(&s).is_err());
        fs::set_permissions(&s.dir, fs::Permissions::from_mode(0o700)).unwrap();
    }

    #[test]
    fn invalid_contents_are_refused_without_quoting_them() {
        let t = TempDir::new("dict-bad");
        let s = setting(&t);
        let w = "SyntheticSecret";
        let many: Vec<String> = (0..=MAX_ENTRIES)
            .map(|i| format!("{{\"text\":\"w{i}\",\"strength\":1}}"))
            .collect();
        let many_ignored: Vec<String> = (0..=MAX_IGNORED).map(|i| format!("\"w{i}\"")).collect();
        for body in [
            format!("not json {w}"),
            "[]".into(),
            format!("{{\"version\":2,\"entries\":[],\"ignore\":[\"{w}\"]}}"),
            "{\"version\":1,\"entries\":[]}".into(),
            format!("{{\"version\":1,\"entries\":[],\"ignore\":[],\"x\":\"{w}\"}}"),
            format!("{{\"version\":1,\"entries\":[{{\"text\":\"{w}\"}}],\"ignore\":[]}}"),
            format!(
                "{{\"version\":1,\"entries\":[{{\"text\":\"{w}\",\"strength\":9}}],\"ignore\":[]}}"
            ),
            format!(
                "{{\"version\":1,\"entries\":[{{\"text\":\" {w}\",\"strength\":1}}],\"ignore\":[]}}"
            ),
            format!(
                "{{\"version\":1,\"entries\":[{{\"text\":\"{w}\",\"strength\":1,\"y\":0}}],\"ignore\":[]}}"
            ),
            format!(
                "{{\"version\":1,\"entries\":[{{\"text\":\"caf\u{e9}{w}\",\"strength\":1}}],\"ignore\":[]}}"
            ),
            format!(
                "{{\"version\":1,\"entries\":[{{\"text\":\"{w}\",\"strength\":1}},{{\"text\":\"{}\",\"strength\":2}}],\"ignore\":[]}}",
                w.to_lowercase()
            ),
            format!("{{\"version\":1,\"entries\":[],\"ignore\":[\"{w}\"]}}"),
            "{\"version\":1,\"entries\":[],\"ignore\":[\"a\",\"a\"]}".into(),
            format!(
                "{{\"version\":1,\"entries\":[{}],\"ignore\":[]}}",
                many.join(",")
            ),
            format!(
                "{{\"version\":1,\"entries\":[],\"ignore\":[{}]}}",
                many_ignored.join(",")
            ),
        ] {
            write_file(&s, &body);
            let e = Store::open(&s)
                .err()
                .unwrap_or_else(|| panic!("accepted {body:.80}"));
            assert!(!e.contains(w) && !e.contains(&w.to_lowercase()), "{e}");
        }
        // Without a tokenizer (a client), encodability is not checked.
        write_file(
            &s,
            "{\"version\":1,\"entries\":[{\"text\":\"caf\u{e9}\",\"strength\":1}],\"ignore\":[\"a b\"]}",
        );
        let d = read(&file(&s), None).unwrap();
        assert_eq!(d.entries.len(), 1);
        assert_eq!(d.ignore, ["a b"]);
        assert!(read(&file(&s), Some(&synthetic_tokenizer())).is_err());
    }

    #[test]
    fn a_failed_directory_sync_is_undone_and_refused() {
        let t = TempDir::new("dict-dirsync");
        let s = setting(&t);
        let mut store = Store::open(&s).unwrap();

        // The very first write: the new file is removed again.
        store.faults.dir_syncs = 1;
        assert_eq!(store.add("Synthetic", 1.0), Err(ChangeError::Storage));
        assert!(store.snapshot().dictionary.entries.is_empty());
        assert!(!file(&s).exists());

        store.add("Synthetic", 1.0).unwrap();
        let before = store.snapshot();
        let saved = read(&file(&s), None).unwrap();

        // Rename done, directory sync fails: the old file is put back.
        store.faults.dir_syncs = 1;
        assert_eq!(store.add("Other", 2.0), Err(ChangeError::Storage));
        assert!(Arc::ptr_eq(&before, &store.snapshot()), "memory unchanged");
        assert_eq!(read(&file(&s), None).unwrap(), saved, "disk as before");

        // The sync after undoing fails too: the undo is still in place.
        store.faults.dir_syncs = 2;
        assert_eq!(store.remove("Synthetic"), Err(ChangeError::Storage));
        assert!(Arc::ptr_eq(&before, &store.snapshot()));
        assert_eq!(read(&file(&s), None).unwrap(), saved);
        assert_eq!(fs::metadata(file(&s)).unwrap().mode() & 0o777, 0o600);

        // Undoing fails: memory follows the file that remains, and the
        // change is still refused.
        store.faults.dir_syncs = 1;
        store.faults.no_rollback = true;
        assert_eq!(store.ignore("Other"), Err(ChangeError::Storage));
        store.faults.no_rollback = false;
        let after = store.snapshot();
        assert!(after.revision != before.revision);
        assert_eq!(after.dictionary, read(&file(&s), None).unwrap());
        assert_eq!(after.dictionary.ignore, ["other"]);
        // No temporary files are left behind.
        assert_eq!(fs::read_dir(&s.dir).unwrap().count(), 1);
        // And it all still loads.
        assert_eq!(
            Store::open(&s).unwrap().snapshot().dictionary,
            after.dictionary
        );
    }

    #[test]
    fn expanded_keys_round_trip() {
        // P6: fold("İ" + 99 × "a") has 101 scalars and is a valid key.
        let t = TempDir::new("dict-keys");
        let s = setting(&t);
        let mut store = Store::open(&s).unwrap();
        let word = format!("\u{130}{}", "a".repeat(99));
        store.ignore(&word).unwrap();
        let key = fold(&word);
        assert_eq!(
            store.snapshot().dictionary.ignore,
            std::slice::from_ref(&key)
        );
        let reopened = Store::open(&s).unwrap();
        assert_eq!(reopened.snapshot().dictionary.ignore, [key]);
        // Keys a dictionary file may not hold.
        for bad in ["NixOS", "a\\u0007b", "a b c d e f g h i", ""] {
            write_file(
                &s,
                &format!("{{\"version\":1,\"entries\":[],\"ignore\":[\"{bad}\"]}}"),
            );
            assert!(Store::open(&s).is_err(), "{bad:?}");
        }
        write_file(
            &s,
            &format!(
                "{{\"version\":1,\"entries\":[],\"ignore\":[\"{}\"]}}",
                "a".repeat(301)
            ),
        );
        assert!(Store::open(&s).is_err());
    }

    #[test]
    fn stale_temporaries_are_removed() {
        let t = TempDir::new("dict-tmp");
        let s = setting(&t);
        crate::paths::ensure_private_dir(&s.dir).unwrap();
        let stale = s.dir.join(".dictionary.json.tmp-1-0");
        fs::write(&stale, b"synthetic").unwrap();
        Store::open(&s).unwrap();
        assert!(!stale.exists());
    }

    #[test]
    fn debug_shows_counts_only() {
        let d = Dictionary {
            entries: vec![DictionaryEntry {
                text: "Synthetic".into(),
                strength: 1.0,
            }],
            ignore: vec!["secretword".into()],
        };
        let s = format!(
            "{d:?} {:?}",
            Snapshot {
                revision: 3,
                dictionary: d.clone()
            }
        );
        assert!(!s.contains("Synthetic") && !s.contains("secretword"), "{s}");
    }
}

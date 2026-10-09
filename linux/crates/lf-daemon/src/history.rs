//! Transcript history: the last [`CAPACITY`] dictations, in
//! `$XDG_DATA_HOME/localflow/history.json` (mode 0600, in a 0700 directory),
//! replaced atomically on every change. Only text is stored, never audio.
//! When history is turned off the daemon neither reads nor writes the file.

use std::collections::VecDeque;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{Value, json};

pub const CAPACITY: usize = 20;
pub const FILE_NAME: &str = "history.json";
const MAX_FILE_BYTES: u64 = 8 << 20;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    /// Seconds since the Unix epoch.
    pub time: u64,
    /// What the recognizer heard, after removing a trailing "press enter".
    pub raw: String,
    /// What was typed.
    pub text: String,
}

pub struct History {
    path: PathBuf,
    entries: VecDeque<Entry>,
}

impl History {
    /// Opens the history in `dir` (created 0700 if missing). An unreadable or
    /// invalid file is reported and replaced on the next write.
    /// Also removes temporary files left by an interrupted write; call it
    /// while holding the instance lock.
    pub fn open(dir: &Path) -> Result<History, String> {
        crate::paths::ensure_private_dir(dir)?;
        remove_stale_temporaries(dir);
        let path = dir.join(FILE_NAME);
        let entries = match read(&path) {
            Ok(e) => e,
            Err(e) => {
                crate::warn!("history: {e}; starting a new history");
                VecDeque::new()
            }
        };
        Ok(History { path, entries })
    }

    pub fn entries(&self) -> impl Iterator<Item = &Entry> {
        self.entries.iter()
    }

    /// Appends an entry, keeping the newest [`CAPACITY`], and saves.
    pub fn push(&mut self, entry: Entry) -> Result<(), String> {
        self.entries.push_back(entry);
        while self.entries.len() > CAPACITY {
            self.entries.pop_front();
        }
        self.save()
    }

    fn save(&self) -> Result<(), String> {
        let entries: Vec<Value> = self
            .entries
            .iter()
            .map(|e| json!({"time": e.time, "raw": e.raw, "text": e.text}))
            .collect();
        let doc = json!({"version": 1, "entries": entries});
        let bytes = serde_json::to_vec_pretty(&doc).map_err(|e| e.to_string())?;
        write_atomic(&self.path, &bytes)
    }
}

fn read(path: &Path) -> Result<VecDeque<Entry>, String> {
    let file = match OpenOptions::new()
        .read(true)
        // Non-blocking so a FIFO planted here cannot hang startup; regular
        // files ignore the flag.
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(VecDeque::new()),
        Err(e) => return Err(format!("cannot open {}: {e}", path.display())),
    };
    let meta = file.metadata().map_err(|e| e.to_string())?;
    if !meta.is_file() || meta.uid() != crate::paths::euid() {
        return Err(format!(
            "{} is not a regular file owned by the current user",
            path.display()
        ));
    }
    if meta.len() > MAX_FILE_BYTES {
        return Err(format!("{} is too large", path.display()));
    }
    let mut bytes = Vec::new();
    (&file)
        .take(MAX_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    if bytes.len() as u64 > MAX_FILE_BYTES {
        return Err(format!("{} is too large", path.display()));
    }
    // Errors below describe structure only; serde_json syntax errors carry
    // positions, not content.
    let doc: Value = serde_json::from_slice(&bytes)
        .map_err(|e| format!("{} is not valid JSON ({e})", path.display()))?;
    let invalid = || format!("{} has an unexpected structure", path.display());
    if doc.get("version").and_then(Value::as_u64) != Some(1) {
        return Err(invalid());
    }
    let items = doc
        .get("entries")
        .and_then(Value::as_array)
        .ok_or_else(invalid)?;
    let mut entries = VecDeque::new();
    for item in items {
        let entry = (|| {
            Some(Entry {
                time: item.get("time")?.as_u64()?,
                raw: item.get("raw")?.as_str()?.to_owned(),
                text: item.get("text")?.as_str()?.to_owned(),
            })
        })()
        .ok_or_else(invalid)?;
        entries.push_back(entry);
    }
    while entries.len() > CAPACITY {
        entries.pop_front();
    }
    Ok(entries)
}

/// Where history is kept, and whether it is on.
#[derive(Clone, Debug)]
pub struct Setting {
    pub dir: PathBuf,
    pub enabled: bool,
}

fn temporary_prefix() -> String {
    format!(".{FILE_NAME}.tmp-")
}

/// Removes temporary history snapshots left by a crash during a write
/// (they hold transcripts). Done even when history is off.
pub fn remove_stale_temporaries(dir: &Path) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let prefix = temporary_prefix();
    for entry in entries.flatten() {
        if entry.file_name().to_string_lossy().starts_with(&prefix)
            && let Err(e) = fs::remove_file(entry.path())
        {
            crate::warn!("history: cannot remove a stale temporary file: {e}");
        }
    }
}

/// Writes `bytes` to a new 0600 file next to `path`, syncs it, renames it
/// over `path` and syncs the directory.
fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let dir = path.parent().ok_or("history path has no parent")?;
    let tmp = dir.join(format!(
        "{}{}-{}",
        temporary_prefix(),
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let result = (|| -> std::io::Result<()> {
        let mut f = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        drop(f);
        fs::rename(&tmp, path)?;
        File::open(dir)?.sync_all()
    })();
    result.map_err(|e| {
        let _ = fs::remove_file(&tmp);
        format!("cannot write {}: {e}", path.display())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::TempDir;

    fn entry(i: u64) -> Entry {
        Entry {
            time: i,
            raw: format!("synthetic raw {i}"),
            text: format!("synthetic text {i}"),
        }
    }

    #[test]
    fn keeps_last_twenty_and_persists() {
        let t = TempDir::new("history");
        let dir = t.path().join("data/localflow");
        let mut h = History::open(&dir).unwrap();
        assert_eq!(h.entries().count(), 0);
        for i in 0..25 {
            h.push(entry(i)).unwrap();
        }
        assert_eq!(h.entries().count(), CAPACITY);
        assert_eq!(h.entries().next().unwrap().time, 5);

        let path = dir.join(FILE_NAME);
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
        assert_eq!(fs::metadata(&dir).unwrap().mode() & 0o777, 0o700);

        let reopened = History::open(&dir).unwrap();
        let times: Vec<u64> = reopened.entries().map(|e| e.time).collect();
        assert_eq!(times, (5..25).collect::<Vec<_>>());
        assert_eq!(reopened.entries().last().unwrap(), &entry(24));
        // No temporary files left behind.
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
    }

    #[test]
    fn invalid_file_starts_fresh_and_is_replaced() {
        let t = TempDir::new("history-bad");
        let dir = t.path().join("localflow");
        crate::paths::ensure_private_dir(&dir).unwrap();
        let path = dir.join(FILE_NAME);
        for bad in [
            &b"not json"[..],
            b"[]",
            b"{\"version\": 2, \"entries\": []}",
            b"{\"version\": 1, \"entries\": [{\"time\": 1}]}",
        ] {
            fs::write(&path, bad).unwrap();
            let mut h = History::open(&dir).unwrap();
            assert_eq!(h.entries().count(), 0);
            h.push(entry(1)).unwrap();
            assert_eq!(History::open(&dir).unwrap().entries().count(), 1);
        }
    }

    #[test]
    fn replaces_loose_permissions_and_refuses_symlinks() {
        let t = TempDir::new("history-perm");
        let dir = t.path().join("localflow");
        crate::paths::ensure_private_dir(&dir).unwrap();
        let path = dir.join(FILE_NAME);
        fs::write(&path, b"{\"version\": 1, \"entries\": []}").unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        let mut h = History::open(&dir).unwrap();
        h.push(entry(1)).unwrap();
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o600);

        // A symlinked history file is not followed for reading.
        let target = t.path().join("elsewhere.json");
        fs::write(
            &target,
            b"{\"version\": 1, \"entries\": [{\"time\": 9, \"raw\": \"r\", \"text\": \"t\"}]}",
        )
        .unwrap();
        fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(&target, &path).unwrap();
        let mut h = History::open(&dir).unwrap();
        assert_eq!(h.entries().count(), 0);
        // Writing replaces the link itself, leaving the target untouched.
        h.push(entry(2)).unwrap();
        assert!(fs::symlink_metadata(&path).unwrap().is_file());
        assert!(fs::read_to_string(&target).unwrap().contains("\"time\": 9"));
    }

    #[test]
    fn removes_stale_temporaries() {
        let t = TempDir::new("history-tmp");
        let dir = t.path().join("localflow");
        crate::paths::ensure_private_dir(&dir).unwrap();
        let stale = dir.join(".history.json.tmp-1-0");
        fs::write(&stale, b"synthetic").unwrap();
        let other = dir.join("unrelated");
        fs::write(&other, b"").unwrap();
        History::open(&dir).unwrap();
        assert!(!stale.exists());
        assert!(other.exists());
        // Also when history is off.
        fs::write(&stale, b"synthetic").unwrap();
        remove_stale_temporaries(&dir);
        assert!(!stale.exists());
        // A missing directory is fine.
        remove_stale_temporaries(&t.path().join("missing"));
    }

    #[test]
    fn a_fifo_does_not_block_opening() {
        let t = TempDir::new("history-fifo");
        let dir = t.path().join("localflow");
        crate::paths::ensure_private_dir(&dir).unwrap();
        let path =
            std::ffi::CString::new(dir.join(FILE_NAME).as_os_str().as_encoded_bytes()).unwrap();
        // SAFETY: valid NUL-terminated path.
        assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
        let h = History::open(&dir).unwrap();
        assert_eq!(h.entries().count(), 0);
    }
}

//! Reading and replacing the daemon's own files: history, the dictionary
//! and the tokens.
//!
//! - [`read_private`] opens with `O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC` (a
//!   symlink is refused and a FIFO cannot block), then checks the opened
//!   file: regular, owned by the effective uid, its mode allowed by a
//!   [`ModeRule`], at most `max` bytes, and reads at most `max + 1` bytes
//!   so a file that grows after the check is still refused.
//! - [`read_regular`] is the same without the symlink, owner and mode
//!   checks, for files the user may manage elsewhere (the config file).
//! - [`write_atomic`] writes a new 0600 temporary file next to the target,
//!   syncs it and renames it over the target; [`remove_stale`] deletes the
//!   temporaries a crash left behind.
//!
//! Errors carry I/O errors and modes, never file contents; callers turn
//! them into their own messages.

use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

/// Which permission bits a private file may have.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModeRule {
    Any,
    /// Exactly 0600 (no setuid, setgid or sticky bits either).
    Exact0600,
    /// No group or other bits.
    NoGroupOther,
}

impl ModeRule {
    fn allows(self, mode: u32) -> bool {
        match self {
            ModeRule::Any => true,
            ModeRule::Exact0600 => mode & 0o7777 == 0o600,
            ModeRule::NoGroupOther => mode & 0o077 == 0,
        }
    }
}

/// Why a file was not read. A missing file is not an error.
#[derive(Debug)]
pub enum ReadError {
    /// Opening failed for a reason other than the file not existing
    /// (`ELOOP` for a refused symlink).
    Open(io::Error),
    /// The opened file's metadata could not be read.
    Metadata(io::Error),
    NotRegular,
    WrongOwner,
    /// The mode is not allowed (the permission bits, `& 0o7777`).
    Mode(u32),
    /// Larger than the limit.
    TooLarge,
    Read(io::Error),
}

/// Reads a private file (see the module docs); `Ok(None)` if it does not
/// exist.
pub fn read_private(path: &Path, max: u64, rule: ModeRule) -> Result<Option<Vec<u8>>, ReadError> {
    let Some((file, meta)) = open(path, libc::O_NOFOLLOW)? else {
        return Ok(None);
    };
    if meta.uid() != crate::paths::euid() {
        return Err(ReadError::WrongOwner);
    }
    if !rule.allows(meta.mode()) {
        return Err(ReadError::Mode(meta.mode() & 0o7777));
    }
    read_bounded(&file, &meta, max).map(Some)
}

/// Reads a regular file of at most `max` bytes, following symlinks, with
/// no owner or mode check; `Ok(None)` if it does not exist.
pub fn read_regular(path: &Path, max: u64) -> Result<Option<Vec<u8>>, ReadError> {
    let Some((file, meta)) = open(path, 0)? else {
        return Ok(None);
    };
    read_bounded(&file, &meta, max).map(Some)
}

/// Opens `path` without blocking and checks it is a regular file.
fn open(path: &Path, flags: libc::c_int) -> Result<Option<(File, Metadata)>, ReadError> {
    let file = match OpenOptions::new()
        .read(true)
        // Non-blocking so a FIFO cannot hang the open; regular files ignore
        // the flag.
        .custom_flags(flags | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(f) => f,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(ReadError::Open(e)),
    };
    let meta = file.metadata().map_err(ReadError::Metadata)?;
    if !meta.is_file() {
        return Err(ReadError::NotRegular);
    }
    Ok(Some((file, meta)))
}

fn read_bounded(file: &File, meta: &Metadata, max: u64) -> Result<Vec<u8>, ReadError> {
    if meta.len() > max {
        return Err(ReadError::TooLarge);
    }
    let mut bytes = Vec::new();
    file.take(max.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(ReadError::Read)?;
    if bytes.len() as u64 > max {
        return Err(ReadError::TooLarge);
    }
    Ok(bytes)
}

/// Whether [`write_atomic`] syncs the directory after the rename.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SyncDir {
    Yes,
    /// The caller syncs it (with [`sync_dir`]).
    No,
}

fn temporary_prefix(file_name: &str) -> String {
    format!(".{file_name}.tmp-")
}

/// Replaces `path` with `bytes` (mode 0600): see the module docs. The
/// temporary file is removed on failure.
pub fn write_atomic(path: &Path, bytes: &[u8], sync: SyncDir) -> io::Result<()> {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let (Some(dir), Some(name)) = (path.parent(), path.file_name()) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "the path has no parent directory",
        ));
    };
    let tmp = dir.join(format!(
        "{}{}-{}",
        temporary_prefix(&name.to_string_lossy()),
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let result = (|| -> io::Result<()> {
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
        match sync {
            SyncDir::Yes => sync_dir(path),
            SyncDir::No => Ok(()),
        }
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

/// Syncs the directory holding `path`, making a rename in it durable.
pub fn sync_dir(path: &Path) -> io::Result<()> {
    let dir = match path.parent() {
        Some(d) if !d.as_os_str().is_empty() => d,
        _ => Path::new("."),
    };
    File::open(dir)?.sync_all()
}

/// Removes the temporary files [`write_atomic`] left in `dir` for the file
/// named `file_name`. A missing directory is fine; returns the errors of
/// the removals that failed.
pub fn remove_stale(dir: &Path, file_name: &str) -> Vec<io::Error> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let prefix = temporary_prefix(file_name);
    entries
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with(&prefix))
        .filter_map(|e| fs::remove_file(e.path()).err())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::TempDir;
    use std::os::unix::fs::PermissionsExt;

    fn write_mode(path: &Path, content: &[u8], mode: u32) {
        let _ = fs::remove_file(path);
        fs::write(path, content).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
    }

    fn mkfifo(path: &Path) {
        let c = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
        // SAFETY: valid NUL-terminated path.
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    }

    #[test]
    fn missing_files_are_none() {
        let t = TempDir::new("pf-missing");
        let p = t.path().join("missing");
        assert!(matches!(read_private(&p, 10, ModeRule::Any), Ok(None)));
        assert!(matches!(read_regular(&p, 10), Ok(None)));
        let deep = t.path().join("no/such/dir/file");
        assert!(matches!(read_private(&deep, 10, ModeRule::Any), Ok(None)));
        assert!(matches!(read_regular(&deep, 10), Ok(None)));
        // A dangling symlink is missing for `read_regular`, refused for
        // `read_private`.
        std::os::unix::fs::symlink(t.path().join("nowhere"), &p).unwrap();
        assert!(matches!(read_regular(&p, 10), Ok(None)));
        assert!(matches!(
            read_private(&p, 10, ModeRule::Any),
            Err(ReadError::Open(e)) if e.raw_os_error() == Some(libc::ELOOP)
        ));
    }

    #[test]
    fn mode_rules() {
        let t = TempDir::new("pf-mode");
        let p = t.path().join("file");
        let cases: [(u32, bool, bool); 7] = [
            // (mode, Exact0600, NoGroupOther)
            (0o600, true, true),
            (0o400, false, true),
            (0o700, false, true),
            (0o640, false, false),
            (0o604, false, false),
            (0o644, false, false),
            (0o666, false, false),
        ];
        for (mode, exact, private) in cases {
            write_mode(&p, b"synthetic", mode);
            let read = |rule| read_private(&p, 100, rule);
            assert_eq!(read(ModeRule::Any).unwrap().unwrap(), b"synthetic");
            for (rule, allowed) in [
                (ModeRule::Exact0600, exact),
                (ModeRule::NoGroupOther, private),
            ] {
                match read(rule) {
                    Ok(Some(b)) => assert!(allowed && b == b"synthetic", "{mode:o} {rule:?}"),
                    Err(ReadError::Mode(m)) => {
                        assert!(!allowed, "{mode:o} {rule:?}");
                        assert_eq!(m, mode);
                    }
                    other => panic!("{mode:o} {rule:?}: {other:?}"),
                }
            }
        }
        // Special bits count for Exact0600 only. The Nix build sandbox
        // refuses setuid and setgid bits (EPERM), so 0o4600 is checked only
        // where it can be set; the sticky bit always can.
        for mode in [0o1600, 0o4600] {
            let _ = fs::remove_file(&p);
            fs::write(&p, b"synthetic").unwrap();
            match fs::set_permissions(&p, fs::Permissions::from_mode(mode)) {
                Ok(()) => {}
                Err(e) if mode == 0o4600 && e.raw_os_error() == Some(libc::EPERM) => continue,
                Err(e) => panic!("{mode:o}: {e}"),
            }
            assert!(
                matches!(
                    read_private(&p, 100, ModeRule::Exact0600),
                    Err(ReadError::Mode(m)) if m == mode
                ),
                "{mode:o}"
            );
            assert!(
                read_private(&p, 100, ModeRule::NoGroupOther)
                    .unwrap()
                    .is_some(),
                "{mode:o}"
            );
        }
    }

    #[test]
    fn size_limit() {
        let t = TempDir::new("pf-size");
        let p = t.path().join("file");
        write_mode(&p, &[b'x'; 64], 0o600);
        assert_eq!(
            read_private(&p, 64, ModeRule::Exact0600)
                .unwrap()
                .unwrap()
                .len(),
            64
        );
        assert_eq!(read_regular(&p, 64).unwrap().unwrap().len(), 64);
        assert!(matches!(
            read_private(&p, 63, ModeRule::Exact0600),
            Err(ReadError::TooLarge)
        ));
        assert!(matches!(read_regular(&p, 63), Err(ReadError::TooLarge)));
        write_mode(&p, b"", 0o600);
        assert_eq!(read_private(&p, 0, ModeRule::Any).unwrap().unwrap(), b"");
    }

    #[test]
    fn irregular_files_are_refused_without_blocking() {
        let t = TempDir::new("pf-irregular");
        let dir = t.path().join("dir");
        fs::create_dir(&dir).unwrap();
        assert!(matches!(
            read_private(&dir, 10, ModeRule::Any),
            Err(ReadError::NotRegular)
        ));
        assert!(matches!(read_regular(&dir, 10), Err(ReadError::NotRegular)));

        let fifo = t.path().join("fifo");
        mkfifo(&fifo);
        assert!(matches!(
            read_private(&fifo, 10, ModeRule::Any),
            Err(ReadError::NotRegular)
        ));
        assert!(matches!(
            read_regular(&fifo, 10),
            Err(ReadError::NotRegular)
        ));
        // Also through a symlink.
        let link = t.path().join("link");
        std::os::unix::fs::symlink(&fifo, &link).unwrap();
        assert!(matches!(
            read_regular(&link, 10),
            Err(ReadError::NotRegular)
        ));
    }

    #[test]
    fn symlinks_are_refused_only_by_read_private() {
        let t = TempDir::new("pf-link");
        let target = t.path().join("target");
        write_mode(&target, b"synthetic", 0o444);
        let link = t.path().join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(matches!(
            read_private(&link, 100, ModeRule::Any),
            Err(ReadError::Open(e)) if e.raw_os_error() == Some(libc::ELOOP)
        ));
        // Any owner and mode: the config may live in the read-only store.
        assert_eq!(read_regular(&link, 100).unwrap().unwrap(), b"synthetic");
    }

    #[test]
    fn errors_never_hold_contents() {
        let t = TempDir::new("pf-errors");
        let p = t.path().join("file");
        let secret = "SyntheticSecretContent";
        write_mode(&p, secret.as_bytes(), 0o644);
        let e = read_private(&p, 100, ModeRule::Exact0600).unwrap_err();
        assert!(!format!("{e:?}").contains(secret));
        let e = read_private(&p, 4, ModeRule::Any).unwrap_err();
        assert!(!format!("{e:?}").contains(secret));
    }

    #[test]
    fn writes_privately_and_replaces() {
        let t = TempDir::new("pf-write");
        let p = t.path().join("data.json");
        for sync in [SyncDir::Yes, SyncDir::No] {
            write_atomic(&p, b"synthetic one", sync).unwrap();
            assert_eq!(fs::read(&p).unwrap(), b"synthetic one");
            assert_eq!(fs::metadata(&p).unwrap().mode() & 0o7777, 0o600);
            // A loose existing file is replaced by a private one.
            fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
            write_atomic(&p, b"synthetic two", sync).unwrap();
            assert_eq!(fs::read(&p).unwrap(), b"synthetic two");
            assert_eq!(fs::metadata(&p).unwrap().mode() & 0o7777, 0o600);
        }
        sync_dir(&p).unwrap();
        // Only the file remains.
        assert_eq!(fs::read_dir(t.path()).unwrap().count(), 1);
    }

    #[test]
    fn writing_replaces_a_symlink_not_its_target() {
        let t = TempDir::new("pf-write-link");
        let target = t.path().join("elsewhere");
        fs::write(&target, b"synthetic target").unwrap();
        let p = t.path().join("data.json");
        std::os::unix::fs::symlink(&target, &p).unwrap();
        write_atomic(&p, b"synthetic", SyncDir::Yes).unwrap();
        assert!(fs::symlink_metadata(&p).unwrap().is_file());
        assert_eq!(fs::read(&target).unwrap(), b"synthetic target");
    }

    #[test]
    fn a_failed_write_leaves_nothing() {
        let t = TempDir::new("pf-write-fail");
        let dir = t.path().join("dir");
        fs::create_dir(&dir).unwrap();
        let p = dir.join("data.json");
        write_atomic(&p, b"synthetic", SyncDir::Yes).unwrap();
        // The rename fails: a directory is in the way of a second target.
        let blocked = dir.join("blocked");
        fs::create_dir(&blocked).unwrap();
        fs::write(blocked.join("x"), b"").unwrap();
        assert!(write_atomic(&blocked, b"synthetic", SyncDir::Yes).is_err());
        let mut names: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        names.sort();
        assert_eq!(names, ["blocked", "data.json"]);
        // No parent at all.
        assert!(write_atomic(Path::new("/"), b"synthetic", SyncDir::Yes).is_err());
    }

    #[test]
    fn stale_temporaries_are_removed_by_name() {
        let t = TempDir::new("pf-stale");
        let dir = t.path();
        let ours = [".data.json.tmp-1-0", ".data.json.tmp-999"];
        let others = ["data.json", ".other.json.tmp-1-0", ".data.json.tm", "x"];
        for name in ours.iter().chain(&others) {
            fs::write(dir.join(name), b"synthetic").unwrap();
        }
        assert!(remove_stale(dir, "data.json").is_empty());
        for name in ours {
            assert!(!dir.join(name).exists(), "{name}");
        }
        for name in others {
            assert!(dir.join(name).exists(), "{name}");
        }
        assert!(remove_stale(&dir.join("missing"), "data.json").is_empty());
    }

    #[test]
    fn write_then_read_round_trips() {
        let t = TempDir::new("pf-round");
        let p = t.path().join("token");
        write_atomic(&p, b"synthetic-token", SyncDir::Yes).unwrap();
        assert_eq!(
            read_private(&p, 64, ModeRule::Exact0600).unwrap().unwrap(),
            b"synthetic-token"
        );
        // A temporary left by the write in progress would be stale.
        assert!(remove_stale(t.path(), "token").is_empty());
        assert!(p.exists());
    }
}

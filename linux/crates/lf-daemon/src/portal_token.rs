//! The RemoteDesktop portal's restore token (`output: "portal"`), kept so
//! the desktop asks for permission once rather than every run.
//!
//! The token is not user content, but it stands for the permission the user
//! granted, so it is treated as a credential:
//! `$XDG_STATE_HOME/localflow/portal-restore-token`, directory 0700, file
//! exactly 0600 and owned by the user, opened without following symlinks,
//! replaced atomically. It is never logged and never appears in errors. A
//! file that fails these checks is ignored (the desktop asks again) with a
//! warning that names only the problem.

use std::fs;
use std::path::{Path, PathBuf};

use lf_portal::TokenStore;

use crate::paths;
use crate::private_file::{self, ModeRule, ReadError, SyncDir};

pub const FILE_NAME: &str = "portal-restore-token";
/// Longest token accepted from the file.
const MAX_TOKEN_BYTES: u64 = 4096;

pub struct FileTokenStore {
    dir: PathBuf,
}

impl FileTokenStore {
    /// Keeps the token in `dir` (created 0700 on the first save).
    pub fn new(dir: PathBuf) -> FileTokenStore {
        FileTokenStore { dir }
    }
}

/// The stored token; `Ok(None)` if there is none.
fn read(dir: &Path) -> Result<Option<String>, &'static str> {
    match fs::symlink_metadata(dir) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("its directory cannot be read"),
        Ok(_) => {}
    }
    paths::check_private_dir(dir).map_err(|_| "its directory is not private")?;
    // Snapshots left by a crash during a write hold the token too.
    private_file::remove_stale(dir, FILE_NAME);
    let bytes = match private_file::read_private(
        &dir.join(FILE_NAME),
        MAX_TOKEN_BYTES,
        ModeRule::Exact0600,
    ) {
        Ok(Some(b)) => b,
        Ok(None) => return Ok(None),
        Err(ReadError::Open(_)) => return Err("the file cannot be opened"),
        Err(ReadError::Metadata(_)) => return Err("the file cannot be read"),
        Err(ReadError::NotRegular | ReadError::WrongOwner | ReadError::Mode(_)) => {
            return Err("the file is not a private regular file (mode 0600)");
        }
        Err(ReadError::TooLarge) => return Err("the file is too large"),
        Err(ReadError::Read(_)) => return Err("the file is not text"),
    };
    let text = String::from_utf8(bytes).map_err(|_| "the file is not text")?;
    let token = text.trim();
    if token.is_empty() || token.chars().any(char::is_control) {
        return Err("the file does not hold a token");
    }
    Ok(Some(token.to_owned()))
}

/// Replaces the stored token atomically.
fn write(dir: &Path, token: &str) -> Result<(), &'static str> {
    paths::ensure_private_dir(dir).map_err(|_| "its directory is not private")?;
    private_file::write_atomic(&dir.join(FILE_NAME), token.as_bytes(), SyncDir::Yes)
        .map_err(|_| "the file cannot be written")
}

impl TokenStore for FileTokenStore {
    fn load(&mut self) -> Option<String> {
        match read(&self.dir) {
            Ok(token) => token,
            Err(problem) => {
                crate::warn!(
                    "portal restore token ignored ({problem}); the desktop will ask for permission again"
                );
                None
            }
        }
    }

    fn save(&mut self, token: &str) {
        if token.len() as u64 > MAX_TOKEN_BYTES || token.chars().any(char::is_control) {
            crate::warn!("portal restore token not saved (unusable token)");
            return;
        }
        if let Err(problem) = write(&self.dir, token) {
            crate::warn!(
                "portal restore token not saved ({problem}); the desktop will ask for permission again next time"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::TempDir;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    #[test]
    fn saves_privately_and_loads_back() {
        let t = TempDir::new("portal-token");
        let dir = t.path().join("state/localflow");
        let mut store = FileTokenStore::new(dir.clone());
        assert_eq!(store.load(), None);
        store.save("synthetic-token-1");
        assert_eq!(fs::metadata(&dir).unwrap().mode() & 0o777, 0o700);
        let file = dir.join(FILE_NAME);
        assert_eq!(fs::metadata(&file).unwrap().mode() & 0o777, 0o600);
        assert_eq!(store.load().as_deref(), Some("synthetic-token-1"));
        store.save("synthetic-token-2");
        assert_eq!(store.load().as_deref(), Some("synthetic-token-2"));
        // Only the token file remains.
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
    }

    #[test]
    fn unsafe_or_invalid_files_are_ignored() {
        let t = TempDir::new("portal-token-bad");
        let dir = t.path().join("localflow");
        let mut store = FileTokenStore::new(dir.clone());
        store.save("synthetic-token");
        let file = dir.join(FILE_NAME);

        for mode in [0o644, 0o400, 0o640, 0o700] {
            fs::set_permissions(&file, fs::Permissions::from_mode(mode)).unwrap();
            assert_eq!(store.load(), None, "mode {mode:o}");
        }
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(store.load().is_some());

        // The longest token loads.
        let longest = "x".repeat(MAX_TOKEN_BYTES as usize);
        fs::write(&file, &longest).unwrap();
        assert_eq!(store.load(), Some(longest));
        fs::write(&file, [b'x', 0xff]).unwrap();
        assert_eq!(store.load(), None);

        // A directory in its place is ignored.
        fs::remove_file(&file).unwrap();
        fs::create_dir(&file).unwrap();
        assert_eq!(store.load(), None);
        fs::remove_dir(&file).unwrap();
        store.save("synthetic-token");

        fs::write(&file, "synthetic\u{7}token").unwrap();
        assert_eq!(store.load(), None);
        fs::write(&file, "x".repeat(5000)).unwrap();
        assert_eq!(store.load(), None);
        fs::write(&file, "").unwrap();
        assert_eq!(store.load(), None);

        // A symlink in place of the file is not followed.
        fs::remove_file(&file).unwrap();
        let target = t.path().join("elsewhere");
        fs::write(&target, "synthetic-token").unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
        std::os::unix::fs::symlink(&target, &file).unwrap();
        assert_eq!(store.load(), None);
        fs::remove_file(&file).unwrap();

        // A directory others can read is not trusted.
        store.save("synthetic-token");
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(store.load(), None);
        store.save("synthetic-token-2");
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(store.load().as_deref(), Some("synthetic-token"));

        // Stale temporaries from a crash are removed.
        let stale = dir.join(format!(".{FILE_NAME}.tmp-999"));
        fs::write(&stale, "synthetic-token").unwrap();
        store.load();
        assert!(!stale.exists());
    }
}

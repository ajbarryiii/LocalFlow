//! XDG locations and private-directory checks.

use std::ffi::OsString;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::path::{Path, PathBuf};

pub const APP_DIR: &str = "localflow";
pub const SOCKET_NAME: &str = "ctl.sock";
pub const LOCK_NAME: &str = "localflowd.lock";

pub fn euid() -> u32 {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() }
}

/// An absolute path from the environment, or `None` (the XDG spec says
/// relative values are invalid and must be ignored).
fn env_dir(value: Option<OsString>) -> Option<PathBuf> {
    value.map(PathBuf::from).filter(|p| p.is_absolute())
}

fn home() -> Result<PathBuf, String> {
    env_dir(std::env::var_os("HOME")).ok_or_else(|| "HOME is not set to an absolute path".into())
}

/// `$XDG_CONFIG_HOME/localflow/config.json`.
pub fn config_file() -> Result<PathBuf, String> {
    let base = match env_dir(std::env::var_os("XDG_CONFIG_HOME")) {
        Some(p) => p,
        None => home()?.join(".config"),
    };
    Ok(base.join(APP_DIR).join("config.json"))
}

/// `$XDG_DATA_HOME/localflow` (not created).
pub fn data_dir() -> Result<PathBuf, String> {
    let base = match env_dir(std::env::var_os("XDG_DATA_HOME")) {
        Some(p) => p,
        None => home()?.join(".local/share"),
    };
    Ok(base.join(APP_DIR))
}

/// `$XDG_RUNTIME_DIR`, which must be set, absolute, and a real directory
/// owned by this user with no group or other access.
pub fn runtime_dir() -> Result<PathBuf, String> {
    let dir = env_dir(std::env::var_os("XDG_RUNTIME_DIR"))
        .ok_or("XDG_RUNTIME_DIR is not set to an absolute path")?;
    check_private_dir(&dir).map_err(|e| format!("XDG_RUNTIME_DIR: {e}"))?;
    Ok(dir)
}

/// `$XDG_RUNTIME_DIR/localflow/ctl.sock`, for clients. Checks nothing; the
/// client verifies the server's credentials instead.
pub fn socket_path_for_client() -> Result<PathBuf, String> {
    let dir = env_dir(std::env::var_os("XDG_RUNTIME_DIR"))
        .ok_or("XDG_RUNTIME_DIR is not set to an absolute path")?;
    Ok(dir.join(APP_DIR).join(SOCKET_NAME))
}

/// Fails unless `dir` is a directory (not a symlink) owned by the effective
/// user with mode `0o700` or stricter.
pub fn check_private_dir(dir: &Path) -> Result<(), String> {
    let meta = fs::symlink_metadata(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    if !meta.file_type().is_dir() {
        return Err(format!("{} is not a directory", dir.display()));
    }
    if meta.uid() != euid() {
        return Err(format!(
            "{} is not owned by the current user",
            dir.display()
        ));
    }
    if meta.mode() & 0o077 != 0 {
        return Err(format!(
            "{} is accessible to other users (mode {:o})",
            dir.display(),
            meta.mode() & 0o777
        ));
    }
    Ok(())
}

/// Creates `dir` with mode 0700 if missing (parents too, also 0700), then
/// checks it with [`check_private_dir`]. An existing insecure directory is an
/// error, not something to repair silently.
pub fn ensure_private_dir(dir: &Path) -> Result<(), String> {
    match fs::symlink_metadata(dir) {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(dir)
                .map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
        }
        Err(e) => return Err(format!("{}: {e}", dir.display())),
    }
    check_private_dir(dir)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    use crate::testing::TempDir;

    #[test]
    fn private_dir_checks() {
        let t = TempDir::new("paths");
        let d = t.path().join("a/b");
        ensure_private_dir(&d).unwrap();
        assert_eq!(fs::metadata(&d).unwrap().mode() & 0o777, 0o700);
        // Idempotent.
        ensure_private_dir(&d).unwrap();

        fs::set_permissions(&d, fs::Permissions::from_mode(0o750)).unwrap();
        assert!(ensure_private_dir(&d).unwrap_err().contains("accessible"));
        fs::set_permissions(&d, fs::Permissions::from_mode(0o700)).unwrap();

        let link = t.path().join("link");
        std::os::unix::fs::symlink(&d, &link).unwrap();
        assert!(
            check_private_dir(&link)
                .unwrap_err()
                .contains("not a directory")
        );

        let file = t.path().join("file");
        fs::write(&file, b"").unwrap();
        assert!(ensure_private_dir(&file).is_err());
    }
}

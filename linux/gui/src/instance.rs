//! One settings window per user. A second `localflow-gui settings` brings
//! the open window forward and exits.
//!
//! The first instance holds an flock on `gui-settings.lock` and listens on
//! `gui-settings.sock`, both in `$XDG_RUNTIME_DIR/localflow` (a private
//! directory). A later instance finds the lock taken, connects, and sends
//! its activation token (`XDG_ACTIVATION_TOKEN`, which lets a Wayland
//! compositor give the window focus; it may be empty). Nothing else is
//! sent.

use std::fs::{File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::{FileTypeExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

const LOCK_NAME: &str = "gui-settings.lock";
const SOCKET_NAME: &str = "gui-settings.sock";
/// Longer tokens are dropped (compositors' tokens are far shorter).
const MAX_TOKEN: usize = 256;

pub enum Instance {
    /// No other window: this process opens one.
    First(Listener),
    /// Another window was asked to come forward.
    Forwarded,
}

/// The first instance's lock and socket.
pub struct Listener {
    listener: UnixListener,
    socket_path: PathBuf,
    _lock: File,
}

impl Drop for Listener {
    fn drop(&mut self) {
        // Before the lock goes, so the next first instance binds afresh.
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

/// Takes the lock in `dir` (made private if missing), or forwards `token`
/// to the instance holding it.
pub fn claim(dir: &Path, token: &str) -> Result<Instance, String> {
    lf_daemon::paths::ensure_private_dir(dir)?;
    let lock_path = dir.join(LOCK_NAME);
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(&lock_path)
        .map_err(|e| format!("cannot open {}: {e}", lock_path.display()))?;
    let socket_path = dir.join(SOCKET_NAME);
    match lock.try_lock() {
        Ok(()) => {}
        Err(std::fs::TryLockError::WouldBlock) => return forward(&socket_path, token),
        Err(std::fs::TryLockError::Error(e)) => {
            return Err(format!("cannot lock {}: {e}", lock_path.display()));
        }
    }
    match std::fs::symlink_metadata(&socket_path) {
        // Left by an instance that exited: we hold the lock.
        Ok(m) if m.file_type().is_socket() => std::fs::remove_file(&socket_path)
            .map_err(|e| format!("cannot remove {}: {e}", socket_path.display()))?,
        Ok(_) => return Err(format!("{} is not a socket", socket_path.display())),
        Err(e) if e.kind() == ErrorKind::NotFound => {}
        Err(e) => return Err(format!("{}: {e}", socket_path.display())),
    }
    let listener = UnixListener::bind(&socket_path)
        .map_err(|e| format!("cannot bind {}: {e}", socket_path.display()))?;
    std::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("cannot chmod {}: {e}", socket_path.display()))?;
    Ok(Instance::First(Listener {
        listener,
        socket_path,
        _lock: lock,
    }))
}

/// Sends `token` to the first instance. It may still be binding its
/// socket, so connecting is retried for a moment.
fn forward(socket_path: &Path, token: &str) -> Result<Instance, String> {
    let mut tries = 0;
    let mut conn = loop {
        match UnixStream::connect(socket_path) {
            Ok(c) => break c,
            Err(_) if tries < 20 => {
                tries += 1;
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => {
                return Err(format!(
                    "a settings window is open, but {} does not answer: {e}",
                    socket_path.display()
                ));
            }
        }
    };
    let token = if valid(token) { token } else { "" };
    conn.write_all(format!("{token}\n").as_bytes())
        .map_err(|e| format!("cannot reach the open settings window: {e}"))?;
    Ok(Instance::Forwarded)
}

/// What a compositor's token looks like: printable ASCII, not too long.
fn valid(token: &str) -> bool {
    token.len() <= MAX_TOKEN && token.bytes().all(|b| b.is_ascii_graphic())
}

impl Listener {
    /// Calls `show` with the token of each later instance (possibly empty),
    /// on a thread that lives as long as the process.
    pub fn serve(self, show: impl Fn(String) + Send + 'static) {
        std::thread::spawn(move || {
            for conn in self.listener.incoming() {
                let Ok(mut conn) = conn else { continue };
                let _ = conn.set_read_timeout(Some(Duration::from_secs(1)));
                let mut buf = Vec::new();
                let _ = (&mut conn).take(MAX_TOKEN as u64 + 1).read_to_end(&mut buf);
                let line = buf.split(|&b| b == b'\n').next().unwrap_or_default();
                let token = std::str::from_utf8(line).unwrap_or_default();
                show(if valid(token) { token } else { "" }.to_owned());
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    struct Dir(PathBuf);
    impl Dir {
        fn new(name: &str) -> Dir {
            let d = std::env::temp_dir().join(format!("lf-gui-inst-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&d);
            Dir(d.join("localflow"))
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(self.0.parent().unwrap());
        }
    }

    fn first(dir: &Path) -> Listener {
        match claim(dir, "") {
            Ok(Instance::First(l)) => l,
            Ok(Instance::Forwarded) => panic!("forwarded"),
            Err(e) => panic!("{e}"),
        }
    }

    #[test]
    fn a_second_instance_hands_its_token_to_the_first() {
        let d = Dir::new("forward");
        let (tx, rx) = mpsc::channel();
        first(&d.0).serve(move |t| tx.send(t).unwrap());
        assert!(matches!(
            claim(&d.0, "synthetic-token_1"),
            Ok(Instance::Forwarded)
        ));
        let got = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(got, "synthetic-token_1");

        // No token, or one that is not a token, arrives empty.
        assert!(matches!(claim(&d.0, ""), Ok(Instance::Forwarded)));
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).unwrap(), "");
        assert!(matches!(claim(&d.0, "two\nlines"), Ok(Instance::Forwarded)));
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).unwrap(), "");

        let mode = std::fs::metadata(d.0.join(SOCKET_NAME))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
    }

    #[test]
    fn the_next_window_is_first_once_the_last_one_has_gone() {
        let d = Dir::new("stale");
        drop(first(&d.0));
        drop(first(&d.0));
        // A socket left behind (a crash) is replaced.
        let _ = UnixListener::bind(d.0.join(SOCKET_NAME)).unwrap();
        assert!(d.0.join(SOCKET_NAME).exists());
        let l = first(&d.0);
        assert!(UnixStream::connect(d.0.join(SOCKET_NAME)).is_ok());
        drop(l);
    }
}

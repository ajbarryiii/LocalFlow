//! The control socket: `$XDG_RUNTIME_DIR/localflow/ctl.sock`.
//!
//! - The `localflow` directory is 0700 and the socket 0600, both owned by
//!   the user; an existing directory with looser permissions is refused.
//! - A lock file in the same directory (`flock`) allows one daemon per user.
//! - Every connection's peer credentials (`SO_PEERCRED`) must show the same
//!   uid as the daemon.
//! - Connections are served one at a time, in accept order, so a press is
//!   handled before the release that follows it. Each gets a short deadline.
//! - A `watch` connection is handed to the control loop once its request is
//!   read and a watcher place is reserved (see `crate::watch`), so watchers
//!   never hold up other commands; over the cap it is refused here.

use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender};
use std::time::{Duration, Instant};

use crate::daemon::Event;
use crate::paths::{self, APP_DIR, LOCK_NAME, SOCKET_NAME};
use crate::protocol::{Command, ErrorCode, MAX_LINE, Reply, parse_request};
use crate::watch::Admission;

/// Time a client has to send its request line. Connections are served one at
/// a time, so this bounds how long a stalled client delays the next command.
pub const REQUEST_DEADLINE: Duration = Duration::from_millis(250);
/// Time the control loop has to answer.
pub const REPLY_DEADLINE: Duration = Duration::from_secs(10);

pub struct Server {
    listener: UnixListener,
    socket_path: PathBuf,
    /// Held while the server exists; the flock is the instance lock.
    _lock: File,
    stopping: AtomicBool,
}

impl Server {
    /// Takes the instance lock and binds the socket under `runtime_dir`,
    /// which must already be a private directory.
    pub fn bind(runtime_dir: &Path) -> Result<Server, String> {
        paths::check_private_dir(runtime_dir).map_err(|e| format!("runtime directory: {e}"))?;
        let dir = runtime_dir.join(APP_DIR);
        paths::ensure_private_dir(&dir)?;

        let lock_path = dir.join(LOCK_NAME);
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&lock_path)
            .map_err(|e| format!("cannot open {}: {e}", lock_path.display()))?;
        // SAFETY: flock on a valid descriptor.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            let err = std::io::Error::last_os_error();
            return Err(if err.kind() == ErrorKind::WouldBlock {
                "another localflowd is already running for this user".into()
            } else {
                format!("cannot lock {}: {err}", lock_path.display())
            });
        }

        let socket_path = dir.join(SOCKET_NAME);
        match fs::symlink_metadata(&socket_path) {
            Ok(m) if m.file_type().is_socket() => {
                // A stale socket from a previous daemon: we hold the lock.
                fs::remove_file(&socket_path)
                    .map_err(|e| format!("cannot remove {}: {e}", socket_path.display()))?;
            }
            Ok(_) => {
                return Err(format!(
                    "{} exists and is not a socket",
                    socket_path.display()
                ));
            }
            Err(e) if e.kind() == ErrorKind::NotFound => {}
            Err(e) => return Err(format!("{}: {e}", socket_path.display())),
        }
        let listener = UnixListener::bind(&socket_path)
            .map_err(|e| format!("cannot bind {}: {e}", socket_path.display()))?;
        fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o600))
            .map_err(|e| format!("cannot chmod {}: {e}", socket_path.display()))?;
        let meta = fs::symlink_metadata(&socket_path).map_err(|e| e.to_string())?;
        if meta.mode() & 0o777 != 0o600 || meta.uid() != paths::euid() {
            return Err(format!(
                "{} has unexpected permissions",
                socket_path.display()
            ));
        }
        Ok(Server {
            listener,
            socket_path,
            _lock: lock,
            stopping: AtomicBool::new(false),
        })
    }

    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    /// Serves connections until [`Server::stop`]. `admission` bounds the
    /// `watch` connections handed to the control loop.
    pub fn serve(&self, events: &Sender<Event>, admission: &Arc<Admission>) {
        for conn in self.listener.incoming() {
            if self.stopping.load(Ordering::Acquire) {
                return;
            }
            match conn {
                Ok(stream) => handle(stream, events, admission),
                Err(_) if self.stopping.load(Ordering::Acquire) => return,
                Err(e) => {
                    crate::warn!("control socket accept failed: {e}");
                    std::thread::sleep(Duration::from_millis(50));
                }
            }
        }
    }

    /// Removes the socket file and wakes [`Server::serve`] so it returns.
    /// The lock is released when the server is dropped. The lock file stays
    /// (removing it while another process waits on it would break mutual
    /// exclusion).
    pub fn stop(&self) {
        self.stopping.store(true, Ordering::Release);
        let _ = fs::remove_file(&self.socket_path);
        // Wakes a blocked accept (it fails with EINVAL on Linux).
        // SAFETY: shutdown on a valid descriptor.
        unsafe { libc::shutdown(self.listener.as_raw_fd(), libc::SHUT_RDWR) };
    }
}

/// The uid of the process on the other end of `stream`.
pub fn peer_uid(stream: &UnixStream) -> std::io::Result<u32> {
    let mut cred = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: `cred` and `len` are valid for writes of the sizes passed.
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    };
    if rc != 0 {
        return Err(std::io::Error::last_os_error());
    }
    if len as usize != std::mem::size_of::<libc::ucred>() {
        return Err(std::io::Error::other("short SO_PEERCRED reply"));
    }
    Ok(cred.uid)
}

fn handle(mut stream: UnixStream, events: &Sender<Event>, admission: &Arc<Admission>) {
    match peer_uid(&stream) {
        Ok(uid) if uid == paths::euid() => {}
        Ok(uid) => {
            crate::warn!("refused a control connection from uid {uid}");
            return;
        }
        Err(e) => {
            crate::warn!("cannot read control peer credentials: {e}");
            return;
        }
    }
    let (reply, unread) = match read_request(&mut stream, Instant::now() + REQUEST_DEADLINE) {
        Ok(line) => match parse_request(&line) {
            Ok(req) if req.command == Command::Watch => {
                // The control loop keeps the connection and answers it; this
                // thread must not wait on a watcher. Over the cap the
                // connection is refused here, so the watch connections queued
                // for the control loop stay bounded.
                let new = match admission.admit(stream) {
                    Ok(new) => new,
                    Err(stream) => {
                        admission.refuse(stream);
                        admission.report_refusals(Instant::now());
                        return;
                    }
                };
                match events.send(Event::Watch(new)) {
                    Ok(()) => return,
                    Err(mpsc::SendError(event)) => {
                        let Event::Watch(new) = event else {
                            return;
                        };
                        stream = new.into_stream();
                        (Reply::Error(ErrorCode::Unavailable), false)
                    }
                }
            }
            Ok(req) => (dispatch(req, events), false),
            Err(code) => (Reply::Error(code), false),
        },
        Err(code) => (Reply::Error(code), code != ErrorCode::Timeout),
    };
    if let Reply::Error(code) = reply {
        crate::debug!("control request rejected: {}", code.name());
    }
    let _ = stream.set_write_timeout(Some(REQUEST_DEADLINE));
    let _ = stream.write_all(reply.to_line().as_bytes());
    if unread {
        // Closing with unread input makes the client see a reset instead of
        // the reply; discard what is already buffered (without waiting).
        let _ = stream.shutdown(std::net::Shutdown::Write);
        if stream.set_nonblocking(true).is_ok() {
            let mut sink = [0u8; 4096];
            for _ in 0..64 {
                if !matches!(stream.read(&mut sink), Ok(n) if n > 0) {
                    break;
                }
            }
        }
    }
}

fn dispatch(req: crate::protocol::Request, events: &Sender<Event>) -> Reply {
    let (tx, rx) = mpsc::channel();
    if events.send(Event::Request(req, tx)).is_err() {
        return Reply::Error(ErrorCode::Unavailable);
    }
    rx.recv_timeout(REPLY_DEADLINE)
        .unwrap_or(Reply::Error(ErrorCode::Unavailable))
}

/// Reads one `\n`-terminated line of at most `MAX_LINE` bytes (newline
/// included) before `deadline`. The line must be all the client sends.
pub fn read_request(stream: &mut UnixStream, deadline: Instant) -> Result<Vec<u8>, ErrorCode> {
    let mut buf = [0u8; MAX_LINE];
    let mut len = 0;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(ErrorCode::Timeout);
        }
        stream
            .set_read_timeout(Some(remaining))
            .map_err(|_| ErrorCode::Malformed)?;
        let n = match stream.read(&mut buf[len..]) {
            Ok(n) => n,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                return Err(ErrorCode::Timeout);
            }
            Err(_) => return Err(ErrorCode::Malformed),
        };
        if n == 0 {
            // End of stream before a newline.
            return Err(ErrorCode::Malformed);
        }
        let start = len;
        len += n;
        if let Some(pos) = buf[start..len].iter().position(|&b| b == b'\n') {
            let end = start + pos;
            if end + 1 != len {
                // More than one line.
                return Err(ErrorCode::Malformed);
            }
            return Ok(buf[..end].to_vec());
        }
        if len == MAX_LINE {
            return Err(ErrorCode::TooLong);
        }
    }
}

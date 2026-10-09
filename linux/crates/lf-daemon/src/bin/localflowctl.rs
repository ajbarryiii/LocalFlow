//! `localflowctl`: sends one command to `localflowd` and prints the reply.
//!
//! `localflowctl watch` instead stays connected and prints a status line on
//! every change (and level lines while recording); `watch --waybar` prints
//! Waybar JSON, shows "offline" while the daemon is unreachable, and keeps
//! reconnecting, so the bar never needs a restart.
//!
//! Exit codes:
//! - 0: the daemon accepted the command (stdout: the reply fields), or the
//!   reader of `watch` output went away;
//! - 1: the daemon answered with an error (stderr: the error code);
//! - 2: usage error;
//! - 3: the daemon is not reachable (not running, or no runtime directory),
//!   or a `watch` connection was lost;
//! - 4: timed out;
//! - 5: protocol error (bad reply, or the socket belongs to another user).

use std::io::{ErrorKind, Read, Write};
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use lf_daemon::paths;
use lf_daemon::protocol::{
    ClientReply, Command, MAX_LINE, Request, monotonic_ns, parse_reply, request_line,
};
use lf_daemon::server::peer_uid;
use lf_daemon::waybar::Indicator;

const USAGE: &str = "usage: localflowctl [--timeout-ms N] <command>
       localflowctl [--timeout-ms N] watch [--waybar]

commands:
  press     start hold-to-talk (key down)
  release   end hold-to-talk (key up)
  toggle    start or stop tap-to-toggle dictation
  cancel    discard the recording, or abandon transcription and typing
  again     type the last dictation again
  status    print the daemon state
  watch     print the state on every change; --waybar prints JSON for a
            Waybar custom module and reconnects while the daemon is down";

/// Above the microphone start timeout (3 s) plus the reply, so a missing
/// device is reported as an error rather than a client timeout.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(6);

/// How often `watch --waybar` tries to reach a daemon that is not running.
const WAYBAR_RETRY: Duration = Duration::from_secs(2);

enum Failure {
    Daemon(String),
    Usage(String),
    Unreachable(String),
    Timeout,
    Protocol(String),
    /// Stdout's reader went away (`watch`); exits quietly with 0.
    Closed,
}

impl Failure {
    fn code(&self) -> u8 {
        match self {
            Failure::Closed => 0,
            Failure::Daemon(_) => 1,
            Failure::Usage(_) => 2,
            Failure::Unreachable(_) => 3,
            Failure::Timeout => 4,
            Failure::Protocol(_) => 5,
        }
    }
}

struct Args {
    command: Command,
    timeout: Duration,
    waybar: bool,
}

fn main() -> ExitCode {
    // First, so the stamp orders this key event against the next one.
    let started = monotonic_ns();
    let result = parse_args().and_then(|args| match args.command {
        Command::Watch if args.waybar => {
            watch_waybar(&args);
            Ok(None)
        }
        Command::Watch => watch(&args).map(|()| None),
        _ => run(started, &args).map(Some),
    });
    match result {
        Ok(fields) => {
            if let Some(fields) = fields {
                println!("{fields}");
            }
            ExitCode::SUCCESS
        }
        Err(f) => {
            match &f {
                Failure::Daemon(code) => eprintln!("localflowctl: daemon error: {code}"),
                Failure::Usage(m) => eprintln!("{m}"),
                Failure::Unreachable(m) => eprintln!("localflowctl: {m}"),
                Failure::Timeout => eprintln!("localflowctl: timed out"),
                Failure::Protocol(m) => eprintln!("localflowctl: protocol error: {m}"),
                Failure::Closed => {}
            }
            ExitCode::from(f.code())
        }
    }
}

fn parse_args() -> Result<Args, Failure> {
    let mut timeout = DEFAULT_TIMEOUT;
    let mut command = None;
    let mut waybar = false;
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "-h" | "--help" => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            "--timeout-ms" => {
                let ms: u64 = it
                    .next()
                    .and_then(|v| v.parse().ok())
                    .filter(|&ms| (1..=600_000).contains(&ms))
                    .ok_or_else(|| {
                        Failure::Usage(format!("--timeout-ms needs 1..600000\n{USAGE}"))
                    })?;
                timeout = Duration::from_millis(ms);
            }
            "--waybar" => waybar = true,
            _ if command.is_none() => {
                command =
                    Some(Command::parse(&arg).ok_or_else(|| {
                        Failure::Usage(format!("unknown command {arg:?}\n{USAGE}"))
                    })?);
            }
            _ => return Err(Failure::Usage(USAGE.into())),
        }
    }
    let command = command.ok_or_else(|| Failure::Usage(USAGE.into()))?;
    if waybar && command != Command::Watch {
        return Err(Failure::Usage(format!("--waybar needs watch\n{USAGE}")));
    }
    Ok(Args {
        command,
        timeout,
        waybar,
    })
}

/// Connects, checks the daemon's uid, and sends `req`.
fn open(req: Request, deadline: Instant) -> Result<UnixStream, Failure> {
    let path = paths::socket_path_for_client().map_err(Failure::Unreachable)?;
    let mut stream = connect(&path, deadline)?;
    match peer_uid(&stream) {
        Ok(uid) if uid == paths::euid() => {}
        Ok(_) => {
            return Err(Failure::Protocol(
                "the socket belongs to another user".into(),
            ));
        }
        Err(e) => return Err(Failure::Protocol(format!("peer credentials: {e}"))),
    }
    stream
        .set_write_timeout(Some(remaining(deadline)?))
        .map_err(|e| Failure::Protocol(e.to_string()))?;
    stream
        .write_all(request_line(req).as_bytes())
        .map_err(io_failure)?;
    Ok(stream)
}

fn run(started: u64, args: &Args) -> Result<String, Failure> {
    let deadline = Instant::now() + args.timeout;
    let mut stream = open(
        Request {
            command: args.command,
            at: Some(started),
        },
        deadline,
    )?;

    let mut buf = Vec::with_capacity(MAX_LINE);
    let mut chunk = [0u8; MAX_LINE];
    loop {
        stream
            .set_read_timeout(Some(remaining(deadline)?))
            .map_err(|e| Failure::Protocol(e.to_string()))?;
        let n = match stream.read(&mut chunk) {
            Ok(n) => n,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(e) => return Err(io_failure(e)),
        };
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
        if buf.contains(&b'\n') || buf.len() > MAX_LINE {
            break;
        }
    }
    let Some(end) = buf.iter().position(|&b| b == b'\n') else {
        return Err(Failure::Protocol(if buf.is_empty() {
            "no reply".into()
        } else {
            "reply too long or unterminated".into()
        }));
    };
    match parse_reply(&buf[..end]) {
        Some(ClientReply::Ok(fields)) => Ok(fields),
        Some(ClientReply::Error(code)) => Err(Failure::Daemon(code)),
        None => Err(Failure::Protocol("malformed reply".into())),
    }
}

/// A `watch` connection: the first line arrives within the deadline, later
/// ones whenever the daemon sends them. Every wait also watches stdout, so
/// the client exits as soon as its reader goes away, even while nothing
/// changes.
struct Watch {
    stream: UnixStream,
    buf: Vec<u8>,
    /// Deadline for the first line only.
    deadline: Option<Instant>,
}

impl Watch {
    fn open(args: &Args) -> Result<Watch, Failure> {
        let deadline = Instant::now() + args.timeout;
        let stream = open(Request::new(Command::Watch), deadline)?;
        Ok(Watch {
            stream,
            buf: Vec::with_capacity(2 * MAX_LINE),
            deadline: Some(deadline),
        })
    }

    /// The next line's `ok` fields; a daemon error, a lost connection or a
    /// bad line is a failure, and a closed stdout is [`Failure::Closed`].
    fn next(&mut self) -> Result<String, Failure> {
        let mut chunk = [0u8; MAX_LINE];
        let end = loop {
            if let Some(end) = self.buf.iter().position(|&b| b == b'\n') {
                break end;
            }
            if self.buf.len() >= MAX_LINE {
                return Err(Failure::Protocol("line too long".into()));
            }
            let timeout = self.deadline.map(remaining).transpose()?;
            if !wait_readable(&self.stream, timeout)? {
                return Err(Failure::Timeout);
            }
            let n = match self.stream.read(&mut chunk) {
                Ok(0) => {
                    return Err(Failure::Unreachable(
                        "the connection to localflowd was closed".into(),
                    ));
                }
                Ok(n) => n,
                Err(e) if matches!(e.kind(), ErrorKind::Interrupted | ErrorKind::WouldBlock) => {
                    continue;
                }
                Err(e) => {
                    return Err(Failure::Unreachable(format!(
                        "the connection to localflowd failed: {e}"
                    )));
                }
            };
            self.buf.extend_from_slice(&chunk[..n]);
        };
        let reply = parse_reply(&self.buf[..end]);
        self.buf.drain(..=end);
        self.deadline = None;
        match reply {
            Some(ClientReply::Ok(fields)) => Ok(fields),
            Some(ClientReply::Error(code)) => Err(Failure::Daemon(code)),
            None => Err(Failure::Protocol("malformed reply".into())),
        }
    }
}

/// True if stdout's reader has gone away: for a pipe, every read end is
/// closed; for a terminal, it hung up. Regular files and `/dev/null` never
/// report this.
fn stdout_gone(revents: libc::c_short) -> bool {
    revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0
}

/// Waits until `stream` is readable (true) or `timeout` passes (false;
/// `None` waits indefinitely). Fails with [`Failure::Closed`] as soon as
/// stdout's reader goes away.
fn wait_readable(stream: &UnixStream, timeout: Option<Duration>) -> Result<bool, Failure> {
    use std::os::fd::AsRawFd;
    let deadline = timeout.map(|t| Instant::now() + t);
    loop {
        let mut fds = [
            libc::pollfd {
                fd: stream.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: libc::STDOUT_FILENO,
                // POLLERR and POLLHUP are always reported.
                events: 0,
                revents: 0,
            },
        ];
        let ms = match deadline {
            None => -1,
            Some(d) => {
                let left = d.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    return Ok(false);
                }
                left.as_millis().clamp(1, i32::MAX as u128) as libc::c_int
            }
        };
        // SAFETY: polls two valid pollfds.
        let n = unsafe { libc::poll(fds.as_mut_ptr(), 2, ms) };
        if n < 0 {
            let e = std::io::Error::last_os_error();
            if e.kind() == ErrorKind::Interrupted {
                continue;
            }
            return Err(Failure::Protocol(e.to_string()));
        }
        if stdout_gone(fds[1].revents) {
            return Err(Failure::Closed);
        }
        if fds[0].revents != 0 {
            // Readable, end of stream or an error: the read reports which.
            return Ok(true);
        }
    }
}

/// Sleeps for `d`, or returns true early once stdout's reader goes away.
fn sleep_unless_stdout_gone(d: Duration) -> bool {
    let deadline = Instant::now() + d;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return false;
        }
        let mut fd = libc::pollfd {
            fd: libc::STDOUT_FILENO,
            events: 0,
            revents: 0,
        };
        let ms = left.as_millis().clamp(1, i32::MAX as u128) as libc::c_int;
        // SAFETY: polls one valid pollfd.
        let n = unsafe { libc::poll(&mut fd, 1, ms) };
        if n > 0 && stdout_gone(fd.revents) {
            return true;
        }
        if n > 0 {
            // Some other condition was reported; do not spin on it.
            std::thread::sleep(left);
            return false;
        }
    }
}

/// Writes one line and flushes it; false once stdout is closed.
fn emit(out: &mut impl Write, line: &str) -> bool {
    writeln!(out, "{line}").and_then(|()| out.flush()).is_ok()
}

/// `watch`: the reply fields of every line, until the daemon goes away
/// (an error) or stdout is closed (`Ok`).
fn watch(args: &Args) -> Result<(), Failure> {
    let mut w = Watch::open(args)?;
    let mut out = std::io::stdout().lock();
    loop {
        let fields = match w.next() {
            Ok(fields) => fields,
            Err(Failure::Closed) => return Ok(()),
            Err(f) => return Err(f),
        };
        if !emit(&mut out, &fields) {
            return Ok(());
        }
    }
}

/// `watch --waybar`: runs until stdout is closed. A lost connection is
/// retried at once; while the daemon is unreachable the offline object is
/// shown and the connection retried every [`WAYBAR_RETRY`].
fn watch_waybar(args: &Args) {
    let mut out = std::io::stdout().lock();
    let mut indicator = Indicator::default();
    let mut last = String::new();
    let mut show = |out: &mut std::io::StdoutLock<'_>, object: String| -> bool {
        if object == last {
            return true;
        }
        let ok = emit(out, &object);
        last = object;
        ok
    };
    let mut retried = false;
    loop {
        let began = Instant::now();
        let mut connected = false;
        if let Ok(mut w) = Watch::open(args) {
            loop {
                match w.next() {
                    Ok(fields) => {
                        connected = true;
                        if let Some(object) = indicator.update(&fields)
                            && !show(&mut out, object)
                        {
                            return;
                        }
                    }
                    Err(Failure::Closed) => return,
                    Err(_) => break,
                }
            }
        }
        // One immediate retry after a working connection drops (a daemon
        // restart, or this client fell behind); not twice in a row unless
        // the connection lasted.
        if connected && (!retried || began.elapsed() >= WAYBAR_RETRY) {
            retried = true;
            continue;
        }
        retried = false;
        // An unchanged offline object is not written again, so a closed
        // stdout is noticed by the wait instead.
        if !show(&mut out, indicator.offline()) || sleep_unless_stdout_gone(WAYBAR_RETRY) {
            return;
        }
    }
}

fn remaining(deadline: Instant) -> Result<Duration, Failure> {
    let r = deadline.saturating_duration_since(Instant::now());
    if r.is_zero() {
        Err(Failure::Timeout)
    } else {
        Ok(r)
    }
}

fn io_failure(e: std::io::Error) -> Failure {
    match e.kind() {
        ErrorKind::WouldBlock | ErrorKind::TimedOut => Failure::Timeout,
        _ => Failure::Protocol(e.to_string()),
    }
}

/// Connects without blocking past `deadline` (a Unix stream connect blocks
/// while the listen backlog is full).
fn connect(path: &Path, deadline: Instant) -> Result<UnixStream, Failure> {
    let bytes = path.as_os_str().as_bytes();
    // SAFETY: zeroed sockaddr_un is valid; the path fits (checked below).
    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.len() >= addr.sun_path.len() {
        return Err(Failure::Unreachable(format!(
            "socket path {} is too long",
            path.display()
        )));
    }
    addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (dst, &src) in addr.sun_path.iter_mut().zip(bytes) {
        *dst = src as libc::c_char;
    }
    // SAFETY: plain socket creation; the descriptor is owned immediately.
    let fd = unsafe {
        libc::socket(
            libc::AF_UNIX,
            libc::SOCK_STREAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
            0,
        )
    };
    if fd < 0 {
        return Err(Failure::Protocol(
            std::io::Error::last_os_error().to_string(),
        ));
    }
    // SAFETY: `fd` is a fresh descriptor owned by nothing else.
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };
    let len = std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t;
    loop {
        use std::os::fd::AsRawFd;
        // SAFETY: `addr` is a valid sockaddr_un of `len` bytes.
        let rc = unsafe {
            libc::connect(
                fd.as_raw_fd(),
                (&addr as *const libc::sockaddr_un).cast(),
                len,
            )
        };
        if rc == 0 {
            break;
        }
        let err = std::io::Error::last_os_error();
        match err.raw_os_error() {
            Some(libc::EINTR) => continue,
            Some(libc::EAGAIN) => {
                if Instant::now() >= deadline {
                    return Err(Failure::Timeout);
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Some(libc::ENOENT | libc::ECONNREFUSED) => {
                return Err(Failure::Unreachable("localflowd is not running".into()));
            }
            _ => {
                return Err(Failure::Unreachable(format!(
                    "cannot connect to {}: {err}",
                    path.display()
                )));
            }
        }
    }
    let stream = UnixStream::from(fd);
    stream
        .set_nonblocking(false)
        .map_err(|e| Failure::Protocol(e.to_string()))?;
    Ok(stream)
}

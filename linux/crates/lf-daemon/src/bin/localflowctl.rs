//! `localflowctl`: sends one command to `localflowd` and prints the reply.
//!
//! `localflowctl watch` instead stays connected and prints a status line on
//! every change (and level lines while recording); `watch --waybar` prints
//! Waybar JSON, shows "offline" while the daemon is unreachable, and keeps
//! reconnecting, so the bar never needs a restart.
//!
//! `localflowctl correct` teaches the custom dictionary from a correction of
//! the last dictation, in rofi (see `lf_daemon::rofi`); it never changes the
//! text already typed. `localflowctl dict …` manages the dictionary. Text
//! from the daemon is never printed, and reaches rofi only through a pipe
//! or an inherited descriptor, never its command line.
//!
//! Exit codes:
//! - 0: the daemon accepted the command (stdout: the reply fields, without
//!   any text), or the reader of `watch` output went away;
//! - 1: the daemon answered with an error (stderr: the error code);
//! - 2: usage error;
//! - 3: the daemon is not reachable (not running, or no runtime directory),
//!   or a `watch` connection was lost;
//! - 4: timed out;
//! - 5: protocol error (bad reply, or the socket belongs to another user);
//! - 6: the dictionary file cannot be read (`dict list`, `dict ignored`);
//! - 7: rofi failed (`correct`).

use std::io::{ErrorKind, Read, Write};
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use lf_daemon::protocol::{
    self, ClientReply, Command, MAX_LINE, MAX_TEXT_LINE, Request, decode_pct, monotonic_ns,
    parse_dec, parse_reply, printable_fields, reply_field, request_line,
};
use lf_daemon::rofi::{self, Answer, Rofi};
use lf_daemon::server::peer_uid;
use lf_daemon::waybar::Indicator;
use lf_daemon::{dictionary, paths};

const USAGE: &str = "usage: localflowctl [--timeout-ms N] <command>
       localflowctl [--timeout-ms N] watch [--waybar]
       localflowctl [--timeout-ms N] correct
       localflowctl [--timeout-ms N] dict add <word…> [--strength F]
       localflowctl [--timeout-ms N] dict remove|unignore <word…>
       localflowctl dict list|ignored

commands:
  press     start hold-to-talk (key down)
  release   end hold-to-talk (key up)
  toggle    start or stop tap-to-toggle dictation
  cancel    discard the recording, or abandon transcription and typing
  again     type the last dictation again
  status    print the daemon state
  watch     print the state on every change; --waybar prints JSON for a
            Waybar custom module and reconnects while the daemon is down
  correct   edit the last dictation in rofi (within two minutes of typing
            it) to teach the dictionary; the text already typed is not
            changed. A word the audio confirms is offered for adding.
  dict      add (strength 0.25 to 8, default 1), remove, list the custom
            dictionary; ignored lists words never suggested, unignore
            allows one again";

/// Above the microphone start timeout (3 s) plus the reply, so a missing
/// device is reported as an error rather than a client timeout.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(6);

/// How often `watch --waybar` tries to reach a daemon that is not running.
const WAYBAR_RETRY: Duration = Duration::from_secs(2);

/// How often, and how long, `correct` polls for the check's result.
const RESULT_POLL: Duration = Duration::from_millis(200);
const RESULT_WAIT: Duration = Duration::from_secs(5);

enum Failure {
    Daemon(String),
    Usage(String),
    Unreachable(String),
    Timeout,
    Protocol(String),
    /// Stdout's reader went away (`watch`); exits quietly with 0.
    Closed,
    /// The dictionary file could not be read.
    Dictionary(String),
    /// rofi failed.
    Helper(String),
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
            Failure::Dictionary(_) => 6,
            Failure::Helper(_) => 7,
        }
    }
}

enum DictAction {
    Add { word: String, strength: Option<u32> },
    Remove(String),
    List,
    Ignored,
    Unignore(String),
}

enum Action {
    /// A key command or `status`.
    Send(Command),
    Watch,
    Correct,
    Dict(DictAction),
}

struct Args {
    action: Action,
    timeout: Duration,
    waybar: bool,
}

fn main() -> ExitCode {
    // First, so the stamp orders this key event against the next one.
    let started = monotonic_ns();
    let result = parse_args().and_then(|args| match &args.action {
        Action::Watch if args.waybar => {
            watch_waybar(&args);
            Ok(None)
        }
        Action::Watch => watch(&args).map(|()| None),
        Action::Send(command) => run(started, *command, &args).map(|f| Some(printable_fields(&f))),
        Action::Correct => correct(&args).map(|m| Some(m.into())),
        Action::Dict(d) => dict(d, &args).map(|m| m.map(String::from)),
    });
    match result {
        Ok(out) => {
            if let Some(out) = out {
                println!("{out}");
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
                Failure::Dictionary(m) => eprintln!("localflowctl: dictionary: {m}"),
                Failure::Helper(m) => eprintln!("localflowctl: {m}"),
                Failure::Closed => {}
            }
            ExitCode::from(f.code())
        }
    }
}

fn usage(m: &str) -> Failure {
    Failure::Usage(if m.is_empty() {
        USAGE.into()
    } else {
        format!("{m}\n{USAGE}")
    })
}

fn parse_args() -> Result<Args, Failure> {
    let mut timeout = DEFAULT_TIMEOUT;
    let mut waybar = false;
    let mut strength = None;
    let mut words: Vec<String> = Vec::new();
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
                    .ok_or_else(|| usage("--timeout-ms needs 1..600000"))?;
                timeout = Duration::from_millis(ms);
            }
            "--waybar" => waybar = true,
            "--strength" => {
                strength = Some(
                    it.next()
                        .as_deref()
                        .and_then(parse_dec)
                        .ok_or_else(|| usage("--strength needs a number from 0.25 to 8"))?,
                );
            }
            _ => words.push(arg),
        }
    }
    let mut words = words.into_iter();
    let first = words.next().ok_or_else(|| usage(""))?;
    let rest: Vec<String> = words.collect();
    let word = |rest: &[String]| -> Result<String, Failure> {
        let w = rest.join(" ");
        if w.trim().is_empty() {
            return Err(usage("a word is needed"));
        }
        Ok(w)
    };
    let action = match first.as_str() {
        "correct" if rest.is_empty() => Action::Correct,
        "dict" => {
            let (sub, rest) = rest
                .split_first()
                .ok_or_else(|| usage("dict needs a subcommand"))?;
            match sub.as_str() {
                "add" => Action::Dict(DictAction::Add {
                    word: word(rest)?,
                    strength: strength.take(),
                }),
                "remove" => Action::Dict(DictAction::Remove(word(rest)?)),
                "unignore" => Action::Dict(DictAction::Unignore(word(rest)?)),
                "list" if rest.is_empty() => Action::Dict(DictAction::List),
                "ignored" if rest.is_empty() => Action::Dict(DictAction::Ignored),
                _ => return Err(usage("unknown dict subcommand")),
            }
        }
        cmd => match Command::parse(cmd).filter(|c| !c.is_text()) {
            Some(Command::Watch) if rest.is_empty() => Action::Watch,
            Some(c) if rest.is_empty() => Action::Send(c),
            Some(_) => return Err(usage("")),
            None => return Err(usage(&format!("unknown command {cmd:?}"))),
        },
    };
    if waybar && !matches!(action, Action::Watch) {
        return Err(usage("--waybar needs watch"));
    }
    if strength.is_some() {
        return Err(usage("--strength needs dict add"));
    }
    Ok(Args {
        action,
        timeout,
        waybar,
    })
}

/// Connects, checks the daemon's uid, and sends `req`.
fn open(req: &Request, deadline: Instant) -> Result<UnixStream, Failure> {
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

/// Sends `req` and returns the reply's `ok` fields.
fn exchange(req: &Request, deadline: Instant) -> Result<String, Failure> {
    let mut stream = open(req, deadline)?;
    let max = if req.command.is_text() {
        MAX_TEXT_LINE
    } else {
        MAX_LINE
    };
    let mut buf = Vec::with_capacity(MAX_LINE);
    let mut chunk = [0u8; 4096];
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
        if buf.contains(&b'\n') || buf.len() > max {
            break;
        }
    }
    let Some(end) = buf.iter().position(|&b| b == b'\n').filter(|&e| e < max) else {
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

fn run(started: u64, command: Command, args: &Args) -> Result<String, Failure> {
    let req = Request {
        command,
        at: Some(started),
        args: protocol::Args::default(),
    };
    exchange(&req, Instant::now() + args.timeout)
}

/// One text command with its own deadline.
fn text_command(command: Command, a: protocol::Args, args: &Args) -> Result<String, Failure> {
    exchange(
        &Request::with_args(command, a),
        Instant::now() + args.timeout,
    )
}

fn field<'a>(fields: &'a str, key: &str) -> Result<&'a str, Failure> {
    reply_field(fields, key).ok_or_else(|| Failure::Protocol(format!("reply without {key}")))
}

fn text_field(fields: &str, key: &str) -> Result<String, Failure> {
    decode_pct(field(fields, key)?).ok_or_else(|| Failure::Protocol(format!("bad {key}")))
}

fn number(fields: &str, key: &str) -> Result<u64, Failure> {
    field(fields, key)?
        .parse()
        .map_err(|_| Failure::Protocol(format!("bad {key}")))
}

fn helper(e: rofi::Failure) -> Failure {
    Failure::Helper(e.to_string())
}

/// `correct`: edit the last dictation in rofi, submit it, and offer a
/// confirmed word for the dictionary. Returns a message without text.
fn correct(args: &Args) -> Result<&'static str, Failure> {
    let begin = text_command(Command::CorrectBegin, Default::default(), args)?;
    let id = number(&begin, "id")?;
    let typed = text_field(&begin, "text")?;
    let rofi = Rofi::system();
    let edited = match rofi.edit(&typed).map_err(helper)? {
        Answer::Chose(t) => t,
        Answer::Dismissed => return Ok("correction cancelled"),
    };
    if edited == typed {
        return Ok("no change");
    }
    drop(typed);
    let submitted = text_command(
        Command::CorrectSubmit,
        protocol::Args {
            id: Some(id),
            text: Some(edited),
            ..Default::default()
        },
        args,
    )?;
    let job = number(&submitted, "job")?;
    // The whole wait, every exchange and sleep included, ends at `until`.
    const TOO_LONG: &str = "no suggestion (the check took too long)";
    let until = Instant::now() + RESULT_WAIT;
    let result = loop {
        let deadline = until.min(Instant::now() + args.timeout);
        let r = match exchange(
            &Request::with_args(
                Command::CorrectResult,
                protocol::Args {
                    job: Some(job),
                    ..Default::default()
                },
            ),
            deadline,
        ) {
            Ok(r) => r,
            Err(Failure::Timeout) if Instant::now() >= until => return Ok(TOO_LONG),
            Err(f) => return Err(f),
        };
        match field(&r, "result")? {
            "pending" => {
                let left = until.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    return Ok(TOO_LONG);
                }
                std::thread::sleep(RESULT_POLL.min(left));
            }
            "none" => return Ok("no suggestion"),
            "suggest" => break r,
            _ => return Err(Failure::Protocol("bad result".into())),
        }
    };
    let word = text_field(&result, "word")?;
    let strength = parse_dec(field(&result, "strength")?)
        .ok_or_else(|| Failure::Protocol("bad strength".into()))?;
    match rofi.suggest(&word).map_err(helper)? {
        Answer::Chose(rofi::ADD) => {
            text_command(
                Command::DictAdd,
                protocol::Args {
                    word: Some(word),
                    strength: Some(strength),
                    ..Default::default()
                },
                args,
            )?;
            Ok("added to the dictionary")
        }
        Answer::Chose(rofi::DONT_SUGGEST) => {
            text_command(
                Command::DictIgnore,
                protocol::Args {
                    word: Some(word),
                    ..Default::default()
                },
                args,
            )?;
            Ok("will not be suggested again")
        }
        _ => Ok("not added"),
    }
}

/// `dict …`. `list` and `ignored` print the user's own dictionary (they
/// read the file directly); the others print a message without text.
fn dict(action: &DictAction, args: &Args) -> Result<Option<&'static str>, Failure> {
    let word_args = |word: &str| protocol::Args {
        word: Some(word.to_owned()),
        ..Default::default()
    };
    match action {
        DictAction::Add { word, strength } => {
            let mut a = word_args(word);
            a.strength = *strength;
            text_command(Command::DictAdd, a, args)?;
            Ok(Some("added"))
        }
        DictAction::Remove(word) => {
            text_command(Command::DictRemove, word_args(word), args)?;
            Ok(Some("removed"))
        }
        DictAction::Unignore(word) => {
            text_command(Command::DictUnignore, word_args(word), args)?;
            Ok(Some("may be suggested again"))
        }
        DictAction::List | DictAction::Ignored => {
            let path = paths::data_dir()
                .map_err(Failure::Dictionary)?
                .join(dictionary::FILE_NAME);
            // Encodability needs the model's vocabulary, which only the
            // daemon loads; everything else is checked as the daemon does.
            let d = dictionary::read(&path, None).map_err(Failure::Dictionary)?;
            let mut out = std::io::stdout().lock();
            if matches!(action, DictAction::List) {
                for e in &d.entries {
                    let milli = (e.strength * 1000.0).round() as u32;
                    let _ = writeln!(out, "{}\t{}", e.text, protocol::format_dec(milli));
                }
            } else {
                for k in &d.ignore {
                    let _ = writeln!(out, "{k}");
                }
            }
            Ok(None)
        }
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
        let stream = open(&Request::new(Command::Watch), deadline)?;
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

//! Control socket line protocol. One request and one reply per connection,
//! each a single line of printable ASCII ending in `\n`, at most
//! [`MAX_LINE`] bytes including the newline. `watch` is the exception: its
//! connection stays open and receives status lines until either side closes.
//!
//! ```text
//! request:  localflow/1 <command> [at=<CLOCK_MONOTONIC ns when the client started>]
//! reply:    localflow/1 ok state=<state> [mode=<mode>] [tag=prompt] model=<model> [note=<note>]
//!           localflow/1 error <code>
//! ```
//!
//! Commands: press, release, toggle, cancel, status, again, watch.
//! States: idle, recording, transcribing, typing. Modes: hold, toggle.
//! Models: loading, ready. `tag=prompt` marks a prompt dictation (double-tap
//! and hold) while it is recorded, transcribed or typed; the field is absent
//! otherwise.
//!
//! `watch` subscribes to status changes. The daemon sends a watch line at
//! once, again whenever the state, mode, model or microphone presence
//! changes, and about 15 times a second while recording (for a level meter):
//!
//! ```text
//! localflow/1 ok state=<state> [mode=<mode>] [tag=prompt] model=<model> mic=<mic> [level=<0-100>]
//! localflow/1 error busy      (too many watchers; the connection closes)
//! ```
//!
//! Mics: present, absent, unknown. `level` (the input level, RMS x 100) is
//! sent only while recording. Watch lines carry no note and nothing derived
//! from dictated text. A watcher that does not keep up is disconnected.
//! A watcher sends nothing after its request; it may shut down its writing
//! side. Shutting down its reading side (or closing) ends the subscription,
//! and the daemon reclaims the place when it next needs one.

pub const VERSION: &str = "localflow/1";
pub const MAX_LINE: usize = 256;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    /// Hold key down.
    Press,
    /// Hold key up.
    Release,
    /// A full tap of the toggle key.
    Toggle,
    /// Discard the current recording, or abandon transcription and typing.
    Cancel,
    Status,
    /// Type the last dictation again (Paste Again).
    Again,
    /// Subscribe to status changes (the connection stays open).
    Watch,
}

impl Command {
    pub const ALL: [Command; 7] = [
        Command::Press,
        Command::Release,
        Command::Toggle,
        Command::Cancel,
        Command::Status,
        Command::Again,
        Command::Watch,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Command::Press => "press",
            Command::Release => "release",
            Command::Toggle => "toggle",
            Command::Cancel => "cancel",
            Command::Status => "status",
            Command::Again => "again",
            Command::Watch => "watch",
        }
    }

    pub fn parse(s: &str) -> Option<Command> {
        Command::ALL.into_iter().find(|c| c.name() == s)
    }
}

/// Why a request was rejected. Sent back as the `error` code.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorCode {
    /// Unsupported protocol version.
    Version,
    /// Not a well-formed request line.
    Malformed,
    UnknownCommand,
    TooLong,
    /// The client did not send a full line in time.
    Timeout,
    /// The microphone could not be started or stopped.
    Capture,
    /// The daemon is shutting down or its control loop did not answer.
    Unavailable,
    /// Too many watchers are connected.
    Busy,
}

impl ErrorCode {
    pub fn name(self) -> &'static str {
        match self {
            ErrorCode::Version => "version",
            ErrorCode::Malformed => "malformed",
            ErrorCode::UnknownCommand => "unknown-command",
            ErrorCode::TooLong => "too-long",
            ErrorCode::Timeout => "timeout",
            ErrorCode::Capture => "capture",
            ErrorCode::Unavailable => "unavailable",
            ErrorCode::Busy => "busy",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Idle,
    Recording,
    Transcribing,
    Typing,
}

impl State {
    pub fn name(self) -> &'static str {
        match self {
            State::Idle => "idle",
            State::Recording => "recording",
            State::Transcribing => "transcribing",
            State::Typing => "typing",
        }
    }
}

/// Extra information about what a command did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Note {
    /// The command had no effect in the current state.
    Ignored,
    /// The recording was discarded or the dictation abandoned.
    Cancelled,
    /// The recording was shorter than `min_recording_seconds` and discarded.
    TooShort,
    /// The recording contained no audio.
    Empty,
}

impl Note {
    pub fn name(self) -> &'static str {
        match self {
            Note::Ignored => "ignored",
            Note::Cancelled => "cancelled",
            Note::TooShort => "too-short",
            Note::Empty => "empty",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Status {
    pub state: State,
    /// Recording trigger mode, while recording.
    pub mode: Option<crate::session::Mode>,
    /// A prompt dictation (double-tap and hold), while it is recorded,
    /// transcribed or typed: its output gets the prompt tag.
    pub prompt: bool,
    pub model_ready: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reply {
    Ok(Status, Option<Note>),
    Error(ErrorCode),
}

impl Reply {
    pub fn to_line(self) -> String {
        match self {
            Reply::Ok(s, note) => {
                let mut line = format!("{VERSION} ok state={}", s.state.name());
                if let Some(m) = s.mode {
                    line += &format!(" mode={}", m.name());
                }
                if s.prompt {
                    line += " tag=prompt";
                }
                line += if s.model_ready {
                    " model=ready"
                } else {
                    " model=loading"
                };
                if let Some(n) = note {
                    line += &format!(" note={}", n.name());
                }
                line + "\n"
            }
            Reply::Error(code) => format!("{VERSION} error {}\n", code.name()),
        }
    }
}

/// One `watch` line: the status, microphone presence and, while recording,
/// the input level.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WatchStatus {
    pub status: Status,
    /// `Some(true)` present, `Some(false)` absent, `None` unknown.
    pub mic: Option<bool>,
    /// Input level, 0..=100.
    pub level: Option<u8>,
}

impl WatchStatus {
    pub fn to_line(self) -> String {
        let mut line = Reply::Ok(self.status, None).to_line();
        line.pop();
        line += match self.mic {
            Some(true) => " mic=present",
            Some(false) => " mic=absent",
            None => " mic=unknown",
        };
        if let Some(level) = self.level {
            line += &format!(" level={level}");
        }
        line + "\n"
    }
}

/// An `AudioCapture::level` reading (RMS in [0, 1]) as a whole percentage.
pub fn level_percent(level: f32) -> u8 {
    if level.is_finite() {
        (level.clamp(0.0, 1.0) * 100.0).round() as u8
    } else {
        0
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Request {
    pub command: Command,
    /// When the client started, in `CLOCK_MONOTONIC` nanoseconds. Hyprland
    /// starts one client process per key event, and their connections can
    /// reach the daemon out of order; this restores the key order.
    pub at: Option<u64>,
}

impl Request {
    pub fn new(command: Command) -> Request {
        Request { command, at: None }
    }
}

pub fn request_line(req: Request) -> String {
    match req.at {
        Some(at) => format!("{VERSION} {} at={at}\n", req.command.name()),
        None => format!("{VERSION} {}\n", req.command.name()),
    }
}

/// `CLOCK_MONOTONIC` now, in nanoseconds (shared by all processes).
pub fn monotonic_ns() -> u64 {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `ts` is a valid timespec to write.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    (ts.tv_sec as u64)
        .saturating_mul(1_000_000_000)
        .saturating_add(ts.tv_nsec as u64)
}

/// Parses one request line, without its trailing newline:
/// `localflow/1 <command> [at=<nanoseconds>]`.
pub fn parse_request(line: &[u8]) -> Result<Request, ErrorCode> {
    if line.len() >= MAX_LINE {
        return Err(ErrorCode::TooLong);
    }
    if !line.iter().all(|&b| (0x20..0x7f).contains(&b)) {
        return Err(ErrorCode::Malformed);
    }
    // All bytes are printable ASCII, so this cannot fail.
    let line = std::str::from_utf8(line).map_err(|_| ErrorCode::Malformed)?;
    if line.split(' ').any(str::is_empty) {
        return Err(ErrorCode::Malformed);
    }
    let mut parts = line.split(' ');
    let (Some(version), Some(cmd), at, None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Err(ErrorCode::Malformed);
    };
    if version != VERSION {
        return Err(if version.starts_with("localflow/") {
            ErrorCode::Version
        } else {
            ErrorCode::Malformed
        });
    }
    let command = Command::parse(cmd).ok_or(ErrorCode::UnknownCommand)?;
    let at = match at {
        None => None,
        Some(field) => {
            let digits = field.strip_prefix("at=").ok_or(ErrorCode::Malformed)?;
            if digits.is_empty() || digits.len() > 20 || !digits.bytes().all(|b| b.is_ascii_digit())
            {
                return Err(ErrorCode::Malformed);
            }
            Some(digits.parse().map_err(|_| ErrorCode::Malformed)?)
        }
    };
    Ok(Request { command, at })
}

/// A reply as seen by a client: `ok` with its fields, or an error code.
#[derive(Debug, PartialEq, Eq)]
pub enum ClientReply {
    Ok(String),
    Error(String),
}

/// Parses a reply line, without its trailing newline.
pub fn parse_reply(line: &[u8]) -> Option<ClientReply> {
    if line.len() >= MAX_LINE || !line.iter().all(|&b| (0x20..0x7f).contains(&b)) {
        return None;
    }
    let line = std::str::from_utf8(line).ok()?;
    let rest = line.strip_prefix(VERSION)?.strip_prefix(' ')?;
    if let Some(fields) = rest.strip_prefix("ok ") {
        let valid = fields.split(' ').all(|f| {
            f.split_once('=').is_some_and(|(k, v)| {
                !k.is_empty()
                    && !v.is_empty()
                    && f.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'=' || b == b'-')
            })
        });
        return valid.then(|| ClientReply::Ok(fields.to_owned()));
    }
    let code = rest.strip_prefix("error ")?;
    (!code.is_empty() && code.bytes().all(|b| b.is_ascii_lowercase() || b == b'-'))
        .then(|| ClientReply::Error(code.to_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::Mode;

    #[test]
    fn requests_round_trip() {
        for command in Command::ALL {
            for at in [None, Some(0), Some(u64::MAX)] {
                let req = Request { command, at };
                let line = request_line(req);
                assert!(line.len() <= MAX_LINE);
                assert_eq!(
                    parse_request(line.trim_end_matches('\n').as_bytes()),
                    Ok(req)
                );
            }
        }
        for bad in [
            &b"localflow/1 press at="[..],
            b"localflow/1 press at=-1",
            b"localflow/1 press at=1x",
            b"localflow/1 press at=99999999999999999999",
            b"localflow/1 press at=000000000000000000001",
            b"localflow/1 press t=1",
            b"localflow/1 press at=1 more",
        ] {
            assert_eq!(parse_request(bad), Err(ErrorCode::Malformed), "{bad:?}");
        }
        let a = monotonic_ns();
        assert!(monotonic_ns() >= a && a > 0);
    }

    #[test]
    fn watch_requests_and_lines() {
        assert_eq!(
            parse_request(b"localflow/1 watch"),
            Ok(Request::new(Command::Watch))
        );
        assert_eq!(
            parse_request(b"localflow/1 watch at=5"),
            Ok(Request {
                command: Command::Watch,
                at: Some(5)
            })
        );
        assert_eq!(Command::parse("watch"), Some(Command::Watch));
        assert_eq!(
            Reply::Error(ErrorCode::Busy).to_line(),
            "localflow/1 error busy\n"
        );

        let idle = Status {
            state: State::Idle,
            mode: None,
            prompt: false,
            model_ready: true,
        };
        let cases = [
            (
                WatchStatus {
                    status: idle,
                    mic: None,
                    level: None,
                },
                "localflow/1 ok state=idle model=ready mic=unknown\n",
            ),
            (
                WatchStatus {
                    status: Status {
                        model_ready: false,
                        ..idle
                    },
                    mic: Some(false),
                    level: None,
                },
                "localflow/1 ok state=idle model=loading mic=absent\n",
            ),
            (
                WatchStatus {
                    status: Status {
                        state: State::Recording,
                        mode: Some(Mode::Toggle),
                        prompt: false,
                        model_ready: true,
                    },
                    mic: Some(true),
                    level: Some(100),
                },
                "localflow/1 ok state=recording mode=toggle model=ready mic=present level=100\n",
            ),
            (
                WatchStatus {
                    status: Status {
                        state: State::Recording,
                        mode: Some(Mode::Hold),
                        prompt: true,
                        model_ready: true,
                    },
                    mic: Some(true),
                    level: Some(7),
                },
                "localflow/1 ok state=recording mode=hold tag=prompt model=ready mic=present level=7\n",
            ),
            (
                WatchStatus {
                    status: Status {
                        state: State::Typing,
                        prompt: true,
                        ..idle
                    },
                    mic: None,
                    level: None,
                },
                "localflow/1 ok state=typing tag=prompt model=ready mic=unknown\n",
            ),
        ];
        for (w, want) in cases {
            let line = w.to_line();
            assert_eq!(line, want);
            assert!(line.len() <= MAX_LINE);
            assert!(matches!(
                parse_reply(line.trim_end().as_bytes()),
                Some(ClientReply::Ok(_))
            ));
        }

        assert_eq!(level_percent(0.0), 0);
        assert_eq!(level_percent(0.424), 42);
        assert_eq!(level_percent(1.0), 100);
        assert_eq!(level_percent(7.0), 100);
        assert_eq!(level_percent(-1.0), 0);
        assert_eq!(level_percent(f32::NAN), 0);
        assert_eq!(level_percent(f32::INFINITY), 0);
    }

    #[test]
    fn rejects_bad_requests() {
        let cases: &[(&[u8], ErrorCode)] = &[
            (b"", ErrorCode::Malformed),
            (b"press", ErrorCode::Malformed),
            (b"localflow/1", ErrorCode::Malformed),
            (b"localflow/1 ", ErrorCode::Malformed),
            (b"localflow/1  press", ErrorCode::Malformed),
            (b"localflow/1 press ", ErrorCode::Malformed),
            (b"localflow/1 press extra", ErrorCode::Malformed),
            (b"localflow/1 explode at=1", ErrorCode::UnknownCommand),
            (b" localflow/1 press", ErrorCode::Malformed),
            (b"localflow/1 PRESS", ErrorCode::UnknownCommand),
            (b"localflow/1 explode", ErrorCode::UnknownCommand),
            (b"localflow/2 press", ErrorCode::Version),
            (b"localflow/1\tpress", ErrorCode::Malformed),
            (b"localflow/1 press\r", ErrorCode::Malformed),
            (b"localflow/1 pr\xc3\xa9ss", ErrorCode::Malformed),
            (b"localflow/1 press\0", ErrorCode::Malformed),
        ];
        for (line, code) in cases {
            assert_eq!(
                parse_request(line),
                Err(*code),
                "{:?}",
                String::from_utf8_lossy(line)
            );
        }
        let long = format!("localflow/1 {}", "a".repeat(MAX_LINE));
        assert_eq!(parse_request(long.as_bytes()), Err(ErrorCode::TooLong));
    }

    #[test]
    fn replies_round_trip() {
        let status = Status {
            state: State::Recording,
            mode: Some(Mode::Hold),
            prompt: false,
            model_ready: false,
        };
        let line = Reply::Ok(status, Some(Note::Ignored)).to_line();
        assert_eq!(
            line,
            "localflow/1 ok state=recording mode=hold model=loading note=ignored\n"
        );
        assert_eq!(
            parse_reply(line.trim_end().as_bytes()),
            Some(ClientReply::Ok(
                "state=recording mode=hold model=loading note=ignored".into()
            ))
        );
        let line = Reply::Error(ErrorCode::UnknownCommand).to_line();
        assert_eq!(line, "localflow/1 error unknown-command\n");
        assert_eq!(
            parse_reply(line.trim_end().as_bytes()),
            Some(ClientReply::Error("unknown-command".into()))
        );
        for bad in [
            &b""[..],
            b"localflow/1",
            b"localflow/1 ok",
            b"localflow/1 ok ",
            b"localflow/1 ok state",
            b"localflow/1 ok state=",
            b"localflow/1 ok state=idle\x1b[2J",
            b"localflow/2 ok state=idle",
            b"localflow/1 error ",
            b"localflow/1 error Bad",
            b"localflow/1 maybe",
        ] {
            assert_eq!(parse_reply(bad), None, "{:?}", String::from_utf8_lossy(bad));
        }
    }
}

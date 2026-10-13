//! Control socket line protocol. One request and one reply per connection,
//! each a single line of printable ASCII (0x20-0x7e, fields separated by
//! single spaces) ending in `\n`, at most [`MAX_LINE`] bytes including the
//! newline. Lines of the text commands (below) may be up to
//! [`MAX_TEXT_LINE`]. `watch` is the exception to one reply: its connection
//! stays open and receives status lines until either side closes.
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
//!
//! # Text commands (custom dictionary)
//!
//! Only these commands carry text, and only in the fields shown. Each field
//! appears at most once, in any order; an unknown, repeated, missing or
//! malformed field is `error bad-request`. `<status>` is the usual
//! `state=… [mode=…] [tag=prompt] model=…`.
//!
//! ```text
//! correct-begin                          ok <status> id=<u64> text=<pct>
//!                                        errors: no-recent, too-long
//! correct-submit id=<u64> text=<pct>     ok <status> job=<u64>   (at once)
//!                                        errors: stale, too-long, bad-request
//! correct-result job=<u64>               ok <status> result=pending | result=none
//!                                        | result=suggest word=<pct> strength=<dec> kind=replace|casing
//!                                        errors: stale, unknown-job
//! dict-add word=<pct> [strength=<dec>]   ok <status>; errors: invalid-entry, full, storage
//! dict-remove word=<pct>                 ok <status>; errors: not-found, storage
//! dict-ignore word=<pct>                 ok <status>; errors: full, storage
//! dict-unignore word=<pct>               ok <status>; errors: not-found, storage
//! ```
//!
//! - `<pct>`: UTF-8 with only `A-Z a-z 0-9 . _ ~ -` literal and every other
//!   byte as `%XX` (uppercase hex). Decoded exactly once; malformed escapes,
//!   invalid UTF-8 and C0/C1 control characters are rejected. Only `text`
//!   may be empty.
//! - `<dec>`: `[0-9]{1,2}(.[0-9]{1,3})?`, a strength within [0.25, 8].
//! - `<u64>`: 1 to 20 decimal digits.
//! - Limits, checked independently: a text frame is at most
//!   [`MAX_TEXT_LINE`] bytes encoded, and a decoded value at most
//!   [`MAX_TEXT_BYTES`]; every other frame stays within [`MAX_LINE`].
//!
//! Text, encoded or not, never appears in logs, watch lines, `Debug` output
//! or error codes.

pub const VERSION: &str = "localflow/1";
pub const MAX_LINE: usize = 256;
/// Longest text-command request or reply line, newline included.
pub const MAX_TEXT_LINE: usize = 16 * 1024;
/// Longest decoded text value.
pub const MAX_TEXT_BYTES: usize = 4096;

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
    /// Start correcting the last dictation: returns its text.
    CorrectBegin,
    /// Submit the corrected text; returns a job to poll.
    CorrectSubmit,
    /// Poll a correction job.
    CorrectResult,
    DictAdd,
    DictRemove,
    DictIgnore,
    DictUnignore,
}

impl Command {
    pub const ALL: [Command; 14] = [
        Command::Press,
        Command::Release,
        Command::Toggle,
        Command::Cancel,
        Command::Status,
        Command::Again,
        Command::Watch,
        Command::CorrectBegin,
        Command::CorrectSubmit,
        Command::CorrectResult,
        Command::DictAdd,
        Command::DictRemove,
        Command::DictIgnore,
        Command::DictUnignore,
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
            Command::CorrectBegin => "correct-begin",
            Command::CorrectSubmit => "correct-submit",
            Command::CorrectResult => "correct-result",
            Command::DictAdd => "dict-add",
            Command::DictRemove => "dict-remove",
            Command::DictIgnore => "dict-ignore",
            Command::DictUnignore => "dict-unignore",
        }
    }

    pub fn parse(s: &str) -> Option<Command> {
        Command::ALL.into_iter().find(|c| c.name() == s)
    }

    /// A text command: its frames may be long and it takes [`Args`], never `at=`.
    pub fn is_text(self) -> bool {
        !matches!(
            self,
            Command::Press
                | Command::Release
                | Command::Toggle
                | Command::Cancel
                | Command::Status
                | Command::Again
                | Command::Watch
        )
    }

    /// Fields a text command takes: `(key, required)`.
    fn fields(self) -> &'static [(&'static str, bool)] {
        match self {
            Command::CorrectSubmit => &[("id", true), ("text", true)],
            Command::CorrectResult => &[("job", true)],
            Command::DictAdd => &[("word", true), ("strength", false)],
            Command::DictRemove | Command::DictIgnore | Command::DictUnignore => &[("word", true)],
            _ => &[],
        }
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
    /// The line, or a decoded text value, is too long.
    TooLong,
    /// The client did not send a full line in time.
    Timeout,
    /// The microphone could not be started or stopped.
    Capture,
    /// The daemon is shutting down or its control loop did not answer.
    Unavailable,
    /// Too many watchers are connected.
    Busy,
    /// A text command's fields are wrong.
    BadRequest,
    /// No dictation to correct.
    NoRecent,
    /// The correction session or job no longer exists.
    Stale,
    UnknownJob,
    /// The word cannot be a dictionary entry.
    InvalidEntry,
    /// The dictionary or ignore list is full.
    Full,
    /// The dictionary could not be saved; nothing changed.
    Storage,
    NotFound,
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
            ErrorCode::BadRequest => "bad-request",
            ErrorCode::NoRecent => "no-recent",
            ErrorCode::Stale => "stale",
            ErrorCode::UnknownJob => "unknown-job",
            ErrorCode::InvalidEntry => "invalid-entry",
            ErrorCode::Full => "full",
            ErrorCode::Storage => "storage",
            ErrorCode::NotFound => "not-found",
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

/// What a correction job concluded, for `correct-result`.
#[derive(Clone, PartialEq, Eq)]
pub enum CorrectionResult {
    Pending,
    None,
    Suggest {
        word: String,
        /// Thousandths.
        strength: u32,
        casing: bool,
    },
}

/// Shows no word.
impl std::fmt::Debug for CorrectionResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CorrectionResult::Pending => f.write_str("Pending"),
            CorrectionResult::None => f.write_str("None"),
            CorrectionResult::Suggest {
                strength, casing, ..
            } => write!(f, "Suggest(strength {strength}, casing {casing})"),
        }
    }
}

/// The fields a text command's reply adds after the status.
#[derive(Clone, PartialEq, Eq)]
pub enum Extra {
    /// `correct-begin`.
    Correction { id: u64, text: String },
    /// `correct-submit`.
    Job(u64),
    /// `correct-result`.
    Result(CorrectionResult),
}

#[derive(Clone, PartialEq, Eq)]
pub enum Reply {
    Ok(Status, Option<Note>),
    With(Status, Extra),
    Error(ErrorCode),
}

/// Never shows text, only which fields a reply has.
impl std::fmt::Debug for Reply {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Reply::Ok(s, n) => f.debug_tuple("Ok").field(s).field(n).finish(),
            Reply::With(s, e) => {
                let what = match e {
                    Extra::Correction { id, .. } => format!("Correction(id {id})"),
                    Extra::Job(j) => format!("Job({j})"),
                    Extra::Result(CorrectionResult::Pending) => "Pending".into(),
                    Extra::Result(CorrectionResult::None) => "None".into(),
                    Extra::Result(CorrectionResult::Suggest {
                        strength, casing, ..
                    }) => {
                        format!("Suggest(strength {strength}, casing {casing})")
                    }
                };
                f.debug_tuple("With").field(s).field(&what).finish()
            }
            Reply::Error(c) => f.debug_tuple("Error").field(c).finish(),
        }
    }
}

fn status_fields(s: Status) -> String {
    let mut line = format!("state={}", s.state.name());
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
    line
}

impl Reply {
    pub fn to_line(&self) -> String {
        match self {
            Reply::Ok(s, note) => {
                let mut line = format!("{VERSION} ok {}", status_fields(*s));
                if let Some(n) = note {
                    line += &format!(" note={}", n.name());
                }
                line + "\n"
            }
            Reply::With(s, extra) => {
                let mut line = format!("{VERSION} ok {}", status_fields(*s));
                match extra {
                    Extra::Correction { id, text } => {
                        line += &format!(" id={id} text={}", encode_pct(text));
                    }
                    Extra::Job(job) => line += &format!(" job={job}"),
                    Extra::Result(CorrectionResult::Pending) => line += " result=pending",
                    Extra::Result(CorrectionResult::None) => line += " result=none",
                    Extra::Result(CorrectionResult::Suggest {
                        word,
                        strength,
                        casing,
                    }) => {
                        line += &format!(
                            " result=suggest word={} strength={} kind={}",
                            encode_pct(word),
                            format_dec(*strength),
                            if *casing { "casing" } else { "replace" }
                        );
                    }
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

/// A text command's fields, decoded.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct Args {
    pub id: Option<u64>,
    pub job: Option<u64>,
    pub text: Option<String>,
    pub word: Option<String>,
    /// Thousandths.
    pub strength: Option<u32>,
}

/// Shows which fields are present, never their text.
impl std::fmt::Debug for Args {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Args")
            .field("id", &self.id)
            .field("job", &self.job)
            .field("text", &self.text.as_ref().map(|_| ".."))
            .field("word", &self.word.as_ref().map(|_| ".."))
            .field("strength", &self.strength)
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub command: Command,
    /// When the client started, in `CLOCK_MONOTONIC` nanoseconds. Hyprland
    /// starts one client process per key event, and their connections can
    /// reach the daemon out of order; this restores the key order.
    pub at: Option<u64>,
    /// A text command's fields (empty otherwise).
    pub args: Args,
}

impl Request {
    pub fn new(command: Command) -> Request {
        Request {
            command,
            at: None,
            args: Args::default(),
        }
    }

    pub fn with_args(command: Command, args: Args) -> Request {
        Request {
            command,
            at: None,
            args,
        }
    }
}

pub fn request_line(req: &Request) -> String {
    let mut line = format!("{VERSION} {}", req.command.name());
    if let Some(at) = req.at {
        line += &format!(" at={at}");
    }
    let a = &req.args;
    if let Some(id) = a.id {
        line += &format!(" id={id}");
    }
    if let Some(job) = a.job {
        line += &format!(" job={job}");
    }
    if let Some(text) = &a.text {
        line += &format!(" text={}", encode_pct(text));
    }
    if let Some(word) = &a.word {
        line += &format!(" word={}", encode_pct(word));
    }
    if let Some(s) = a.strength {
        line += &format!(" strength={}", format_dec(s));
    }
    line + "\n"
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

/// Bytes kept literal by `<pct>`.
fn pct_literal(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'~' | b'-')
}

/// `<pct>` encoding of UTF-8 text.
pub fn encode_pct(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for &b in s.as_bytes() {
        if pct_literal(b) {
            out.push(b as char);
        } else {
            out += &format!("%{b:02X}");
        }
    }
    out
}

/// A C0 or C1 control character (or DEL).
pub fn is_control(c: char) -> bool {
    matches!(c, '\0'..='\u{1f}' | '\u{7f}'..='\u{9f}')
}

/// Decodes a `<pct>` value exactly once: escapes must be `%` and two
/// uppercase hex digits, the result valid UTF-8 without control characters.
pub fn decode_pct(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            let hex = |c: u8| match c {
                b'0'..=b'9' => Some(c - b'0'),
                b'A'..=b'F' => Some(c - b'A' + 10),
                _ => None,
            };
            let hi = hex(*b.get(i + 1)?)?;
            let lo = hex(*b.get(i + 2)?)?;
            out.push(hi << 4 | lo);
            i += 3;
        } else if pct_literal(b[i]) {
            out.push(b[i]);
            i += 1;
        } else {
            return None;
        }
    }
    let text = String::from_utf8(out).ok()?;
    (!text.chars().any(is_control)).then_some(text)
}

/// `<dec>` for thousandths (no trailing zeros; `1000` is `1`).
pub fn format_dec(milli: u32) -> String {
    let (int, frac) = (milli / 1000, milli % 1000);
    if frac == 0 {
        return int.to_string();
    }
    let mut f = format!("{frac:03}");
    while f.ends_with('0') {
        f.pop();
    }
    format!("{int}.{f}")
}

/// Strengths a `<dec>` may give, in thousandths.
pub const STRENGTH_RANGE: std::ops::RangeInclusive<u32> = 250..=8000;

/// Parses `<dec>` (`[0-9]{1,2}(.[0-9]{1,3})?`) into thousandths within
/// [`STRENGTH_RANGE`].
pub fn parse_dec(s: &str) -> Option<u32> {
    let (int, frac) = match s.split_once('.') {
        Some((i, f)) => (i, Some(f)),
        None => (s, None),
    };
    let digits =
        |d: &str, max: usize| (1..=max).contains(&d.len()) && d.bytes().all(|b| b.is_ascii_digit());
    if !digits(int, 2) || frac.is_some_and(|f| !digits(f, 3)) {
        return None;
    }
    let mut milli = int.parse::<u32>().ok()? * 1000;
    if let Some(f) = frac {
        milli += format!("{f:0<3}").parse::<u32>().ok()?;
    }
    STRENGTH_RANGE.contains(&milli).then_some(milli)
}

fn parse_u64(s: &str) -> Option<u64> {
    if s.is_empty() || s.len() > 20 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

/// Parses one request line, without its trailing newline:
/// `localflow/1 <command> [at=<nanoseconds>]`, or a text command with its
/// fields (see the module docs).
pub fn parse_request(line: &[u8]) -> Result<Request, ErrorCode> {
    if line.len() >= MAX_TEXT_LINE {
        return Err(ErrorCode::TooLong);
    }
    if !line.iter().all(|&b| (0x20..0x7f).contains(&b)) {
        return Err(ErrorCode::Malformed);
    }
    // All bytes are printable ASCII, so this cannot fail.
    let line_str = std::str::from_utf8(line).map_err(|_| ErrorCode::Malformed)?;
    // Fields are split before anything is decoded.
    let fields: Vec<&str> = line_str.split(' ').collect();
    if fields.iter().any(|f| f.is_empty()) {
        return Err(if line.len() >= MAX_LINE {
            ErrorCode::TooLong
        } else {
            ErrorCode::Malformed
        });
    }
    let (Some(&version), Some(&cmd)) = (fields.first(), fields.get(1)) else {
        return Err(ErrorCode::Malformed);
    };
    if version != VERSION {
        return Err(if version.starts_with("localflow/") {
            ErrorCode::Version
        } else {
            ErrorCode::Malformed
        });
    }
    let command = Command::parse(cmd).ok_or(if line.len() >= MAX_LINE {
        ErrorCode::TooLong
    } else {
        ErrorCode::UnknownCommand
    })?;
    if !command.is_text() {
        if line.len() >= MAX_LINE {
            return Err(ErrorCode::TooLong);
        }
        let at = match fields[2..] {
            [] => None,
            [field] => {
                let digits = field.strip_prefix("at=").ok_or(ErrorCode::Malformed)?;
                Some(parse_u64(digits).ok_or(ErrorCode::Malformed)?)
            }
            _ => return Err(ErrorCode::Malformed),
        };
        return Ok(Request {
            command,
            at,
            args: Args::default(),
        });
    }
    let schema = command.fields();
    let mut args = Args::default();
    let mut seen: Vec<&str> = Vec::new();
    for field in &fields[2..] {
        let (key, value) = field.split_once('=').ok_or(ErrorCode::BadRequest)?;
        if !schema.iter().any(|(k, _)| *k == key) || seen.contains(&key) {
            return Err(ErrorCode::BadRequest);
        }
        seen.push(key);
        let text = |v: &str, empty_ok: bool| -> Result<String, ErrorCode> {
            let t = decode_pct(v).ok_or(ErrorCode::BadRequest)?;
            if t.len() > MAX_TEXT_BYTES {
                return Err(ErrorCode::TooLong);
            }
            if t.is_empty() && !empty_ok {
                return Err(ErrorCode::BadRequest);
            }
            Ok(t)
        };
        match key {
            "id" => args.id = Some(parse_u64(value).ok_or(ErrorCode::BadRequest)?),
            "job" => args.job = Some(parse_u64(value).ok_or(ErrorCode::BadRequest)?),
            "text" => args.text = Some(text(value, true)?),
            "word" => args.word = Some(text(value, false)?),
            "strength" => args.strength = Some(parse_dec(value).ok_or(ErrorCode::BadRequest)?),
            _ => return Err(ErrorCode::BadRequest),
        }
    }
    if schema
        .iter()
        .any(|(k, required)| *required && !seen.contains(k))
    {
        return Err(ErrorCode::BadRequest);
    }
    Ok(Request {
        command,
        at: None,
        args,
    })
}

/// Reply keys whose values are text: clients must not print them.
pub const TEXT_KEYS: [&str; 2] = ["text", "word"];

/// A reply as seen by a client: `ok` with its fields, or an error code.
#[derive(PartialEq, Eq)]
pub enum ClientReply {
    Ok(String),
    Error(String),
}

/// Shows no field values (they may carry text).
impl std::fmt::Debug for ClientReply {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ClientReply::Ok(_) => f.write_str("Ok(..)"),
            ClientReply::Error(code) => f.debug_tuple("Error").field(code).finish(),
        }
    }
}

/// Parses a reply line, without its trailing newline. Lines up to
/// [`MAX_TEXT_LINE`] are accepted; a field is `key=value` with a key of
/// lowercase letters and `-` and a value of `<pct>` characters, non-empty
/// except for `text`.
pub fn parse_reply(line: &[u8]) -> Option<ClientReply> {
    if line.len() >= MAX_TEXT_LINE || !line.iter().all(|&b| (0x20..0x7f).contains(&b)) {
        return None;
    }
    let line = std::str::from_utf8(line).ok()?;
    let rest = line.strip_prefix(VERSION)?.strip_prefix(' ')?;
    if let Some(fields) = rest.strip_prefix("ok ") {
        let valid = fields.split(' ').all(|f| {
            f.split_once('=').is_some_and(|(k, v)| {
                !k.is_empty()
                    && k.bytes().all(|b| b.is_ascii_lowercase() || b == b'-')
                    && (!v.is_empty() || k == "text")
                    && v.bytes().all(|b| pct_literal(b) || b == b'%')
            })
        });
        return valid.then(|| ClientReply::Ok(fields.to_owned()));
    }
    let code = rest.strip_prefix("error ")?;
    (!code.is_empty() && code.bytes().all(|b| b.is_ascii_lowercase() || b == b'-'))
        .then(|| ClientReply::Error(code.to_owned()))
}

/// The value of `key` among reply fields.
pub fn reply_field<'a>(fields: &'a str, key: &str) -> Option<&'a str> {
    fields
        .split(' ')
        .find_map(|f| f.split_once('=').filter(|(k, _)| *k == key).map(|(_, v)| v))
}

/// Reply fields fit to print: without [`TEXT_KEYS`].
pub fn printable_fields(fields: &str) -> String {
    fields
        .split(' ')
        .filter(|f| {
            f.split_once('=')
                .is_none_or(|(k, _)| !TEXT_KEYS.contains(&k))
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::Mode;

    const KEY_COMMANDS: [Command; 7] = [
        Command::Press,
        Command::Release,
        Command::Toggle,
        Command::Cancel,
        Command::Status,
        Command::Again,
        Command::Watch,
    ];

    #[test]
    fn requests_round_trip() {
        for command in KEY_COMMANDS {
            for at in [None, Some(0), Some(u64::MAX)] {
                let req = Request {
                    command,
                    at,
                    args: Args::default(),
                };
                let line = request_line(&req);
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
                at: Some(5),
                args: Args::default(),
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
        // Key commands keep the short limit even with a long frame.
        let long = format!("localflow/1 press at={}", "1".repeat(MAX_LINE));
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
            b"localflow/1 ok state=idle word=",
            b"localflow/1 ok state=idle text=a+b",
            b"localflow/1 ok State=idle",
        ] {
            assert_eq!(parse_reply(bad), None, "{:?}", String::from_utf8_lossy(bad));
        }
    }

    const IDLE: Status = Status {
        state: State::Idle,
        mode: None,
        prompt: false,
        model_ready: true,
    };

    #[test]
    fn pct_round_trips_any_text_and_rejects_the_rest() {
        for s in [
            "",
            "plain",
            "Synthetic words, with spaces & symbols: 100% / x=y?",
            "na\u{ef}ve caf\u{e9} \u{3b1}\u{3b8} \u{1f642} e\u{301}",
            "A-Z_a.z~0",
        ] {
            let e = encode_pct(s);
            assert!(e.bytes().all(|b| pct_literal(b) || b == b'%'), "{e}");
            assert_eq!(decode_pct(&e).as_deref(), Some(s));
        }
        assert_eq!(encode_pct("a b"), "a%20b");
        assert_eq!(encode_pct("\u{e9}"), "%C3%A9");
        assert_eq!(decode_pct("%41").as_deref(), Some("A"));
        for bad in [
            "%", "%4", "%4G", "%c3%a9", "a b", "a+b", "%C3", "%FF", "a%0Ab", "%7F", "%C2%80",
            "%C2%9F", "%00", "a=b", "%E2%82",
        ] {
            assert_eq!(decode_pct(bad), None, "{bad}");
        }
        // Decoded exactly once: an escaped escape stays an escape.
        assert_eq!(decode_pct("%2541").as_deref(), Some("%41"));
    }

    #[test]
    fn dec_syntax_and_range() {
        for (s, milli) in [
            ("1", 1000),
            ("1.0", 1000),
            ("1.41", 1410),
            ("0.25", 250),
            ("4", 4000),
            ("4.000", 4000),
            ("5.66", 5660),
            ("8", 8000),
            ("2.83", 2830),
            ("01.5", 1500),
        ] {
            assert_eq!(parse_dec(s), Some(milli), "{s}");
        }
        for bad in [
            "", ".5", "1.", "1.4142", "100", "0.24", "8.001", "-1", "1e0", "1,5", " 1", "nan",
        ] {
            assert_eq!(parse_dec(bad), None, "{bad}");
        }
        for milli in [250, 500, 1000, 1410, 2000, 2830, 4000, 5660, 8000, 1234] {
            assert_eq!(parse_dec(&format_dec(milli)), Some(milli));
        }
        assert_eq!(format_dec(1000), "1");
        assert_eq!(format_dec(1410), "1.41");
        assert_eq!(format_dec(250), "0.25");
    }

    fn args(f: impl FnOnce(&mut Args)) -> Args {
        let mut a = Args::default();
        f(&mut a);
        a
    }

    #[test]
    fn text_requests_round_trip() {
        let long = "w".repeat(MAX_TEXT_BYTES);
        let cases = [
            Request::new(Command::CorrectBegin),
            Request::with_args(
                Command::CorrectSubmit,
                args(|a| {
                    a.id = Some(7);
                    a.text = Some("Synthetic \u{e9}dit, 100%".into());
                }),
            ),
            Request::with_args(
                Command::CorrectSubmit,
                args(|a| {
                    a.id = Some(u64::MAX);
                    a.text = Some(String::new());
                }),
            ),
            // Worst case: every byte escaped.
            Request::with_args(
                Command::CorrectSubmit,
                args(|a| {
                    a.id = Some(1);
                    a.text = Some(" ".repeat(MAX_TEXT_BYTES));
                }),
            ),
            Request::with_args(
                Command::CorrectSubmit,
                args(|a| {
                    a.id = Some(1);
                    a.text = Some(long.clone());
                }),
            ),
            Request::with_args(Command::CorrectResult, args(|a| a.job = Some(3))),
            Request::with_args(
                Command::DictAdd,
                args(|a| {
                    a.word = Some("New York".into());
                    a.strength = Some(1410);
                }),
            ),
            Request::with_args(Command::DictAdd, args(|a| a.word = Some("C#".into()))),
            Request::with_args(Command::DictRemove, args(|a| a.word = Some("x".into()))),
            Request::with_args(Command::DictIgnore, args(|a| a.word = Some("x".into()))),
            Request::with_args(Command::DictUnignore, args(|a| a.word = Some("x".into()))),
        ];
        for req in cases {
            let line = request_line(&req);
            assert!(line.len() <= MAX_TEXT_LINE, "{}", line.len());
            assert_eq!(
                parse_request(line.trim_end_matches('\n').as_bytes()),
                Ok(req.clone()),
                "{:?}",
                req.command
            );
        }
        // Field order does not matter.
        assert_eq!(
            parse_request(b"localflow/1 dict-add strength=2 word=a"),
            Ok(Request::with_args(
                Command::DictAdd,
                args(|a| {
                    a.word = Some("a".into());
                    a.strength = Some(2000);
                })
            ))
        );
    }

    #[test]
    fn text_requests_are_strict() {
        let cases: &[(&str, ErrorCode)] = &[
            ("localflow/1 correct-begin at=5", ErrorCode::BadRequest),
            ("localflow/1 correct-begin x=1", ErrorCode::BadRequest),
            ("localflow/1 correct-submit id=1", ErrorCode::BadRequest),
            ("localflow/1 correct-submit text=a", ErrorCode::BadRequest),
            (
                "localflow/1 correct-submit id=1 text=a text=b",
                ErrorCode::BadRequest,
            ),
            (
                "localflow/1 correct-submit id=1 id=1 text=a",
                ErrorCode::BadRequest,
            ),
            (
                "localflow/1 correct-submit id=x text=a",
                ErrorCode::BadRequest,
            ),
            (
                "localflow/1 correct-submit id= text=a",
                ErrorCode::BadRequest,
            ),
            (
                "localflow/1 correct-submit id=1 text=a%2",
                ErrorCode::BadRequest,
            ),
            (
                "localflow/1 correct-submit id=1 text=a%0A",
                ErrorCode::BadRequest,
            ),
            (
                "localflow/1 correct-submit id=1 text=%C2%85",
                ErrorCode::BadRequest,
            ),
            (
                "localflow/1 correct-submit id=1 text=%FF",
                ErrorCode::BadRequest,
            ),
            (
                "localflow/1 correct-submit id=1 text=a+b",
                ErrorCode::BadRequest,
            ),
            (
                "localflow/1 correct-submit id=1 text",
                ErrorCode::BadRequest,
            ),
            (
                "localflow/1 correct-submit id=1 word=a",
                ErrorCode::BadRequest,
            ),
            ("localflow/1 correct-result", ErrorCode::BadRequest),
            (
                "localflow/1 correct-result job=1 id=1",
                ErrorCode::BadRequest,
            ),
            ("localflow/1 dict-add", ErrorCode::BadRequest),
            ("localflow/1 dict-add word=", ErrorCode::BadRequest),
            (
                "localflow/1 dict-add word=a strength=9",
                ErrorCode::BadRequest,
            ),
            (
                "localflow/1 dict-add word=a strength=1.41421",
                ErrorCode::BadRequest,
            ),
            (
                "localflow/1 dict-remove word=a strength=1",
                ErrorCode::BadRequest,
            ),
            (
                "localflow/1 dict-ignore word=a word=b",
                ErrorCode::BadRequest,
            ),
            ("localflow/1 dict-unignore", ErrorCode::BadRequest),
            (
                "localflow/1 correct-submit id=1  text=a",
                ErrorCode::Malformed,
            ),
        ];
        for (line, code) in cases {
            assert_eq!(parse_request(line.as_bytes()), Err(*code), "{line}");
        }
        // Decoded and encoded limits are independent.
        let over = format!(
            "localflow/1 correct-submit id=1 text={}",
            "w".repeat(MAX_TEXT_BYTES + 1)
        );
        assert_eq!(parse_request(over.as_bytes()), Err(ErrorCode::TooLong));
        let at = format!(
            "localflow/1 correct-submit id=1 text={}",
            "w".repeat(MAX_TEXT_BYTES)
        );
        assert!(parse_request(at.as_bytes()).is_ok());
        let frame = format!(
            "localflow/1 correct-submit id=1 text={}",
            "%20".repeat(MAX_TEXT_LINE / 3)
        );
        assert_eq!(parse_request(frame.as_bytes()), Err(ErrorCode::TooLong));
        let word = format!(
            "localflow/1 dict-add word={}",
            "w".repeat(MAX_TEXT_BYTES + 1)
        );
        assert_eq!(parse_request(word.as_bytes()), Err(ErrorCode::TooLong));
    }

    #[test]
    fn text_replies_round_trip_and_print_no_text() {
        let text = "Synthetic dictation, typed \u{e9}.";
        let cases = [
            (
                Reply::With(
                    IDLE,
                    Extra::Correction {
                        id: 4,
                        text: text.into(),
                    },
                ),
                "localflow/1 ok state=idle model=ready id=4 text=Synthetic%20dictation%2C%20typed%20%C3%A9.\n",
            ),
            (
                Reply::With(IDLE, Extra::Job(9)),
                "localflow/1 ok state=idle model=ready job=9\n",
            ),
            (
                Reply::With(IDLE, Extra::Result(CorrectionResult::Pending)),
                "localflow/1 ok state=idle model=ready result=pending\n",
            ),
            (
                Reply::With(IDLE, Extra::Result(CorrectionResult::None)),
                "localflow/1 ok state=idle model=ready result=none\n",
            ),
            (
                Reply::With(
                    IDLE,
                    Extra::Result(CorrectionResult::Suggest {
                        word: "New York".into(),
                        strength: 1410,
                        casing: false,
                    }),
                ),
                "localflow/1 ok state=idle model=ready result=suggest word=New%20York strength=1.41 kind=replace\n",
            ),
            (
                Reply::With(
                    IDLE,
                    Extra::Result(CorrectionResult::Suggest {
                        word: "NixOS".into(),
                        strength: 1000,
                        casing: true,
                    }),
                ),
                "localflow/1 ok state=idle model=ready result=suggest word=NixOS strength=1 kind=casing\n",
            ),
        ];
        for (reply, want) in cases {
            let line = reply.to_line();
            assert_eq!(line, want);
            let Some(ClientReply::Ok(fields)) = parse_reply(line.trim_end().as_bytes()) else {
                panic!("{reply:?}");
            };
            let printed = printable_fields(&fields);
            assert!(!printed.contains("text=") && !printed.contains("word="));
            assert!(!printed.contains("Synthetic") && !printed.contains("York"));
            // Debug shows no text either.
            let d = format!("{reply:?} {:?}", ClientReply::Ok(fields.clone()));
            assert!(
                !d.contains("Synthetic") && !d.contains("York") && !d.contains("NixOS"),
                "{d}"
            );
        }
        assert_eq!(
            reply_field("state=idle id=4 text=a%20b", "text"),
            Some("a%20b")
        );
        assert_eq!(reply_field("state=idle", "text"), None);
        // The largest correct-begin reply fits a text line.
        let worst = Reply::With(
            IDLE,
            Extra::Correction {
                id: u64::MAX,
                text: "\u{e9}".repeat(MAX_TEXT_BYTES / 2),
            },
        )
        .to_line();
        assert!(worst.len() < MAX_TEXT_LINE);
        let args = Args {
            word: Some("Synthetic".into()),
            text: Some("Synthetic".into()),
            ..Args::default()
        };
        assert!(!format!("{args:?}").contains("Synthetic"));
        // Every error code is a valid reply.
        for code in [
            ErrorCode::BadRequest,
            ErrorCode::NoRecent,
            ErrorCode::Stale,
            ErrorCode::UnknownJob,
            ErrorCode::InvalidEntry,
            ErrorCode::Full,
            ErrorCode::Storage,
            ErrorCode::NotFound,
        ] {
            let line = Reply::Error(code).to_line();
            assert_eq!(
                parse_reply(line.trim_end().as_bytes()),
                Some(ClientReply::Error(code.name().into()))
            );
        }
    }
}

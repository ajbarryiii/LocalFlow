//! The T3 Code bridge behind `localflowctl agents t3` (AGENT-LINK.md, "T3
//! Code bridge").
//!
//! - The token file must be a regular file owned by the effective uid with
//!   no group or other permission bits, at most [`MAX_TOKEN_FILE_BYTES`],
//!   holding one token of `0x21`–`0x7e` characters (surrounding whitespace
//!   trimmed). It is opened with `O_NOFOLLOW`, so a symlink is refused as
//!   not regular. The token is never printed: [`Token`]'s `Debug` hides it
//!   and no error or message quotes it.
//! - T3's `server-runtime.json` gives the host and port; an unspecified
//!   address becomes loopback, and any other host must be loopback.
//! - [`poll`] sends one `GET /api/orchestration/shell` over plain HTTP/1.1
//!   (`Connection: close`) and [`count`]s the snapshot's threads.
//! - [`Bridge::step`] re-reads both files, polls, and reports the counts to
//!   the daemon through a [`Reporter`]. Only counts leave this module:
//!   never thread titles, messages or the token.

use std::ffi::OsString;
use std::fmt;
use std::fs::File;
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::Value;

use crate::private_file::{self, ModeRule, ReadError};

/// The largest token file accepted.
pub const MAX_TOKEN_FILE_BYTES: u64 = 4096;
/// The largest response body accepted.
pub const MAX_BODY_BYTES: usize = 32 << 20;
/// The largest status line plus headers accepted.
pub const MAX_HEAD_BYTES: usize = 64 << 10;
/// The largest raw response read: the body cap plus room for the head and
/// chunk framing.
const MAX_RAW_BYTES: usize = MAX_BODY_BYTES + (1 << 20);
/// The largest `server-runtime.json` read.
const MAX_RUNTIME_BYTES: u64 = 64 << 10;
/// The daemon's limit for each count (`agents-set`).
pub const MAX_COUNT: u32 = 999;
/// The path polled.
pub const SHELL_PATH: &str = "/api/orchestration/shell";

/// Threads per state, as reported by `agents-set`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Counts {
    pub approval: u32,
    pub input: u32,
    pub working: u32,
    pub done: u32,
}

impl Counts {
    /// Each count limited to `max`.
    pub fn clamped(self, max: u32) -> Counts {
        Counts {
            approval: self.approval.min(max),
            input: self.input.min(max),
            working: self.working.min(max),
            done: self.done.min(max),
        }
    }
}

fn str_field<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

fn present(v: &Value, key: &str) -> bool {
    v.get(key).is_some_and(|x| !x.is_null())
}

/// Counts the threads of a T3 Code 0.1.0 `OrchestrationV2ShellSnapshot`,
/// mirroring T3's `projectThreadAwarenessV2`: a pending request (input,
/// else approval) first, then the run status (`activityRunStatus`, else
/// `status`). `now_iso` is the current time as [`now_iso`] formats it;
/// `snoozedUntil` is compared with it as text.
///
/// Entries of `threads` that are not objects are skipped, and a field of an
/// unexpected type counts as absent. `None` without a numeric
/// `schemaVersion` and a `threads` array, so an older (0.0.x) shell is an
/// unexpected response rather than zero counts. Counts saturate.
pub fn count(shell: &Value, now_iso: &str) -> Option<Counts> {
    shell.get("schemaVersion")?.as_u64()?;
    let threads = shell.get("threads")?.as_array()?;
    let mut c = Counts::default();
    for t in threads.iter().filter(|t| t.is_object()) {
        let subagent = t
            .get("lineage")
            .and_then(|l| str_field(l, "relationshipToParent"))
            == Some("subagent");
        if present(t, "archivedAt") || present(t, "deletedAt") || subagent {
            continue;
        }
        let request = t.get("pendingRuntimeRequest").filter(|r| r.is_object());
        let request_kind = request.and_then(|r| str_field(r, "kind"));
        let status = str_field(t, "activityRunStatus").or_else(|| str_field(t, "status"));
        let slot = if request_kind == Some("user_input") {
            &mut c.input
        } else if request.is_some() && request_kind != Some("auth_refresh") {
            &mut c.approval
        } else {
            match status {
                Some("preparing" | "starting" | "running" | "waiting") => &mut c.working,
                Some("completed") if wakes_agent(t) => &mut c.working,
                Some("completed") => {
                    let settled = match str_field(t, "settledOverride") {
                        Some("settled") => true,
                        Some("active") => false,
                        _ => present(t, "settledAt"),
                    };
                    let snoozed = str_field(t, "snoozedUntil").is_some_and(|s| s > now_iso);
                    if settled || snoozed {
                        continue;
                    }
                    &mut c.done
                }
                _ => continue,
            }
        };
        *slot = slot.saturating_add(1);
    }
    Some(c)
}

/// Background work left by a completed run that will wake the agent again
/// (T3's `backgroundWorkHoldsCompletion`): any task but a `command`, such as
/// a dev server. Unknown kinds count, as in T3.
fn wakes_agent(thread: &Value) -> bool {
    thread
        .get("pendingBackgroundTasks")
        .and_then(Value::as_array)
        .is_some_and(|tasks| {
            tasks
                .iter()
                .any(|task| str_field(task, "kind") != Some("command"))
        })
}

/// The current UTC time like JavaScript's `toISOString`:
/// `2026-10-16T21:39:12.653Z`.
pub fn now_iso() -> String {
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX));
    iso_from_unix_millis(ms)
}

/// Formats milliseconds since the Unix epoch as `YYYY-MM-DDTHH:MM:SS.mmmZ`
/// (proleptic Gregorian calendar, UTC).
pub fn iso_from_unix_millis(ms: u64) -> String {
    let millis = ms % 1000;
    let secs = ms / 1000;
    let days = secs / 86_400;
    let rem = secs % 86_400;
    // Howard Hinnant's civil_from_days, for days since 1970-01-01 >= 0.
    let z = days + 719_468;
    let era = z / 146_097;
    let doe = z % 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + u64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{millis:03}Z",
        rem / 3600,
        rem / 60 % 60,
        rem % 60
    )
}

/// Why the token file was refused. Never carries the token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TokenError {
    Missing,
    /// Not a regular file (a symlink, directory, FIFO, …).
    NotRegular,
    WrongOwner,
    /// Group or other permission bits are set (the mode is given).
    Permissions(u32),
    TooBig,
    /// Empty, or a character outside `0x21`–`0x7e`.
    Invalid,
    Io(std::io::ErrorKind),
}

impl fmt::Display for TokenError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TokenError::Missing => f.write_str("the T3 token file does not exist"),
            TokenError::NotRegular => f.write_str("the T3 token file is not a regular file"),
            TokenError::WrongOwner => {
                f.write_str("the T3 token file is not owned by the current user")
            }
            TokenError::Permissions(mode) => write!(
                f,
                "the T3 token file is accessible to other users (mode {mode:o}; use 0600)"
            ),
            TokenError::TooBig => write!(
                f,
                "the T3 token file is larger than {MAX_TOKEN_FILE_BYTES} bytes"
            ),
            TokenError::Invalid => f.write_str(
                "the T3 token file must hold one token of printable ASCII characters without spaces",
            ),
            TokenError::Io(kind) => write!(f, "cannot read the T3 token file: {kind}"),
        }
    }
}

impl std::error::Error for TokenError {}

/// A T3 session token. `Debug` does not show it.
#[derive(Clone, PartialEq, Eq)]
pub struct Token(String);

impl Token {
    /// The token itself, for the `Authorization` header only.
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for Token {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Token(..)")
    }
}

/// Reads and checks the token file (see the module docs).
pub fn read_token(path: &Path) -> Result<Token, TokenError> {
    let bytes = match private_file::read_private(path, MAX_TOKEN_FILE_BYTES, ModeRule::NoGroupOther)
    {
        Ok(Some(b)) => b,
        Ok(None) => return Err(TokenError::Missing),
        Err(ReadError::Open(e)) if e.raw_os_error() == Some(libc::ELOOP) => {
            return Err(TokenError::NotRegular);
        }
        Err(ReadError::Open(e) | ReadError::Metadata(e) | ReadError::Read(e)) => {
            return Err(TokenError::Io(e.kind()));
        }
        Err(ReadError::NotRegular) => return Err(TokenError::NotRegular),
        Err(ReadError::WrongOwner) => return Err(TokenError::WrongOwner),
        Err(ReadError::Mode(mode)) => return Err(TokenError::Permissions(mode)),
        Err(ReadError::TooLarge) => return Err(TokenError::TooBig),
    };
    let token = bytes.trim_ascii();
    if token.is_empty() || !token.iter().all(|b| (0x21..=0x7e).contains(b)) {
        return Err(TokenError::Invalid);
    }
    // All ASCII, checked above.
    Ok(Token(String::from_utf8_lossy(token).into_owned()))
}

fn absolute(value: Option<OsString>) -> Option<PathBuf> {
    value.map(PathBuf::from).filter(|p| p.is_absolute())
}

fn token_path_from(xdg_config: Option<OsString>, home: Option<OsString>) -> Option<PathBuf> {
    let base = match absolute(xdg_config) {
        Some(p) => p,
        None => absolute(home)?.join(".config"),
    };
    Some(base.join(crate::paths::APP_DIR).join("t3-token"))
}

/// `$XDG_CONFIG_HOME/localflow/t3-token`, else
/// `$HOME/.config/localflow/t3-token`. A relative value is ignored, as the
/// XDG spec says; `None` without an absolute `HOME`.
pub fn default_token_path() -> Option<PathBuf> {
    token_path_from(
        std::env::var_os("XDG_CONFIG_HOME"),
        std::env::var_os("HOME"),
    )
}

fn runtime_path_from(t3_home: Option<OsString>, home: Option<OsString>) -> Option<PathBuf> {
    let home = absolute(home);
    let base = match t3_home.filter(|v| !v.is_empty()) {
        None => home?.join(".t3"),
        Some(v) => {
            let p = PathBuf::from(v);
            if p.is_absolute() {
                p
            } else if let Ok(rest) = p.strip_prefix("~") {
                home?.join(rest)
            } else {
                // A relative T3CODE_HOME depends on T3's working directory.
                return None;
            }
        }
    };
    Some(base.join("userdata").join("server-runtime.json"))
}

/// `$T3CODE_HOME/userdata/server-runtime.json`, else
/// `$HOME/.t3/userdata/server-runtime.json`. A leading `~` in `T3CODE_HOME`
/// is expanded; any other relative value gives `None`, as does a missing or
/// relative `HOME` when it is needed.
pub fn runtime_path() -> Option<PathBuf> {
    runtime_path_from(std::env::var_os("T3CODE_HOME"), std::env::var_os("HOME"))
}

/// Where T3 Code's server listens.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Server {
    /// A loopback IPv4 address, or an unbracketed loopback IPv6 address.
    pub host: String,
    pub port: u16,
}

/// Reads `server-runtime.json`. A missing, empty or unspecified host
/// (`0.0.0.0`, `::`) and `localhost` become loopback, any other host must be
/// a loopback address, and brackets around an IPv6 address are
/// removed. Errors quote no file content.
pub fn read_server(path: &Path) -> Result<Server, String> {
    let file = File::open(path).map_err(|e| format!("cannot open {}: {e}", path.display()))?;
    let mut bytes = Vec::new();
    file.take(MAX_RUNTIME_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    if bytes.len() as u64 > MAX_RUNTIME_BYTES {
        return Err(format!("{} is too large", path.display()));
    }
    let doc: Value = serde_json::from_slice(&bytes)
        .map_err(|_| format!("{} is not valid JSON", path.display()))?;
    let port = doc
        .get("port")
        .and_then(Value::as_u64)
        .and_then(|p| u16::try_from(p).ok())
        .filter(|&p| p != 0)
        .ok_or_else(|| format!("{} has no valid port", path.display()))?;
    let host = match doc.get("host") {
        None | Some(Value::Null) => "",
        Some(Value::String(s)) => s.as_str(),
        Some(_) => return Err(format!("{} has an invalid host", path.display())),
    };
    let host = host
        .strip_prefix('[')
        .and_then(|h| h.strip_suffix(']'))
        .unwrap_or(host);
    let host = match host {
        "" | "0.0.0.0" | "localhost" => "127.0.0.1",
        "::" => "::1",
        h => h,
    };
    // The token is only ever sent over loopback; an address keeps the Host
    // header clean too.
    match host.parse::<std::net::IpAddr>() {
        Ok(ip) if ip.is_loopback() => Ok(Server {
            host: ip.to_string(),
            port,
        }),
        Ok(_) => Err(format!(
            "{} names a host that is not loopback",
            path.display()
        )),
        Err(_) => Err(format!("{} has an invalid host", path.display())),
    }
}

/// Why an HTTP response could not be decoded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HttpError {
    /// Not a valid HTTP/1.x response.
    Malformed(&'static str),
    /// The response ended early.
    Truncated,
    /// The head or body is over its limit.
    TooLarge,
}

impl fmt::Display for HttpError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            HttpError::Malformed(why) => write!(f, "malformed HTTP response: {why}"),
            HttpError::Truncated => f.write_str("truncated HTTP response"),
            HttpError::TooLarge => f.write_str("HTTP response too large"),
        }
    }
}

fn find(hay: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    hay.get(from..)?
        .windows(needle.len())
        .position(|w| w == needle)
        .map(|i| i + from)
}

/// Decodes a complete HTTP/1.x response read until the server closed the
/// connection: the status and the body, framed by `Transfer-Encoding:
/// chunked` (extensions and trailers ignored), `Content-Length` (bytes
/// beyond it ignored), or the end of the input. Bodies over
/// [`MAX_BODY_BYTES`] are refused. 1xx responses are malformed here; 204
/// and 304 have an empty body.
pub fn parse_response(bytes: &[u8]) -> Result<(u16, Vec<u8>), HttpError> {
    let head_end = match find(bytes, b"\r\n\r\n", 0) {
        Some(i) if i + 4 <= MAX_HEAD_BYTES => i,
        Some(_) => return Err(HttpError::TooLarge),
        None if bytes.len() >= MAX_HEAD_BYTES => return Err(HttpError::TooLarge),
        None => return Err(HttpError::Truncated),
    };
    let head = std::str::from_utf8(&bytes[..head_end])
        .map_err(|_| HttpError::Malformed("head is not text"))?;
    let rest = &bytes[head_end + 4..];
    let mut lines = head.split("\r\n");
    let status_line = lines.next().unwrap_or("");
    let status = status_line
        .strip_prefix("HTTP/1.")
        .and_then(|s| {
            let mut it = s.splitn(3, ' ');
            let minor = it.next()?;
            let code = it.next()?;
            (minor.len() == 1
                && minor.as_bytes()[0].is_ascii_digit()
                && code.len() == 3
                && code.bytes().all(|b| b.is_ascii_digit()))
            .then(|| code.parse::<u16>().ok())
            .flatten()
        })
        .filter(|c| (100..=599).contains(c))
        .ok_or(HttpError::Malformed("bad status line"))?;
    let mut length: Option<usize> = None;
    let mut chunked = false;
    for line in lines {
        let (name, value) = line
            .split_once(':')
            .ok_or(HttpError::Malformed("bad header"))?;
        if name.is_empty() || name.bytes().any(|b| b.is_ascii_whitespace()) {
            return Err(HttpError::Malformed("bad header"));
        }
        let value = value.trim_matches([' ', '\t']);
        if name.eq_ignore_ascii_case("transfer-encoding") {
            let last = value.rsplit(',').next().unwrap_or("").trim();
            if !last.eq_ignore_ascii_case("chunked") {
                return Err(HttpError::Malformed("unsupported transfer coding"));
            }
            chunked = true;
        } else if name.eq_ignore_ascii_case("content-length") {
            for v in value.split(',').map(str::trim) {
                if v.is_empty() || !v.bytes().all(|b| b.is_ascii_digit()) {
                    return Err(HttpError::Malformed("bad content length"));
                }
                let n = v.parse::<usize>().map_err(|_| HttpError::TooLarge)?;
                if length.is_some_and(|l| l != n) {
                    return Err(HttpError::Malformed("conflicting content lengths"));
                }
                length = Some(n);
            }
        }
    }
    if status < 200 {
        return Err(HttpError::Malformed("informational response"));
    }
    if status == 204 || status == 304 {
        return Ok((status, Vec::new()));
    }
    let body = if chunked {
        decode_chunked(rest)?
    } else if let Some(n) = length {
        if n > MAX_BODY_BYTES {
            return Err(HttpError::TooLarge);
        }
        rest.get(..n).ok_or(HttpError::Truncated)?.to_vec()
    } else {
        if rest.len() > MAX_BODY_BYTES {
            return Err(HttpError::TooLarge);
        }
        rest.to_vec()
    };
    Ok((status, body))
}

fn decode_chunked(mut rest: &[u8]) -> Result<Vec<u8>, HttpError> {
    let mut body = Vec::new();
    loop {
        let eol = find(rest, b"\r\n", 0).ok_or(HttpError::Truncated)?;
        let line = &rest[..eol];
        let size = line.split(|&b| b == b';').next().unwrap_or(b"");
        let size = size.trim_ascii();
        if size.is_empty() || size.len() > 16 || !size.iter().all(u8::is_ascii_hexdigit) {
            return Err(HttpError::Malformed("bad chunk size"));
        }
        // At most 16 hex digits: fits in u64.
        let size = u64::from_str_radix(std::str::from_utf8(size).unwrap_or("0"), 16)
            .map_err(|_| HttpError::Malformed("bad chunk size"))?;
        rest = &rest[eol + 2..];
        if size == 0 {
            // Trailer fields, up to an empty line.
            loop {
                let eol = find(rest, b"\r\n", 0).ok_or(HttpError::Truncated)?;
                if eol == 0 {
                    return Ok(body);
                }
                rest = &rest[eol + 2..];
            }
        }
        let size = usize::try_from(size).map_err(|_| HttpError::TooLarge)?;
        if size > MAX_BODY_BYTES - body.len() {
            return Err(HttpError::TooLarge);
        }
        let data = rest.get(..size).ok_or(HttpError::Truncated)?;
        body.extend_from_slice(data);
        rest = &rest[size..];
        match rest.get(..2) {
            Some(b"\r\n") => rest = &rest[2..],
            Some(_) => return Err(HttpError::Malformed("chunk not terminated")),
            None => return Err(HttpError::Truncated),
        }
    }
}

/// Why a poll gave no counts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PollError {
    /// No connection, or it failed or timed out before a full response.
    Unreachable,
    /// 401 or 403: the token was refused.
    Rejected(u16),
    /// Any other status but 200.
    Status(u16),
    /// The response could not be decoded or is not a shell snapshot.
    Protocol,
}

/// Polls T3 Code once: `GET /api/orchestration/shell` with the token, then
/// [`count`]. `timeout` bounds the whole exchange.
pub fn poll(server: &Server, token: &Token, timeout: Duration) -> Result<Counts, PollError> {
    let deadline = Instant::now() + timeout;
    let remaining = || {
        deadline
            .checked_duration_since(Instant::now())
            .filter(|d| !d.is_zero())
            .ok_or(PollError::Unreachable)
    };
    let addrs = (server.host.as_str(), server.port)
        .to_socket_addrs()
        .map_err(|_| PollError::Unreachable)?;
    let mut stream = None;
    for addr in addrs {
        if let Ok(s) = TcpStream::connect_timeout(&addr, remaining()?) {
            stream = Some(s);
            break;
        }
    }
    let mut stream = stream.ok_or(PollError::Unreachable)?;
    let authority = if server.host.contains(':') {
        format!("[{}]:{}", server.host, server.port)
    } else {
        format!("{}:{}", server.host, server.port)
    };
    let request = format!(
        "GET {SHELL_PATH} HTTP/1.1\r\nHost: {authority}\r\nAuthorization: Bearer {}\r\nAccept: application/json\r\nConnection: close\r\n\r\n",
        token.expose()
    );
    stream
        .set_write_timeout(Some(remaining()?))
        .map_err(|_| PollError::Unreachable)?;
    stream
        .write_all(request.as_bytes())
        .map_err(|_| PollError::Unreachable)?;
    let mut raw = Vec::new();
    let mut buf = vec![0u8; 64 << 10];
    loop {
        stream
            .set_read_timeout(Some(remaining()?))
            .map_err(|_| PollError::Unreachable)?;
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if raw.len() + n > MAX_RAW_BYTES {
                    return Err(PollError::Protocol);
                }
                raw.extend_from_slice(&buf[..n]);
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return Err(PollError::Unreachable),
        }
    }
    let (status, body) = parse_response(&raw).map_err(|_| PollError::Protocol)?;
    match status {
        200 => {}
        401 | 403 => return Err(PollError::Rejected(status)),
        s => return Err(PollError::Status(s)),
    }
    let doc: Value = serde_json::from_slice(&body).map_err(|_| PollError::Protocol)?;
    count(&doc, &now_iso()).ok_or(PollError::Protocol)
}

/// Sends reports to the daemon. Each call returns `false` when the daemon
/// could not be reached.
pub trait Reporter {
    /// `agents-set` with the counts and `ttl`.
    fn set(&mut self, counts: Counts, ttl: Duration) -> bool;
    /// `agents-clear`.
    fn clear(&mut self) -> bool;
}

/// The outcome of the last T3 poll, for state-change messages.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Link {
    Reachable,
    Failed(PollError),
}

/// The bridge's state between cycles.
#[derive(Debug)]
pub struct Bridge {
    token_path: PathBuf,
    runtime_path: PathBuf,
    interval: Duration,
    /// The last T3 outcome; `None` before the first cycle.
    link: Option<Link>,
    /// Whether the daemon may hold a report from this bridge (or a previous
    /// run), so a failure must send `agents-clear`.
    may_report: bool,
    /// Whether the daemon answered the last report.
    daemon_up: bool,
}

impl Bridge {
    pub fn new(token_path: PathBuf, runtime_path: PathBuf, interval: Duration) -> Bridge {
        Bridge {
            token_path,
            runtime_path,
            interval,
            link: None,
            may_report: true,
            daemon_up: true,
        }
    }

    /// Three intervals rounded up to whole seconds, clamped to 5..=600 s.
    pub fn ttl(&self) -> Duration {
        let ms = self.interval.as_millis().saturating_mul(3);
        let secs = u64::try_from(ms.div_ceil(1000)).unwrap_or(u64::MAX);
        Duration::from_secs(secs.clamp(5, 600))
    }

    /// One poll-and-report cycle; returns the state-change message to print
    /// on stderr, if any (lines joined by `\n`).
    ///
    /// - The token and `server-runtime.json` are re-read every cycle. A bad
    ///   token file is returned as an error (after clearing any report); a
    ///   missing or invalid runtime file counts as T3 unreachable.
    /// - Success: `set` with the counts (each at most [`MAX_COUNT`]) and
    ///   [`Bridge::ttl`]. Failure: `clear`, once after reporting (including
    ///   on the first cycle, for a report left by a previous run); a clear
    ///   the daemon did not receive is retried next cycle.
    /// - Messages name the T3 state when it changes (and on the first
    ///   cycle), and the daemon becoming unreachable or reachable again.
    pub fn step(
        &mut self,
        reporter: &mut dyn Reporter,
        poll: &mut dyn FnMut(&Server, &Token) -> Result<Counts, PollError>,
    ) -> Result<Option<String>, TokenError> {
        let token = match read_token(&self.token_path) {
            Ok(t) => t,
            Err(e) => {
                if self.may_report {
                    reporter.clear();
                    self.may_report = false;
                }
                return Err(e);
            }
        };
        let result = match read_server(&self.runtime_path) {
            Ok(server) => poll(&server, &token),
            Err(_) => Err(PollError::Unreachable),
        };
        let mut lines = Vec::new();
        let link = match result {
            Ok(_) => Link::Reachable,
            Err(e) => Link::Failed(e),
        };
        if self.link != Some(link) {
            lines.push(link_message(link));
            self.link = Some(link);
        }
        let delivered = match result {
            Ok(counts) => {
                self.may_report = true;
                Some(reporter.set(counts.clamped(MAX_COUNT), self.ttl()))
            }
            Err(_) if self.may_report => {
                let ok = reporter.clear();
                self.may_report = !ok;
                Some(ok)
            }
            Err(_) => None,
        };
        if let Some(up) = delivered
            && up != self.daemon_up
        {
            self.daemon_up = up;
            lines.push(
                if up {
                    "LocalFlow daemon reachable again"
                } else {
                    "LocalFlow daemon unreachable; still polling T3 Code"
                }
                .to_owned(),
            );
        }
        Ok((!lines.is_empty()).then(|| lines.join("\n")))
    }
}

fn link_message(link: Link) -> String {
    match link {
        Link::Reachable => "T3 Code reachable".into(),
        Link::Failed(PollError::Unreachable) => "T3 Code unreachable".into(),
        Link::Failed(PollError::Rejected(s)) => {
            format!("T3 Code rejected the token (HTTP {s})")
        }
        Link::Failed(PollError::Status(s)) => format!("T3 Code returned HTTP {s}"),
        Link::Failed(PollError::Protocol) => "T3 Code sent an unexpected response".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::VecDeque;
    use std::fs;
    use std::net::TcpListener;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::mpsc;

    use crate::testing::TempDir;

    const NOW: &str = "2026-10-16T12:00:00.000Z";
    const TOKEN: &str = "synthetic-token-7f3a";

    /// A synthetic T3 Code 0.1.0 thread shell at rest (idle, nothing
    /// pending), then `over` applied.
    fn thread(over: Value) -> Value {
        let mut t = json!({
            "id": "thread-synthetic",
            "projectId": "project-synthetic",
            "title": "Invented title",
            "lineage": {
                "parentThreadId": null,
                "relationshipToParent": null,
                "rootThreadId": "thread-synthetic",
            },
            "status": "idle",
            "activityRunStatus": null,
            "pendingRuntimeRequest": null,
            "pendingBackgroundTasks": [],
            "archivedAt": null,
            "deletedAt": null,
            "settledOverride": null,
            "settledAt": null,
        });
        for (k, v) in over.as_object().unwrap() {
            t[k] = v.clone();
        }
        t
    }

    fn request(kind: &str) -> Value {
        json!({"id": "request-synthetic", "kind": kind, "createdAt": "2026-10-16T11:00:00.000Z"})
    }

    fn task(kind: &str) -> Value {
        json!({"taskId": "task-synthetic", "kind": kind})
    }

    fn shell(threads: Vec<Value>) -> Value {
        json!({"schemaVersion": 1, "snapshotSequence": 1, "threads": threads, "archivedThreads": [], "projects": []})
    }

    fn counts_of(threads: Vec<Value>) -> Counts {
        count(&shell(threads), NOW).unwrap()
    }

    fn one(over: Value) -> Counts {
        counts_of(vec![thread(over)])
    }

    const APPROVAL: Counts = Counts {
        approval: 1,
        input: 0,
        working: 0,
        done: 0,
    };
    const INPUT: Counts = Counts {
        approval: 0,
        input: 1,
        working: 0,
        done: 0,
    };
    const WORKING: Counts = Counts {
        approval: 0,
        input: 0,
        working: 1,
        done: 0,
    };
    const DONE: Counts = Counts {
        approval: 0,
        input: 0,
        working: 0,
        done: 1,
    };
    const NONE: Counts = Counts {
        approval: 0,
        input: 0,
        working: 0,
        done: 0,
    };

    #[test]
    fn snapshot_shape_is_checked() {
        assert_eq!(
            count(&json!({"schemaVersion": 1, "projects": []}), NOW),
            None
        );
        assert_eq!(
            count(&json!({"schemaVersion": 1, "threads": {}}), NOW),
            None
        );
        assert_eq!(count(&json!([]), NOW), None);
        assert_eq!(
            count(&json!({"schemaVersion": "1", "threads": []}), NOW),
            None
        );
        assert_eq!(count(&shell(vec![]), NOW), Some(NONE));
        // A T3 Code 0.0.x shell (no schemaVersion) is not read as zero counts.
        let old = json!({
            "snapshotSequence": 1,
            "projects": [],
            "threads": [{"id": "thread-synthetic", "hasPendingApprovals": true}],
            "updatedAt": "2026-10-16T10:00:00.000Z",
        });
        assert_eq!(count(&old, NOW), None);
    }

    #[test]
    fn archived_deleted_and_subagent_threads_are_skipped() {
        let approval = request("command_execution_approval");
        assert_eq!(
            one(
                json!({"archivedAt": "2026-10-16T10:00:00.000Z", "pendingRuntimeRequest": approval})
            ),
            NONE
        );
        assert_eq!(
            one(json!({"deletedAt": "2026-10-16T10:00:00.000Z", "status": "running"})),
            NONE
        );
        let subagent = json!({
            "parentThreadId": "thread-parent",
            "relationshipToParent": "subagent",
            "rootThreadId": "thread-parent",
        });
        assert_eq!(
            one(json!({"lineage": subagent, "pendingRuntimeRequest": request("user_input")})),
            NONE
        );
        // A fork is a thread of its own.
        let fork = json!({
            "parentThreadId": "thread-parent",
            "relationshipToParent": "fork",
            "rootThreadId": "thread-parent",
        });
        assert_eq!(one(json!({"lineage": fork, "status": "running"})), WORKING);
    }

    #[test]
    fn pending_requests_come_first() {
        assert_eq!(
            one(json!({"pendingRuntimeRequest": request("user_input"), "status": "failed"})),
            INPUT
        );
        assert_eq!(
            one(json!({
                "pendingRuntimeRequest": request("command_execution_approval"),
                "activityRunStatus": "running",
                "settledOverride": "settled",
                "snoozedUntil": "2099-01-01T00:00:00.000Z",
            })),
            APPROVAL
        );
        // Any other kind, including ones this build does not know, asks for
        // approval; an auth refresh does not.
        assert_eq!(
            one(json!({"pendingRuntimeRequest": request("dynamic_tool_call")})),
            APPROVAL
        );
        assert_eq!(
            one(json!({"pendingRuntimeRequest": request("invented_kind")})),
            APPROVAL
        );
        assert_eq!(
            one(json!({"pendingRuntimeRequest": request("auth_refresh"), "status": "running"})),
            WORKING
        );
        assert_eq!(
            one(json!({"pendingRuntimeRequest": request("auth_refresh")})),
            NONE
        );
    }

    #[test]
    fn working_threads() {
        for status in ["preparing", "starting", "running", "waiting"] {
            assert_eq!(one(json!({"status": status})), WORKING, "{status}");
            assert_eq!(
                one(json!({"status": "completed", "activityRunStatus": status})),
                WORKING,
                "{status}"
            );
        }
        // Settled and snoozed affect done only.
        assert_eq!(
            one(json!({
                "status": "running",
                "settledOverride": "settled",
                "snoozedUntil": "2099-01-01T00:00:00.000Z",
            })),
            WORKING
        );
    }

    #[test]
    fn background_work_that_wakes_the_agent_keeps_it_working() {
        for kind in ["subagent", "monitor", "background_task", "invented_kind"] {
            assert_eq!(
                one(json!({"status": "completed", "pendingBackgroundTasks": [task(kind)]})),
                WORKING,
                "{kind}"
            );
        }
        assert_eq!(
            one(json!({"status": "completed", "pendingBackgroundTasks": [task("command")]})),
            DONE
        );
        assert_eq!(
            one(json!({
                "status": "completed",
                "pendingBackgroundTasks": [task("command"), task("monitor")],
            })),
            WORKING
        );
    }

    #[test]
    fn other_statuses_are_not_counted() {
        for status in [
            "idle",
            "queued",
            "interrupted",
            "cancelled",
            "rolled_back",
            "failed",
            "invented",
        ] {
            assert_eq!(one(json!({"status": status})), NONE, "{status}");
        }
        assert_eq!(one(json!({"status": null})), NONE);
        // The activity status wins over the thread status.
        assert_eq!(
            one(json!({"status": "completed", "activityRunStatus": "invented"})),
            NONE
        );
        assert_eq!(
            one(json!({"status": "failed", "activityRunStatus": "running"})),
            WORKING
        );
    }

    #[test]
    fn completed_threads_are_done() {
        assert_eq!(one(json!({"status": "completed"})), DONE);
        assert_eq!(
            one(json!({"status": "completed", "activityRunStatus": null})),
            DONE
        );
    }

    #[test]
    fn settled_threads_are_not_done() {
        assert_eq!(
            one(json!({"status": "completed", "settledOverride": "settled"})),
            NONE
        );
        assert_eq!(
            one(json!({"status": "completed", "settledAt": "2026-10-16T10:00:00.000Z"})),
            NONE
        );
        assert_eq!(
            one(json!({
                "status": "completed",
                "settledAt": "2026-10-16T10:00:00.000Z",
                "settledOverride": "active",
            })),
            DONE
        );
        assert_eq!(
            one(json!({"status": "completed", "settledOverride": "active"})),
            DONE
        );
    }

    #[test]
    fn snoozed_threads_are_not_done() {
        assert_eq!(
            one(json!({"status": "completed", "snoozedUntil": "2026-10-16T12:00:00.001Z"})),
            NONE
        );
        assert_eq!(
            one(json!({"status": "completed", "snoozedUntil": NOW})),
            DONE
        );
        assert_eq!(
            one(json!({"status": "completed", "snoozedUntil": "2026-10-16T11:59:59.999Z"})),
            DONE
        );
        assert_eq!(
            one(json!({"status": "completed", "snoozedUntil": null})),
            DONE
        );
    }

    #[test]
    fn non_objects_and_mistyped_fields_are_tolerated() {
        let c = counts_of(vec![
            json!(null),
            json!("thread"),
            json!(7),
            thread(json!({"pendingRuntimeRequest": "user_input"})),
            thread(json!({"status": 3})),
            thread(json!({"pendingBackgroundTasks": "monitor", "status": "completed"})),
            thread(json!({"pendingRuntimeRequest": request("user_input")})),
        ]);
        assert_eq!(
            c,
            Counts {
                approval: 0,
                input: 1,
                working: 0,
                done: 1
            }
        );
    }

    #[test]
    fn counts_add_up() {
        let c = counts_of(vec![
            thread(json!({"pendingRuntimeRequest": request("command_execution_approval")})),
            thread(json!({"pendingRuntimeRequest": request("file_change_approval")})),
            thread(json!({"pendingRuntimeRequest": request("user_input")})),
            thread(json!({"status": "running"})),
            thread(json!({"status": "completed"})),
            thread(json!({"status": "completed", "pendingBackgroundTasks": [task("command")]})),
            thread(json!({"status": "idle"})),
        ]);
        assert_eq!(
            c,
            Counts {
                approval: 2,
                input: 1,
                working: 1,
                done: 2
            }
        );
    }

    #[test]
    fn iso_formatting() {
        assert_eq!(iso_from_unix_millis(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso_from_unix_millis(5), "1970-01-01T00:00:00.005Z");
        assert_eq!(iso_from_unix_millis(60_050), "1970-01-01T00:01:00.050Z");
        assert_eq!(
            iso_from_unix_millis(1_792_186_752_653),
            "2026-10-16T21:39:12.653Z"
        );
        assert_eq!(
            iso_from_unix_millis(951_868_799_999),
            "2000-02-29T23:59:59.999Z"
        );
        assert_eq!(
            iso_from_unix_millis(951_868_800_000),
            "2000-03-01T00:00:00.000Z"
        );
        assert_eq!(
            iso_from_unix_millis(1_735_689_599_000),
            "2024-12-31T23:59:59.000Z"
        );
        // 2100 is not a leap year.
        assert_eq!(
            iso_from_unix_millis(4_107_542_400_000 - 86_400_000),
            "2100-02-28T00:00:00.000Z"
        );
        assert_eq!(
            iso_from_unix_millis(4_107_542_400_000),
            "2100-03-01T00:00:00.000Z"
        );
    }

    #[test]
    fn now_iso_has_the_javascript_shape() {
        let s = now_iso();
        assert_eq!(s.len(), 24, "{s}");
        assert!(s.ends_with('Z') && s.as_bytes()[10] == b'T' && s.as_bytes()[19] == b'.');
        assert!(s.as_str() > "2026-01-01T00:00:00.000Z");
    }

    /// Replaces `path` with a file holding `content` with `mode`.
    fn write_mode(path: &Path, content: &[u8], mode: u32) {
        let _ = fs::remove_file(path);
        fs::write(path, content).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
    }

    #[test]
    fn token_file_accepted() {
        let t = TempDir::new("t3-token");
        let p = t.path().join("t3-token");
        write_mode(&p, format!("  {TOKEN}\n").as_bytes(), 0o600);
        assert_eq!(read_token(&p).unwrap().expose(), TOKEN);
        write_mode(&p, TOKEN.as_bytes(), 0o400);
        assert_eq!(read_token(&p).unwrap().expose(), TOKEN);
        write_mode(&p, TOKEN.as_bytes(), 0o700);
        assert_eq!(read_token(&p).unwrap().expose(), TOKEN);
        let longest = "x".repeat(MAX_TOKEN_FILE_BYTES as usize);
        write_mode(&p, longest.as_bytes(), 0o600);
        assert_eq!(read_token(&p).unwrap().expose(), longest);
    }

    #[test]
    fn token_file_refused() {
        let t = TempDir::new("t3-token");
        let p = t.path().join("t3-token");
        assert_eq!(read_token(&p), Err(TokenError::Missing));

        for mode in [0o644, 0o640, 0o604, 0o610, 0o601] {
            write_mode(&p, TOKEN.as_bytes(), mode);
            assert_eq!(read_token(&p), Err(TokenError::Permissions(mode)));
        }

        write_mode(&p, TOKEN.as_bytes(), 0o600);
        let link = t.path().join("link");
        std::os::unix::fs::symlink(&p, &link).unwrap();
        assert_eq!(read_token(&link), Err(TokenError::NotRegular));
        assert_eq!(read_token(t.path()), Err(TokenError::NotRegular));

        write_mode(
            &p,
            "x".repeat(MAX_TOKEN_FILE_BYTES as usize + 1).as_bytes(),
            0o600,
        );
        assert_eq!(read_token(&p), Err(TokenError::TooBig));

        for bad in [
            &b""[..],
            b" \n\t ",
            b"synthetic token",
            b"synthetic\ntoken",
            b"synth\x7ftoken",
            "synthétique".as_bytes(),
        ] {
            write_mode(&p, bad, 0o600);
            assert_eq!(read_token(&p), Err(TokenError::Invalid), "{bad:?}");
        }
    }

    #[test]
    fn token_never_shown() {
        let t = TempDir::new("t3-token");
        let p = t.path().join("t3-token");
        write_mode(&p, TOKEN.as_bytes(), 0o600);
        let token = read_token(&p).unwrap();
        assert_eq!(format!("{token:?}"), "Token(..)");
        for e in [
            TokenError::Missing,
            TokenError::NotRegular,
            TokenError::WrongOwner,
            TokenError::Permissions(0o644),
            TokenError::TooBig,
            TokenError::Invalid,
            TokenError::Io(std::io::ErrorKind::PermissionDenied),
        ] {
            let s = e.to_string();
            assert!(s.starts_with("the T3 token file") || s.starts_with("cannot read"));
            assert!(!s.contains(TOKEN));
        }
    }

    #[test]
    fn default_paths() {
        let os = |s: &str| Some(OsString::from(s));
        assert_eq!(
            token_path_from(os("/cfg"), os("/home/u")),
            Some(PathBuf::from("/cfg/localflow/t3-token"))
        );
        assert_eq!(
            token_path_from(os("relative"), os("/home/u")),
            Some(PathBuf::from("/home/u/.config/localflow/t3-token"))
        );
        assert_eq!(token_path_from(None, None), None);
        assert_eq!(token_path_from(None, os("home")), None);

        assert_eq!(
            runtime_path_from(os("/t3home"), None),
            Some(PathBuf::from("/t3home/userdata/server-runtime.json"))
        );
        assert_eq!(
            runtime_path_from(None, os("/home/u")),
            Some(PathBuf::from("/home/u/.t3/userdata/server-runtime.json"))
        );
        assert_eq!(
            runtime_path_from(os(""), os("/home/u")),
            Some(PathBuf::from("/home/u/.t3/userdata/server-runtime.json"))
        );
        assert_eq!(
            runtime_path_from(os("~/t3"), os("/home/u")),
            Some(PathBuf::from("/home/u/t3/userdata/server-runtime.json"))
        );
        assert_eq!(runtime_path_from(os("t3"), os("/home/u")), None);
        assert_eq!(runtime_path_from(None, None), None);
    }

    fn runtime_json(host: Value, port: Value) -> Value {
        json!({
            "version": "0.0.0-synthetic",
            "pid": 4242,
            "host": host,
            "port": port,
            "origin": "http://127.0.0.1:3773",
            "startedAt": "2026-10-16T10:00:00.000Z",
        })
    }

    #[test]
    fn server_from_runtime_file() {
        let t = TempDir::new("t3-runtime");
        let p = t.path().join("server-runtime.json");
        let server = |doc: Value| {
            fs::write(&p, doc.to_string()).unwrap();
            read_server(&p)
        };
        let ok = |host: &str, port: u16| {
            Ok(Server {
                host: host.into(),
                port,
            })
        };
        assert_eq!(
            server(runtime_json(json!("0.0.0.0"), json!(3773))),
            ok("127.0.0.1", 3773)
        );
        assert_eq!(
            server(runtime_json(json!("::"), json!(3773))),
            ok("::1", 3773)
        );
        assert_eq!(
            server(runtime_json(json!("[::]"), json!(3773))),
            ok("::1", 3773)
        );
        assert_eq!(
            server(runtime_json(json!(""), json!(1))),
            ok("127.0.0.1", 1)
        );
        assert_eq!(
            server(runtime_json(Value::Null, json!(3773))),
            ok("127.0.0.1", 3773)
        );
        assert_eq!(server(json!({"port": 3773})), ok("127.0.0.1", 3773));
        assert_eq!(
            server(runtime_json(json!("127.0.0.1"), json!(65535))),
            ok("127.0.0.1", 65535)
        );
        assert_eq!(
            server(runtime_json(json!("[::1]"), json!(3773))),
            ok("::1", 3773)
        );
        assert_eq!(
            server(runtime_json(json!("localhost"), json!(3773))),
            ok("127.0.0.1", 3773)
        );
        assert_eq!(
            server(runtime_json(json!("127.0.0.2"), json!(3773))),
            ok("127.0.0.2", 3773)
        );

        for (host, port) in [
            (json!("127.0.0.1"), json!(0)),
            (json!("127.0.0.1"), json!(65536)),
            (json!("127.0.0.1"), json!(-1)),
            (json!("127.0.0.1"), json!("3773")),
            (json!("127.0.0.1"), Value::Null),
            (json!(7), json!(3773)),
            (json!("host\r\nX-Injected: 1"), json!(3773)),
            (json!("bad host"), json!(3773)),
            // The token is only ever sent over loopback.
            (json!("192.0.2.7"), json!(3773)),
            (json!("2001:db8::7"), json!(3773)),
            (json!("t3.example"), json!(3773)),
        ] {
            assert!(
                server(runtime_json(host.clone(), port.clone())).is_err(),
                "{host} {port}"
            );
        }
        fs::write(&p, b"not json").unwrap();
        assert!(read_server(&p).is_err());
        assert!(read_server(&t.path().join("missing.json")).is_err());
    }

    #[test]
    fn http_content_length() {
        let r =
            b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 5\r\n\r\nhello";
        assert_eq!(parse_response(r), Ok((200, b"hello".to_vec())));
        let r = b"HTTP/1.1 200 OK\r\ncontent-length:  5 \r\n\r\nhello, extra";
        assert_eq!(parse_response(r), Ok((200, b"hello".to_vec())));
        let r = b"HTTP/1.0 401 Unauthorized\r\nContent-Length: 0\r\n\r\n";
        assert_eq!(parse_response(r), Ok((401, Vec::new())));
        let r = b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello";
        assert_eq!(parse_response(r), Ok((200, b"hello".to_vec())));
        let r = b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nhello";
        assert_eq!(parse_response(r), Err(HttpError::Truncated));
        let r = b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello!";
        assert!(matches!(parse_response(r), Err(HttpError::Malformed(_))));
        let r = b"HTTP/1.1 200 OK\r\nContent-Length: -5\r\n\r\nhello";
        assert!(matches!(parse_response(r), Err(HttpError::Malformed(_))));
    }

    #[test]
    fn http_chunked() {
        let r = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;name=value\r\nhello\r\nB \r\n world 1234\r\n0\r\nX-Trailer: synthetic\r\n\r\n";
        assert_eq!(parse_response(r), Ok((200, b"hello world 1234".to_vec())));
        let r = b"HTTP/1.1 200 OK\r\ntransfer-encoding: Chunked\r\nContent-Length: 99\r\n\r\n3\r\nabc\r\n0\r\n\r\n";
        assert_eq!(parse_response(r), Ok((200, b"abc".to_vec())));
        for truncated in [
            &b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n"[..],
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel",
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello",
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n",
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
        ] {
            assert_eq!(parse_response(truncated), Err(HttpError::Truncated));
        }
        for bad in [
            &b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n0\r\n\r\n"[..],
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\r\n",
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nhelloo\r\n0\r\n\r\n",
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\nxyz",
        ] {
            assert!(matches!(parse_response(bad), Err(HttpError::Malformed(_))));
        }
    }

    #[test]
    fn http_close_delimited_and_heads() {
        let r = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"threads\":[]}";
        assert_eq!(parse_response(r), Ok((200, b"{\"threads\":[]}".to_vec())));
        let r = b"HTTP/1.1 200\r\n\r\n";
        assert_eq!(parse_response(r), Ok((200, Vec::new())));
        let r = b"HTTP/1.1 204 No Content\r\n\r\nignored";
        assert_eq!(parse_response(r), Ok((204, Vec::new())));
        assert_eq!(
            parse_response(b"HTTP/1.1 200 OK\r\nContent-Le"),
            Err(HttpError::Truncated)
        );
        assert_eq!(parse_response(b""), Err(HttpError::Truncated));
        for bad in [
            &b"HTTP/2 200 OK\r\n\r\n"[..],
            b"HTTP/1.1 20 OK\r\n\r\n",
            b"HTTP/1.1 999 Odd\r\n\r\n",
            b"SSH-2.0-synthetic\r\n\r\n",
            b"HTTP/1.1 200 OK\r\nno colon\r\n\r\n",
            b"HTTP/1.1 200 OK\r\nBad Name: x\r\n\r\n",
            b"HTTP/1.1 100 Continue\r\n\r\n",
        ] {
            assert!(
                matches!(parse_response(bad), Err(HttpError::Malformed(_))),
                "{bad:?}"
            );
        }
    }

    #[test]
    fn http_limits() {
        let max = MAX_BODY_BYTES;
        let r = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", max + 1);
        assert_eq!(parse_response(r.as_bytes()), Err(HttpError::TooLarge));
        let r = format!(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n{:x}\r\n",
            max + 1
        );
        assert_eq!(parse_response(r.as_bytes()), Err(HttpError::TooLarge));
        let r = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nffffffffffffffff\r\n";
        assert_eq!(parse_response(r), Err(HttpError::TooLarge));

        let mut r = b"HTTP/1.1 200 OK\r\n\r\n".to_vec();
        let head = r.len();
        r.resize(head + max, b'x');
        assert_eq!(
            parse_response(&r).map(|(s, b)| (s, b.len())),
            Ok((200, max))
        );
        r.push(b'x');
        assert_eq!(parse_response(&r), Err(HttpError::TooLarge));

        let mut r = b"HTTP/1.1 200 OK\r\nX-Long: ".to_vec();
        r.resize(MAX_HEAD_BYTES + 10, b'a');
        assert_eq!(parse_response(&r), Err(HttpError::TooLarge));
    }

    /// Serves one canned response on loopback and returns the request.
    fn serve(response: Vec<u8>) -> (Server, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let server = Server {
            host: "127.0.0.1".into(),
            port: listener.local_addr().unwrap().port(),
        };
        (server, serve_on(listener, response))
    }

    fn serve_on(listener: TcpListener, response: Vec<u8>) -> mpsc::Receiver<String> {
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut req = Vec::new();
            let mut buf = [0u8; 1024];
            while find(&req, b"\r\n\r\n", 0).is_none() {
                match s.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => req.extend_from_slice(&buf[..n]),
                }
            }
            let _ = tx.send(String::from_utf8_lossy(&req).into_owned());
            let _ = s.write_all(&response);
        });
        rx
    }

    fn token() -> Token {
        Token(TOKEN.into())
    }

    fn json_response(body: &Value) -> Vec<u8> {
        let body = body.to_string();
        format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        )
        .into_bytes()
    }

    const TIMEOUT: Duration = Duration::from_secs(5);

    #[test]
    fn poll_counts_a_snapshot() {
        let snapshot = json!({
            "schemaVersion": 1,
            "snapshotSequence": 3,
            "projects": [{"id": "project-synthetic", "title": "Invented"}],
            "threads": [
                thread(json!({"pendingRuntimeRequest": request("command_execution_approval")})),
                thread(json!({"status": "running"})),
                thread(json!({"status": "completed"})),
            ],
            "archivedThreads": [],
        });
        let (server, rx) = serve(json_response(&snapshot));
        let c = poll(&server, &token(), TIMEOUT).unwrap();
        assert_eq!(
            c,
            Counts {
                approval: 1,
                input: 0,
                working: 1,
                done: 1
            }
        );
        let req = rx.recv().unwrap();
        assert!(
            req.starts_with("GET /api/orchestration/shell HTTP/1.1\r\n"),
            "{req}"
        );
        assert!(req.contains(&format!("\r\nHost: 127.0.0.1:{}\r\n", server.port)));
        assert!(req.contains(&format!("\r\nAuthorization: Bearer {TOKEN}\r\n")));
        assert!(req.contains("\r\nAccept: application/json\r\n"));
        assert!(req.contains("\r\nConnection: close\r\n"));
    }

    #[test]
    fn poll_chunked_and_close_delimited() {
        let body = shell(vec![thread(
            json!({"pendingRuntimeRequest": request("user_input")}),
        )])
        .to_string();
        let (a, b) = body.split_at(10);
        let chunked = format!(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n{:x}\r\n{a}\r\n{:x};ext=1\r\n{b}\r\n0\r\n\r\n",
            a.len(),
            b.len()
        );
        let (server, _rx) = serve(chunked.into_bytes());
        assert_eq!(poll(&server, &token(), TIMEOUT), Ok(INPUT));
        let close = format!("HTTP/1.1 200 OK\r\n\r\n{body}");
        let (server, _rx) = serve(close.into_bytes());
        assert_eq!(poll(&server, &token(), TIMEOUT), Ok(INPUT));
    }

    #[test]
    fn poll_errors() {
        let cases: [(&[u8], PollError); 6] = [
            (
                b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n",
                PollError::Rejected(401),
            ),
            (
                b"HTTP/1.1 403 Forbidden\r\nContent-Length: 2\r\n\r\n{}",
                PollError::Rejected(403),
            ),
            (
                b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n",
                PollError::Status(500),
            ),
            (
                b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nnot json",
                PollError::Protocol,
            ),
            (
                b"HTTP/1.1 200 OK\r\nContent-Length: 15\r\n\r\n{\"projects\":[]}",
                PollError::Protocol,
            ),
            (b"garbage", PollError::Protocol),
        ];
        for (response, expected) in cases {
            let (server, _rx) = serve(response.to_vec());
            assert_eq!(poll(&server, &token(), TIMEOUT), Err(expected));
        }
    }

    #[test]
    fn poll_unreachable() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        let server = Server {
            host: "127.0.0.1".into(),
            port,
        };
        assert_eq!(
            poll(&server, &token(), TIMEOUT),
            Err(PollError::Unreachable)
        );

        // Accepts but never answers: the timeout ends the poll.
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let server = Server {
            host: "127.0.0.1".into(),
            port: listener.local_addr().unwrap().port(),
        };
        let started = Instant::now();
        assert_eq!(
            poll(&server, &token(), Duration::from_millis(300)),
            Err(PollError::Unreachable)
        );
        assert!(started.elapsed() < Duration::from_secs(3));
        drop(listener);
    }

    #[test]
    fn poll_ipv6_brackets_the_host() {
        let Ok(listener) = TcpListener::bind("[::1]:0") else {
            return; // No IPv6 loopback here.
        };
        let server = Server {
            host: "::1".into(),
            port: listener.local_addr().unwrap().port(),
        };
        let rx = serve_on(listener, json_response(&shell(vec![])));
        assert_eq!(poll(&server, &token(), TIMEOUT), Ok(NONE));
        let req = rx.recv().unwrap();
        assert!(
            req.contains(&format!("\r\nHost: [::1]:{}\r\n", server.port)),
            "{req}"
        );
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    enum Event {
        Set(Counts, Duration),
        Clear,
    }

    struct FakeReporter {
        events: Vec<Event>,
        up: bool,
    }

    impl Reporter for FakeReporter {
        fn set(&mut self, counts: Counts, ttl: Duration) -> bool {
            self.events.push(Event::Set(counts, ttl));
            self.up
        }
        fn clear(&mut self) -> bool {
            self.events.push(Event::Clear);
            self.up
        }
    }

    struct Rig {
        dir: TempDir,
        bridge: Bridge,
        reporter: FakeReporter,
        results: VecDeque<Result<Counts, PollError>>,
        seen: Vec<(Server, String)>,
    }

    impl Rig {
        fn new() -> Rig {
            let dir = TempDir::new("t3-bridge");
            let token = dir.path().join("t3-token");
            let runtime = dir.path().join("server-runtime.json");
            write_mode(&token, format!("{TOKEN}\n").as_bytes(), 0o600);
            fs::write(
                &runtime,
                runtime_json(json!("0.0.0.0"), json!(3773)).to_string(),
            )
            .unwrap();
            Rig {
                bridge: Bridge::new(token, runtime, Duration::from_millis(2000)),
                dir,
                reporter: FakeReporter {
                    events: Vec::new(),
                    up: true,
                },
                results: VecDeque::new(),
                seen: Vec::new(),
            }
        }

        fn step(
            &mut self,
            result: Result<Counts, PollError>,
        ) -> Result<Option<String>, TokenError> {
            self.results.push_back(result);
            let results = &mut self.results;
            let seen = &mut self.seen;
            let out = self.bridge.step(&mut self.reporter, &mut |s, t| {
                seen.push((s.clone(), t.expose().to_owned()));
                results.pop_front().unwrap()
            });
            self.results.clear();
            if let Ok(Some(m)) = &out {
                assert!(!m.contains(TOKEN));
            }
            out
        }

        fn msg(&mut self, result: Result<Counts, PollError>) -> Option<String> {
            self.step(result).unwrap()
        }

        fn events(&mut self) -> Vec<Event> {
            std::mem::take(&mut self.reporter.events)
        }
    }

    const SIX: Duration = Duration::from_secs(6);

    #[test]
    fn ttl_is_three_intervals_clamped() {
        let ttl = |ms| Bridge::new(PathBuf::new(), PathBuf::new(), Duration::from_millis(ms)).ttl();
        assert_eq!(ttl(2000), SIX);
        assert_eq!(ttl(500), Duration::from_secs(5));
        assert_eq!(ttl(1700), SIX);
        assert_eq!(ttl(60_000), Duration::from_secs(180));
        assert_eq!(ttl(300_000), Duration::from_secs(600));
    }

    #[test]
    fn bridge_reports_and_clears_once() {
        let mut r = Rig::new();
        assert_eq!(r.msg(Ok(APPROVAL)), Some("T3 Code reachable".into()));
        assert_eq!(r.msg(Ok(DONE)), None);
        assert_eq!(
            r.events(),
            [Event::Set(APPROVAL, SIX), Event::Set(DONE, SIX)]
        );
        assert_eq!(
            r.seen[0].0,
            Server {
                host: "127.0.0.1".into(),
                port: 3773
            }
        );
        assert_eq!(r.seen[0].1, TOKEN);

        assert_eq!(
            r.msg(Err(PollError::Unreachable)),
            Some("T3 Code unreachable".into())
        );
        assert_eq!(r.msg(Err(PollError::Unreachable)), None);
        assert_eq!(r.events(), [Event::Clear]);

        assert_eq!(
            r.msg(Err(PollError::Rejected(401))),
            Some("T3 Code rejected the token (HTTP 401)".into())
        );
        assert_eq!(
            r.msg(Err(PollError::Status(500))),
            Some("T3 Code returned HTTP 500".into())
        );
        assert_eq!(
            r.msg(Err(PollError::Protocol)),
            Some("T3 Code sent an unexpected response".into())
        );
        assert_eq!(r.msg(Err(PollError::Protocol)), None);
        assert_eq!(r.events(), []);

        assert_eq!(r.msg(Ok(WORKING)), Some("T3 Code reachable".into()));
        assert_eq!(r.events(), [Event::Set(WORKING, SIX)]);
    }

    #[test]
    fn bridge_clears_a_stale_report_on_first_failure() {
        let mut r = Rig::new();
        assert_eq!(
            r.msg(Err(PollError::Rejected(403))),
            Some("T3 Code rejected the token (HTTP 403)".into())
        );
        assert_eq!(r.msg(Err(PollError::Rejected(403))), None);
        assert_eq!(r.events(), [Event::Clear]);
    }

    #[test]
    fn bridge_clamps_counts() {
        let mut r = Rig::new();
        let many = Counts {
            approval: 5000,
            input: 999,
            working: 1000,
            done: 3,
        };
        r.msg(Ok(many));
        assert_eq!(
            r.events(),
            [Event::Set(
                Counts {
                    approval: 999,
                    input: 999,
                    working: 999,
                    done: 3
                },
                SIX
            )]
        );
    }

    #[test]
    fn bridge_rereads_runtime_and_token() {
        let mut r = Rig::new();
        r.msg(Ok(DONE));
        let runtime = r.dir.path().join("server-runtime.json");
        fs::write(&runtime, runtime_json(json!("::"), json!(4000)).to_string()).unwrap();
        write_mode(
            &r.dir.path().join("t3-token"),
            b"synthetic-token-second",
            0o600,
        );
        assert_eq!(r.msg(Ok(DONE)), None);
        assert_eq!(
            r.seen[1].0,
            Server {
                host: "::1".into(),
                port: 4000
            }
        );
        assert_eq!(r.seen[1].1, "synthetic-token-second");

        // No runtime file: unreachable without polling.
        fs::remove_file(&runtime).unwrap();
        assert_eq!(r.msg(Ok(DONE)), Some("T3 Code unreachable".into()));
        assert_eq!(r.seen.len(), 2);
        fs::write(&runtime, b"{\"port\":").unwrap();
        assert_eq!(r.msg(Ok(DONE)), None);
        assert_eq!(r.seen.len(), 2);
        assert_eq!(
            r.events(),
            [Event::Set(DONE, SIX), Event::Set(DONE, SIX), Event::Clear]
        );
    }

    #[test]
    fn bridge_token_errors_are_fatal() {
        let mut r = Rig::new();
        r.msg(Ok(DONE));
        let token = r.dir.path().join("t3-token");
        fs::set_permissions(&token, fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(r.step(Ok(DONE)), Err(TokenError::Permissions(0o644)));
        assert_eq!(r.events(), [Event::Set(DONE, SIX), Event::Clear]);
        assert_eq!(r.seen.len(), 1);
        fs::remove_file(&token).unwrap();
        assert_eq!(r.step(Ok(DONE)), Err(TokenError::Missing));
        assert_eq!(r.events(), []);
    }

    #[test]
    fn bridge_keeps_polling_without_the_daemon() {
        let mut r = Rig::new();
        r.reporter.up = false;
        assert_eq!(
            r.msg(Ok(DONE)),
            Some("T3 Code reachable\nLocalFlow daemon unreachable; still polling T3 Code".into())
        );
        assert_eq!(r.msg(Ok(DONE)), None);
        // A clear the daemon missed is retried.
        assert_eq!(
            r.msg(Err(PollError::Unreachable)),
            Some("T3 Code unreachable".into())
        );
        assert_eq!(r.msg(Err(PollError::Unreachable)), None);
        r.reporter.up = true;
        assert_eq!(
            r.msg(Err(PollError::Unreachable)),
            Some("LocalFlow daemon reachable again".into())
        );
        assert_eq!(r.msg(Err(PollError::Unreachable)), None);
        assert_eq!(
            r.events(),
            [
                Event::Set(DONE, SIX),
                Event::Set(DONE, SIX),
                Event::Clear,
                Event::Clear,
                Event::Clear
            ]
        );
    }
}

//! Pickers: the menu programs `localflowctl correct` and `localflowctl dict
//! review` show text in. Two operations:
//!
//! - **Edit:** an input box prefilled with the last dictation; the edited
//!   text comes back (`correct`).
//! - **Choose:** the suggestion dialog, three rows naming a word ("Add “X” to
//!   your dictionary", "Not now", "Don't suggest “X”"); the chosen row comes
//!   back (`correct`, `dict review`).
//!
//! # Privacy contract
//!
//! Dictated text must not leak. Every adapter keeps all of this, and a tool
//! (or one of its operations) that cannot is not supported:
//!
//! - Dictated text and dictionary words never appear in argv or the
//!   environment. Argv and any environment changes are built from
//!   `&'static str` only (the rest of the environment is inherited), and the
//!   text reaches the picker through stdin (a pipe) or an inherited
//!   configuration file descriptor (a memfd on fd 3).
//! - The picker writes no history or cache of what it showed or what was
//!   typed.
//! - The user's configuration for the tool is replaced, so it cannot run a
//!   command or load a plugin that sees the text. For a GTK tool (wofi) that
//!   includes GTK's own plugins: input methods (which can read an input
//!   box's whole text), the accessibility bridge and GTK modules.
//! - stderr is read and dropped: only the exit status is reported.
//! - A parent deadline kills and reaps the picker; anything but a
//!   well-formed answer means "do nothing".
//!
//! # Tools
//!
//! `"picker"` in `config.json` picks one: `"auto"` (the default) takes, for
//! each operation, the first tool on `PATH` that supports it, in the order
//! rofi, fuzzel, wofi, tofi. Verdicts, from each version's manual and
//! source as packaged in nixpkgs, and run in a private headless sway:
//!
//! - **rofi** (2.0.0): edit and choose. See [`rofi`].
//! - **fuzzel** (1.14.1): choose only. It can prefill its box only with
//!   `--search=TEXT` on its command line (its configuration file has no
//!   such key), so it cannot edit. Rows come from stdin. `--config=/dev/null`
//!   replaces the user's configuration (and its `include`s);
//!   `--cache=/dev/null` keeps the dmenu cache off (fuzzel caches dmenu
//!   entries only when a cache file is configured); `--log-no-syslog` and
//!   `--log-level=none` keep it out of syslog. It answers with the row's
//!   text rather than `--index`, because outside a UTF-8 locale fuzzel
//!   drops the rows it cannot convert and numbers the rest from 0.
//!   `--only-match` refuses typed text on Return. Escape exits 2.
//! - **wofi** (1.5.3): edit and choose. The prefill goes in a configuration
//!   file on fd 3 (`--conf=/dev/fd/3`, `search=…`), which replaces the
//!   user's configuration; rows come from stdin. `dmenu-print_line_num`
//!   answers with the row number and turns wofi's dmenu cache off
//!   altogether (`cache_file=/dev/null` too). wofi also reads
//!   `/etc/wofi/config` and `/usr/etc/wofi/config` whatever it is given, and
//!   such a file could set `pre_display_cmd`, a shell command run on every
//!   row, which a later file cannot unset; so LocalFlow does not use wofi
//!   when either exists. It runs with GTK's built-in input method
//!   (`GTK_IM_MODULE=gtk-im-context-simple`), without the accessibility
//!   bridge (`NO_AT_BRIDGE=1`) or `GTK_MODULES`/`GTK3_MODULES`, and with
//!   `XDG_CONFIG_HOME=/dev/null`, so neither its own nor GTK's user
//!   settings load (no user stylesheet either). Its configuration format
//!   drops leading spaces from a value, so text that starts with a space
//!   cannot be edited in wofi. Escape exits 1.
//! - **tofi** (0.9.1): choose only. It has no way to prefill its input.
//!   Rows come from stdin; `--config=/dev/null` replaces the user's
//!   configuration (and its `include`s); in dmenu mode it keeps no history
//!   unless a history file is configured, and `--history=false` is passed
//!   too. It answers with the row's text, normalized to NFC, so rows are
//!   told apart by their fixed text. Escape exits 0 with no output. tofi
//!   chooses its mode from `argv[0]`, so it is started as `tofi`.

pub mod fuzzel;
pub mod rofi;
pub mod tofi;
pub mod wofi;

use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

/// How long a picker may stay open.
pub const DEADLINE: Duration = Duration::from_secs(120);
/// The most output read from a picker (the rest is discarded).
const MAX_OUTPUT: usize = 64 * 1024;
/// The descriptor a picker reads its configuration from.
const CONFIG_FD: libc::c_int = 3;

/// The suggestion dialog's rows, in order.
pub const ADD: usize = 0;
pub const NOT_NOW: usize = 1;
pub const DONT_SUGGEST: usize = 2;

/// The suggestion rows' fixed text before and after the word; `None` for a
/// row without the word.
const ROWS: [(&str, Option<&str>); 3] = [
    ("Add \u{201C}", Some("\u{201D} to your dictionary")),
    ("Not now", None),
    ("Don\u{2019}t suggest \u{201C}", Some("\u{201D}")),
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Rofi,
    Fuzzel,
    Wofi,
    Tofi,
}

impl Kind {
    /// In `auto` order.
    pub const ALL: [Kind; 4] = [Kind::Rofi, Kind::Fuzzel, Kind::Wofi, Kind::Tofi];

    /// Its name, which is also its program name and its `picker` value.
    pub fn name(self) -> &'static str {
        match self {
            Kind::Rofi => "rofi",
            Kind::Fuzzel => "fuzzel",
            Kind::Wofi => "wofi",
            Kind::Tofi => "tofi",
        }
    }

    pub fn supports(self, op: Op) -> bool {
        match op {
            Op::Choose => true,
            Op::Edit => matches!(self, Kind::Rofi | Kind::Wofi),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Op {
    Edit,
    Choose,
}

/// The `picker` setting.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Choice {
    /// The first installed tool that supports the operation.
    #[default]
    Auto,
    Only(Kind),
}

impl Choice {
    /// The accepted values, for error messages.
    pub const VALUES: &str = "auto, rofi, fuzzel, wofi, tofi";

    pub fn parse(s: &str) -> Option<Choice> {
        if s == "auto" {
            return Some(Choice::Auto);
        }
        Kind::ALL
            .into_iter()
            .find(|k| k.name() == s)
            .map(Choice::Only)
    }
}

/// Whether a tool can be used here.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Probe {
    /// Not on `PATH`.
    Missing,
    /// Installed at this path.
    Found(PathBuf),
    /// Installed, but it cannot keep the contract here (the reason).
    Refused(&'static str),
}

/// Looks `kind` up on `PATH` and checks what it depends on.
pub fn probe(kind: Kind) -> Probe {
    let Some(path) = find_in_path(kind.name()) else {
        return Probe::Missing;
    };
    if kind == Kind::Wofi
        && let Some(why) = wofi::system_config()
    {
        return Probe::Refused(why);
    }
    Probe::Found(path)
}

/// The first executable regular file `name` in an absolute `PATH` entry.
pub fn find_in_path(name: &str) -> Option<PathBuf> {
    find_in_dirs(&std::env::var_os("PATH")?, name)
}

/// [`find_in_path`] for a given `PATH` value.
fn find_in_dirs(path: &std::ffi::OsStr, name: &str) -> Option<PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    std::env::split_paths(path)
        .filter(|dir| dir.is_absolute())
        .map(|dir| dir.join(name))
        .find(|p| {
            std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
}

/// Why no picker can be used.
#[derive(Debug, PartialEq, Eq)]
pub enum NoPicker {
    /// `auto` found no installed tool for the operation.
    NoneFound(Op),
    /// The configured tool cannot do the operation.
    Unsupported(Kind, Op),
    /// The configured tool is not installed.
    Missing(Kind),
    /// The configured tool cannot keep the contract here.
    Refused(Kind, &'static str),
}

impl std::fmt::Display for NoPicker {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NoPicker::NoneFound(Op::Edit) => {
                f.write_str("no picker that can edit text was found (install rofi or wofi)")
            }
            NoPicker::NoneFound(Op::Choose) => {
                f.write_str("no picker was found (install rofi, fuzzel, wofi or tofi)")
            }
            NoPicker::Unsupported(k, _) => write!(
                f,
                "{} cannot edit text without putting it on its command line; \
                 set \"picker\" to \"rofi\", \"wofi\" or \"auto\" to correct dictations",
                k.name()
            ),
            NoPicker::Missing(k) => write!(f, "{} is not installed (not found on PATH)", k.name()),
            NoPicker::Refused(k, why) => write!(f, "{} is not used: {why}", k.name()),
        }
    }
}

/// The picker for `op` under `choice`; `probe` says what is installed.
pub fn select(choice: Choice, op: Op, probe: impl Fn(Kind) -> Probe) -> Result<Picker, NoPicker> {
    match choice {
        Choice::Only(kind) => {
            if !kind.supports(op) {
                return Err(NoPicker::Unsupported(kind, op));
            }
            match probe(kind) {
                Probe::Found(program) => Ok(Picker::new(kind, program)),
                Probe::Missing => Err(NoPicker::Missing(kind)),
                Probe::Refused(why) => Err(NoPicker::Refused(kind, why)),
            }
        }
        Choice::Auto => Kind::ALL
            .into_iter()
            .filter(|k| k.supports(op))
            .find_map(|k| match probe(k) {
                Probe::Found(program) => Some(Picker::new(k, program)),
                _ => None,
            })
            .ok_or(NoPicker::NoneFound(op)),
    }
}

pub struct Picker {
    pub kind: Kind,
    pub program: PathBuf,
    pub deadline: Duration,
}

/// Why a picker gave no answer. Carries no output.
#[derive(Debug, PartialEq, Eq)]
pub enum Failure {
    /// It could not be started.
    Spawn(std::io::ErrorKind),
    /// It exited with this status (a non-zero code, or a signal).
    Exit(Option<i32>),
    /// It ran past the deadline and was killed.
    Timeout,
    /// It exited successfully, but the output was not what was asked for.
    Output,
    /// The text cannot be passed to this tool safely.
    Unsafe,
    /// This tool cannot do the operation.
    Unsupported,
    Io(std::io::ErrorKind),
}

/// Follows the tool's name: "rofi exited with status 2".
impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Failure::Spawn(k) => write!(f, "could not be started ({k})"),
            Failure::Exit(Some(c)) => write!(f, "exited with status {c}"),
            Failure::Exit(None) => write!(f, "was killed by a signal"),
            Failure::Timeout => write!(f, "did not finish in time"),
            Failure::Output => write!(f, "gave unexpected output"),
            Failure::Unsafe => write!(f, "cannot be given this text safely"),
            Failure::Unsupported => write!(f, "cannot edit text"),
            Failure::Io(k) => write!(f, "could not be talked to ({k})"),
        }
    }
}

/// What the user did.
#[derive(PartialEq, Eq)]
pub enum Answer<T> {
    /// Accepted, with a well-formed answer.
    Chose(T),
    /// Dismissed (Escape).
    Dismissed,
}

/// Shows no text.
impl<T> std::fmt::Debug for Answer<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Answer::Chose(_) => "Chose(..)",
            Answer::Dismissed => "Dismissed",
        })
    }
}

/// How a tool reports that it was dismissed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dismissal {
    /// One of these exit statuses (rofi and wofi: 1; fuzzel: 2 for Escape,
    /// 1 when it closes without a choice).
    Exit(&'static [i32]),
    /// Exit status 0 with no output (tofi); its status 1 is an error.
    NoOutput,
}

/// How a tool answers the suggestion dialog.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reply {
    /// The row's number, from 0.
    Index,
    /// The row's text.
    Row,
}

/// One run of a picker, built by an adapter.
#[derive(Debug)]
pub struct Invocation {
    /// Static strings only: no text can reach the command line.
    pub args: Vec<&'static str>,
    /// `argv[0]`, when it must not be the program's path.
    pub arg0: Option<&'static str>,
    /// Environment changes, static too: set to a value, or removed
    /// (`None`). Everything else is inherited.
    pub env: &'static [(&'static str, Option<&'static str>)],
    /// Given to the picker as fd 3 (a memfd).
    pub config: Option<String>,
    /// Written to its stdin, a pipe; without it stdin is `/dev/null`.
    pub stdin: Option<String>,
    pub dismissal: Dismissal,
    pub reply: Reply,
}

/// The suggestion dialog's rows (stdin), one per line, or `None` when the
/// word has a control character.
pub fn suggestion_rows(word: &str) -> Option<String> {
    if word.chars().any(crate::protocol::is_control) {
        return None;
    }
    let mut rows = String::new();
    for (before, after) in ROWS {
        rows += before;
        if let Some(after) = after {
            rows += word;
            rows += after;
        }
        rows.push('\n');
    }
    Some(rows)
}

/// The suggestion row a picker answered with its text, told apart by the
/// rows' fixed text (the word may come back in another normal form).
fn row_of(answer: &str) -> Option<usize> {
    ROWS.iter().position(|&(before, after)| match after {
        None => answer == before,
        Some(after) => {
            answer.len() > before.len() + after.len()
                && answer.starts_with(before)
                && answer.ends_with(after)
        }
    })
}

impl Picker {
    /// `program` as `kind`, with [`DEADLINE`].
    pub fn new(kind: Kind, program: PathBuf) -> Picker {
        Picker {
            kind,
            program,
            deadline: DEADLINE,
        }
    }

    /// The invocation that edits `prefill`.
    pub fn edit_invocation(&self, prefill: &str) -> Result<Invocation, Failure> {
        if prefill.chars().any(crate::protocol::is_control) {
            return Err(Failure::Unsafe);
        }
        match self.kind {
            Kind::Rofi => rofi::edit(prefill),
            Kind::Wofi => wofi::edit(prefill),
            Kind::Fuzzel | Kind::Tofi => Err(Failure::Unsupported),
        }
    }

    /// The invocation that shows `rows`.
    pub fn choose_invocation(&self, rows: String) -> Invocation {
        match self.kind {
            Kind::Rofi => rofi::choose(rows),
            Kind::Fuzzel => fuzzel::choose(rows),
            Kind::Wofi => wofi::choose(rows),
            Kind::Tofi => tofi::choose(rows),
        }
    }

    /// Lets the user edit `prefill`; the edited text on accept.
    pub fn edit(&self, prefill: &str) -> Result<Answer<String>, Failure> {
        let inv = self.edit_invocation(prefill)?;
        let out = match self.run(&inv)? {
            Answer::Chose(out) => out,
            Answer::Dismissed => return Ok(Answer::Dismissed),
        };
        let text = String::from_utf8(out).map_err(|_| Failure::Output)?;
        let text = text.strip_suffix('\n').unwrap_or(&text);
        if text.chars().any(crate::protocol::is_control)
            || text.len() > crate::protocol::MAX_TEXT_BYTES
        {
            return Err(Failure::Output);
        }
        Ok(Answer::Chose(text.to_owned()))
    }

    /// Asks whether to add `word`: [`ADD`], [`NOT_NOW`] or [`DONT_SUGGEST`].
    pub fn suggest(&self, word: &str) -> Result<Answer<usize>, Failure> {
        let rows = suggestion_rows(word).ok_or(Failure::Unsafe)?;
        let inv = self.choose_invocation(rows);
        let out = match self.run(&inv)? {
            Answer::Chose(out) => out,
            Answer::Dismissed => return Ok(Answer::Dismissed),
        };
        let out = std::str::from_utf8(&out).map_err(|_| Failure::Output)?;
        let out = out.strip_suffix('\n').unwrap_or(out);
        let row = match inv.reply {
            Reply::Index => match out {
                "0" => Some(ADD),
                "1" => Some(NOT_NOW),
                "2" => Some(DONT_SUGGEST),
                _ => None,
            },
            Reply::Row => row_of(out),
        };
        row.map(Answer::Chose).ok_or(Failure::Output)
    }

    /// Runs `inv`, with stdout and stderr captured, until [`Self::deadline`].
    /// The output on accept; nothing on a dismissal.
    fn run(&self, inv: &Invocation) -> Result<Answer<Vec<u8>>, Failure> {
        let memfd = match &inv.config {
            Some(config) => Some(config_fd(config).map_err(|e| Failure::Io(e.kind()))?),
            None => None,
        };
        let mut cmd = Command::new(&self.program);
        if let Some(arg0) = inv.arg0 {
            cmd.arg0(arg0);
        }
        for &(key, value) in inv.env {
            match value {
                Some(v) => cmd.env(key, v),
                None => cmd.env_remove(key),
            };
        }
        cmd.args(&inv.args)
            .stdin(if inv.stdin.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(raw) = memfd.as_ref().map(AsRawFd::as_raw_fd) {
            // SAFETY: only async-signal-safe calls (dup2, fcntl) between
            // fork and exec. dup2 clears close-on-exec on the copy; when the
            // memfd already is fd 3 its flag is cleared directly.
            unsafe {
                cmd.pre_exec(move || {
                    if raw == CONFIG_FD {
                        if libc::fcntl(raw, libc::F_SETFD, 0) != 0 {
                            return Err(std::io::Error::last_os_error());
                        }
                    } else if libc::dup2(raw, CONFIG_FD) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
        }
        // A program written a moment ago can be briefly busy (ETXTBSY: a
        // process forked meanwhile still holds it open for writing until it
        // execs), so that is retried a few times.
        let mut tries = 0;
        let mut child = loop {
            match cmd.spawn() {
                Ok(child) => break child,
                Err(e) if e.kind() == std::io::ErrorKind::ExecutableFileBusy && tries < 5 => {
                    tries += 1;
                    std::thread::sleep(Duration::from_millis(20));
                }
                Err(e) => return Err(Failure::Spawn(e.kind())),
            }
        };
        drop(memfd);
        let stdout = child.stdout.take().map(|s| drain(s, MAX_OUTPUT));
        // stderr is read so the picker cannot block on it, then dropped
        // unseen.
        let stderr = child.stderr.take().map(|s| drain(s, 0));
        if let (Some(rows), Some(mut pipe)) = (&inv.stdin, child.stdin.take()) {
            let rows = rows.clone();
            // A picker that never reads must not block us: write on a
            // thread.
            std::thread::spawn(move || {
                let _ = pipe.write_all(rows.as_bytes());
            });
        }
        let status = wait(&mut child, self.deadline)?;
        // The picker has exited, so its pipes close now, unless something
        // it started holds them open: then give up on the output.
        let out = stdout.and_then(|h| join_within(h, READER_GRACE));
        if let Some(h) = stderr {
            let _ = join_within(h, READER_GRACE);
        }
        match (status.code(), inv.dismissal) {
            (Some(0), Dismissal::NoOutput) if out.as_ref().is_some_and(Vec::is_empty) => {
                Ok(Answer::Dismissed)
            }
            (Some(0), _) => out.map(Answer::Chose).ok_or(Failure::Output),
            (Some(c), Dismissal::Exit(codes)) if codes.contains(&c) => Ok(Answer::Dismissed),
            (code, _) => Err(Failure::Exit(code)),
        }
    }
}

/// A sealed-off in-memory file holding `config`, close-on-exec.
fn config_fd(config: &str) -> std::io::Result<OwnedFd> {
    // SAFETY: a valid NUL-terminated name and flags.
    let fd = unsafe { libc::memfd_create(c"localflow-picker".as_ptr(), libc::MFD_CLOEXEC) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: a fresh descriptor owned by nothing else.
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };
    let mut file = std::fs::File::from(fd);
    file.write_all(config.as_bytes())?;
    Ok(OwnedFd::from(file))
}

/// Reads `r` to the end on a thread, keeping at most `limit` bytes.
fn drain(mut r: impl Read + Send + 'static, limit: usize) -> std::thread::JoinHandle<Vec<u8>> {
    std::thread::spawn(move || {
        let mut kept = Vec::new();
        let mut buf = [0u8; 4096];
        loop {
            match r.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let room = limit.saturating_sub(kept.len());
                    kept.extend_from_slice(&buf[..n.min(room)]);
                }
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                Err(_) => break,
            }
        }
        kept
    })
}

/// How long, once the picker has exited, its output may take to finish.
const READER_GRACE: Duration = Duration::from_secs(1);

/// The reader's result if it finishes within `grace`; otherwise it is left
/// to end on its own.
fn join_within(h: std::thread::JoinHandle<Vec<u8>>, grace: Duration) -> Option<Vec<u8>> {
    let end = Instant::now() + grace;
    while !h.is_finished() {
        if Instant::now() >= end {
            return None;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    h.join().ok()
}

/// Waits for `child` until `deadline` passes, then kills and reaps it.
fn wait(child: &mut std::process::Child, deadline: Duration) -> Result<ExitStatus, Failure> {
    let end = Instant::now() + deadline;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) if Instant::now() >= end => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(Failure::Timeout);
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(Failure::Io(e.kind()));
            }
        }
    }
}

/// True if `path` exists (a broken symlink counts).
fn exists(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::testing::TempDir;
    use std::os::unix::fs::PermissionsExt;

    /// A fake picker: a shell script (synthetic, never given user text on
    /// its command line) that records its arguments, `$0`, environment,
    /// configuration (fd 3, when open) and stdin in `dir`, then runs `body`.
    pub(crate) fn fake(dir: &TempDir, kind: Kind, body: &str) -> Picker {
        let d = dir.path().display();
        let script = format!(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{d}/args'\nprintf '%s' \"$0\" > '{d}/arg0'\n\
             env > '{d}/env'\nrm -f '{d}/config'\n\
             if [ -e /dev/fd/3 ]; then cat /dev/fd/3 > '{d}/config'; fi\n\
             cat > '{d}/stdin'\n{body}\n"
        );
        let path = dir.path().join(kind.name());
        std::fs::write(&path, script).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        Picker {
            kind,
            program: path,
            deadline: Duration::from_secs(10),
        }
    }

    pub(crate) fn read(dir: &TempDir, name: &str) -> String {
        std::fs::read_to_string(dir.path().join(name)).unwrap_or_default()
    }

    pub(crate) fn args(dir: &TempDir) -> Vec<String> {
        read(dir, "args").lines().map(String::from).collect()
    }

    /// Synthetic text with Rasi, INI and shell metacharacters.
    pub(crate) const SECRET: &str = "Synthetic \"quoted\" \\ #text $(x) = \u{e9} 100%";
    const WORD: &str = "Zorblaxian";

    /// The contract every adapter keeps: no text on argv or in the
    /// environment, whatever the operation.
    #[test]
    fn no_adapter_puts_text_on_argv_or_in_the_environment() {
        let dir = TempDir::new("picker-argv");
        for kind in Kind::ALL {
            let p = fake(&dir, kind, "echo 0");
            if kind.supports(Op::Edit) {
                let _ = p.edit(SECRET);
                let seen = [read(&dir, "args"), read(&dir, "arg0"), read(&dir, "env")];
                for s in &seen {
                    assert!(!s.contains("ynthetic") && !s.contains("quoted"), "{kind:?}");
                }
                assert!(read(&dir, "config").contains("ynthetic"), "{kind:?}");
            }
            let _ = p.suggest(WORD);
            for s in [read(&dir, "args"), read(&dir, "arg0"), read(&dir, "env")] {
                assert!(!s.contains(WORD), "{kind:?}");
            }
            assert_eq!(read(&dir, "stdin"), suggestion_rows(WORD).unwrap());
            assert!(!read(&dir, "config").contains(WORD), "{kind:?}");
        }
    }

    #[test]
    fn edit_is_refused_by_pickers_that_cannot_prefill() {
        let dir = TempDir::new("picker-unsupported");
        for kind in [Kind::Fuzzel, Kind::Tofi] {
            assert!(!kind.supports(Op::Edit) && kind.supports(Op::Choose));
            let p = fake(&dir, kind, "touch ran");
            assert_eq!(p.edit("x").unwrap_err(), Failure::Unsupported);
            assert!(!dir.path().join("ran").exists(), "{kind:?}");
        }
    }

    #[test]
    fn dismissal_and_exit_statuses() {
        let dir = TempDir::new("picker-exit");
        for kind in [Kind::Rofi, Kind::Fuzzel, Kind::Wofi] {
            let p = fake(&dir, kind, "echo leaked >&2; exit 1");
            assert!(p.suggest(WORD).unwrap() == Answer::Dismissed, "{kind:?}");
            let p = fake(&dir, kind, "echo 0; exit 10");
            assert_eq!(p.suggest(WORD).unwrap_err(), Failure::Exit(Some(10)));
        }
        // tofi: Escape is a success without output; 1 is an error.
        let p = fake(&dir, Kind::Tofi, "exit 0");
        assert!(p.suggest(WORD).unwrap() == Answer::Dismissed);
        let p = fake(&dir, Kind::Tofi, "exit 1");
        assert_eq!(p.suggest(WORD).unwrap_err(), Failure::Exit(Some(1)));
        for kind in Kind::ALL {
            for code in [3, 65] {
                let p = fake(
                    &dir,
                    kind,
                    &format!("echo partial; echo {SECRET:?} >&2; exit {code}"),
                );
                let e = p.suggest(WORD).unwrap_err();
                assert_eq!(e, Failure::Exit(Some(code)));
                // Nothing the picker printed reaches the error.
                assert!(!e.to_string().contains("partial") && !e.to_string().contains("ynthetic"));
            }
            let p = fake(&dir, kind, "kill -9 $$");
            assert_eq!(p.suggest(WORD).unwrap_err(), Failure::Exit(None));
            let missing = Picker::new(kind, dir.path().join("absent"));
            assert!(matches!(missing.suggest(WORD), Err(Failure::Spawn(_))));
        }
    }

    #[test]
    fn answers_map_to_rows() {
        let dir = TempDir::new("picker-rows");
        for kind in [Kind::Rofi, Kind::Wofi] {
            for (out, want) in [("0", ADD), ("1", NOT_NOW), ("2", DONT_SUGGEST)] {
                let p = fake(&dir, kind, &format!("echo {out}"));
                assert!(p.suggest(WORD).unwrap() == Answer::Chose(want), "{kind:?}");
            }
            for out in ["3", "", "0 1", "x", "-1", "00"] {
                let p = fake(&dir, kind, &format!("printf '%s' '{out}'"));
                assert_eq!(p.suggest(WORD).err(), Some(Failure::Output), "{out:?}");
            }
        }
        // fuzzel and tofi answer with the row's text, maybe in another
        // normal form (tofi): "é" decomposed comes back for the precomposed
        // word.
        let rows: Vec<String> = suggestion_rows("Caf\u{e9}")
            .unwrap()
            .lines()
            .map(String::from)
            .collect();
        let nfd = suggestion_rows("Cafe\u{301}").unwrap();
        let answer = format!("cat '{}/answer'", dir.path().display());
        for kind in [Kind::Fuzzel, Kind::Tofi] {
            for (i, row) in rows
                .iter()
                .chain(nfd.lines().map(String::from).collect::<Vec<_>>().iter())
                .enumerate()
            {
                std::fs::write(dir.path().join("answer"), format!("{row}\n")).unwrap();
                let p = fake(&dir, kind, &answer);
                assert!(
                    p.suggest("Caf\u{e9}").unwrap() == Answer::Chose(i % 3),
                    "{kind:?} {row}"
                );
            }
            // Typed text, a row number, or a row with something missing.
            for out in [
                "Add \u{201C}\u{201D} to your dictionary",
                "Not now!",
                "Add",
                "x",
                "0",
                "-1",
            ] {
                std::fs::write(dir.path().join("answer"), out).unwrap();
                let p = fake(&dir, kind, &answer);
                assert_eq!(p.suggest(WORD).err(), Some(Failure::Output), "{out:?}");
            }
        }
    }

    #[test]
    fn a_hung_picker_is_killed_and_reaped() {
        let dir = TempDir::new("picker-hang");
        for kind in Kind::ALL {
            let mut p = fake(&dir, kind, "exec sleep 30");
            p.deadline = Duration::from_millis(300);
            let start = Instant::now();
            assert_eq!(p.suggest(WORD).unwrap_err(), Failure::Timeout, "{kind:?}");
            assert!(start.elapsed() < Duration::from_secs(5));
        }
        // Something it started keeps the pipes open after it exits.
        let p = fake(&dir, Kind::Rofi, "sleep 4 & echo partial");
        let start = Instant::now();
        assert_eq!(p.edit("x").unwrap_err(), Failure::Output);
        assert!(start.elapsed() < Duration::from_secs(3));
    }

    #[test]
    fn floods_and_bad_output_are_refused() {
        let dir = TempDir::new("picker-flood");
        for kind in [Kind::Rofi, Kind::Wofi] {
            // Megabytes on both streams neither block nor get through.
            let p = fake(
                &dir,
                kind,
                "head -c 3000000 /dev/zero | tr '\\0' 'a'; head -c 3000000 /dev/zero >&2",
            );
            assert_eq!(p.edit("x").unwrap_err(), Failure::Output);
            for body in ["printf 'a\\nb\\n'", "printf 'a\\tb'", "printf '\\377'"] {
                let p = fake(&dir, kind, body);
                assert_eq!(p.edit("x").unwrap_err(), Failure::Output, "{body}");
            }
            let p = fake(
                &dir,
                kind,
                "printf 'Synthetic edited \\342\\200\\234text\\n'",
            );
            assert!(p.edit("x").unwrap() == Answer::Chose("Synthetic edited \u{201C}text".into()));
        }
        // Text that cannot be passed is refused before anything runs.
        for kind in Kind::ALL {
            let p = fake(&dir, kind, "touch ran");
            if kind.supports(Op::Edit) {
                assert_eq!(p.edit("a\nb").unwrap_err(), Failure::Unsafe);
            }
            assert_eq!(p.suggest("a\u{85}").unwrap_err(), Failure::Unsafe);
            assert!(!dir.path().join("ran").exists());
        }
        let debug = format!("{:?}", Answer::Chose(SECRET.to_string()));
        assert!(!debug.contains("ynthetic"));
    }

    #[test]
    fn selection() {
        let p = |s: &str| PathBuf::from(s);
        let installed = |names: &'static [&'static str]| {
            move |k: Kind| {
                if names.contains(&k.name()) {
                    Probe::Found(PathBuf::from(format!("/bin/{}", k.name())))
                } else {
                    Probe::Missing
                }
            }
        };
        let pick = |c, op, names| select(c, op, installed(names)).map(|p| (p.kind, p.program));
        // auto: rofi first, then fuzzel, wofi, tofi; edit skips those that
        // cannot.
        let all = &["rofi", "fuzzel", "wofi", "tofi"];
        assert_eq!(
            pick(Choice::Auto, Op::Edit, all),
            Ok((Kind::Rofi, p("/bin/rofi")))
        );
        assert_eq!(pick(Choice::Auto, Op::Choose, all).unwrap().0, Kind::Rofi);
        let no_rofi = &["fuzzel", "wofi", "tofi"];
        assert_eq!(pick(Choice::Auto, Op::Edit, no_rofi).unwrap().0, Kind::Wofi);
        assert_eq!(
            pick(Choice::Auto, Op::Choose, no_rofi).unwrap().0,
            Kind::Fuzzel
        );
        assert_eq!(
            pick(Choice::Auto, Op::Choose, &["tofi"]).unwrap().0,
            Kind::Tofi
        );
        assert_eq!(
            pick(Choice::Auto, Op::Edit, &["fuzzel", "tofi"]).unwrap_err(),
            NoPicker::NoneFound(Op::Edit)
        );
        assert_eq!(
            pick(Choice::Auto, Op::Choose, &[]).unwrap_err(),
            NoPicker::NoneFound(Op::Choose)
        );
        // A configured tool is used for what it can do, and only it.
        let only = |k| Choice::Only(k);
        assert_eq!(
            pick(only(Kind::Tofi), Op::Choose, all).unwrap().0,
            Kind::Tofi
        );
        assert_eq!(
            pick(only(Kind::Tofi), Op::Edit, all).unwrap_err(),
            NoPicker::Unsupported(Kind::Tofi, Op::Edit)
        );
        assert_eq!(
            pick(only(Kind::Fuzzel), Op::Choose, &["rofi"]).unwrap_err(),
            NoPicker::Missing(Kind::Fuzzel)
        );
        // A refused tool is skipped by auto, and an error when configured.
        let refused = |k: Kind| match k {
            Kind::Wofi => Probe::Refused("synthetic reason"),
            Kind::Tofi => Probe::Found(p("/bin/tofi")),
            _ => Probe::Missing,
        };
        assert_eq!(
            select(Choice::Auto, Op::Edit, refused).err(),
            Some(NoPicker::NoneFound(Op::Edit))
        );
        assert_eq!(
            select(Choice::Auto, Op::Choose, refused).unwrap().kind,
            Kind::Tofi
        );
        assert_eq!(
            select(only(Kind::Wofi), Op::Choose, refused).err(),
            Some(NoPicker::Refused(Kind::Wofi, "synthetic reason"))
        );
        // Messages say what to do.
        assert!(
            NoPicker::Unsupported(Kind::Fuzzel, Op::Edit)
                .to_string()
                .starts_with("fuzzel cannot edit text")
        );
        assert!(
            NoPicker::NoneFound(Op::Edit)
                .to_string()
                .contains("rofi or wofi")
        );
    }

    #[test]
    fn choices_parse() {
        assert_eq!(Choice::parse("auto"), Some(Choice::Auto));
        for k in Kind::ALL {
            assert_eq!(Choice::parse(k.name()), Some(Choice::Only(k)));
            assert!(Choice::VALUES.contains(k.name()));
        }
        for bad in ["", "Rofi", "dmenu", "rofi "] {
            assert_eq!(Choice::parse(bad), None);
        }
        assert_eq!(Choice::default(), Choice::Auto);
    }

    #[test]
    fn path_lookup_takes_the_first_executable() {
        let dir = TempDir::new("picker-path");
        let (a, b) = (dir.path().join("a"), dir.path().join("b"));
        std::fs::create_dir_all(&a).unwrap();
        std::fs::create_dir_all(&b).unwrap();
        // Not executable, a directory, then the real one.
        std::fs::write(a.join("fuzzel"), "").unwrap();
        std::fs::create_dir_all(a.join("tofi")).unwrap();
        std::fs::write(b.join("fuzzel"), "").unwrap();
        std::fs::set_permissions(b.join("fuzzel"), std::fs::Permissions::from_mode(0o700)).unwrap();
        // A relative entry is skipped, even when it holds the program.
        std::fs::create_dir_all(dir.path().join("rel")).unwrap();
        std::fs::copy(b.join("fuzzel"), dir.path().join("rel/rofi")).unwrap();
        let path = std::env::join_paths([
            Path::new("rel"),
            a.as_path(),
            dir.path().join("missing").as_path(),
            b.as_path(),
        ])
        .unwrap();
        assert_eq!(find_in_dirs(&path, "fuzzel"), Some(b.join("fuzzel")));
        assert_eq!(find_in_dirs(&path, "tofi"), None);
        assert_eq!(find_in_dirs(&path, "rofi"), None);
    }

    #[test]
    fn rows_keep_their_order_and_text() {
        assert_eq!(
            suggestion_rows("Kubernetes").unwrap(),
            "Add \u{201C}Kubernetes\u{201D} to your dictionary\nNot now\n\
             Don\u{2019}t suggest \u{201C}Kubernetes\u{201D}\n"
        );
    }
}

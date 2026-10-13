//! rofi as `localflowctl correct`'s helper. Dictated text must not leak:
//!
//! - It never appears in argv. The edit box is prefilled through an
//!   inherited configuration file descriptor: `-config /dev/fd/3` reading a
//!   memfd that holds `configuration { filter: "…"; }`. That file replaces
//!   the user's rofi configuration (so their settings and theme are not
//!   loaded either) and `-no-plugins` keeps plugins out. Tested against
//!   rofi 2.0.0: a Rasi string unescapes `\"` and `\\`, a raw newline ends
//!   it, and a string runs to the last quote on its line, so every property
//!   gets its own line and control characters are refused.
//! - The suggestion dialog reads its rows from stdin (a pipe). rofi 2.0.0
//!   has no `mesg` configuration option, so the word is in the rows
//!   ("Add “X” to your dictionary", "Not now", "Don't suggest “X”").
//! - `-disable-history` (also set in the configuration), so rofi keeps no
//!   history of what was typed in the box.
//! - stderr is read and dropped: only the exit status is reported.
//! - A parent deadline kills and reaps rofi; anything but exit 0 with
//!   well-formed output means "do nothing".

use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

/// How long rofi may stay open.
pub const DEADLINE: Duration = Duration::from_secs(120);
/// The most output read from rofi (the rest is discarded).
const MAX_OUTPUT: usize = 64 * 1024;
/// The descriptor rofi reads its configuration from.
const CONFIG_FD: libc::c_int = 3;

/// The suggestion dialog's rows, in order.
pub const ADD: usize = 0;
pub const NOT_NOW: usize = 1;
pub const DONT_SUGGEST: usize = 2;

pub struct Rofi {
    pub program: PathBuf,
    pub deadline: Duration,
}

/// Why rofi gave no answer. Carries no output.
#[derive(Debug, PartialEq, Eq)]
pub enum Failure {
    /// It could not be started.
    Spawn(std::io::ErrorKind),
    /// It exited with this status (a non-zero code, or a signal).
    Exit(Option<i32>),
    /// It ran past the deadline and was killed.
    Timeout,
    /// Exit 0, but the output was not what was asked for.
    Output,
    /// The text cannot be passed safely (control characters).
    Unsafe,
    Io(std::io::ErrorKind),
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Failure::Spawn(k) => write!(f, "cannot run rofi ({k})"),
            Failure::Exit(Some(c)) => write!(f, "rofi exited with status {c}"),
            Failure::Exit(None) => write!(f, "rofi was killed by a signal"),
            Failure::Timeout => write!(f, "rofi did not finish in time"),
            Failure::Output => write!(f, "rofi gave unexpected output"),
            Failure::Unsafe => write!(f, "the text cannot be shown in rofi"),
            Failure::Io(k) => write!(f, "talking to rofi failed ({k})"),
        }
    }
}

/// What the user did.
#[derive(PartialEq, Eq)]
pub enum Answer<T> {
    /// Accepted (exit 0 with well-formed output).
    Chose(T),
    /// Dismissed (Escape: exit 1).
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

/// A Rasi string literal for `s`, or `None` when `s` has a control
/// character (a raw newline would end the string).
pub fn rasi_string(s: &str) -> Option<String> {
    if s.chars().any(crate::protocol::is_control) {
        return None;
    }
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        if matches!(c, '"' | '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    Some(out)
}

/// The edit dialog's configuration: the prefill, and no history.
pub fn edit_config(prefill: &str) -> Option<String> {
    Some(format!(
        "configuration {{\n  filter: {};\n  disable-history: true;\n}}\n",
        rasi_string(prefill)?
    ))
}

/// The suggestion dialog's rows (stdin), one per line.
pub fn suggestion_rows(word: &str) -> Option<String> {
    if word.chars().any(crate::protocol::is_control) {
        return None;
    }
    Some(format!(
        "Add \u{201C}{word}\u{201D} to your dictionary\nNot now\nDon\u{2019}t suggest \u{201C}{word}\u{201D}\n"
    ))
}

impl Rofi {
    /// `rofi` from `PATH`, with [`DEADLINE`].
    pub fn system() -> Rofi {
        Rofi {
            program: PathBuf::from("rofi"),
            deadline: DEADLINE,
        }
    }

    /// Lets the user edit `prefill`; the edited text on accept.
    pub fn edit(&self, prefill: &str) -> Result<Answer<String>, Failure> {
        let config = edit_config(prefill).ok_or(Failure::Unsafe)?;
        let args = [
            "-dmenu",
            "-disable-history",
            "-no-plugins",
            "-format",
            "f",
            "-p",
            "Correct",
        ];
        let out = match self.run(&args, &config, None)? {
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
        let config = "configuration {\n  disable-history: true;\n}\n";
        let args = [
            "-dmenu",
            "-disable-history",
            "-no-plugins",
            "-no-custom",
            "-format",
            "i",
            "-p",
            "LocalFlow",
        ];
        let out = match self.run(&args, config, Some(rows.as_bytes()))? {
            Answer::Chose(out) => out,
            Answer::Dismissed => return Ok(Answer::Dismissed),
        };
        match out.as_slice() {
            b"0\n" | b"0" => Ok(Answer::Chose(ADD)),
            b"1\n" | b"1" => Ok(Answer::Chose(NOT_NOW)),
            b"2\n" | b"2" => Ok(Answer::Chose(DONT_SUGGEST)),
            _ => Err(Failure::Output),
        }
    }

    /// Runs rofi with `args` plus `-config /dev/fd/3` (fd 3 reading
    /// `config`), `stdin` (or `/dev/null`), and stdout and stderr captured.
    /// Exit 0 gives stdout; exit 1 is a dismissal.
    fn run(
        &self,
        args: &[&str],
        config: &str,
        stdin: Option<&[u8]>,
    ) -> Result<Answer<Vec<u8>>, Failure> {
        let memfd = config_fd(config).map_err(|e| Failure::Io(e.kind()))?;
        let raw = memfd.as_raw_fd();
        let mut cmd = Command::new(&self.program);
        cmd.args(args)
            .args(["-config", "/dev/fd/3"])
            .stdin(if stdin.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        // SAFETY: only async-signal-safe calls (dup2, fcntl) between fork
        // and exec. dup2 clears close-on-exec on the copy; when the memfd
        // already is fd 3 its flag is cleared directly.
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
        let mut child = cmd.spawn().map_err(|e| Failure::Spawn(e.kind()))?;
        drop(memfd);
        let stdout = child.stdout.take().map(|s| drain(s, MAX_OUTPUT));
        // stderr is read so rofi cannot block on it, then dropped unseen.
        let stderr = child.stderr.take().map(|s| drain(s, 0));
        if let (Some(rows), Some(mut pipe)) = (stdin, child.stdin.take()) {
            let rows = rows.to_vec();
            // A rofi that never reads must not block us: write on a thread.
            std::thread::spawn(move || {
                let _ = pipe.write_all(&rows);
            });
        }
        let status = wait(&mut child, self.deadline)?;
        // rofi has exited, so its pipes close now, unless something it
        // started holds them open: then give up on the output.
        let out = stdout.and_then(|h| join_within(h, READER_GRACE));
        if let Some(h) = stderr {
            let _ = join_within(h, READER_GRACE);
        }
        match status.code() {
            Some(0) => out.map(Answer::Chose).ok_or(Failure::Output),
            Some(1) => Ok(Answer::Dismissed),
            code => Err(Failure::Exit(code)),
        }
    }
}

/// A sealed-off in-memory file holding `config`, close-on-exec.
fn config_fd(config: &str) -> std::io::Result<OwnedFd> {
    // SAFETY: a valid NUL-terminated name and flags.
    let fd = unsafe { libc::memfd_create(c"localflow-rofi".as_ptr(), libc::MFD_CLOEXEC) };
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

/// How long, once rofi has exited, its output may take to finish.
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::TempDir;
    use std::os::unix::fs::PermissionsExt;

    /// A fake rofi: a shell script (synthetic, never given user text on its
    /// command line) that records its arguments, configuration and stdin in
    /// `dir`, then runs `body`.
    fn fake(dir: &TempDir, body: &str) -> Rofi {
        let d = dir.path().display();
        let script = format!(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{d}/args'\ncat /dev/fd/3 > '{d}/config'\ncat > '{d}/stdin'\n{body}\n"
        );
        let path = dir.path().join("rofi");
        std::fs::write(&path, script).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        Rofi {
            program: path,
            deadline: Duration::from_secs(10),
        }
    }

    fn read(dir: &TempDir, name: &str) -> String {
        std::fs::read_to_string(dir.path().join(name)).unwrap()
    }

    const SECRET: &str = "Synthetic \"quoted\" \\ text \u{e9} 100%";

    #[test]
    fn edit_prefills_through_the_config_fd_only() {
        let dir = TempDir::new("rofi-edit");
        let r = fake(&dir, "printf 'Synthetic edited \\342\\200\\234text\\n'");
        let got = r.edit(SECRET).unwrap();
        assert!(got == Answer::Chose("Synthetic edited \u{201C}text".into()));
        let args = read(&dir, "args");
        assert_eq!(
            args.lines().collect::<Vec<_>>(),
            [
                "-dmenu",
                "-disable-history",
                "-no-plugins",
                "-format",
                "f",
                "-p",
                "Correct",
                "-config",
                "/dev/fd/3"
            ]
        );
        assert!(!args.contains("Synthetic"));
        assert_eq!(read(&dir, "config"), edit_config(SECRET).unwrap());
        assert!(
            read(&dir, "config").contains(r#"filter: "Synthetic \"quoted\" \\ text"#),
            "{}",
            read(&dir, "config")
        );
        // stdin is /dev/null.
        assert_eq!(read(&dir, "stdin"), "");
    }

    #[test]
    fn suggestion_rows_come_from_stdin() {
        let dir = TempDir::new("rofi-suggest");
        for (out, want) in [
            ("0", Some(ADD)),
            ("1", Some(NOT_NOW)),
            ("2", Some(DONT_SUGGEST)),
        ] {
            let r = fake(&dir, &format!("echo {out}"));
            assert!(r.suggest("Kubernetes").unwrap() == Answer::Chose(want.unwrap()));
        }
        let args = read(&dir, "args");
        assert!(args.contains("-no-custom") && args.contains("-disable-history"));
        assert!(!args.contains("Kubernetes"));
        assert_eq!(read(&dir, "stdin"), suggestion_rows("Kubernetes").unwrap());
        assert!(read(&dir, "stdin").starts_with("Add \u{201C}Kubernetes\u{201D}"));
        assert!(!read(&dir, "config").contains("Kubernetes"));
        // Anything else is not an answer.
        for out in ["3", "", "0 1", "x"] {
            let r = fake(&dir, &format!("printf '{out}'"));
            assert_eq!(
                r.suggest("Kubernetes").err(),
                Some(Failure::Output),
                "{out:?}"
            );
        }
    }

    #[test]
    fn exits_other_than_success_do_nothing() {
        let dir = TempDir::new("rofi-exit");
        let r = fake(&dir, "echo leaked >&2; exit 1");
        assert!(r.edit("x").unwrap() == Answer::Dismissed);
        for code in [2, 10, 65] {
            let r = fake(
                &dir,
                &format!("echo partial; echo {SECRET:?} >&2; exit {code}"),
            );
            let e = r.edit("x").unwrap_err();
            assert_eq!(e, Failure::Exit(Some(code)));
            // Nothing rofi printed reaches the error.
            assert!(!e.to_string().contains("partial") && !e.to_string().contains("ynthetic"));
        }
        let r = fake(&dir, "kill -9 $$");
        assert_eq!(r.edit("x").unwrap_err(), Failure::Exit(None));
        let missing = Rofi {
            program: dir.path().join("absent"),
            deadline: Duration::from_secs(1),
        };
        assert!(matches!(missing.edit("x"), Err(Failure::Spawn(_))));
    }

    #[test]
    fn a_hung_rofi_is_killed_and_reaped() {
        let dir = TempDir::new("rofi-hang");
        let mut r = fake(&dir, "exec sleep 30");
        r.deadline = Duration::from_millis(300);
        let start = Instant::now();
        assert_eq!(r.edit("x").unwrap_err(), Failure::Timeout);
        assert!(start.elapsed() < Duration::from_secs(5));
        // Something it started keeps the pipes open after it exits.
        let r = fake(&dir, "sleep 4 & echo partial");
        let start = Instant::now();
        assert_eq!(r.edit("x").unwrap_err(), Failure::Output);
        assert!(start.elapsed() < Duration::from_secs(3));
    }

    #[test]
    fn floods_and_bad_output_are_refused() {
        let dir = TempDir::new("rofi-flood");
        // Megabytes on both streams neither block nor get through.
        let r = fake(
            &dir,
            "head -c 3000000 /dev/zero | tr '\\0' 'a'; head -c 3000000 /dev/zero >&2",
        );
        assert_eq!(r.edit("x").unwrap_err(), Failure::Output);
        for body in ["printf 'a\\nb\\n'", "printf 'a\\tb'", "printf '\\377'"] {
            let r = fake(&dir, body);
            assert_eq!(r.edit("x").unwrap_err(), Failure::Output, "{body}");
        }
        // Text that cannot be passed is refused before anything runs.
        let r = fake(&dir, "touch ran");
        assert_eq!(r.edit("a\nb").unwrap_err(), Failure::Unsafe);
        assert_eq!(r.suggest("a\u{85}").unwrap_err(), Failure::Unsafe);
        assert!(!dir.path().join("ran").exists());
    }

    #[test]
    fn rasi_escaping() {
        assert_eq!(rasi_string("plain").unwrap(), "\"plain\"");
        assert_eq!(rasi_string(r#"a"b\c"#).unwrap(), r#""a\"b\\c""#);
        assert_eq!(
            rasi_string("\"; } @import \"x").unwrap(),
            r#""\"; } @import \"x""#
        );
        assert!(rasi_string("a\nb").is_none() && rasi_string("\u{7f}").is_none());
        let debug = format!("{:?}", Answer::Chose(SECRET.to_string()));
        assert!(!debug.contains("ynthetic"));
    }

    /// The installed rofi reads the generated configuration back exactly
    /// (`-dump-config` needs no display). Skipped when rofi is absent.
    #[test]
    fn real_rofi_reads_the_prefill_back() {
        let Ok(out) = Command::new("rofi").arg("-v").output() else {
            eprintln!("rofi not installed; skipped");
            return;
        };
        if !out.status.success() {
            return;
        }
        for text in [
            "plain",
            SECRET,
            r#"a"; } @import "/x"; configuration { filter: "b"#,
            "\\101 \\n // /* c */ \u{1f642} e\u{301}",
            "",
        ] {
            let memfd = config_fd(&edit_config(text).unwrap()).unwrap();
            let raw = memfd.as_raw_fd();
            let mut cmd = Command::new("rofi");
            cmd.args(["-config", "/dev/fd/3", "-dump-config"])
                .stdin(Stdio::null())
                .stderr(Stdio::null());
            // SAFETY: as in `Rofi::run`.
            unsafe {
                cmd.pre_exec(move || {
                    if raw != CONFIG_FD && libc::dup2(raw, CONFIG_FD) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    if raw == CONFIG_FD {
                        libc::fcntl(raw, libc::F_SETFD, 0);
                    }
                    Ok(())
                });
            }
            let dump = String::from_utf8(cmd.output().unwrap().stdout).unwrap();
            let line = dump
                .lines()
                .find_map(|l| l.strip_prefix("\tfilter: \""))
                .and_then(|l| l.strip_suffix("\";"))
                .unwrap_or_else(|| panic!("no filter for {text:?}"));
            assert_eq!(line, text);
            assert!(dump.contains("\tdisable-history: true;"));
        }
    }
}

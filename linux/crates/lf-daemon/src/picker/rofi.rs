//! rofi (tested against 2.0.0): edit and choose.
//!
//! - The edit box is prefilled through an inherited configuration file
//!   descriptor: `-config /dev/fd/3` reading a memfd that holds
//!   `configuration { filter: "…"; }`. That file replaces the user's rofi
//!   configuration (so their settings and theme are not loaded either) and
//!   `-no-plugins` keeps plugins out. A Rasi string unescapes `\"` and `\\`,
//!   a raw newline ends it, and a string runs to the last quote on its line,
//!   so every property gets its own line and control characters are
//!   refused.
//! - The suggestion dialog reads its rows from stdin (a pipe). rofi 2.0.0
//!   has no `mesg` configuration option, so the word is in the rows.
//!   `-no-custom` refuses typed text and `-format i` answers with the row
//!   number.
//! - `-disable-history` (also set in the configuration), so rofi keeps no
//!   history of what was typed in the box.
//! - Escape exits 1.

use super::{Dismissal, Failure, Invocation, Reply};

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

/// The suggestion dialog's configuration: no history.
const CHOOSE_CONFIG: &str = "configuration {\n  disable-history: true;\n}\n";

pub(super) fn edit(prefill: &str) -> Result<Invocation, Failure> {
    Ok(Invocation {
        args: vec![
            "-dmenu",
            "-disable-history",
            "-no-plugins",
            "-format",
            "f",
            "-p",
            "Correct",
            "-config",
            "/dev/fd/3",
        ],
        arg0: None,
        config: Some(edit_config(prefill).ok_or(Failure::Unsafe)?),
        stdin: None,
        dismissal: Dismissal::Exit(&[1]),
        reply: Reply::Index,
    })
}

pub(super) fn choose(rows: String) -> Invocation {
    Invocation {
        args: vec![
            "-dmenu",
            "-disable-history",
            "-no-plugins",
            "-no-custom",
            "-format",
            "i",
            "-p",
            "LocalFlow",
            "-config",
            "/dev/fd/3",
        ],
        arg0: None,
        config: Some(CHOOSE_CONFIG.into()),
        stdin: Some(rows),
        dismissal: Dismissal::Exit(&[1]),
        reply: Reply::Index,
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::{SECRET, args, fake, read};
    use super::super::{ADD, Answer, Kind, suggestion_rows};
    use super::*;
    use crate::testing::TempDir;
    use std::os::fd::AsRawFd;
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};

    #[test]
    fn edit_prefills_through_the_config_fd_only() {
        let dir = TempDir::new("rofi-edit");
        let r = fake(&dir, Kind::Rofi, "printf 'Synthetic edited\\n'");
        assert!(r.edit(SECRET).unwrap() == Answer::Chose("Synthetic edited".into()));
        assert_eq!(
            args(&dir),
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
        assert_eq!(read(&dir, "config"), edit_config(SECRET).unwrap());
        assert!(
            read(&dir, "config").contains(r#"filter: "Synthetic \"quoted\" \\ #text"#),
            "{}",
            read(&dir, "config")
        );
        // stdin is /dev/null.
        assert_eq!(read(&dir, "stdin"), "");
    }

    #[test]
    fn suggestion_rows_come_from_stdin() {
        let dir = TempDir::new("rofi-suggest");
        let r = fake(&dir, Kind::Rofi, "echo 0");
        assert!(r.suggest("Kubernetes").unwrap() == Answer::Chose(ADD));
        assert_eq!(
            args(&dir),
            [
                "-dmenu",
                "-disable-history",
                "-no-plugins",
                "-no-custom",
                "-format",
                "i",
                "-p",
                "LocalFlow",
                "-config",
                "/dev/fd/3"
            ]
        );
        assert_eq!(read(&dir, "stdin"), suggestion_rows("Kubernetes").unwrap());
        assert_eq!(read(&dir, "config"), CHOOSE_CONFIG);
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
            let memfd = super::super::config_fd(&edit_config(text).unwrap()).unwrap();
            let raw = memfd.as_raw_fd();
            let mut cmd = Command::new("rofi");
            cmd.args(["-config", "/dev/fd/3", "-dump-config"])
                .stdin(Stdio::null())
                .stderr(Stdio::null());
            // SAFETY: as in `Picker::run`.
            unsafe {
                cmd.pre_exec(move || {
                    if raw != 3 && libc::dup2(raw, 3) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                    if raw == 3 {
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

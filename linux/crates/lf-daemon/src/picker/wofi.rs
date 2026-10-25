//! wofi (tested against 1.5.3): edit and choose.
//!
//! - The prefill goes in a configuration file on fd 3 (`--conf=/dev/fd/3`,
//!   key `search`), which replaces the user's configuration. wofi's format
//!   is one `key=value` per line; a backslash makes the next character
//!   literal and an unescaped `#` starts a comment, so `\` and `#` are
//!   escaped. A raw newline would end the value, so control characters are
//!   refused, and leading spaces are dropped from a value, so text that
//!   starts with a space is refused too.
//! - The suggestion dialog reads its rows from stdin (a pipe).
//! - `dmenu-print_line_num=true` answers with the row number and turns
//!   wofi's dmenu cache off altogether; `cache_file=/dev/null` too.
//!   `no_custom_entry` refuses typed text, and the search box is hidden so
//!   that typing cannot leave Return on a row that is filtered out.
//!   Markup, images and search parsing stay off.
//! - wofi also reads [`SYSTEM_CONFIGS`] whatever it is given. Such a file
//!   could set `pre_display_cmd`, a shell command run on every row with
//!   the row's text, which a later file cannot unset; so wofi is not used
//!   when one exists ([`system_config`]).
//! - GTK's own plugins are kept out too ([`ENV`]): an input method can read
//!   the edit box's whole text (surrounding text), so wofi runs with GTK's
//!   built-in one; the accessibility bridge and `GTK_MODULES` /
//!   `GTK3_MODULES` are off; `XDG_CONFIG_HOME=/dev/null` keeps GTK's user
//!   settings (which can name modules) and wofi's own files out, so the
//!   user's wofi stylesheet does not apply either; and an unreachable
//!   session bus keeps out the modules and settings GTK otherwise reads
//!   over D-Bus (`org.gtk.Settings` from the settings daemon, the settings
//!   portal), and any input-method or accessibility service there.
//! - Escape exits 1.

use std::path::Path;

use super::{Dismissal, Failure, Invocation, Reply};

/// Read by wofi before the configuration it is given.
pub const SYSTEM_CONFIGS: [&str; 2] = ["/usr/etc/wofi/config", "/etc/wofi/config"];

/// Why wofi cannot be used here, if it cannot.
pub fn system_config() -> Option<&'static str> {
    refused_by(SYSTEM_CONFIGS.iter().map(Path::new))
}

fn refused_by<'a>(mut paths: impl Iterator<Item = &'a Path>) -> Option<&'static str> {
    paths.any(super::exists).then_some(
        "a system configuration (/etc/wofi/config or /usr/etc/wofi/config) exists; \
         wofi reads it whatever LocalFlow passes, and it could run a command on every row",
    )
}

/// `s` as a wofi configuration value, or `None` when it cannot be one
/// (control characters, or a leading space).
pub fn config_value(s: &str) -> Option<String> {
    if s.chars().any(crate::protocol::is_control) || s.starts_with(' ') {
        return None;
    }
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if matches!(c, '\\' | '#') {
            out.push('\\');
        }
        out.push(c);
    }
    Some(out)
}

/// Settings both dialogs share.
const COMMON: &str = "cache_file=/dev/null
dmenu-print_line_num=true
dmenu-parse_action=false
allow_markup=false
allow_images=false
parse_search=false
";

/// The edit dialog's configuration.
pub fn edit_config(prefill: &str) -> Option<String> {
    Some(format!(
        "{COMMON}prompt=Correct\nexec_search=true\nsearch={}\n",
        config_value(prefill)?
    ))
}

/// The suggestion dialog's configuration.
const CHOOSE_CONFIG: &str = "cache_file=/dev/null
dmenu-print_line_num=true
dmenu-parse_action=false
allow_markup=false
allow_images=false
parse_search=false
prompt=LocalFlow
no_custom_entry=true
hide_search=true
";

/// Environment changes for wofi: GTK's built-in input method, no
/// accessibility bridge, no GTK modules, no user configuration, and no
/// session bus.
pub const ENV: &[(&str, Option<&str>)] = &[
    ("GTK_IM_MODULE", Some("gtk-im-context-simple")),
    ("NO_AT_BRIDGE", Some("1")),
    ("GTK_MODULES", None),
    ("GTK3_MODULES", None),
    ("XDG_CONFIG_HOME", Some("/dev/null")),
    // GTK also reads modules (and other settings) from the session bus:
    // org.gtk.Settings, and the settings portal.
    ("DBUS_SESSION_BUS_ADDRESS", Some("unix:path=/dev/null")),
];

const ARGS: [&str; 3] = ["--dmenu", "--conf=/dev/fd/3", "--cache-file=/dev/null"];

pub(super) fn edit(prefill: &str) -> Result<Invocation, Failure> {
    Ok(Invocation {
        args: ARGS.to_vec(),
        arg0: None,
        env: ENV,
        config: Some(edit_config(prefill).ok_or(Failure::Unsafe)?),
        stdin: None,
        dismissal: Dismissal::Exit(&[1]),
        reply: Reply::Index,
    })
}

pub(super) fn choose(rows: String) -> Invocation {
    Invocation {
        args: ARGS.to_vec(),
        arg0: None,
        env: ENV,
        config: Some(CHOOSE_CONFIG.into()),
        stdin: Some(rows),
        dismissal: Dismissal::Exit(&[1]),
        reply: Reply::Index,
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::{SECRET, args, fake, read};
    use super::super::{ADD, Answer, Failure, Kind, suggestion_rows};
    use super::*;
    use crate::testing::TempDir;

    /// wofi 1.5.3's `config_put`, transcribed: what wofi reads back from a
    /// configuration line.
    fn wofi_reads(line: &str) -> Option<(String, String)> {
        let mut unescaped = String::new();
        let mut chars = line.chars();
        while let Some(c) = chars.next() {
            match c {
                '\\' => unescaped.extend(chars.next()),
                '#' => break,
                c => unescaped.push(c),
            }
        }
        let (key, value) = unescaped.split_once('=')?;
        let value = value.trim_start_matches(' ');
        let value = value.strip_suffix(['\n', ' ']).unwrap_or(value).to_owned();
        Some((key.trim_end_matches(' ').to_owned(), value))
    }

    #[test]
    fn edit_prefills_through_the_config_fd_only() {
        let dir = TempDir::new("wofi-edit");
        let w = fake(&dir, Kind::Wofi, "printf 'Synthetic edited\\n'");
        assert!(w.edit(SECRET).unwrap() == Answer::Chose("Synthetic edited".into()));
        assert_eq!(
            args(&dir),
            ["--dmenu", "--conf=/dev/fd/3", "--cache-file=/dev/null"]
        );
        let config = read(&dir, "config");
        assert_eq!(config, edit_config(SECRET).unwrap());
        let search = config.lines().find(|l| l.starts_with("search=")).unwrap();
        assert_eq!(
            wofi_reads(&format!("{search}\n")),
            Some(("search".into(), SECRET.into()))
        );
        for line in [
            "cache_file=/dev/null",
            "dmenu-print_line_num=true",
            "exec_search=true",
        ] {
            assert!(config.lines().any(|l| l == line), "{line}");
        }
        assert_eq!(read(&dir, "stdin"), "");
    }

    /// GTK's plugins (input methods, accessibility, modules) and user
    /// settings stay out of both dialogs.
    #[test]
    fn gtk_plugins_and_user_settings_are_kept_out() {
        let dir = TempDir::new("wofi-env");
        let w = fake(&dir, Kind::Wofi, "echo 0");
        for inv in [
            w.edit_invocation("x").unwrap(),
            w.choose_invocation("x\n".into()),
        ] {
            assert_eq!(inv.env, ENV);
        }
        w.suggest("Kubernetes").unwrap();
        let env = read(&dir, "env");
        for line in [
            "GTK_IM_MODULE=gtk-im-context-simple",
            "NO_AT_BRIDGE=1",
            "XDG_CONFIG_HOME=/dev/null",
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/dev/null",
        ] {
            assert!(env.lines().any(|l| l == line), "{line}");
        }
        assert!(
            !env.lines()
                .any(|l| l.starts_with("GTK_MODULES=") || l.starts_with("GTK3_MODULES="))
        );
        assert!(ENV.contains(&("GTK_MODULES", None)) && ENV.contains(&("GTK3_MODULES", None)));
    }

    #[test]
    fn suggestion_rows_come_from_stdin() {
        let dir = TempDir::new("wofi-suggest");
        let w = fake(&dir, Kind::Wofi, "echo 0");
        assert!(w.suggest("Kubernetes").unwrap() == Answer::Chose(ADD));
        assert_eq!(
            args(&dir),
            ["--dmenu", "--conf=/dev/fd/3", "--cache-file=/dev/null"]
        );
        assert_eq!(read(&dir, "config"), CHOOSE_CONFIG);
        assert!(CHOOSE_CONFIG.starts_with(COMMON));
        assert_eq!(read(&dir, "stdin"), suggestion_rows("Kubernetes").unwrap());
    }

    #[test]
    fn config_values_round_trip_or_are_refused() {
        for text in [
            "plain",
            SECRET,
            "a # comment\\# \\\\ = b",
            "trailing spaces  ",
            "\u{1f642} e\u{301}",
            "=",
            "",
        ] {
            let line = format!("search={}\n", config_value(text).unwrap());
            assert_eq!(
                wofi_reads(&line),
                Some(("search".into(), text.into())),
                "{text:?}"
            );
        }
        for text in [" leading", "a\nb", "a\rb", "\u{85}"] {
            assert_eq!(config_value(text), None, "{text:?}");
        }
        let dir = TempDir::new("wofi-unsafe");
        let w = fake(&dir, Kind::Wofi, "touch ran");
        assert_eq!(w.edit(" leading").unwrap_err(), Failure::Unsafe);
        assert!(!dir.path().join("ran").exists());
    }

    #[test]
    fn a_system_configuration_refuses_wofi() {
        let dir = TempDir::new("wofi-system");
        let (a, b) = (dir.path().join("a"), dir.path().join("b"));
        assert_eq!(refused_by([a.as_path(), b.as_path()].into_iter()), None);
        std::fs::write(&b, "").unwrap();
        assert!(refused_by([a.as_path(), b.as_path()].into_iter()).is_some());
        assert_eq!(SYSTEM_CONFIGS, ["/usr/etc/wofi/config", "/etc/wofi/config"]);
    }
}

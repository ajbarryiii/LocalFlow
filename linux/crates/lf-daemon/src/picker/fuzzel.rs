//! fuzzel (tested against 1.14.1): choose only.
//!
//! fuzzel prefills its box only from `--search=TEXT` on its command line
//! (its configuration file has no such key), so it cannot edit. For the
//! suggestion dialog:
//!
//! - Rows come from stdin (a pipe).
//! - `--config=/dev/null` replaces the user's configuration and its
//!   `include`s.
//! - `--cache=/dev/null`: in dmenu mode fuzzel caches the chosen entries
//!   only when a cache file is configured, and this one discards them.
//! - `--log-no-syslog` and `--log-level=none` keep it out of syslog.
//! - It answers with the row's text, not `--index`: outside a UTF-8 locale
//!   fuzzel drops the rows it cannot convert and numbers the rest from 0,
//!   so "Not now" would come back as 0 ("Add"). `--only-match` refuses
//!   typed text on Return (Shift+Return still prints it, which matches no
//!   row); `--no-sort` keeps the rows' order.
//! - Escape exits 2; closing without a choice (focus lost, or Return with
//!   nothing matching) exits 1.

use super::{Dismissal, Invocation, Reply};

pub(super) fn choose(rows: String) -> Invocation {
    Invocation {
        args: vec![
            "--dmenu",
            "--only-match",
            "--no-sort",
            "--config=/dev/null",
            "--cache=/dev/null",
            "--log-level=none",
            "--log-no-syslog",
            "--minimal-lines",
            "--prompt=LocalFlow: ",
        ],
        arg0: None,
        config: None,
        stdin: Some(rows),
        dismissal: Dismissal::Exit(&[1, 2]),
        reply: Reply::Row,
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::{args, fake, read};
    use super::super::{Answer, DONT_SUGGEST, Failure, Kind, suggestion_rows};
    use crate::testing::TempDir;

    #[test]
    fn suggestion_rows_come_from_stdin_with_no_cache_or_config() {
        let dir = TempDir::new("fuzzel-suggest");
        // Answers with the third row (the fake saved its stdin first).
        let third = format!("sed -n 3p '{}/stdin'", dir.path().display());
        let f = fake(&dir, Kind::Fuzzel, &third);
        assert!(f.suggest("Kubernetes").unwrap() == Answer::Chose(DONT_SUGGEST));
        assert_eq!(
            args(&dir),
            [
                "--dmenu",
                "--only-match",
                "--no-sort",
                "--config=/dev/null",
                "--cache=/dev/null",
                "--log-level=none",
                "--log-no-syslog",
                "--minimal-lines",
                "--prompt=LocalFlow: ",
            ]
        );
        assert_eq!(read(&dir, "stdin"), suggestion_rows("Kubernetes").unwrap());
        // No configuration descriptor is passed.
        assert_eq!(read(&dir, "config"), "");
    }

    /// Escape exits 2 and a close without a choice 1; a row number (what
    /// `--index` would print) or typed text is not an answer.
    #[test]
    fn dismissals_and_answers() {
        let dir = TempDir::new("fuzzel-exit");
        for code in [1, 2] {
            let f = fake(&dir, Kind::Fuzzel, &format!("exit {code}"));
            assert!(f.suggest("Kubernetes").unwrap() == Answer::Dismissed);
        }
        for out in ["0", "1", "-1", "zz"] {
            let f = fake(&dir, Kind::Fuzzel, &format!("echo '{out}'"));
            assert_eq!(f.suggest("Kubernetes").err(), Some(Failure::Output));
        }
        let f = fake(&dir, Kind::Fuzzel, "exit 3");
        assert_eq!(f.suggest("Kubernetes").err(), Some(Failure::Exit(Some(3))));
    }
}

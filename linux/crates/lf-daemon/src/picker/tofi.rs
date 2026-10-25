//! tofi (tested against 0.9.1): choose only.
//!
//! tofi has no way to prefill its input, so it cannot edit. For the
//! suggestion dialog:
//!
//! - Rows come from stdin (a pipe).
//! - `--config=/dev/null` replaces the user's configuration and its
//!   `include`s.
//! - In dmenu mode tofi keeps no history unless a history file is
//!   configured; `--history=false` is passed too.
//! - `--require-match=true` refuses typed text.
//! - It answers with the row's text, normalized to NFC, so rows are told
//!   apart by their fixed text.
//! - Escape exits 0 with no output; status 1 is an error.
//! - tofi picks its mode from `argv[0]` (a path containing `-run` would
//!   make it list programs), so it is started as `tofi`.

use super::{Dismissal, Invocation, Reply};

pub(super) fn choose(rows: String) -> Invocation {
    Invocation {
        args: vec![
            "--config=/dev/null",
            "--history=false",
            "--require-match=true",
            "--auto-accept-single=false",
            "--prompt-text=LocalFlow: ",
        ],
        arg0: Some("tofi"),
        config: None,
        stdin: Some(rows),
        dismissal: Dismissal::NoOutput,
        reply: Reply::Row,
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::{args, fake, read};
    use super::super::{Answer, Kind, NOT_NOW, suggestion_rows};
    use crate::testing::TempDir;

    #[test]
    fn suggestion_rows_come_from_stdin_with_no_history_or_config() {
        let dir = TempDir::new("tofi-suggest");
        let t = fake(&dir, Kind::Tofi, "echo 'Not now'");
        assert!(t.suggest("Kubernetes").unwrap() == Answer::Chose(NOT_NOW));
        assert_eq!(
            args(&dir),
            [
                "--config=/dev/null",
                "--history=false",
                "--require-match=true",
                "--auto-accept-single=false",
                "--prompt-text=LocalFlow: ",
            ]
        );
        // A script's `$0` is its path whatever argv[0] was, so look at the
        // invocation instead.
        assert_eq!(t.choose_invocation(String::new()).arg0, Some("tofi"));
        assert_eq!(read(&dir, "stdin"), suggestion_rows("Kubernetes").unwrap());
        assert_eq!(read(&dir, "config"), "");
    }
}

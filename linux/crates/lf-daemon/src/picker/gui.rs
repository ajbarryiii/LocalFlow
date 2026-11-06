//! localflow-gui (LocalFlow's own windows, `linux/gui`): edit and choose.
//!
//! - `localflow-gui edit` reads the text to correct from stdin (a pipe) and
//!   prints the edited text and a newline when it is accepted.
//! - `localflow-gui choose` reads the rows from stdin, one per line, and
//!   prints the chosen row's number.
//! - Escape or closing the window exits 1 with no output.
//! - It keeps no history or cache, reads no configuration of its own, and
//!   is built without the accessibility bridge.

use super::{Dismissal, Invocation, Reply};

pub(super) fn edit(prefill: &str) -> Invocation {
    Invocation {
        args: vec!["edit"],
        arg0: None,
        env: &[],
        config: None,
        stdin: Some(prefill.to_owned()),
        dismissal: Dismissal::Exit(&[1]),
        reply: Reply::Index,
    }
}

pub(super) fn choose(rows: String) -> Invocation {
    Invocation {
        args: vec!["choose"],
        arg0: None,
        env: &[],
        config: None,
        stdin: Some(rows),
        dismissal: Dismissal::Exit(&[1]),
        reply: Reply::Index,
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::{SECRET, args, fake, read};
    use super::super::{Answer, DONT_SUGGEST, Failure, Kind, suggestion_rows};
    use crate::testing::TempDir;

    #[test]
    fn edit_passes_the_text_on_stdin_and_reads_the_edit_back() {
        let dir = TempDir::new("gui-edit");
        let f = fake(&dir, Kind::Gui, "printf 'Synthetic corrected text\\n'");
        assert!(f.edit(SECRET).unwrap() == Answer::Chose("Synthetic corrected text".into()));
        assert_eq!(args(&dir), ["edit"]);
        assert_eq!(read(&dir, "stdin"), SECRET);
        assert_eq!(read(&dir, "config"), "");
    }

    #[test]
    fn choose_passes_rows_on_stdin_and_answers_with_the_row_number() {
        let dir = TempDir::new("gui-choose");
        let f = fake(&dir, Kind::Gui, "echo 2");
        assert!(f.suggest("Kubernetes").unwrap() == Answer::Chose(DONT_SUGGEST));
        assert_eq!(args(&dir), ["choose"]);
        assert_eq!(read(&dir, "stdin"), suggestion_rows("Kubernetes").unwrap());
    }

    #[test]
    fn escape_is_a_dismissal_and_other_statuses_are_errors() {
        let dir = TempDir::new("gui-exit");
        let f = fake(&dir, Kind::Gui, "exit 1");
        assert!(f.edit("x").unwrap() == Answer::Dismissed);
        assert!(f.suggest("Kubernetes").unwrap() == Answer::Dismissed);
        let f = fake(&dir, Kind::Gui, "echo 0; exit 2");
        assert_eq!(f.suggest("Kubernetes").err(), Some(Failure::Exit(Some(2))));
    }
}

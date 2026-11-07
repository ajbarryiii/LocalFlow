//! The two dialogs `localflowctl` opens through the `gui` picker:
//!
//! - **Edit** (`localflow-gui edit`): the last dictation in a text box.
//!   Enter accepts and prints the text; Shift+Enter is refused (a
//!   dictation is one line).
//! - **Choose** (`localflow-gui choose`): one button per row, the first
//!   highlighted. Pressing one prints its number; so do Enter or Space on
//!   the highlighted row (Up, Down and Tab move it) and the digits 1-9. The
//!   buttons never take keyboard focus, so the keys always act on the
//!   highlight the window shows.
//!
//! Escape, or closing the window, dismisses: exit status 1, no output.
//! Nothing is written anywhere but stdout.

use std::sync::Mutex;

use rune::tok::space;
use rune::{Cx, El, Key, KeyEvent, TextEdit, Tx, col, icon, row};
use rune_kit::{Button, ButtonVariant, Kit, TextArea};

/// The answer for `main` to print once the window has closed.
pub static ANSWER: Mutex<Option<Outcome>> = Mutex::new(None);

/// Records `outcome` in the state and for `main`, and quits.
fn finish(slot: &mut Option<Outcome>, outcome: Outcome, tx: &mut Tx) {
    *ANSWER.lock().unwrap() = Some(outcome.clone());
    *slot = Some(outcome);
    tx.quit();
}

/// What the user did, once they did it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    Accepted(String),
    Chose(usize),
    Dismissed,
}

pub struct Edit {
    pub edit: TextEdit,
    pub outcome: Option<Outcome>,
}

impl Edit {
    pub fn new(prefill: &str) -> Edit {
        let mut edit = TextEdit::new(prefill);
        edit.focused = true;
        // Selected, so typing replaces it.
        edit.set_selection(0, prefill.len());
        Edit {
            edit,
            outcome: None,
        }
    }

    fn accept(&mut self, tx: &mut Tx) {
        // A paste may carry line breaks; a dictation is one line.
        let one_line: String = self
            .edit
            .text
            .split(['\n', '\r'])
            .filter(|l| !l.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        finish(&mut self.outcome, Outcome::Accepted(one_line), tx);
    }
}

pub fn edit_view(s: &Edit, cx: &mut Cx<Edit>) -> El {
    let k = Kit::neutral(cx.system_dark());
    let field = TextArea::new(&s.edit)
        .label("Correction")
        .width(None)
        .auto_grow(2, 8)
        .on_edit(|s: &mut Edit| &mut s.edit)
        .on_key(|s: &mut Edit, e: &KeyEvent, tx: &mut Tx| match e.key {
            Key::Enter if !e.mods.shift => {
                s.accept(tx);
                true
            }
            // Shift+Enter would start a second line.
            Key::Enter => true,
            Key::Escape => {
                dismiss(&mut s.outcome, tx);
                true
            }
            _ => false,
        })
        .build(&k);
    let buttons = row()
        .key("buttons")
        .gap(space::S2)
        .justify_end()
        .child(
            Button::new("Cancel")
                .variant(ButtonVariant::Ghost)
                .on_press_tx(|s: &mut Edit, tx| dismiss(&mut s.outcome, tx))
                .build(&k)
                .key("cancel"),
        )
        .child(
            Button::new("Correct")
                .variant(ButtonVariant::Contrast)
                .shortcut("Enter")
                .on_press_tx(|s: &mut Edit, tx| s.accept(tx))
                .build(&k)
                .key("correct"),
        );
    col()
        .key("edit-window")
        .w_full()
        .h_full()
        .padding(16.0)
        .gap(space::S3)
        .fill(k.c.bg_base)
        .child(field)
        .child(buttons)
}

pub struct Choose {
    pub rows: Vec<String>,
    /// The highlighted row, which Enter chooses.
    pub selected: usize,
    pub outcome: Option<Outcome>,
}

impl Choose {
    pub fn new(rows: Vec<String>) -> Choose {
        Choose {
            rows,
            selected: 0,
            outcome: None,
        }
    }
}

pub fn choose_view(s: &Choose, cx: &mut Cx<Choose>) -> El {
    let k = Kit::neutral(cx.system_dark());
    let mut list = col().key("rows").gap(space::S2).w_full();
    for (i, label) in s.rows.iter().enumerate() {
        let variant = if i == s.selected {
            ButtonVariant::Contrast
        } else {
            ButtonVariant::Neutral
        };
        list = list.child(
            row().key(format!("row-{i}")).w_full().child(
                Button::new(label.clone())
                    .variant(variant)
                    .on_press_tx(move |s: &mut Choose, tx| {
                        finish(&mut s.outcome, Outcome::Chose(i), tx)
                    })
                    .build(&k)
                    .key(format!("choice-{i}"))
                    // The keyboard drives the highlight only (a focused
                    // button would take Enter and Space for itself).
                    .focusable(false)
                    .grow(1.0),
            ),
        );
    }
    col()
        .key("choose-window")
        .w_full()
        .h_full()
        .padding(16.0)
        .gap(space::S3)
        .justify_center()
        .items_center()
        .fill(k.c.bg_base)
        .child(
            icon(&rune_kit::glyphs::MIC, 18.0)
                .key("mark")
                .color(k.c.text_weak),
        )
        .child(list)
}

/// The edit window's height for `text`: about 64 characters a line at
/// 560 pt, 2 to 8 lines, the buttons under them.
pub fn edit_height(text: &str) -> f32 {
    let lines = text.chars().count().div_ceil(64).clamp(2, 8);
    16.0 * 2.0 + 16.0 + lines as f32 * 20.0 + space::S3 + 32.0
}

/// The choose window's height for `rows` buttons: padding, the mark, and
/// a 32 pt button with an 8 pt gap per row.
pub fn choose_height(rows: usize) -> f32 {
    16.0 * 2.0 + 18.0 + space::S3 + rows as f32 * 32.0 + rows.saturating_sub(1) as f32 * space::S2
}

/// The choose dialog's keys: Escape dismisses; Up, Down and Tab move the
/// highlight; Enter or Space choose the highlighted row; 1-9 choose that
/// row.
pub fn choose_key(s: &mut Choose, e: &KeyEvent, tx: &mut Tx) -> bool {
    let n = s.rows.len();
    if n == 0 {
        return false;
    }
    match &e.key {
        Key::Escape => dismiss(&mut s.outcome, tx),
        Key::Down => s.selected = (s.selected + 1).min(n - 1),
        Key::Up => s.selected = s.selected.saturating_sub(1),
        Key::Tab if e.mods.shift => s.selected = (s.selected + n - 1) % n,
        Key::Tab => s.selected = (s.selected + 1) % n,
        Key::Enter => finish(&mut s.outcome, Outcome::Chose(s.selected), tx),
        Key::Text(t) if t == " " => finish(&mut s.outcome, Outcome::Chose(s.selected), tx),
        Key::Text(t) => match t.parse::<usize>() {
            Ok(d) if (1..=n.min(9)).contains(&d) => {
                finish(&mut s.outcome, Outcome::Chose(d - 1), tx)
            }
            _ => return false,
        },
        _ => return false,
    }
    true
}

pub fn edit_key(s: &mut Edit, e: &KeyEvent, tx: &mut Tx) -> bool {
    if e.key == Key::Escape {
        dismiss(&mut s.outcome, tx);
        return true;
    }
    false
}

fn dismiss(outcome: &mut Option<Outcome>, tx: &mut Tx) {
    finish(outcome, Outcome::Dismissed, tx);
}

/// The rows `choose` reads from stdin: one per line, empty lines dropped.
pub fn parse_rows(input: &str) -> Vec<String> {
    input
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(String::from)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use rune::{Env, Mods, Runtime};

    fn choose_window() -> Runtime<Choose> {
        let rows = parse_rows("Add \u{201C}Zorblax\u{201D}\nNot now\nDon\u{2019}t suggest\n");
        let mut rt = Runtime::new(
            Choose::new(rows),
            choose_view,
            (420.0, 220.0),
            Env::new(true, 1.0),
        );
        rt.on_key = Some(choose_key);
        rt.frame(0.0);
        rt
    }

    fn type_key(rt: &mut Runtime<Choose>, k: Key) {
        rt.key(KeyEvent {
            key: k,
            mods: Mods::default(),
        });
        rt.frame(1.0 / 60.0);
    }

    #[test]
    fn the_keyboard_moves_the_highlight_and_chooses() {
        let mut rt = choose_window();
        type_key(&mut rt, Key::Down);
        type_key(&mut rt, Key::Down);
        type_key(&mut rt, Key::Down);
        assert_eq!(rt.state.selected, 2, "Down stops at the last row");
        type_key(&mut rt, Key::Up);
        type_key(&mut rt, Key::Enter);
        assert_eq!(rt.state.outcome, Some(Outcome::Chose(1)));

        let mut rt = choose_window();
        type_key(&mut rt, Key::Tab);
        type_key(&mut rt, Key::Text(" ".into()));
        assert_eq!(rt.state.outcome, Some(Outcome::Chose(1)));

        let mut rt = choose_window();
        type_key(&mut rt, Key::Text("3".into()));
        assert_eq!(rt.state.outcome, Some(Outcome::Chose(2)));

        // A click cancelled by dragging off the button leaves nothing
        // focused: the keys still act on the highlight.
        let mut rt = choose_window();
        let (x, y) = rt.find("choice-2").unwrap();
        rt.pointer_down(x, y);
        rt.pointer_move(x, y + 400.0);
        rt.pointer_up(x, y + 400.0);
        rt.frame(1.0 / 60.0);
        assert_eq!(rt.state.outcome, None, "the cancelled click chose nothing");
        type_key(&mut rt, Key::Down);
        type_key(&mut rt, Key::Enter);
        assert_eq!(rt.state.outcome, Some(Outcome::Chose(1)));
        let mut rt = choose_window();
        let (x, y) = rt.find("choice-2").unwrap();
        rt.pointer_down(x, y);
        rt.pointer_move(x, y + 400.0);
        rt.pointer_up(x, y + 400.0);
        rt.frame(1.0 / 60.0);
        type_key(&mut rt, Key::Text(" ".into()));
        assert_eq!(rt.state.outcome, Some(Outcome::Chose(0)));

        // A digit past the rows does nothing.
        let mut rt = choose_window();
        type_key(&mut rt, Key::Text("4".into()));
        assert_eq!(rt.state.outcome, None);
        type_key(&mut rt, Key::Escape);
        assert_eq!(rt.state.outcome, Some(Outcome::Dismissed));
    }

    fn press<S: 'static>(rt: &mut Runtime<S>, key: &str) {
        let (x, y) = rt.find(key).unwrap_or_else(|| panic!("no {key:?}"));
        rt.pointer_down(x, y);
        rt.pointer_up(x, y);
        rt.frame(1.0 / 60.0);
    }

    fn key(key: Key, shift: bool) -> KeyEvent {
        KeyEvent {
            key,
            mods: Mods {
                shift,
                ..Mods::default()
            },
        }
    }

    #[test]
    fn enter_accepts_the_edited_text_on_one_line() {
        let mut rt = Runtime::new(
            Edit::new("synthetic dictation"),
            edit_view,
            (520.0, 200.0),
            Env::new(true, 1.0),
        );
        rt.frame(0.0);
        // The whole text is selected, so typing replaces it.
        rt.key(key(Key::Text("synthetic fix".into()), false));
        rt.frame(1.0 / 60.0);
        rt.key(key(Key::Enter, true));
        rt.frame(1.0 / 60.0);
        assert_eq!(
            rt.state.outcome, None,
            "Shift+Enter adds no line and does not accept"
        );
        rt.key(key(Key::Enter, false));
        rt.frame(1.0 / 60.0);
        assert_eq!(
            rt.state.outcome,
            Some(Outcome::Accepted("synthetic fix".into()))
        );
    }

    #[test]
    fn pasted_line_breaks_become_spaces() {
        let mut s = Edit::new("");
        s.edit.text = "synthetic\nfirst\r\n\nsecond".into();
        let mut rt = Runtime::new(s, edit_view, (520.0, 200.0), Env::new(true, 1.0));
        rt.frame(0.0);
        press(&mut rt, "correct");
        assert_eq!(
            rt.state.outcome,
            Some(Outcome::Accepted("synthetic first second".into()))
        );
    }

    #[test]
    fn escape_and_cancel_dismiss() {
        let mut rt = Runtime::new(
            Edit::new("synthetic"),
            edit_view,
            (520.0, 200.0),
            Env::new(true, 1.0),
        );
        rt.frame(0.0);
        rt.key(key(Key::Escape, false));
        rt.frame(1.0 / 60.0);
        assert_eq!(rt.state.outcome, Some(Outcome::Dismissed));

        let mut rt = Runtime::new(
            Edit::new("synthetic"),
            edit_view,
            (520.0, 200.0),
            Env::new(true, 1.0),
        );
        rt.frame(0.0);
        press(&mut rt, "cancel");
        assert_eq!(rt.state.outcome, Some(Outcome::Dismissed));
    }

    #[test]
    fn choosing_a_row_answers_with_its_number() {
        let rows = parse_rows("Add \u{201C}Zorblax\u{201D}\nNot now\n\nDon\u{2019}t suggest\n");
        assert_eq!(rows.len(), 3);
        for i in 0..rows.len() {
            let s = Choose::new(rows.clone());
            let mut rt = Runtime::new(s, choose_view, (420.0, 220.0), Env::new(true, 1.0));
            rt.frame(0.0);
            press(&mut rt, &format!("choice-{i}"));
            assert_eq!(rt.state.outcome, Some(Outcome::Chose(i)));
        }
    }
}

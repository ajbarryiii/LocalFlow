//! Characters to key presses through an XKB layout.
//!
//! Unlike the Wayland virtual keyboard, which uploads its own keymap,
//! backends that send plain key codes (libei, uinput) type with whatever
//! layout the desktop applies to them. [`Layout`] finds, for every
//! character, a key and the modifier keys to hold so that layout produces
//! exactly that character, by simulating the presses with libxkbcommon.
//!
//! Only ordinary printable keys are used (the same allowlist as the virtual
//! keyboard, plus Space, Tab and Return), with Shift, AltGr (level 3) and
//! level 5 as modifiers. Dead keys and Compose sequences are not used, so a
//! character the layout reaches only through them (é on a US layout) cannot
//! be typed, and the text is refused rather than typed differently.

use std::collections::HashMap;

use lf_io_api::IoError;
use xkbcommon::xkb;

/// Linux evdev code of Tab.
pub const KEY_TAB: u32 = 15;
/// Linux evdev code of Return.
pub const KEY_ENTER: u32 = 28;
/// Linux evdev code of left Shift.
pub const KEY_LEFTSHIFT: u32 = 42;
/// Linux evdev code of right Shift.
pub const KEY_RIGHTSHIFT: u32 = 54;
/// Linux evdev code of the Space bar.
pub const KEY_SPACE: u32 = 57;
/// Linux evdev code of right Alt (AltGr on most layouts).
pub const KEY_RIGHTALT: u32 = 100;

/// Highest evdev code looked at (XKB keycode 255, the X11 limit).
pub const MAX_EVDEV_CODE: u32 = 247;

/// Evdev codes that may type characters: the US number, top, home and
/// bottom rows, Space, and the ISO/JIS extra keys (`IntlBackslash`, `IntlRo`,
/// `IntlYen`). Keypad, function, media and other special keys are never
/// used: applications and compositors act on them by key code.
const CHAR_CODES: &[(u32, u32)] = &[
    (2, 13),
    (16, 27),
    (30, 41),
    (43, 53),
    (57, 57),
    (86, 86),
    (89, 89),
    (124, 124),
];

/// Evdev codes characters may be typed with, in preference order.
pub fn char_codes() -> Vec<u32> {
    CHAR_CODES.iter().flat_map(|&(lo, hi)| lo..=hi).collect()
}

/// One thing to type.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Token {
    /// Return (from `\n`, `\r\n` or `\r`, and for pressing Enter).
    Return,
    /// Tab (from `\t`).
    Tab,
    /// Any other character, the space included.
    Char(char),
}

/// A character that is a control character other than `\n`, `\r` or `\t`.
/// Carries only its position, never the text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ControlChar {
    /// Index of the character (in chars, not bytes).
    pub index: usize,
}

/// Splits text into tokens. Newlines (`\n`, `\r\n`, lone `\r`) become
/// Return and `\t` Tab; other control characters (Unicode category Cc) are
/// rejected. Matches the virtual keyboard's rules.
pub fn tokenize(text: &str) -> Result<Vec<Token>, ControlChar> {
    let mut tokens = Vec::with_capacity(text.len());
    let mut chars = text.chars().enumerate().peekable();
    while let Some((index, c)) = chars.next() {
        tokens.push(match c {
            '\n' => Token::Return,
            '\r' => {
                if matches!(chars.peek(), Some((_, '\n'))) {
                    chars.next();
                }
                Token::Return
            }
            '\t' => Token::Tab,
            c if c.is_control() => return Err(ControlChar { index }),
            c => Token::Char(c),
        });
    }
    Ok(tokens)
}

/// How to type one token: hold `mods` (in this order), tap `code`, release
/// `mods` (in reverse).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Stroke {
    /// Evdev codes of the modifier keys to hold.
    pub mods: Vec<u32>,
    /// Evdev code of the key to tap.
    pub code: u32,
}

/// RMLVO names of an XKB layout. Empty fields (and `options: None`) take
/// libxkbcommon's defaults: the `XKB_DEFAULT_RULES`, `_MODEL`, `_LAYOUT`,
/// `_VARIANT` and `_OPTIONS` environment variables, else the system
/// defaults (normally `evdev`, `pc105`, `us`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Rmlvo {
    pub rules: String,
    pub model: String,
    pub layout: String,
    pub variant: String,
    pub options: Option<String>,
}

/// The keys that type each character with one XKB layout and state.
#[derive(Clone, Debug)]
pub struct Layout {
    strokes: HashMap<Token, Stroke>,
    modifiers: Vec<u32>,
}

fn context(flags: xkb::ContextFlags) -> xkb::Context {
    let mut ctx = xkb::Context::new(flags);
    // libxkbcommon writes its diagnostics straight to stderr, which could
    // block the daemon on a stalled journal; keep it quiet.
    ctx.set_log_level(xkb::LogLevel::Critical);
    ctx
}

fn no_nul(s: &str) -> bool {
    !s.contains('\0')
}

impl Layout {
    /// Compiles the layout named by `names` (see [`Rmlvo`]) and uses its
    /// first group with no modifiers locked. The error names no layout.
    pub fn from_names(names: &Rmlvo) -> Result<Layout, IoError> {
        let fields = [&names.rules, &names.model, &names.layout, &names.variant];
        if !fields.iter().all(|s| no_nul(s)) || !names.options.as_deref().is_none_or(no_nul) {
            return Err(IoError("invalid keyboard layout name".into()));
        }
        let ctx = context(xkb::CONTEXT_NO_FLAGS);
        let keymap = xkb::Keymap::new_from_names(
            &ctx,
            &names.rules,
            &names.model,
            &names.layout,
            &names.variant,
            names.options.clone(),
            xkb::KEYMAP_COMPILE_NO_FLAGS,
        )
        .ok_or_else(|| IoError("cannot compile the keyboard layout".into()))?;
        Ok(Layout::build(&keymap, 0, 0))
    }

    /// Compiles a complete XKB keymap in text format v1 (as a compositor
    /// sends it; no include files are read) and uses group `group` with the
    /// modifiers in `locked_mods` locked (Caps Lock, say).
    pub fn from_keymap_text(text: &str, group: u32, locked_mods: u32) -> Result<Layout, IoError> {
        let ctx = context(xkb::CONTEXT_NO_DEFAULT_INCLUDES | xkb::CONTEXT_NO_ENVIRONMENT_NAMES);
        let keymap = xkb::Keymap::new_from_string(
            &ctx,
            text.to_owned(),
            xkb::KEYMAP_FORMAT_TEXT_V1,
            xkb::KEYMAP_COMPILE_NO_FLAGS,
        )
        .ok_or_else(|| IoError("cannot compile the desktop's keymap".into()))?;
        Ok(Layout::build(&keymap, group, locked_mods))
    }

    fn build(keymap: &xkb::Keymap, group: u32, locked_mods: u32) -> Layout {
        let base = || {
            let mut s = xkb::State::new(keymap);
            s.update_mask(0, 0, locked_mods, 0, 0, group);
            s
        };
        let key = |code: u32| xkb::Keycode::new(code + 8);
        let idle = base();
        let find = |sym: u32, preferred: &[u32]| -> Option<u32> {
            let is = |code: u32| idle.key_get_one_sym(key(code)).raw() == sym;
            preferred
                .iter()
                .copied()
                .find(|&c| is(c))
                .or_else(|| (1..=MAX_EVDEV_CODE).find(|&c| is(c)))
        };
        let shift = find(xkb::keysyms::KEY_Shift_L, &[KEY_LEFTSHIFT])
            .or_else(|| find(xkb::keysyms::KEY_Shift_R, &[KEY_RIGHTSHIFT]));
        let level3 = find(xkb::keysyms::KEY_ISO_Level3_Shift, &[KEY_RIGHTALT]);
        let level5 = find(xkb::keysyms::KEY_ISO_Level5_Shift, &[]);
        let modifiers: Vec<u32> = [shift, level3, level5].into_iter().flatten().collect();

        // Every subset of the modifiers, fewest first.
        let mut combos: Vec<Vec<u32>> = (0u32..1 << modifiers.len())
            .map(|bits| {
                modifiers
                    .iter()
                    .enumerate()
                    .filter(|(i, _)| bits & (1 << i) != 0)
                    .map(|(_, &m)| m)
                    .collect()
            })
            .collect();
        combos.sort_by_key(Vec::len);

        let mut codes = char_codes();
        codes.extend([KEY_TAB, KEY_ENTER]);
        codes.retain(|c| !modifiers.contains(c));

        let mut strokes = HashMap::new();
        for combo in combos {
            let mut state = base();
            for &m in &combo {
                state.update_key(key(m), xkb::KeyDirection::Down);
            }
            for &code in &codes {
                let sym = state.key_get_one_sym(key(code)).raw();
                let token = match sym {
                    xkb::keysyms::KEY_Return => Token::Return,
                    xkb::keysyms::KEY_Tab => Token::Tab,
                    _ => match char::from_u32(state.key_get_utf32(key(code))) {
                        Some(c) if c != '\0' && !c.is_control() => Token::Char(c),
                        _ => continue,
                    },
                };
                strokes.entry(token).or_insert_with(|| Stroke {
                    mods: combo.clone(),
                    code,
                });
            }
        }
        Layout { strokes, modifiers }
    }

    /// How to type `token`, if the layout can.
    pub fn stroke(&self, token: Token) -> Option<&Stroke> {
        self.strokes.get(&token)
    }

    /// The strokes for all of `text`, or an error naming the position of
    /// the first character that cannot be typed (never the character).
    pub fn strokes(&self, text: &str) -> Result<Vec<Stroke>, IoError> {
        let tokens = tokenize(text).map_err(|e| {
            IoError(format!(
                "cannot type control character at position {} (only \\n, \\r and \\t are supported)",
                e.index
            ))
        })?;
        let mut index = 0;
        let mut out = Vec::with_capacity(tokens.len());
        let mut chars = text.chars().peekable();
        for token in tokens {
            let stroke = self.stroke(token).ok_or_else(|| {
                IoError(format!(
                    "cannot type the character at position {index}: the keyboard layout has no key for it"
                ))
            })?;
            out.push(stroke.clone());
            // Advance the character position past this token (`\r\n` is one).
            let c = chars.next();
            index += 1;
            if c == Some('\r') && chars.peek() == Some(&'\n') {
                chars.next();
                index += 1;
            }
        }
        Ok(out)
    }

    /// Every evdev code the strokes of this layout may press.
    pub fn key_codes(&self) -> Vec<u32> {
        let mut codes: Vec<u32> = self
            .strokes
            .values()
            .map(|s| s.code)
            .chain(self.modifiers.iter().copied())
            .collect();
        codes.sort_unstable();
        codes.dedup();
        codes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokenize_matches_the_virtual_keyboard() {
        use Token::*;
        assert_eq!(
            tokenize("a\nb\r\nc\rd\te f").unwrap(),
            vec![
                Char('a'),
                Return,
                Char('b'),
                Return,
                Char('c'),
                Return,
                Char('d'),
                Tab,
                Char('e'),
                Char(' '),
                Char('f')
            ]
        );
        assert_eq!(tokenize("\r\r\n").unwrap(), vec![Return, Return]);
        assert_eq!(tokenize("ab\u{7}c"), Err(ControlChar { index: 2 }));
        assert_eq!(tokenize("x\u{85}"), Err(ControlChar { index: 1 }));
    }

    #[test]
    fn char_codes_are_printable_keys_only() {
        let codes = char_codes();
        assert_eq!(codes.len(), 51);
        for special in [
            1, 14, 15, 28, 29, 42, 54, 55, 56, 58, 59, 69, 71, 96, 98, 100, 125,
        ] {
            assert!(!codes.contains(&special), "{special}");
        }
    }
}

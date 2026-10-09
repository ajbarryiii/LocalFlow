//! Keymap planning for the virtual keyboard.
//!
//! The virtual keyboard uploads its own XKB keymap, so typed text does not
//! depend on the user's layout (Dvorak, AZERTY, ...). Every character becomes
//! a key whose single keysym is the character's Unicode keysym (`U20AC`), and
//! the text is typed by pressing those keys with no modifiers.
//!
//! A keymap has a limited number of keycodes. Text with more distinct
//! characters than that is split into consecutive batches, each with its own
//! keymap.

use std::collections::HashSet;
use std::fmt::Write as _;

/// One key press the virtual keyboard can produce.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Sym {
    /// Return (from `\n`, `\r\n` or `\r`, and for `press_enter`).
    Return,
    /// Tab (from `\t`).
    Tab,
    /// The space bar (from `' '`).
    Space,
    /// Any other printable character, typed through its Unicode keysym.
    Char(char),
}

/// Linux evdev code of Tab. Tab, Return and Space keep their usual keys, so
/// applications that look at the physical key (`event.code`) see the
/// expected key. They are in every keymap.
pub const KEY_TAB: u32 = 15;
/// Linux evdev code of Return.
pub const KEY_ENTER: u32 = 28;
/// Linux evdev code of Space, used only for `' '`.
pub const KEY_SPACE: u32 = 57;

/// Highest evdev code ever used. XKB keycode 255 (evdev + 8) is the X11
/// limit, so XWayland clients can receive every key.
pub const MAX_EVDEV_CODE: u32 = 247;

/// Evdev codes that carry characters: only ordinary printable keys of a
/// physical keyboard (the US number, top, home and bottom rows, plus the
/// ISO/JIS extra keys `IntlBackslash`, `IntlRo` and `IntlYen`).
///
/// This is an allowlist on purpose. Chromium and Electron drop key events
/// whose evdev code has no DOM `code` mapping (and alias some media codes).
/// Compositors (Hyprland `code:` binds), input methods and applications act
/// on special keys (Esc, modifiers, F-keys, navigation, keypad, IME toggles,
/// media and power keys) by keycode, whatever keysym the keymap gives them.
const CHAR_CODES: &[(u32, u32)] = &[
    (2, 13),    // 1 2 3 4 5 6 7 8 9 0 - =
    (16, 27),   // q w e r t y u i o p [ ]
    (30, 41),   // a s d f g h j k l ; ' `
    (43, 53),   // \ z x c v b n m , . /
    (86, 86),   // IntlBackslash (ISO 102nd key)
    (89, 89),   // IntlRo (JIS)
    (124, 124), // IntlYen (JIS)
];

/// Evdev codes available for characters, in assignment order.
pub fn char_pool() -> Vec<u32> {
    CHAR_CODES.iter().flat_map(|&(lo, hi)| lo..=hi).collect()
}

/// A character that cannot be typed. Carries only its position, never the
/// text itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UnsupportedChar {
    /// Index of the character (in chars, not bytes) within the text.
    pub index: usize,
}

/// Converts text to key presses. Newlines (`\n`, `\r\n`, lone `\r`) become
/// Return, `\t` becomes Tab and `' '` the space bar. Other control
/// characters (Unicode category Cc: C0, DEL and C1) have no keysym and are
/// rejected, so nothing is typed.
pub fn tokenize(text: &str) -> Result<Vec<Sym>, UnsupportedChar> {
    let mut syms = Vec::with_capacity(text.len());
    let mut chars = text.chars().enumerate().peekable();
    while let Some((index, c)) = chars.next() {
        let sym = match c {
            '\n' => Sym::Return,
            '\r' => {
                if matches!(chars.peek(), Some((_, '\n'))) {
                    chars.next();
                }
                Sym::Return
            }
            '\t' => Sym::Tab,
            ' ' => Sym::Space,
            c if c.is_control() => return Err(UnsupportedChar { index }),
            c => Sym::Char(c),
        };
        syms.push(sym);
    }
    Ok(syms)
}

/// A run of consecutive key presses typed with one keymap.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Batch {
    /// Index range into the token list.
    pub start: usize,
    pub end: usize,
    /// The keymap for this batch.
    pub keymap: Keymap,
}

/// Splits key presses into consecutive batches whose distinct characters
/// fit into `pool` each. Return, Tab and Space are always present and do
/// not count. Batches are maximal: a new one starts only when the next
/// character would not fit.
pub fn plan(syms: &[Sym], pool: &[u32]) -> Vec<Batch> {
    assert!(!pool.is_empty(), "empty keycode pool");
    let mut batches = Vec::new();
    let mut start = 0;
    let mut chars: Vec<char> = Vec::new();
    let mut seen: HashSet<char> = HashSet::new();
    for (i, sym) in syms.iter().enumerate() {
        if let Sym::Char(c) = *sym
            && !seen.contains(&c)
        {
            if chars.len() == pool.len() {
                batches.push(Batch {
                    start,
                    end: i,
                    keymap: Keymap::new(&chars, pool),
                });
                start = i;
                chars.clear();
                seen.clear();
            }
            seen.insert(c);
            chars.push(c);
        }
    }
    if start < syms.len() {
        batches.push(Batch {
            start,
            end: syms.len(),
            keymap: Keymap::new(&chars, pool),
        });
    }
    batches
}

/// A keymap: Return, Tab and Space on their usual keys plus up to
/// `pool.len()` characters, each on its own key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Keymap {
    /// (evdev code, character), in pool order.
    keys: Vec<(u32, char)>,
}

impl Keymap {
    /// The keymap with only Return, Tab and Space.
    pub fn base() -> Self {
        Self { keys: Vec::new() }
    }

    /// Panics if `chars` has duplicates, contains `' '` or a control
    /// character, or has more entries than `pool`.
    pub fn new(chars: &[char], pool: &[u32]) -> Self {
        assert!(chars.len() <= pool.len(), "too many characters for keymap");
        assert!(
            chars.iter().all(|&c| c != ' ' && !c.is_control()),
            "space and control characters have fixed keys or none"
        );
        let keys: Vec<(u32, char)> = pool.iter().copied().zip(chars.iter().copied()).collect();
        let distinct: HashSet<char> = chars.iter().copied().collect();
        assert_eq!(distinct.len(), chars.len(), "duplicate characters");
        Self { keys }
    }

    /// Evdev code that types `sym`, if this keymap has it.
    pub fn code(&self, sym: Sym) -> Option<u32> {
        match sym {
            Sym::Return => Some(KEY_ENTER),
            Sym::Tab => Some(KEY_TAB),
            Sym::Space => Some(KEY_SPACE),
            Sym::Char(c) => self
                .keys
                .iter()
                .find_map(|&(code, k)| (k == c).then_some(code)),
        }
    }

    /// True if every key press in `syms` has a key in this keymap.
    pub fn covers(&self, syms: &[Sym]) -> bool {
        syms.iter().all(|&s| self.code(s).is_some())
    }

    /// Number of character keys (not counting Return, Tab and Space).
    pub fn len(&self) -> usize {
        self.keys.len()
    }

    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }

    /// The keymap in XKB text format v1, without a trailing NUL.
    ///
    /// Types and compatibility come from the compositor's `complete` set,
    /// as in `wtype`; XWayland needs the canonical key types. Every key has
    /// one level, so modifiers never change what it types.
    pub fn to_xkb(&self) -> String {
        let mut keys: Vec<(u32, String)> = Vec::with_capacity(self.keys.len() + 3);
        keys.push((KEY_TAB, "Tab".to_owned()));
        keys.push((KEY_ENTER, "Return".to_owned()));
        keys.push((KEY_SPACE, "space".to_owned()));
        for &(code, c) in &self.keys {
            keys.push((code, keysym_name(c)));
        }
        keys.sort_by_key(|&(code, _)| code);

        let mut s = String::with_capacity(256 + keys.len() * 48);
        s.push_str("xkb_keymap {\n");
        s.push_str("xkb_keycodes \"localflow\" {\n");
        s.push_str("minimum = 8;\n");
        let _ = writeln!(s, "maximum = {};", MAX_EVDEV_CODE + 8);
        for (code, _) in &keys {
            let _ = writeln!(s, "<K{code}> = {};", code + 8);
        }
        s.push_str("};\n");
        s.push_str("xkb_types \"localflow\" { include \"complete\" };\n");
        s.push_str("xkb_compatibility \"localflow\" { include \"complete\" };\n");
        s.push_str("xkb_symbols \"localflow\" {\n");
        for (code, name) in &keys {
            let _ = writeln!(s, "key <K{code}> {{ [ {name} ] }};");
        }
        s.push_str("};\n");
        s.push_str("};\n");
        s
    }
}

/// XKB keysym name for a printable character: `U` and at least four hex
/// digits. libxkbcommon maps `U0020`-`U007E` and `U00A0`-`U00FF` to the
/// Latin-1 keysyms (equal to the code point) and everything else up to
/// U+10FFFF to the Unicode keysym 0x01000000 + code point.
pub fn keysym_name(c: char) -> String {
    debug_assert!(!c.is_control());
    format!("U{:04X}", u32::from(c))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pool_is_the_printable_key_allowlist() {
        let pool = char_pool();
        assert_eq!(pool.len(), 50);
        let mut expected: Vec<u32> = (2..=13).chain(16..=27).chain(30..=41).collect();
        expected.extend(43..=53);
        expected.extend([86, 89, 124]);
        assert_eq!(pool, expected);
        // Never Esc, Backspace, Tab, Return, modifiers, Space, locks,
        // F-keys, keypad, navigation, IME, media or power keys.
        for code in [
            1, 14, 15, 28, 29, 42, 54, 55, 56, 57, 58, 59, 69, 71, 85, 87, 92, 96, 97, 100, 102,
            113, 116, 122, 125, 127, 142, 164, 170, 183, 194, 200, 207,
        ] {
            assert!(!pool.contains(&code), "special code {code} in pool");
        }
        assert!(pool.iter().all(|&c| (1..=MAX_EVDEV_CODE).contains(&c)));
        assert!(
            ![KEY_TAB, KEY_ENTER, KEY_SPACE]
                .iter()
                .any(|c| pool.contains(c))
        );
    }

    #[test]
    fn tokenize_maps_newlines_tabs_and_space() {
        use Sym::*;
        let t = tokenize("a\nb\r\nc\rd\te f").unwrap();
        assert_eq!(
            t,
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
                Space,
                Char('f')
            ]
        );
        assert_eq!(tokenize("\r\r\n").unwrap(), vec![Return, Return]);
        assert_eq!(tokenize("").unwrap(), vec![]);
        // Other spaces are ordinary characters.
        assert_eq!(tokenize("\u{A0}").unwrap(), vec![Char('\u{A0}')]);
    }

    #[test]
    fn tokenize_keeps_non_ascii_and_non_bmp() {
        let t = tokenize("é€👍🏽\u{200D}").unwrap();
        assert_eq!(
            t,
            vec![
                Sym::Char('é'),
                Sym::Char('€'),
                Sym::Char('👍'),
                Sym::Char('\u{1F3FD}'),
                Sym::Char('\u{200D}')
            ]
        );
    }

    #[test]
    fn tokenize_rejects_controls_with_position_only() {
        assert_eq!(tokenize("ab\u{7}c"), Err(UnsupportedChar { index: 2 }));
        assert_eq!(tokenize("\u{7F}"), Err(UnsupportedChar { index: 0 }));
        assert_eq!(tokenize("x\u{85}"), Err(UnsupportedChar { index: 1 }));
        assert_eq!(tokenize("\u{1B}"), Err(UnsupportedChar { index: 0 }));
    }

    #[test]
    fn keysym_names() {
        assert_eq!(keysym_name('a'), "U0061");
        assert_eq!(keysym_name('é'), "U00E9");
        assert_eq!(keysym_name('€'), "U20AC");
        assert_eq!(keysym_name('👍'), "U1F44D");
        assert_eq!(keysym_name('\u{10FFFF}'), "U10FFFF");
    }

    #[test]
    fn plan_single_batch_when_it_fits() {
        let pool = char_pool();
        let syms = tokenize("hello\nworld\thello there").unwrap();
        let batches = plan(&syms, &pool);
        assert_eq!(batches.len(), 1);
        let b = &batches[0];
        assert_eq!((b.start, b.end), (0, syms.len()));
        // h e l o w r d t
        assert_eq!(b.keymap.len(), 8);
        assert!(b.keymap.covers(&syms));
        assert_eq!(b.keymap.code(Sym::Char('h')), Some(pool[0]));
        assert_eq!(b.keymap.code(Sym::Char('e')), Some(pool[1]));
        assert_eq!(b.keymap.code(Sym::Return), Some(KEY_ENTER));
        assert_eq!(b.keymap.code(Sym::Tab), Some(KEY_TAB));
        assert_eq!(b.keymap.code(Sym::Space), Some(KEY_SPACE));
        assert_eq!(b.keymap.code(Sym::Char('z')), None);
    }

    #[test]
    fn plan_splits_into_maximal_batches() {
        let pool = [10, 11, 12];
        let syms = tokenize("abcabd\nde\tf ab").unwrap();
        let batches = plan(&syms, &pool);
        // [a b c a b] [d \n d e \t f ' '] [a b]
        let ranges: Vec<(usize, usize)> = batches.iter().map(|b| (b.start, b.end)).collect();
        assert_eq!(ranges, vec![(0, 5), (5, 12), (12, 14)]);
        for b in &batches {
            assert!(b.keymap.len() <= pool.len());
            assert!(b.keymap.covers(&syms[b.start..b.end]));
        }
        assert_eq!(batches[1].keymap.code(Sym::Char('d')), Some(10));
        assert_eq!(batches[1].keymap.code(Sym::Char('f')), Some(12));
    }

    #[test]
    fn plan_covers_everything_in_order() {
        let pool = char_pool();
        // 1,000 distinct CJK characters interleaved with repeats.
        let mut text = String::new();
        for i in 0..1000u32 {
            text.push(char::from_u32(0x4E00 + i).unwrap());
            if i % 7 == 0 {
                text.push_str("a \n");
            }
        }
        let syms = tokenize(&text).unwrap();
        let batches = plan(&syms, &pool);
        assert!(batches.len() >= 1000 / pool.len());
        let mut next = 0;
        for b in &batches {
            assert_eq!(b.start, next);
            assert!(b.end > b.start);
            assert!(b.keymap.len() <= pool.len());
            assert!(b.keymap.covers(&syms[b.start..b.end]));
            next = b.end;
        }
        assert_eq!(next, syms.len());
        // Every batch but the last is full.
        for b in &batches[..batches.len() - 1] {
            assert_eq!(b.keymap.len(), pool.len());
        }
    }

    #[test]
    fn plan_of_only_fixed_keys_has_empty_keymap() {
        let syms = tokenize("\n\t \n").unwrap();
        let batches = plan(&syms, &char_pool());
        assert_eq!(batches.len(), 1);
        assert!(batches[0].keymap.is_empty());
        assert!(batches[0].keymap.covers(&syms));
        assert!(plan(&[], &char_pool()).is_empty());
    }

    #[test]
    #[should_panic(expected = "duplicate")]
    fn keymap_rejects_duplicates() {
        Keymap::new(&['a', 'b', 'a'], &[2, 3, 4]);
    }

    #[test]
    fn xkb_text_shape() {
        let km = Keymap::new(&['a', '€', '👍'], &[2, 3, 4]);
        let s = km.to_xkb();
        assert!(s.contains("<K2> = 10;"));
        assert!(s.contains("<K15> = 23;"));
        assert!(s.contains("<K28> = 36;"));
        assert!(s.contains("<K57> = 65;"));
        assert!(s.contains("key <K2> { [ U0061 ] };"));
        assert!(s.contains("key <K3> { [ U20AC ] };"));
        assert!(s.contains("key <K4> { [ U1F44D ] };"));
        assert!(s.contains("key <K15> { [ Tab ] };"));
        assert!(s.contains("key <K28> { [ Return ] };"));
        assert!(s.contains("key <K57> { [ space ] };"));
        assert!(s.contains("maximum = 255;"));
        assert!(!s.contains('\0'));
        // Key names are at most four characters (X11 limit).
        for code in char_pool() {
            assert!(format!("K{code}").len() <= 4);
        }
    }
}

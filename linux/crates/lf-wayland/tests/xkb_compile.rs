//! Compiles generated keymaps with the real libxkbcommon and checks that
//! every key produces exactly its character, also after the compositor-style
//! round trip through `xkb_keymap_get_as_string`.

use lf_wayland::keymap::{self, KEY_ENTER, KEY_SPACE, KEY_TAB, Keymap, Sym};
use xkbcommon::xkb;

fn compile(text: String) -> xkb::Keymap {
    let ctx = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
    xkb::Keymap::new_from_string(
        &ctx,
        text,
        xkb::KEYMAP_FORMAT_TEXT_V1,
        xkb::COMPILE_NO_FLAGS,
    )
    .expect("keymap compiles")
}

fn check(km: &xkb::Keymap, chars: &[char], pool: &[u32], ours: &Keymap) {
    assert!(km.max_keycode().raw() <= 255);
    let state = xkb::State::new(km);
    for &c in chars {
        let code = ours.code(Sym::Char(c)).unwrap();
        assert!(pool.contains(&code));
        let key = xkb::Keycode::new(code + 8);
        assert_eq!(km.num_levels_for_key(key, 0), 1, "U+{:04X}", u32::from(c));
        let sym = state.key_get_one_sym(key);
        assert_eq!(
            xkb::keysym_to_utf32(sym),
            u32::from(c),
            "U+{:04X} -> keysym {:#x}",
            u32::from(c),
            sym.raw()
        );
        assert_eq!(state.key_get_utf8(key), c.to_string());
    }
    let ret = state.key_get_one_sym(xkb::Keycode::new(KEY_ENTER + 8));
    assert_eq!(ret.raw(), xkb::keysyms::KEY_Return);
    let tab = state.key_get_one_sym(xkb::Keycode::new(KEY_TAB + 8));
    assert_eq!(tab.raw(), xkb::keysyms::KEY_Tab);
    assert_eq!(state.key_get_utf8(xkb::Keycode::new(KEY_SPACE + 8)), " ");
}

fn roundtrip(chars: &[char]) {
    let pool = keymap::char_pool();
    let ours = Keymap::new(chars, &pool);
    let km = compile(ours.to_xkb());
    check(&km, chars, &pool, &ours);
    // What clients actually receive: the compositor's re-serialization.
    let again = compile(km.get_as_string(xkb::KEYMAP_FORMAT_TEXT_V1));
    check(&again, chars, &pool, &ours);
}

#[test]
fn printable_ascii() {
    let chars: Vec<char> = (0x21u8..0x7f).map(char::from).collect();
    for chunk in chars.chunks(keymap::char_pool().len()) {
        roundtrip(chunk);
    }
}

#[test]
fn latin1_and_bmp() {
    let mut chars: Vec<char> = (0xA0u32..=0xFF).filter_map(char::from_u32).collect();
    chars.extend("€ŁŒœŸ—–“”‘’…•™ΩπЖжא日本語한글\u{0301}\u{200D}\u{FEFF}\u{FFFD}".chars());
    chars.dedup();
    let pool = keymap::char_pool();
    for chunk in chars.chunks(pool.len()) {
        roundtrip(chunk);
    }
}

#[test]
fn non_bmp_and_extremes() {
    let chars = [
        '👍',
        '\u{1F3FD}',
        '🎉',
        '𝔘',
        '\u{10000}',
        '\u{10FFFF}',
        '\u{E000}',
    ];
    roundtrip(&chars);
}

#[test]
fn full_keymap() {
    let pool = keymap::char_pool();
    let chars: Vec<char> = (0..pool.len() as u32)
        .map(|i| char::from_u32(0x4E00 + i).unwrap())
        .collect();
    roundtrip(&chars);
}

#[test]
fn base_keymap() {
    roundtrip(&[]);
}

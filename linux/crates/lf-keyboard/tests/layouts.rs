//! Contract tests: characters map to the keys and modifiers that make the
//! layout produce exactly them, and nothing else is typed.
//!
//! `SYNTHETIC` is a self-contained keymap (no include files), so these
//! tests do not depend on the system's XKB data; the RMLVO tests use the
//! xkeyboard-config data libxkbcommon was built with.

use std::time::{Duration, Instant};

use lf_io_api::TextOutput;
use lf_keyboard::layout::{self, Layout, Rmlvo, Stroke, Token};
use lf_keyboard::uinput::{
    EV_KEY, EV_SYN, EVENT_SIZE, EventWriter, SYN_REPORT, UinputConfig, UinputTyper,
};
use lf_keyboard::{Pace, type_strokes};

/// Evdev codes in the synthetic keymap (XKB keycode = evdev + 8).
const K1: u32 = 2;
const KQ: u32 = 16;
const KA: u32 = 30;
const KZ: u32 = 44;
const SHIFT: u32 = 42;
const ALTGR: u32 = 100;
const LSGT: u32 = 86;
const KP_MULTIPLY: u32 = 55;

pub const SYNTHETIC: &str = r#"xkb_keymap {
xkb_keycodes "synthetic" {
    minimum = 8;
    maximum = 255;
    <AE01> = 10;
    <AD01> = 24;
    <AC01> = 38;
    <AB01> = 52;
    <SPCE> = 65;
    <TAB> = 23;
    <RTRN> = 36;
    <LFSH> = 50;
    <RALT> = 108;
    <LSGT> = 94;
    <KPMU> = 63;
    <CAPS> = 66;
};
xkb_types "synthetic" {
    virtual_modifiers LevelThree;
    type "ONE_LEVEL" {
        modifiers = none;
        map[none] = Level1;
        level_name[Level1] = "Any";
    };
    type "TWO_LEVEL" {
        modifiers = Shift;
        map[Shift] = Level2;
        level_name[Level1] = "Base";
        level_name[Level2] = "Shift";
    };
    type "ALPHABETIC" {
        modifiers = Shift + Lock;
        map[Shift] = Level2;
        map[Lock] = Level2;
        level_name[Level1] = "Base";
        level_name[Level2] = "Caps";
    };
    type "FOUR_LEVEL" {
        modifiers = Shift + LevelThree;
        map[Shift] = Level2;
        map[LevelThree] = Level3;
        map[Shift + LevelThree] = Level4;
        level_name[Level1] = "Base";
        level_name[Level2] = "Shift";
        level_name[Level3] = "AltGr";
        level_name[Level4] = "Shift AltGr";
    };
};
xkb_compatibility "synthetic" {
    virtual_modifiers LevelThree;
    interpret Shift_L { action = SetMods(modifiers = Shift); };
    interpret ISO_Level3_Shift {
        useModMapMods = level1;
        virtualModifier = LevelThree;
        action = SetMods(modifiers = LevelThree);
    };
    interpret Caps_Lock { action = LockMods(modifiers = Lock); };
};
xkb_symbols "synthetic" {
    key <AE01> { type = "FOUR_LEVEL", [ 1, exclam, onesuperior, exclamdown ] };
    key <AD01> { type = "FOUR_LEVEL", [ q, Q, at, Greek_OMEGA ] };
    key <AC01> { type = "ALPHABETIC", [ a, A ] };
    key <AB01> { type = "TWO_LEVEL", [ dead_acute, dead_grave ] };
    key <SPCE> { [ space ] };
    key <TAB> { [ Tab ] };
    key <RTRN> { [ Return ] };
    key <LFSH> { [ Shift_L ] };
    key <RALT> { [ ISO_Level3_Shift ] };
    key <LSGT> { type = "TWO_LEVEL", [ less, greater ] };
    key <KPMU> { [ KP_Multiply ] };
    key <CAPS> { [ Caps_Lock ] };
    modifier_map Shift { <LFSH> };
    modifier_map Lock { <CAPS> };
    modifier_map Mod5 { <RALT> };
};
};
"#;

/// The real modifier mask of Lock (Caps Lock).
const LOCK_MASK: u32 = 1 << 1;

fn synthetic() -> Layout {
    Layout::from_keymap_text(SYNTHETIC, 0, 0).expect("synthetic keymap compiles")
}

fn s(mods: &[u32], code: u32) -> Stroke {
    Stroke {
        mods: mods.to_vec(),
        code,
    }
}

fn stroke(l: &Layout, c: char) -> Option<Stroke> {
    l.stroke(Token::Char(c)).cloned()
}

#[test]
fn characters_take_the_fewest_modifiers() {
    let l = synthetic();
    assert_eq!(stroke(&l, 'a'), Some(s(&[], KA)));
    assert_eq!(stroke(&l, 'A'), Some(s(&[SHIFT], KA)));
    assert_eq!(stroke(&l, '1'), Some(s(&[], K1)));
    assert_eq!(stroke(&l, '!'), Some(s(&[SHIFT], K1)));
    assert_eq!(stroke(&l, '¹'), Some(s(&[ALTGR], K1)));
    assert_eq!(stroke(&l, '¡'), Some(s(&[SHIFT, ALTGR], K1)));
    assert_eq!(stroke(&l, '@'), Some(s(&[ALTGR], KQ)));
    assert_eq!(stroke(&l, 'Ω'), Some(s(&[SHIFT, ALTGR], KQ)));
    assert_eq!(stroke(&l, '<'), Some(s(&[], LSGT)));
    assert_eq!(stroke(&l, '>'), Some(s(&[SHIFT], LSGT)));
    assert_eq!(stroke(&l, ' '), Some(s(&[], layout::KEY_SPACE)));
    assert_eq!(l.stroke(Token::Tab).cloned(), Some(s(&[], layout::KEY_TAB)));
    assert_eq!(
        l.stroke(Token::Return).cloned(),
        Some(s(&[], layout::KEY_ENTER))
    );
}

#[test]
fn keypad_dead_and_missing_characters_are_not_typed() {
    let l = synthetic();
    // Only on the keypad, which is never used.
    assert_eq!(stroke(&l, '*'), None);
    // Dead keys produce no character of their own; é needs a sequence.
    assert_eq!(stroke(&l, '´'), None);
    assert_eq!(stroke(&l, 'é'), None);
    assert_eq!(stroke(&l, 'b'), None);
    assert!(
        !l.key_codes().contains(&KP_MULTIPLY) && !l.key_codes().contains(&KZ),
        "{:?}",
        l.key_codes()
    );
    assert!(l.key_codes().contains(&SHIFT) && l.key_codes().contains(&ALTGR));
}

#[test]
fn text_maps_whole_or_not_at_all_and_errors_name_positions_only() {
    let l = synthetic();
    assert_eq!(
        l.strokes("aA\r\n1\t").unwrap(),
        vec![
            s(&[], KA),
            s(&[SHIFT], KA),
            s(&[], layout::KEY_ENTER),
            s(&[], K1),
            s(&[], layout::KEY_TAB)
        ]
    );
    let err = l.strokes("a\r\naé").unwrap_err();
    assert!(err.0.contains("position 4"), "{err}");
    assert!(!err.0.contains('é'), "{err}");
    let err = l.strokes("a\u{7}").unwrap_err();
    assert!(err.0.contains("position 1"), "{err}");
}

#[test]
fn locked_caps_lock_is_accounted_for() {
    let l = Layout::from_keymap_text(SYNTHETIC, 0, LOCK_MASK).unwrap();
    assert_eq!(stroke(&l, 'a'), Some(s(&[SHIFT], KA)));
    assert_eq!(stroke(&l, 'A'), Some(s(&[], KA)));
    // Keys whose type ignores Lock are unchanged.
    assert_eq!(stroke(&l, '1'), Some(s(&[], K1)));
}

#[test]
fn an_invalid_keymap_is_an_error() {
    assert!(Layout::from_keymap_text("xkb_keymap { nonsense", 0, 0).is_err());
    // No include files are read for a compositor's keymap.
    let with_include = "xkb_keymap { xkb_keycodes { include \"evdev\" }; \
        xkb_types { include \"complete\" }; xkb_compatibility { include \"complete\" }; \
        xkb_symbols { include \"pc+us\" }; };";
    assert!(Layout::from_keymap_text(with_include, 0, 0).is_err());
}

fn names(layout: &str, variant: &str) -> Rmlvo {
    Rmlvo {
        rules: "evdev".into(),
        model: "pc105".into(),
        layout: layout.into(),
        variant: variant.into(),
        options: None,
    }
}

#[test]
fn system_layouts_follow_their_key_positions() {
    let us = Layout::from_names(&names("us", "")).unwrap();
    assert_eq!(stroke(&us, 'a'), Some(s(&[], KA)));
    assert_eq!(stroke(&us, '@'), Some(s(&[SHIFT], 3)));
    assert_eq!(stroke(&us, 'é'), None);

    let de = Layout::from_names(&names("de", "")).unwrap();
    assert_eq!(stroke(&de, 'z'), Some(s(&[], 21)));
    assert_eq!(stroke(&de, 'y'), Some(s(&[], 44)));
    assert_eq!(stroke(&de, '@'), Some(s(&[ALTGR], KQ)));
    assert_eq!(stroke(&de, 'ä'), Some(s(&[], 40)));

    let dvorak = Layout::from_names(&names("us", "dvorak")).unwrap();
    assert_eq!(stroke(&dvorak, 'a'), Some(s(&[], KA)));
    assert_eq!(stroke(&dvorak, 'o'), Some(s(&[], 31)));
    assert_eq!(stroke(&dvorak, 'e'), Some(s(&[], 32)));
}

#[test]
fn a_later_group_of_a_compositor_keymap_can_be_used() {
    use xkbcommon::xkb;
    let ctx = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
    let km = xkb::Keymap::new_from_names(
        &ctx,
        "evdev",
        "pc105",
        "us,de",
        ",",
        None,
        xkb::KEYMAP_COMPILE_NO_FLAGS,
    )
    .unwrap();
    let text = km.get_as_string(xkb::KEYMAP_FORMAT_TEXT_V1);
    let first = Layout::from_keymap_text(&text, 0, 0).unwrap();
    let second = Layout::from_keymap_text(&text, 1, 0).unwrap();
    assert_eq!(stroke(&first, 'ä'), None);
    assert_eq!(stroke(&second, 'ä'), Some(s(&[], 40)));
    assert_eq!(stroke(&first, 'y'), Some(s(&[], 21)));
    assert_eq!(stroke(&second, 'y'), Some(s(&[], 44)));
}

#[test]
fn an_unknown_layout_name_is_an_error_without_the_name() {
    let err = Layout::from_names(&names("synthetic-no-such-layout", "")).unwrap_err();
    assert!(!err.0.contains("synthetic"), "{err}");
}

/// (type, code, value) of each event, checking the timestamps are zero.
fn decode(bytes: &[u8]) -> Vec<(u16, u16, i32)> {
    assert_eq!(bytes.len() % EVENT_SIZE, 0);
    bytes
        .chunks(EVENT_SIZE)
        .map(|e| {
            assert!(
                e[..16].iter().all(|&b| b == 0),
                "timestamp left to the kernel"
            );
            (
                u16::from_ne_bytes([e[16], e[17]]),
                u16::from_ne_bytes([e[18], e[19]]),
                i32::from_ne_bytes([e[20], e[21], e[22], e[23]]),
            )
        })
        .collect()
}

#[test]
fn uinput_events_frame_every_key_change() {
    let l = synthetic();
    let mut w = EventWriter::new(Vec::new());
    let pace = Pace {
        key_delay: Duration::ZERO,
        timeout: Duration::from_secs(1),
        deadline: Some(Instant::now() + Duration::from_secs(5)),
    };
    type_strokes(&mut w, &l.strokes("aA\n").unwrap(), pace).unwrap();
    let key = |code: u32, v: i32| (EV_KEY, code as u16, v);
    let syn = (EV_SYN, SYN_REPORT, 0);
    let expected = vec![
        key(KA, 1),
        syn,
        key(KA, 0),
        syn,
        key(SHIFT, 1),
        syn,
        key(KA, 1),
        syn,
        key(KA, 0),
        syn,
        key(SHIFT, 0),
        syn,
        key(layout::KEY_ENTER, 1),
        syn,
        key(layout::KEY_ENTER, 0),
        syn,
    ];
    assert_eq!(decode(&w.into_inner()), expected);
}

fn scratch(tag: &str) -> std::path::PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos());
    let dir =
        std::env::temp_dir().join(format!("lf-keyboard-{tag}-{}-{nanos}", std::process::id()));
    std::fs::create_dir(&dir).unwrap();
    dir
}

fn uinput_config(path: std::path::PathBuf) -> UinputConfig {
    UinputConfig {
        path,
        layout: names("us", ""),
        call_timeout: Some(Duration::from_secs(2)),
        ..UinputConfig::default()
    }
}

#[test]
fn uinput_fails_cleanly_without_a_device() {
    let dir = scratch("missing");
    let missing = dir.join("no-such-uinput");
    assert!(!lf_keyboard::uinput::writable(&missing));
    let mut t = UinputTyper::new(uinput_config(missing)).unwrap();
    // The layout check needs no device.
    assert!(t.check("Synthetic text").is_ok());
    assert!(t.check("synthetic é").is_err());
    let t0 = Instant::now();
    assert!(t.connect().is_err());
    assert!(t.type_text("x").is_err());
    assert!(t.press_enter().is_err());
    assert!(t0.elapsed() < Duration::from_secs(1));

    // A regular file opens but is not a uinput device: the first ioctl
    // fails and nothing is written.
    let file = dir.join("not-uinput");
    std::fs::write(&file, b"").unwrap();
    assert!(lf_keyboard::uinput::writable(&file));
    let mut t = UinputTyper::new(uinput_config(file.clone())).unwrap();
    let err = t.connect().unwrap_err();
    assert!(err.0.contains("not a uinput device"), "{err}");
    assert!(t.type_text("x").is_err());
    assert_eq!(std::fs::metadata(&file).unwrap().len(), 0);
    let _ = std::fs::remove_dir_all(&dir);
}

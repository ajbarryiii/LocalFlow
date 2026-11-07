//! LocalFlow's look, shared by the settings window and both dialogs: the
//! iPhone app's (`iOS/App/Components.swift`, `Theme`). Always dark, as the
//! app and the site are: near-black surfaces, white ink, hairline edges, and
//! brand colour only on state (a switch that is on, a dot, a check, an
//! error).

use rune::color::hex;
use rune::{Color, El, Icon, el, icon};
use rune_kit::{Button, ButtonVariant, ControlSize, Kit, PaletteFocus, PaletteSeed};

fn rgb(s: &str) -> Color {
    hex(s).expect("a #rrggbb colour")
}

/// The window behind everything.
pub fn screen() -> Color {
    rgb("#05080A")
}

/// A card of settings, and a text box.
pub fn card() -> Color {
    rgb("#0F1A1C")
}

/// The main action's near-black pill and its grey hairline.
fn pill() -> Color {
    rgb("#09090A")
}

fn edge() -> Color {
    rgb("#6E6E70")
}

/// Waiting: a change not applied yet.
pub fn glacier() -> Color {
    rgb("#67E8F9")
}

/// Done.
fn aurora() -> Color {
    rgb("#6DFFA8")
}

/// A warning or something to fix.
pub fn ember() -> Color {
    rgb("#F5C66B")
}

/// The kit every LocalFlow window draws with.
pub fn kit() -> Kit {
    let mut k = Kit::from_palette_focus(
        PaletteSeed {
            bg: screen(),
            fg: Color::WHITE,
            // A switch that is on: aurora, a shade deeper so the knob stays crisp.
            accent: rgb("#3FD17A"),
        },
        // Focus is a soft white ring, never blue.
        PaletteFocus::Custom(Color::WHITE.alpha(0.75)),
    );
    let (secondary, faint) = (k.light(0.6), k.light(0.4));
    let c = &mut k.c;
    c.layer_01 = card();
    c.text_muted = secondary;
    c.text_weak = secondary;
    c.icon_muted = secondary;
    c.text_faint = faint;
    c.icon_faint = faint;
    c.knob = Color::WHITE;
    c.knob_on = Color::WHITE;
    // The main action: the near-black pill with white ink (see `primary`).
    c.bg_contrast = pill();
    c.text_contrast = Color::WHITE;
    c.contrast_hover = Color::WHITE.alpha(0.08);
    c.contrast_pressed = Color::WHITE.alpha(0.14);
    // Selected text: a soft white wash, not the switches' green.
    c.text_accent = Color::WHITE;
    c.success.icon = aurora();
    c.danger.fg = ember();
    c.danger.icon = ember();
    c.danger.border = ember();
    k
}

/// `k` for segmented controls: a track set into the card, and the chosen
/// segment clearly lifted from it.
pub fn segments(k: &Kit) -> Kit {
    let mut s = k.clone();
    s.c.layer_01 = screen();
    s.c.bg_base = rgb("#2C3739");
    s.c.border_strong = Color::WHITE.alpha(0.16);
    s
}

/// `k` for text fields: placeholders in secondary ink, not faint, since
/// they carry meaning (the microphone's "Default").
pub fn fields(k: &Kit) -> Kit {
    let mut f = k.clone();
    f.c.text_faint = k.c.text_muted;
    f
}

/// A pill's height, as a large push button.
const PILL_HEIGHT: f32 = 28.0;

/// The main action: the iPhone's near-black pill with a hairline edge and
/// white semibold ink (`PillLabel`).
pub fn primary(k: &Kit, b: Button) -> El {
    let mut k = k.clone();
    k.ty.ui_medium.weight = 600.0;
    b.variant(ButtonVariant::Contrast)
        .control_size(ControlSize::Large)
        .build(&k)
        .radius(PILL_HEIGHT / 2.0)
        .px(16.0)
        .gradient(Color::TRANSPARENT, Color::TRANSPARENT)
        .border(1.0, edge())
}

/// A quieter action beside the main one: secondary ink, no surface.
pub fn secondary(k: &Kit, b: Button) -> El {
    b.variant(ButtonVariant::GhostMuted)
        .control_size(ControlSize::Large)
        .build(k)
        .radius(PILL_HEIGHT / 2.0)
        .px(14.0)
}

/// A state's small dot (`StateDot` on the iPhone).
pub fn dot(color: Color) -> El {
    el().size(6.0, 6.0).radius(3.0).fill(color).a11y_hidden()
}

/// LocalFlow's ridge mark (`RidgeMark` in `iOS/KeyboardCore`): the W line,
/// in the mark's 32 units, drawn heavier (1.3) for small sizes as the
/// keyboard draws it.
static RIDGE_LINE: Icon = Icon {
    name: "lf-ridge-line",
    view: 32.0,
    body: r#"<path d="M5.4 6.1L9.2 19L17.2 8.2L19.4 18.8L24.8 11.6L26.6 15.9" stroke="currentColor" stroke-width="3.12" stroke-linecap="round" stroke-linejoin="round" fill="none"/>"#,
};

/// The mark's dot.
static RIDGE_DOT: Icon = Icon {
    name: "lf-ridge-dot",
    view: 32.0,
    body: r#"<circle cx="16" cy="26" r="2.34"/>"#,
};

/// The ridge mark, `side` points square: the line in white, its dot in
/// aurora. Decorative.
pub fn mark(side: f32) -> El {
    el().key("mark")
        .size(side, side)
        .a11y_hidden()
        .child(
            icon(&RIDGE_LINE, side)
                .color(Color::WHITE)
                .absolute(0.0, 0.0),
        )
        .child(icon(&RIDGE_DOT, side).color(aurora()).absolute(0.0, 0.0))
}

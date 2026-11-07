//! The settings window (`localflow-gui`, or `localflow-gui settings`).
//!
//! - It shows the configuration `config.json` and `settings.json` make
//!   together (`lf_daemon::config::Layers`).
//! - A change is a draft until **Apply**, which writes `settings.json` (only
//!   the keys that differ from `config.json`) and restarts the daemon when a
//!   key it reads changed. **Discard** drops the draft.
//! - A setting the window changed has a reset icon, which takes it back to
//!   `config.json`'s value (or the default).
//! - Values that make an invalid configuration keep Apply disabled and show
//!   the daemon's own message, which names the key and never the value.

use std::path::PathBuf;

use lf_daemon::config::{Config, Layers, write_settings};
use rune::tok::space;
use rune::{Cx, El, Icon, ScrollSpec, TextEdit, Tx, col, el, icon, row, text};
use rune_kit::{
    Button, ButtonVariant, IconButton, IconButtonVariant, Kit, SegmentedControl, Select, Switch,
    TextInput,
};
use serde_json::{Map, Value, json};

/// Back to `config.json`'s value.
static RESET: Icon = Icon {
    name: "lf-reset",
    view: 16.0,
    body: r#"<path d="M3.5 8A4.5 4.5 0 1 0 5 4.6M3.5 2.5V5.5H6.5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>"#,
};

/// Remove a voice macro.
static REMOVE: Icon = Icon {
    name: "lf-remove",
    view: 16.0,
    body: r#"<path d="M4.5 4.5L11.5 11.5M11.5 4.5L4.5 11.5" stroke="currentColor" stroke-linecap="round"/>"#,
};

static PLUS: Icon = Icon {
    name: "lf-plus",
    view: 16.0,
    body: r#"<path d="M8 3.5V12.5M3.5 8H12.5" stroke="currentColor" stroke-linecap="round"/>"#,
};

static CHECK: Icon = Icon {
    name: "lf-check",
    view: 16.0,
    body: r#"<path d="M3.5 8.5L6.5 11.5L12.5 4.5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>"#,
};

/// Restarts the daemon after Apply; `None` in tests.
pub type Restart = Option<fn() -> Result<(), String>>;

pub struct Settings {
    pub config_path: PathBuf,
    pub data_dir: PathBuf,
    /// `config.json`'s keys and `settings.json`'s as last read or written.
    pub layers: Layers,
    /// The settings being edited.
    pub draft: Map<String, Value>,
    /// What the draft makes; `Err` keeps Apply disabled.
    pub config: Result<Config, String>,
    /// The last configuration that was valid, which the controls show.
    pub shown: Config,
    pub prompt_tag: TextEdit,
    pub input_device: TextEdit,
    pub macros: Vec<(TextEdit, TextEdit)>,
    pub open: Option<&'static str>,
    pub status: Status,
    pub restart: Restart,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Status {
    Idle,
    Applied,
    Failed(String),
}

/// Keys the daemon ignores (`localflowctl` reads them on each run).
const CLIENT_ONLY: &[&str] = &["picker"];

impl Settings {
    /// The window's state over `layers`, or the error that stops it (an
    /// invalid `config.json` or `settings.json`).
    pub fn new(
        config_path: PathBuf,
        data_dir: PathBuf,
        layers: Layers,
        restart: Restart,
    ) -> Result<Settings, String> {
        let config = layers.config(&data_dir)?;
        let mut s = Settings {
            config_path,
            data_dir,
            draft: layers.settings.clone(),
            layers,
            shown: config.clone(),
            config: Ok(config),
            prompt_tag: TextEdit::default(),
            input_device: TextEdit::default(),
            macros: Vec::new(),
            open: None,
            status: Status::Idle,
            restart,
        };
        s.reset_fields();
        Ok(s)
    }

    /// The text fields from the shown configuration.
    fn reset_fields(&mut self) {
        self.prompt_tag = TextEdit::new(self.shown.prompt_tag.clone());
        self.input_device = TextEdit::new(self.shown.input_device.clone().unwrap_or_default());
        self.macros = self
            .shown
            .voice_macros
            .iter()
            .map(|m| {
                (
                    TextEdit::new(m.command.clone()),
                    TextEdit::new(m.payload.clone()),
                )
            })
            .collect();
    }

    /// The configuration `config.json` and `settings` make.
    fn with(&self, settings: Map<String, Value>) -> Result<Config, String> {
        Layers {
            file: self.layers.file.clone(),
            settings,
        }
        .config(&self.data_dir)
    }

    /// Sets `key` in the draft; a value that changes nothing over
    /// `config.json` drops the key instead.
    pub fn set(&mut self, key: &str, value: Value) {
        let mut without = self.draft.clone();
        without.remove(key);
        let mut with = self.draft.clone();
        with.insert(key.to_owned(), value);
        let same = matches!((self.with(without.clone()), self.with(with.clone())), (Ok(a), Ok(b)) if a == b);
        self.draft = if same { without } else { with };
        self.recompute();
    }

    /// Takes `key` back to `config.json`'s value.
    pub fn reset(&mut self, key: &str) {
        self.draft.remove(key);
        self.recompute();
        if matches!(key, "prompt_tag" | "input_device" | "voice_macros") {
            self.reset_fields();
        }
    }

    fn recompute(&mut self) {
        self.status = Status::Idle;
        self.config = self.with(self.draft.clone());
        if let Ok(c) = &self.config {
            self.shown = c.clone();
        }
    }

    pub fn dirty(&self) -> bool {
        self.draft != self.layers.settings
    }

    pub fn discard(&mut self) {
        self.draft = self.layers.settings.clone();
        self.recompute();
        self.reset_fields();
    }

    /// Writes the draft and restarts the daemon if a key it reads changed.
    pub fn apply(&mut self) {
        let changed: Vec<&String> = self
            .draft
            .keys()
            .chain(self.layers.settings.keys())
            .filter(|k| self.draft.get(*k) != self.layers.settings.get(*k))
            .collect();
        let daemon_reads = changed.iter().any(|k| !CLIENT_ONLY.contains(&k.as_str()));
        match write_settings(&self.config_path, &self.data_dir, &self.draft) {
            Ok(config) => {
                // config.json may have changed since the window opened (a
                // Home Manager switch): work from both files as they are.
                match Layers::load(&self.config_path, &self.data_dir) {
                    Ok(layers) => self.layers = layers,
                    Err(_) => self.layers.settings = self.draft.clone(),
                }
                self.draft = self.layers.settings.clone();
                self.shown = config.clone();
                self.config = Ok(config);
                self.status = Status::Applied;
                if daemon_reads
                    && let Some(restart) = self.restart
                    && let Err(e) = restart()
                {
                    self.status = Status::Failed(e);
                }
            }
            Err(e) => self.status = Status::Failed(e),
        }
    }

    fn sync_macros(&mut self) {
        let list: Vec<Value> = self
            .macros
            .iter()
            .filter(|(c, _)| !c.text.trim().is_empty())
            .map(|(c, p)| json!({"command": c.text, "payload": p.text}))
            .collect();
        self.set("voice_macros", Value::Array(list));
    }
}

/// `systemctl --user try-restart localflowd.service`: restarts the daemon
/// if it runs as the usual user unit.
pub fn restart_daemon() -> Result<(), String> {
    let status = std::process::Command::new("systemctl")
        .args(["--user", "try-restart", "localflowd.service"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map_err(|e| format!("could not restart the daemon: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err("could not restart the daemon (systemctl --user try-restart localflowd)".into())
    }
}

/// A labelled row: the label, a reset icon when the window changed the
/// key, and the control.
fn setting(k: &Kit, s: &Settings, key: &'static str, label: &str, control: El) -> El {
    let changed = s.draft.contains_key(key);
    let mut left = row().key("left").gap(space::S2).center_y().grow(1.0).child(
        text(label.to_owned())
            .key("label")
            .font(k.ty.ui)
            .color(k.c.text_base)
            .a11y_hidden(),
    );
    if changed {
        left = left.child(
            IconButton::new(&RESET)
                .variant(IconButtonVariant::GhostMuted)
                .label(format!("Reset {label}"))
                .help("Back to config.json")
                .on_press(move |s: &mut Settings| s.reset(key))
                .build(k)
                .key(format!("reset-{key}")),
        );
    }
    row()
        .key(key)
        .min_h(40.0)
        .px(space::S3)
        .gap(space::S3)
        .center_y()
        .label(label.to_owned())
        .child(left)
        .child(control)
}

fn toggle(k: &Kit, s: &Settings, key: &'static str, label: &str, on: bool) -> El {
    let control = Switch::new(on)
        .label(label.to_owned())
        .hide_label()
        .on_toggle(move |s: &mut Settings| s.set(key, Value::Bool(!on)))
        .build(k)
        .key(format!("switch-{key}"));
    setting(k, s, key, label, control)
}

fn card(k: &Kit, key: &str, title: &str, rows: Vec<El>) -> El {
    let mut body = col()
        .key("card")
        .padding(space::S1)
        .fill(k.c.layer_01)
        .radius(10.0)
        .box_shadow(rune::Shadow {
            spread: 0.5,
            color: k.c.border_base,
            ..Default::default()
        });
    let n = rows.len();
    for (i, r) in rows.into_iter().enumerate() {
        body = body.child(r);
        if i + 1 < n {
            body = body.child(
                el().key(format!("sep{i}"))
                    .h(1.0)
                    .mx(space::S3)
                    .fill(k.c.border_base)
                    .a11y_hidden(),
            );
        }
    }
    col()
        .key(key.to_owned())
        .gap(space::S2)
        .child(
            text(title.to_owned())
                .key("header")
                .font(k.ty.small)
                .color(k.c.text_weak)
                .ml(space::S3),
        )
        .child(body)
}

/// "Auto" is the model's default (no `precision` key).
const PRECISION: [&str; 5] = ["Auto", "f32", "i8x1", "i8x2", "i8x3"];

pub fn view(s: &Settings, cx: &mut Cx<Settings>) -> El {
    let k = Kit::neutral(cx.system_dark());
    let c = &s.shown;
    let mut layer = Vec::new();

    let dictation = card(
        &k,
        "dictation",
        "Dictation",
        vec![
            toggle(
                &k,
                s,
                "press_enter",
                "Say \u{201C}press enter\u{201D} to send",
                c.press_enter,
            ),
            toggle(
                &k,
                s,
                "spoken_numbers",
                "Numbers as digits",
                c.spoken_numbers,
            ),
            toggle(
                &k,
                s,
                "spoken_delimiters",
                "Spoken quotes and brackets",
                c.spoken_delimiters,
            ),
            toggle(
                &k,
                s,
                "pause_media",
                "Pause media while recording",
                c.pause_media,
            ),
            toggle(&k, s, "history", "Keep recent transcripts", c.history),
        ],
    );

    let tag = TextInput::new(&s.prompt_tag)
        .label("Prompt tag")
        .placeholder("Untagged")
        .width(Some(160.0))
        .on_edit(|s: &mut Settings| &mut s.prompt_tag)
        .on_change(|s: &mut Settings, _: &mut Tx| {
            let v = s.prompt_tag.text.clone();
            s.set("prompt_tag", Value::String(v));
        })
        .build(&k);
    static DOUBLE_TAP: [(&str, u64); 4] = [
        ("Off", 0),
        ("250 ms", 250),
        ("400 ms", 400),
        ("600 ms", 600),
    ];
    let tap_labels: Vec<&str> = DOUBLE_TAP.iter().map(|(l, _)| *l).collect();
    let tap_current = DOUBLE_TAP.iter().position(|(_, v)| *v == c.double_tap_ms);
    let tap = SegmentedControl::new(&tap_labels, tap_current)
        .label("Double-tap")
        .fit()
        .on_pick(|s: &mut Settings, i: usize, _: &mut Tx| {
            s.set("double_tap_ms", json!(DOUBLE_TAP[i].1))
        })
        .build(&k)
        .key("choice-double_tap_ms");
    let prompt = card(
        &k,
        "prompt",
        "Hold to Prompt",
        vec![
            setting(&k, s, "double_tap_ms", "Double-tap and hold", tap),
            setting(&k, s, "prompt_tag", "Tag", tag),
        ],
    );

    static OUTPUT: [(&str, &str); 4] = [
        ("Auto", "auto"),
        ("Wayland", "wayland"),
        ("Portal", "portal"),
        ("uinput", "uinput"),
    ];
    let out_labels: Vec<&str> = OUTPUT.iter().map(|(l, _)| *l).collect();
    let out_current = OUTPUT.iter().position(|(_, v)| *v == output_name(c));
    let output = SegmentedControl::new(&out_labels, out_current)
        .label("Output")
        .fit()
        .on_pick(|s: &mut Settings, i: usize, _: &mut Tx| s.set("output", json!(OUTPUT[i].1)))
        .build(&k)
        .key("choice-output");
    static DELAY: [(&str, u64); 4] = [("0", 0), ("1 ms", 1), ("5 ms", 5), ("10 ms", 10)];
    let delay_labels: Vec<&str> = DELAY.iter().map(|(l, _)| *l).collect();
    let delay = SegmentedControl::new(
        &delay_labels,
        DELAY.iter().position(|(_, v)| *v == c.key_delay_ms),
    )
    .label("Key delay")
    .fit()
    .on_pick(|s: &mut Settings, i: usize, _: &mut Tx| s.set("key_delay_ms", json!(DELAY[i].1)))
    .build(&k)
    .key("choice-key_delay_ms");
    static PICKERS: [(&str, &str); 6] = [
        ("Auto", "auto"),
        ("LocalFlow", "gui"),
        ("rofi", "rofi"),
        ("fuzzel", "fuzzel"),
        ("wofi", "wofi"),
        ("tofi", "tofi"),
    ];
    let picker_labels: Vec<&str> = PICKERS.iter().map(|(l, _)| *l).collect();
    let picker_now = PICKERS
        .iter()
        .find(|(_, v)| *v == picker_name(c))
        .map(|(l, _)| *l);
    let picker = Select::new("picker-select", &picker_labels)
        .current(picker_now)
        .label("Correction dialogs")
        .width(140.0)
        .open(s.open == Some("picker"))
        .on_toggle(|s: &mut Settings| {
            s.open = if s.open.is_some() {
                None
            } else {
                Some("picker")
            }
        })
        .on_close(|s: &mut Settings| s.open = None)
        .on_choose(|s: &mut Settings, v: &str, _: &mut Tx| {
            s.open = None;
            if let Some((_, name)) = PICKERS.iter().find(|(l, _)| *l == v) {
                s.set("picker", json!(name));
            }
        })
        .build(&k, &mut layer);
    let typing = card(
        &k,
        "typing",
        "Typing",
        vec![
            setting(&k, s, "output", "Output", output),
            setting(&k, s, "key_delay_ms", "Pause between keys", delay),
            setting(&k, s, "picker", "Correction dialogs", picker),
        ],
    );

    let precision_now = match c.precision {
        None => 0,
        Some(p) => PRECISION.iter().position(|n| *n == p.name()).unwrap_or(0),
    };
    let precision = SegmentedControl::new(&PRECISION, Some(precision_now))
        .label("Precision")
        .fit()
        .on_pick(|s: &mut Settings, i: usize, _: &mut Tx| {
            if i == 0 {
                s.reset("precision");
            } else {
                s.set("precision", json!(PRECISION[i]));
            }
        })
        .build(&k)
        .key("choice-precision");
    let device = TextInput::new(&s.input_device)
        .label("Microphone")
        .placeholder("Default")
        .width(Some(200.0))
        .on_edit(|s: &mut Settings| &mut s.input_device)
        .on_change(|s: &mut Settings, _: &mut Tx| {
            let t = s.input_device.text.trim().to_owned();
            s.set(
                "input_device",
                if t.is_empty() {
                    Value::Null
                } else {
                    Value::String(t)
                },
            );
        })
        .build(&k);
    let recognition = card(
        &k,
        "recognition",
        "Recognition",
        vec![
            setting(&k, s, "precision", "Precision", precision),
            setting(&k, s, "input_device", "Microphone", device),
        ],
    );

    let mut macro_rows = Vec::new();
    for i in 0..s.macros.len() {
        let command = TextInput::new(&s.macros[i].0)
            .label("Say")
            .placeholder("Say")
            .width(Some(150.0))
            .on_edit(move |s: &mut Settings| &mut s.macros[i].0)
            .on_change(|s: &mut Settings, _: &mut Tx| s.sync_macros())
            .build(&k);
        let payload = TextInput::new(&s.macros[i].1)
            .label("Type")
            .placeholder("Type")
            .width(None)
            .on_edit(move |s: &mut Settings| &mut s.macros[i].1)
            .on_change(|s: &mut Settings, _: &mut Tx| s.sync_macros())
            .build(&k)
            .grow(1.0);
        let remove = IconButton::new(&REMOVE)
            .variant(IconButtonVariant::GhostMuted)
            .label("Remove macro")
            .on_press(move |s: &mut Settings| {
                s.macros.remove(i);
                s.sync_macros();
            })
            .build(&k);
        macro_rows.push(
            row()
                .key(format!("macro-{i}"))
                .min_h(40.0)
                .px(space::S3)
                .gap(space::S2)
                .center_y()
                .child(command)
                .child(icon(&rune_kit::glyphs::ARROW_RIGHT, 14.0).color(k.c.text_weak))
                .child(payload)
                .child(remove),
        );
    }
    let mut add_row = row()
        .key("macro-add")
        .min_h(40.0)
        .px(space::S3)
        .gap(space::S2)
        .center_y()
        .child(
            IconButton::new(&PLUS)
                .variant(IconButtonVariant::Ghost)
                .label("Add macro")
                .on_press(|s: &mut Settings| {
                    s.macros.push((TextEdit::default(), TextEdit::default()))
                })
                .build(&k)
                .key("add-macro"),
        );
    add_row = add_row.child(el().grow(1.0));
    if s.draft.contains_key("voice_macros") {
        add_row = add_row.child(
            IconButton::new(&RESET)
                .variant(IconButtonVariant::GhostMuted)
                .label("Reset voice macros")
                .help("Back to config.json")
                .on_press(|s: &mut Settings| s.reset("voice_macros"))
                .build(&k)
                .key("reset-voice_macros"),
        );
    }
    macro_rows.push(add_row);
    let macros = card(&k, "macros", "Voice macros", macro_rows);

    let content = col()
        .key("content")
        .w_full()
        .px(space::S6)
        .pt(16.0)
        .pb(space::S6)
        .gap(space::S6)
        .child(dictation)
        .child(prompt)
        .child(typing)
        .child(recognition)
        .child(macros);

    let mut footer = row()
        .key("footer")
        .h(56.0)
        .px(space::S6)
        .gap(space::S2)
        .center_y()
        .fill(k.c.bg_base);
    footer = match (&s.config, &s.status) {
        (Err(e), _) | (_, Status::Failed(e)) => footer.child(
            text(e.clone())
                .key("error")
                .font(k.ty.small)
                .color(k.c.danger.fg)
                .grow(1.0)
                .shrink(),
        ),
        (_, Status::Applied) => footer
            .child(icon(&CHECK, 16.0).key("applied").color(k.c.success.icon))
            .child(el().grow(1.0)),
        _ => footer.child(el().grow(1.0)),
    };
    let can_apply = s.dirty() && s.config.is_ok();
    footer = footer
        .child(
            Button::new("Discard")
                .variant(ButtonVariant::Ghost)
                .disabled(!s.dirty())
                .on_press(|s: &mut Settings| s.discard())
                .build(&k)
                .key("discard"),
        )
        .child(
            Button::new("Apply")
                .variant(ButtonVariant::Contrast)
                .disabled(!can_apply)
                .on_press(|s: &mut Settings| s.apply())
                .build(&k)
                .key("apply"),
        );

    let body = col()
        .key("window")
        .w_full()
        .h_full()
        .fill(k.c.bg_base)
        .child(
            content
                .scroll(ScrollSpec {
                    stick_bottom: false,
                })
                .grow(1.0)
                .min_h(0.0),
        )
        .child(
            el().key("footer-rule")
                .h(1.0)
                .w_full()
                .fill(k.c.border_base),
        )
        .child(footer);
    rune_kit::root(body, layer)
}

fn output_name(c: &Config) -> &'static str {
    use lf_daemon::config::Output;
    match c.output {
        Output::Auto => "auto",
        Output::Wayland => "wayland",
        Output::Portal => "portal",
        Output::Uinput => "uinput",
    }
}

fn picker_name(c: &Config) -> &'static str {
    use lf_daemon::picker::Choice;
    match c.picker {
        Choice::Auto => "auto",
        Choice::Only(k) => k.name(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rune::{Env, Runtime};
    use std::path::Path;

    /// A temporary directory with a read-only config.json, as Home Manager
    /// installs it.
    struct Dir(PathBuf);
    impl Dir {
        fn new(name: &str, config: &str) -> Dir {
            use std::os::unix::fs::PermissionsExt;
            let d = std::env::temp_dir().join(format!("lf-gui-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&d);
            std::fs::create_dir_all(&d).unwrap();
            let store = d.join("store.json");
            std::fs::write(&store, config).unwrap();
            std::fs::set_permissions(&store, std::fs::Permissions::from_mode(0o444)).unwrap();
            std::os::unix::fs::symlink(&store, d.join("config.json")).unwrap();
            Dir(d)
        }
        fn config(&self) -> PathBuf {
            self.0.join("config.json")
        }
        fn settings(&self) -> Option<Value> {
            std::fs::read(self.0.join("settings.json"))
                .ok()
                .map(|b| serde_json::from_slice(&b).unwrap())
        }
        fn window(&self) -> Runtime<Settings> {
            let layers = Layers::load(&self.config(), Path::new("/d")).unwrap();
            let s = Settings::new(self.config(), "/d".into(), layers, None).unwrap();
            // Tall enough that nothing needs scrolling.
            let mut rt = Runtime::new(s, view, (560.0, 1400.0), Env::new(true, 1.0));
            rt.frame(0.0);
            rt
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn press(rt: &mut Runtime<Settings>, key: &str) {
        let (x, y) = rt.find(key).unwrap_or_else(|| panic!("no {key:?}"));
        rt.pointer_down(x, y);
        rt.pointer_up(x, y);
        for _ in 0..3 {
            rt.frame(1.0 / 60.0);
        }
    }

    #[test]
    fn a_toggle_is_a_draft_until_apply_writes_only_what_differs() {
        let d = Dir::new(
            "toggle",
            r#"{"version": 1, "press_enter": false, "key_delay_ms": 0}"#,
        );
        let mut rt = d.window();
        assert!(!rt.state.shown.press_enter);
        press(&mut rt, "switch-press_enter");
        assert!(rt.state.shown.press_enter && rt.state.dirty());
        assert_eq!(d.settings(), None, "nothing is written before Apply");
        assert!(
            rt.find("reset-press_enter").is_some(),
            "a changed setting can be reset"
        );

        press(&mut rt, "apply");
        assert_eq!(d.settings(), Some(json!({"press_enter": true})));
        assert_eq!(rt.state.status, Status::Applied);
        assert!(!rt.state.dirty());

        // Flipping it back to config.json's value drops the key.
        press(&mut rt, "switch-press_enter");
        assert!(rt.state.draft.is_empty() && rt.state.dirty());
        press(&mut rt, "apply");
        assert_eq!(d.settings(), None, "no settings left: the file is removed");
    }

    #[test]
    fn apply_picks_up_a_changed_config_file() {
        let d = Dir::new("rebase", r#"{"version": 1, "press_enter": false}"#);
        let mut rt = d.window();
        // A Home Manager switch replaces config.json while the window is open.
        std::fs::remove_file(d.config()).unwrap();
        std::fs::write(
            d.0.join("new-store.json"),
            r#"{"version": 1, "press_enter": true}"#,
        )
        .unwrap();
        std::os::unix::fs::symlink(d.0.join("new-store.json"), d.config()).unwrap();
        press(&mut rt, "switch-history");
        press(&mut rt, "apply");
        assert!(rt.state.shown.press_enter, "the new config.json shows");
        // Turning it off now is an override of the new value.
        press(&mut rt, "switch-press_enter");
        assert!(!rt.state.shown.press_enter && rt.state.dirty());
        press(&mut rt, "apply");
        assert_eq!(
            d.settings(),
            Some(json!({"history": true, "press_enter": false}))
        );
    }

    #[test]
    fn reset_and_discard_go_back() {
        let d = Dir::new("reset", r#"{"version": 1}"#);
        let mut rt = d.window();
        press(&mut rt, "switch-history");
        assert!(rt.state.shown.history);
        press(&mut rt, "reset-history");
        assert!(!rt.state.shown.history && !rt.state.dirty());

        press(&mut rt, "switch-pause_media");
        press(&mut rt, "discard");
        assert!(rt.state.shown.pause_media && rt.state.draft.is_empty());
        assert_eq!(d.settings(), None);
    }

    #[test]
    fn invalid_text_keeps_apply_disabled_and_names_the_key() {
        let d = Dir::new("invalid", r#"{"version": 1}"#);
        let mut rt = d.window();
        rt.update(|s, _| s.set("prompt_tag", Value::String("x".repeat(65))));
        rt.frame(1.0 / 60.0);
        assert!(rt.find("error").is_some(), "the error is shown");
        let e = rt.state.config.clone().unwrap_err();
        assert!(e.contains("prompt_tag") && !e.contains("xxxx"), "{e}");
        press(&mut rt, "apply");
        assert_eq!(d.settings(), None);
        // The controls keep the last valid configuration.
        assert_eq!(rt.state.shown.prompt_tag, "[dictated]");
    }

    #[test]
    fn existing_settings_show_and_macros_round_trip() {
        let d = Dir::new(
            "macros",
            r#"{"version": 1, "voice_macros": [{"command": "sign off", "payload": "Synthetic regards"}]}"#,
        );
        let mut rt = d.window();
        assert_eq!(rt.state.macros.len(), 1);
        press(&mut rt, "add-macro");
        assert_eq!(rt.state.macros.len(), 2);
        rt.update(|s, _| {
            s.macros[1].0 = TextEdit::new("synthetic hello");
            s.macros[1].1 = TextEdit::new("Hello there");
            s.sync_macros();
        });
        rt.frame(1.0 / 60.0);
        press(&mut rt, "apply");
        assert_eq!(
            d.settings(),
            Some(json!({"voice_macros": [
                {"command": "sign off", "payload": "Synthetic regards"},
                {"command": "synthetic hello", "payload": "Hello there"}
            ]}))
        );
        // A new window shows what was applied.
        let rt = d.window();
        assert_eq!(rt.state.macros.len(), 2);
        assert!(rt.find("reset-voice_macros").is_some());
    }

    #[test]
    fn picking_a_segment_sets_its_value() {
        let d = Dir::new("segments", r#"{"version": 1}"#);
        let mut rt = d.window();
        rt.update(|s, _| {
            s.set("key_delay_ms", json!(5));
            s.set("picker", json!("gui"));
        });
        rt.frame(1.0 / 60.0);
        press(&mut rt, "apply");
        assert_eq!(
            d.settings(),
            Some(json!({"key_delay_ms": 5, "picker": "gui"}))
        );
    }
}

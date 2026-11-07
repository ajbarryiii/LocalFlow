//! The settings window (`localflow-gui`, or `localflow-gui settings`).
//!
//! - It shows the configuration `config.json` and `settings.json` make
//!   together (`lf_daemon::config::Layers`).
//! - A change is a draft until **Apply**, which writes `settings.json` (only
//!   the keys that differ from `config.json`) and restarts the daemon when a
//!   key it reads changed. **Discard** drops the draft.
//! - A setting whose draft differs from what is saved has a glacier dot
//!   beside its label. A setting the window changed has a reset icon, which
//!   takes it back to `config.json`'s value (or the default).
//! - A text field whose value makes an invalid configuration is marked, with
//!   a few plain words under it (never the value), and Apply stays disabled.
//! - If Apply saved the settings but the daemon did not restart, the footer
//!   says so until a restart works: with Retry when the restart failed, or
//!   asking for a restart by hand when the daemon runs outside its user
//!   unit (which `try-restart` would silently skip). Later changes keep the
//!   warning, and their Apply restarts the daemon whatever the keys.
//! - Clicking anywhere on a switch's row flips the switch.
//! - Escape closes the window. With changes not yet applied it asks first;
//!   a second Escape closes without applying them.

use std::path::PathBuf;

use lf_daemon::config::{Config, Layers, write_settings};
use rune::tok::space;
use rune::{Cx, El, Icon, Key, KeyEvent, Mods, ScrollSpec, TextEdit, Tx, col, el, icon, row, text};
use rune_kit::{
    Button, IconButton, IconButtonVariant, Kit, SegmentedControl, Select, SelectAppearance, Switch,
    TextInput,
};
use serde_json::{Map, Value, json};

use crate::look;

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

/// How Apply reaches the daemon: [`Daemon::SYSTEM`] in the app, stand-ins in
/// tests.
#[derive(Clone, Copy)]
pub struct Daemon {
    /// Whether it runs as the active user unit.
    pub unit_active: fn() -> bool,
    /// Restarts the user unit.
    pub restart_unit: fn() -> Result<(), String>,
    /// Whether a daemon answers on the control socket.
    pub answers: fn() -> bool,
}

/// What restarting the daemon over saved settings did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Restarted {
    /// It restarted, or none runs (it reads the settings when it starts).
    Done,
    /// It runs outside its user unit, so only its user can restart it.
    Manual,
    /// The restart failed (why).
    Failed(String),
}

impl Daemon {
    pub const SYSTEM: Daemon = Daemon {
        unit_active,
        restart_unit,
        answers,
    };

    /// Restarts the daemon if it runs as the user unit. `try-restart` alone
    /// would succeed and do nothing for one started some other way.
    pub fn restart(&self) -> Restarted {
        if (self.unit_active)() {
            match (self.restart_unit)() {
                Ok(()) => Restarted::Done,
                Err(e) => Restarted::Failed(e),
            }
        } else if (self.answers)() {
            Restarted::Manual
        } else {
            Restarted::Done
        }
    }
}

/// Saved settings the daemon does not run yet.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Pending {
    /// The restart failed (why, for the footer's tooltip).
    Failed(String),
    /// The daemon runs outside its user unit.
    Manual,
}

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
    /// What the last Apply did.
    pub status: Status,
    /// A restart the saved settings still need, kept until one works.
    pub pending: Option<Pending>,
    /// `None`: no daemon to restart.
    pub daemon: Option<Daemon>,
    /// Escape was pressed with changes not applied: the footer asks.
    pub asking_to_close: bool,
    /// The window quit.
    pub closed: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Status {
    Idle,
    /// Saved (and restarted, unless [`Settings::pending`] says otherwise).
    Applied,
    /// Nothing was saved.
    Failed(String),
}

/// A text field whose value is invalid.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Spot {
    PromptTag,
    Microphone,
    /// A voice macro's row; `payload` for its "Type" field, else "Say".
    Macro {
        row: usize,
        payload: bool,
    },
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
        daemon: Option<Daemon>,
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
            pending: None,
            daemon,
            asking_to_close: false,
            closed: false,
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
        self.asking_to_close = false;
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

    /// Closes the window, unless changes are not applied and the window has
    /// not asked yet: then it asks.
    pub fn close(&mut self, tx: &mut Tx) {
        if self.dirty() && !self.asking_to_close {
            self.asking_to_close = true;
            return;
        }
        self.closed = true;
        tx.quit();
    }

    /// Writes the draft and restarts the daemon if a key it reads changed,
    /// or if earlier saved settings still wait for a restart.
    pub fn apply(&mut self) {
        self.asking_to_close = false;
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
                if daemon_reads || self.pending.is_some() {
                    self.restart_daemon();
                }
            }
            Err(e) => self.status = Status::Failed(e),
        }
    }

    /// Restarts the daemon over saved settings; until that works, the
    /// restart stays pending. Also the restart-failed footer's Retry.
    pub fn restart_daemon(&mut self) {
        self.status = Status::Applied;
        self.pending = match self.daemon.map_or(Restarted::Done, |d| d.restart()) {
            Restarted::Done => None,
            Restarted::Manual => Some(Pending::Manual),
            Restarted::Failed(e) => Some(Pending::Failed(e)),
        };
    }

    /// Whether `key`'s draft differs from what is saved.
    pub fn unapplied(&self, key: &str) -> bool {
        self.draft.get(key) != self.layers.settings.get(key)
    }

    /// The text field that makes the draft invalid, and what to do about it
    /// in a few plain words (never its value).
    pub fn problem(&self) -> Option<(Spot, &'static str)> {
        let e = self.config.as_ref().err()?;
        let breaks = |t: &str| t.chars().any(char::is_control);
        if e.starts_with("prompt_tag") {
            let fix = if breaks(&self.prompt_tag.text) {
                "No tabs or line breaks"
            } else {
                "Use 64 characters or fewer"
            };
            return Some((Spot::PromptTag, fix));
        }
        if e.starts_with("input_device") {
            let fix = if breaks(&self.input_device.text) {
                "No tabs or line breaks"
            } else {
                "Use a shorter name"
            };
            return Some((Spot::Microphone, fix));
        }
        // `voice_macros[<i>].<field> ...`, counting only the rows that have
        // something to say (see `sync_macros`).
        let rest = e.strip_prefix("voice_macros[")?;
        let (i, rest) = rest.split_once(']')?;
        let row = self
            .macros
            .iter()
            .enumerate()
            .filter(|(_, (c, _))| !c.text.trim().is_empty())
            .nth(i.parse().ok()?)?
            .0;
        let payload = rest.starts_with(".payload");
        let fix = if rest.contains("never match") {
            "Use words, not just punctuation"
        } else {
            "Use shorter text"
        };
        Some((Spot::Macro { row, payload }, fix))
    }

    /// The plain words for `spot`, when it is the invalid field.
    fn problem_at(&self, spot: Spot) -> Option<&'static str> {
        self.problem()
            .filter(|(s, _)| *s == spot)
            .map(|(_, fix)| fix)
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

/// The window's keys: Escape closes (see [`Settings::close`]). Holding it
/// does nothing more, so the question it may raise needs a second press.
pub fn key(s: &mut Settings, e: &KeyEvent, tx: &mut Tx) -> bool {
    if e.key == Key::Escape && e.mods == Mods::default() {
        if !tx.key_repeat() {
            s.close(tx);
        }
        return true;
    }
    false
}

/// `systemctl --user` with `args`, quietly: whether it succeeded.
fn systemctl(args: &[&str]) -> Result<bool, String> {
    use std::process::{Command, Stdio};
    Command::new("systemctl")
        .arg("--user")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .map_err(|e| format!("could not run systemctl: {e}"))
}

/// Whether `localflowd.service` is the active user unit (no systemctl:
/// it is not).
fn unit_active() -> bool {
    systemctl(&["--quiet", "is-active", "localflowd.service"]).unwrap_or(false)
}

/// `systemctl --user try-restart localflowd.service`. It returns in about
/// 20 ms (the daemon stops at once; systemd does not wait for the model to
/// load), so Apply needs no "applying" state.
fn restart_unit() -> Result<(), String> {
    if systemctl(&["try-restart", "localflowd.service"])? {
        Ok(())
    } else {
        Err("could not restart the daemon (systemctl --user try-restart localflowd)".into())
    }
}

/// Whether this user's daemon answers a `status` request on the control
/// socket within half a second.
fn answers() -> bool {
    use lf_daemon::protocol::{ClientReply, Command, MAX_LINE, Request, parse_reply, request_line};
    use std::io::{BufRead, BufReader, Read, Write};
    use std::os::unix::net::UnixStream;

    let Ok(path) = lf_daemon::paths::socket_path_for_client() else {
        return false;
    };
    let Ok(mut stream) = UnixStream::connect(path) else {
        return false;
    };
    let wait = Some(std::time::Duration::from_millis(500));
    let mine = lf_daemon::server::peer_uid(&stream).ok() == Some(lf_daemon::paths::euid());
    if !mine
        || stream.set_read_timeout(wait).is_err()
        || stream.set_write_timeout(wait).is_err()
        || stream
            .write_all(request_line(&Request::new(Command::Status)).as_bytes())
            .is_err()
    {
        return false;
    }
    let mut line = Vec::new();
    let read = BufReader::new(stream.take(MAX_LINE as u64)).read_until(b'\n', &mut line);
    read.is_ok()
        && line.pop() == Some(b'\n')
        && matches!(parse_reply(&line), Some(ClientReply::Ok(_)))
}

/// A labelled row: the label, a glacier dot while its draft is not applied,
/// a reset icon when the window changed the key, and the control.
fn setting(k: &Kit, s: &Settings, key: &'static str, label: &str, control: El) -> El {
    let mut left = row().key("left").gap(space::S2).center_y().grow(1.0).child(
        text(label.to_owned())
            .key("label")
            .font(k.ty.ui)
            .color(k.c.text_base)
            .a11y_hidden(),
    );
    if s.unapplied(key) {
        left = left.child(look::dot(look::glacier()).key(format!("unapplied-{key}")));
    }
    if s.draft.contains_key(key) {
        left = left.child(reset(k, key, label));
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

/// Takes `key` back to `config.json`'s value.
fn reset(k: &Kit, key: &'static str, label: &str) -> El {
    IconButton::new(&RESET)
        .variant(IconButtonVariant::GhostMuted)
        .label(format!("Reset {label}"))
        .help("Back to default")
        .on_press(move |s: &mut Settings| s.reset(key))
        .build(k)
        .key(format!("reset-{key}"))
}

/// A switch's row: a click anywhere on it flips the switch, which stays the
/// row's only focus stop.
fn toggle(k: &Kit, s: &Settings, key: &'static str, label: &str, on: bool) -> El {
    let control = Switch::new(on)
        .label(label.to_owned())
        .hide_label()
        .on_toggle(move |s: &mut Settings| s.set(key, Value::Bool(!on)))
        .build(k)
        .key(format!("switch-{key}"));
    setting(k, s, key, label, control)
        .on_press(move |s: &mut Settings| s.set(key, Value::Bool(!on)))
        .role("group")
}

/// A text field's `row` with `fix` under its field, when its value is the
/// invalid one. The label stays on the field's line.
fn with_fix(k: &Kit, row: El, key: &str, fix: Option<&'static str>) -> El {
    let Some(fix) = fix else { return row };
    col().child(row).child(
        text(fix)
            .key(format!("error-{key}"))
            .font(k.ty.small)
            .color(k.c.danger.fg)
            .self_end()
            .px(space::S3)
            .pb(space::S2),
    )
}

fn card(k: &Kit, key: &str, title: &str, unapplied: bool, rows: Vec<El>) -> El {
    let mut body = col()
        .key("card")
        .padding(space::S1)
        .fill(k.c.layer_01)
        .radius(12.0)
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
                    .fill(k.c.border_muted)
                    .a11y_hidden(),
            );
        }
    }
    let mut header = row()
        .key("header")
        .gap(space::S2)
        .center_y()
        .ml(space::S3)
        .child(
            text(title.to_owned())
                .font(k.ty.small_medium)
                .color(k.c.text_muted),
        );
    if unapplied {
        header = header.child(look::dot(look::glacier()).key(format!("unapplied-{key}")));
    }
    col()
        .key(key.to_owned())
        .gap(space::S2)
        .child(header)
        .child(body)
}

/// A menu for `key`: `options` are labels and values, a `None` value
/// takes the key back to `config.json`'s. `Settings::open` names the open
/// menu.
fn menu(
    k: &Kit,
    s: &Settings,
    key: &'static str,
    label: &str,
    options: &'static [(&'static str, Option<&'static str>)],
    current: Option<&str>,
    layer: &mut Vec<El>,
) -> El {
    let labels: Vec<&str> = options.iter().map(|(l, _)| *l).collect();
    let now = options.iter().find(|(_, v)| *v == current).map(|(l, _)| *l);
    Select::new(format!("{key}-select"), &labels)
        .appearance(SelectAppearance::Field)
        .current(now)
        .label(label.to_owned())
        .width(FIELD_WIDTH)
        .open(s.open == Some(key))
        .on_toggle(move |s: &mut Settings| s.open = if s.open.is_some() { None } else { Some(key) })
        .on_close(|s: &mut Settings| s.open = None)
        .on_choose(move |s: &mut Settings, v: &str, _: &mut Tx| {
            s.open = None;
            match options.iter().find(|(l, _)| *l == v) {
                Some((_, Some(value))) => s.set(key, json!(value)),
                Some((_, None)) => s.reset(key),
                None => {}
            }
        })
        .build(k, layer)
}

/// Text fields and menus share one width, so their edges line up.
const FIELD_WIDTH: f32 = 200.0;

/// `precision`'s values, from the fastest (README, `precision`), named for
/// speed alone. "Auto" is the model's own (no `precision` key): i8x1 for
/// 1-bit models, i8x2 for ternary ones.
const SPEED: [(&str, Option<&str>); 5] = [
    ("Auto", None),
    ("Fastest", Some("i8x1")),
    ("Fast", Some("i8x2")),
    ("Slow", Some("i8x3")),
    ("Slowest", Some("f32")),
];

/// `output`'s values.
const OUTPUT: [(&str, Option<&str>); 4] = [
    ("Auto", Some("auto")),
    ("Wayland", Some("wayland")),
    ("Desktop portal", Some("portal")),
    ("Kernel device", Some("uinput")),
];

const PICKERS: [(&str, Option<&str>); 6] = [
    ("Auto", Some("auto")),
    ("LocalFlow", Some("gui")),
    ("rofi", Some("rofi")),
    ("fuzzel", Some("fuzzel")),
    ("wofi", Some("wofi")),
    ("tofi", Some("tofi")),
];

pub fn view(s: &Settings, _cx: &mut Cx<Settings>) -> El {
    let k = look::kit();
    let seg = look::segments(&k);
    let fields = look::fields(&k);
    let c = &s.shown;
    let mut layer = Vec::new();

    let dictation = card(
        &k,
        "dictation",
        "Dictation",
        false,
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

    let tag_fix = s.problem_at(Spot::PromptTag);
    let tag = TextInput::new(&s.prompt_tag)
        .label("Prompt tag")
        .placeholder("Untagged")
        .width(Some(FIELD_WIDTH))
        .invalid(tag_fix.is_some())
        .on_edit(|s: &mut Settings| &mut s.prompt_tag)
        .on_change(|s: &mut Settings, _: &mut Tx| {
            let v = s.prompt_tag.text.clone();
            s.set("prompt_tag", Value::String(v));
        })
        .build(&fields)
        .key("prompt-tag-field");
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
        .build(&seg)
        .key("choice-double_tap_ms");
    let prompt = card(
        &k,
        "prompt",
        "Hold to prompt",
        false,
        vec![
            setting(&k, s, "double_tap_ms", "Double-tap and hold", tap),
            with_fix(
                &k,
                setting(&k, s, "prompt_tag", "Prompt tag", tag),
                "prompt_tag",
                tag_fix,
            ),
        ],
    );

    let output = menu(
        &k,
        s,
        "output",
        "Type with",
        &OUTPUT,
        Some(output_name(c)),
        &mut layer,
    );
    static DELAY: [(&str, u64); 4] = [("0 ms", 0), ("1 ms", 1), ("5 ms", 5), ("10 ms", 10)];
    let delay_labels: Vec<&str> = DELAY.iter().map(|(l, _)| *l).collect();
    let delay = SegmentedControl::new(
        &delay_labels,
        DELAY.iter().position(|(_, v)| *v == c.key_delay_ms),
    )
    .label("Pause between keys")
    .fit()
    .on_pick(|s: &mut Settings, i: usize, _: &mut Tx| s.set("key_delay_ms", json!(DELAY[i].1)))
    .build(&seg)
    .key("choice-key_delay_ms");
    let picker = menu(
        &k,
        s,
        "picker",
        "Correction dialogs",
        &PICKERS,
        Some(picker_name(c)),
        &mut layer,
    );
    let typing = card(
        &k,
        "typing",
        "Typing",
        false,
        vec![
            setting(&k, s, "output", "Type with", output),
            setting(&k, s, "key_delay_ms", "Pause between keys", delay),
            setting(&k, s, "picker", "Correction dialogs", picker),
        ],
    );

    let precision = c.precision.map(|p| p.name());
    let speed = menu(
        &k,
        s,
        "precision",
        "Speed",
        &SPEED,
        precision.as_deref(),
        &mut layer,
    );
    let mic_fix = s.problem_at(Spot::Microphone);
    let device = TextInput::new(&s.input_device)
        .label("Microphone")
        .placeholder("Default")
        .width(Some(FIELD_WIDTH))
        .invalid(mic_fix.is_some())
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
        .build(&fields)
        .key("microphone-field");
    let recognition = card(
        &k,
        "recognition",
        "Recognition",
        false,
        vec![
            setting(&k, s, "precision", "Speed", speed),
            with_fix(
                &k,
                setting(&k, s, "input_device", "Microphone", device),
                "input_device",
                mic_fix,
            ),
        ],
    );

    let mut macro_rows = Vec::new();
    for i in 0..s.macros.len() {
        let fix = |payload| s.problem_at(Spot::Macro { row: i, payload });
        let (say_fix, type_fix) = (fix(false), fix(true));
        let command = TextInput::new(&s.macros[i].0)
            .label("Say")
            .placeholder("Say")
            .width(Some(150.0))
            .invalid(say_fix.is_some())
            .on_edit(move |s: &mut Settings| &mut s.macros[i].0)
            .on_change(|s: &mut Settings, _: &mut Tx| s.sync_macros())
            .build(&fields);
        let payload = TextInput::new(&s.macros[i].1)
            .label("Type")
            .placeholder("Type")
            .width(None)
            .invalid(type_fix.is_some())
            .on_edit(move |s: &mut Settings| &mut s.macros[i].1)
            .on_change(|s: &mut Settings, _: &mut Tx| s.sync_macros())
            .build(&fields)
            .grow(1.0);
        let remove = IconButton::new(&REMOVE)
            .variant(IconButtonVariant::GhostMuted)
            .label("Remove macro")
            .on_press(move |s: &mut Settings| {
                s.macros.remove(i);
                s.sync_macros();
            })
            .build(&k);
        let fields = row()
            .key("fields")
            .gap(space::S2)
            .center_y()
            .child(command)
            .child(icon(&rune_kit::glyphs::ARROW_RIGHT, 14.0).color(k.c.text_muted))
            .child(payload)
            .child(remove);
        let mut item = col()
            .key(format!("macro-{i}"))
            .px(space::S3)
            .py(6.0)
            .gap(space::S1)
            .child(fields);
        if let Some(fix) = say_fix.or(type_fix) {
            item = item.child(
                text(fix)
                    .key(format!("error-macro-{i}"))
                    .font(k.ty.small)
                    .color(k.c.danger.fg)
                    // Under the field it is about.
                    .ml(if say_fix.is_some() {
                        0.0
                    } else {
                        150.0 + 2.0 * space::S2 + 14.0
                    }),
            );
        }
        macro_rows.push(item);
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
        add_row = add_row.child(reset(&k, "voice_macros", "voice macros"));
    }
    macro_rows.push(add_row);
    let macros = card(
        &k,
        "voice_macros",
        "Voice macros",
        s.unapplied("voice_macros"),
        macro_rows,
    );

    let content = col()
        .key("content")
        .w_full()
        .px(space::S6)
        .pt(16.0)
        .pb(space::S6)
        .gap(20.0)
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
    if s.asking_to_close {
        footer = footer
            .child(
                text("Close without applying?")
                    .key("asking")
                    .font(k.ty.ui)
                    .color(k.c.text_base)
                    .grow(1.0)
                    .shrink(),
            )
            .child(
                look::secondary(
                    &k,
                    Button::new("Keep editing")
                        .on_press(|s: &mut Settings| s.asking_to_close = false),
                )
                .key("keep-editing"),
            )
            .child(
                look::primary(
                    &k,
                    Button::new("Close").on_press_tx(|s: &mut Settings, tx: &mut Tx| s.close(tx)),
                )
                .key("close-anyway"),
            );
        return page(&k, content, footer, layer);
    }
    let note = |key: &'static str, words: String, color: rune::Color| {
        text(words)
            .key(key)
            .font(k.ty.ui)
            .color(color)
            .grow(1.0)
            .shrink()
            .truncate()
    };
    // A restart the saved settings still need stays in the footer until
    // one works, whatever else changes (only a failed save goes first).
    let pending = match &s.pending {
        _ if matches!(s.status, Status::Failed(_)) => None,
        Some(Pending::Failed(why)) => Some((
            "restart-failed",
            if s.dirty() {
                "LocalFlow didn\u{2019}t restart."
            } else {
                "Saved. LocalFlow didn\u{2019}t restart."
            },
            why.clone(),
        )),
        Some(Pending::Manual) => Some((
            "restart-manual",
            if s.dirty() {
                "LocalFlow needs a restart."
            } else {
                "Saved. Restart LocalFlow to use it."
            },
            "LocalFlow doesn\u{2019}t run as its systemd service, so this window can\u{2019}t restart it."
                .to_owned(),
        )),
        None => None,
    };
    if let Some((key, words, why)) = pending {
        footer = footer
            .child(look::dot(look::ember()).key(key))
            .child(note("restart-note", words.into(), k.c.text_base).help(why));
        // Saved, with nothing left to apply: the restart is the one thing
        // to do (Apply restarts too, once there are changes).
        if !s.dirty() {
            if matches!(s.pending, Some(Pending::Failed(_))) {
                footer = footer.child(
                    look::primary(
                        &k,
                        Button::new("Retry").on_press(|s: &mut Settings| s.restart_daemon()),
                    )
                    .key("retry"),
                );
            }
            return page(&k, content, footer, layer);
        }
    } else {
        footer = feedback(&k, s, footer, note);
    }
    let can_apply = s.dirty() && s.config.is_ok();
    footer = footer
        .child(
            look::secondary(
                &k,
                Button::new("Discard")
                    .disabled(!s.dirty())
                    .on_press(|s: &mut Settings| s.discard()),
            )
            .key("discard"),
        )
        .child(
            look::primary(
                &k,
                Button::new("Apply")
                    .disabled(!can_apply)
                    .on_press(|s: &mut Settings| s.apply()),
            )
            .key("apply"),
        );
    page(&k, content, footer, layer)
}

/// The footer's left side without a pending restart: what to fix, a failed
/// save, or the check after Apply.
fn feedback(
    k: &Kit,
    s: &Settings,
    footer: El,
    note: impl Fn(&'static str, String, rune::Color) -> El,
) -> El {
    match (&s.config, &s.status) {
        (Err(e), _) => {
            let words = match s.problem() {
                Some((Spot::PromptTag, _)) => "Fix the prompt tag to apply".to_owned(),
                Some((Spot::Microphone, _)) => "Fix the microphone to apply".to_owned(),
                Some((Spot::Macro { row, .. }, _)) => {
                    format!("Fix voice macro {} to apply", row + 1)
                }
                None => e.clone(),
            };
            footer.child(note("error", words, k.c.danger.fg))
        }
        (_, Status::Failed(e)) => footer.child(note("error", e.clone(), k.c.danger.fg)),
        (_, Status::Applied) => footer
            .child(icon(&CHECK, 16.0).key("applied").color(k.c.success.icon))
            .child(el().grow(1.0)),
        _ => footer.child(el().grow(1.0)),
    }
}

/// The scrolling settings over the footer.
fn page(k: &Kit, content: El, footer: El, layer: Vec<El>) -> El {
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
    use rune::{Env, Key, KeyEvent, Mods, Runtime};
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
            self.window_with(None)
        }
        fn window_with(&self, daemon: Option<Daemon>) -> Runtime<Settings> {
            let layers = Layers::load(&self.config(), Path::new("/d")).unwrap();
            let s = Settings::new(self.config(), "/d".into(), layers, daemon).unwrap();
            // Tall enough that nothing needs scrolling.
            let mut rt = Runtime::new(s, view, (560.0, 1400.0), Env::new(true, 1.0));
            rt.on_key = Some(key);
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
    fn a_switch_row_flips_from_anywhere_on_it_once() {
        let d = Dir::new("row", r#"{"version": 1}"#);
        let mut rt = d.window();
        let off = rt.state.shown.history;
        // The row's middle, between its label and its switch.
        press(&mut rt, "history");
        assert_eq!(rt.state.shown.history, !off);
        // The switch itself flips it once, not once for it and once for
        // the row.
        press(&mut rt, "switch-history");
        assert_eq!(rt.state.shown.history, off);
        press(&mut rt, "switch-history");
        assert_eq!(rt.state.shown.history, !off);
        // The reset icon in the row only resets.
        press(&mut rt, "reset-history");
        assert_eq!(rt.state.shown.history, off);
        assert!(!rt.state.dirty());

        // The keyboard has one stop per row: the switch.
        let mut rt = d.window();
        let (enter, numbers) = (rt.state.shown.press_enter, rt.state.shown.spoken_numbers);
        for _ in 0..2 {
            rt.key(KeyEvent {
                key: Key::Tab,
                mods: Mods::default(),
            });
            rt.key(KeyEvent {
                key: Key::Text(" ".into()),
                mods: Mods::default(),
            });
            rt.frame(1.0 / 60.0);
        }
        assert_eq!(rt.state.shown.press_enter, !enter);
        assert_eq!(rt.state.shown.spoken_numbers, !numbers);
    }

    #[test]
    fn a_setting_not_applied_has_a_dot_until_apply() {
        let d = Dir::new("unapplied", r#"{"version": 1}"#);
        let mut rt = d.window();
        assert!(rt.find("unapplied-history").is_none());
        press(&mut rt, "switch-history");
        assert!(rt.find("unapplied-history").is_some());
        assert!(rt.find("unapplied-pause_media").is_none());
        press(&mut rt, "apply");
        // Saved: no dot, but it still differs from config.json.
        assert!(rt.find("unapplied-history").is_none());
        assert!(rt.find("reset-history").is_some());
        // Taking it back is a change not applied yet, too.
        press(&mut rt, "reset-history");
        assert!(rt.find("unapplied-history").is_some());
        press(&mut rt, "discard");
        assert!(rt.find("unapplied-history").is_none());

        // Voice macros, on their card's title.
        press(&mut rt, "add-macro");
        assert!(
            rt.find("unapplied-voice_macros").is_none(),
            "an empty row is nothing yet"
        );
        rt.update(|s, _| {
            s.macros[0].0 = TextEdit::new("synthetic sign off");
            s.sync_macros();
        });
        rt.frame(1.0 / 60.0);
        assert!(rt.find("unapplied-voice_macros").is_some());
    }

    #[test]
    fn an_invalid_field_says_what_to_fix_under_it() {
        let d = Dir::new("fix", r#"{"version": 1}"#);
        let mut rt = d.window();
        let secret = "synthetic".repeat(8);
        rt.update(|s, _| {
            s.prompt_tag = TextEdit::new(secret.clone());
            s.set("prompt_tag", Value::String(secret.clone()));
        });
        rt.frame(1.0 / 60.0);
        assert_eq!(
            rt.state.problem(),
            Some((Spot::PromptTag, "Use 64 characters or fewer"))
        );
        assert!(rt.find("error-prompt_tag").is_some());
        assert!(rt.find("error-input_device").is_none());
        press(&mut rt, "apply");
        assert_eq!(d.settings(), None, "Apply stays disabled");
        // Fixed, the words go.
        rt.update(|s, _| {
            s.prompt_tag = TextEdit::new("[synthetic]");
            s.set("prompt_tag", json!("[synthetic]"));
        });
        rt.frame(1.0 / 60.0);
        assert_eq!(rt.state.problem(), None);
        assert!(rt.find("error-prompt_tag").is_none());

        let mut rt = d.window();
        rt.update(|s, _| {
            s.input_device = TextEdit::new("synthetic\tmic");
            s.set("input_device", json!("synthetic\tmic"));
        });
        rt.frame(1.0 / 60.0);
        assert_eq!(
            rt.state.problem(),
            Some((Spot::Microphone, "No tabs or line breaks"))
        );
        assert!(rt.find("error-input_device").is_some());

        // The second macro row, counting the empty first one, which is not
        // saved.
        let mut rt = d.window();
        rt.update(|s, _| {
            s.macros = vec![
                (TextEdit::default(), TextEdit::default()),
                (TextEdit::new("?!"), TextEdit::new("synthetic")),
            ];
            s.sync_macros();
        });
        rt.frame(1.0 / 60.0);
        assert_eq!(
            rt.state.problem(),
            Some((
                Spot::Macro {
                    row: 1,
                    payload: false
                },
                "Use words, not just punctuation"
            ))
        );
        assert!(rt.find("error-macro-1").is_some());
        assert!(rt.find("error-macro-0").is_none());
        let (_, fix) = rt.state.problem().unwrap();
        assert!(!fix.contains("synthetic") && !fix.contains("?!"));
    }

    thread_local! {
        /// Restarts of the user unit this test thread asked for.
        static RESTARTS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    }

    fn restarts() -> usize {
        RESTARTS.with(|n| n.get())
    }

    #[test]
    fn an_invalid_fields_label_stays_on_the_fields_line() {
        let d = Dir::new("invalid-line", r#"{"version": 1}"#);
        let mut rt = d.window();
        let centre = |rt: &Runtime<Settings>, key: &str| rt.find(key).unwrap().1;
        let before = centre(&rt, "prompt_tag/left/label");
        rt.update(|s, _| {
            s.prompt_tag = TextEdit::new("x".repeat(65));
            s.set("prompt_tag", Value::String("x".repeat(65)));
        });
        rt.frame(1.0 / 60.0);
        assert!(rt.find("error-prompt_tag").is_some());
        let (label, field) = (
            centre(&rt, "prompt_tag/left/label"),
            centre(&rt, "prompt-tag-field"),
        );
        assert!((label - field).abs() < 0.5, "label {label}, field {field}");
        assert!(
            (label - before).abs() < 0.5,
            "the label moved: {before} to {label}"
        );
    }

    #[test]
    fn the_speed_menu_goes_from_fastest_to_slowest() {
        let values: Vec<_> = SPEED.iter().map(|(_, v)| *v).collect();
        assert_eq!(
            values,
            [None, Some("i8x1"), Some("i8x2"), Some("i8x3"), Some("f32")]
        );
        assert_eq!(SPEED[0].0, "Auto");
        // Speed words only: nothing about accuracy.
        for (label, _) in SPEED {
            let l = label.to_lowercase();
            assert!(!l.contains("precis") && !l.contains("accura"), "{label}");
        }
    }

    fn restart_fails() -> Result<(), String> {
        RESTARTS.with(|n| n.set(n.get() + 1));
        Err("synthetic restart failure".into())
    }

    fn restart_works() -> Result<(), String> {
        RESTARTS.with(|n| n.set(n.get() + 1));
        Ok(())
    }

    fn yes() -> bool {
        true
    }

    fn no() -> bool {
        false
    }

    /// The user unit runs, and restarting it fails.
    const FAILING: Daemon = Daemon {
        unit_active: yes,
        restart_unit: restart_fails,
        answers: yes,
    };
    const WORKING: Daemon = Daemon {
        unit_active: yes,
        restart_unit: restart_works,
        answers: yes,
    };
    /// Started some other way (`exec-once`): the unit is not active, but the
    /// daemon answers on its socket.
    const OUTSIDE_SYSTEMD: Daemon = Daemon {
        unit_active: no,
        restart_unit: restart_works,
        answers: yes,
    };
    const NOT_RUNNING: Daemon = Daemon {
        unit_active: no,
        restart_unit: restart_works,
        answers: no,
    };

    #[test]
    fn a_restart_is_done_failed_or_left_to_the_user() {
        let before = restarts();
        assert_eq!(WORKING.restart(), Restarted::Done);
        assert!(matches!(FAILING.restart(), Restarted::Failed(_)));
        assert_eq!(restarts(), before + 2);
        // Not the user unit: try-restart would do nothing and succeed, so
        // it is not run.
        assert_eq!(OUTSIDE_SYSTEMD.restart(), Restarted::Manual);
        // Nothing running reads the settings when it starts.
        assert_eq!(NOT_RUNNING.restart(), Restarted::Done);
        assert_eq!(restarts(), before + 2);
    }

    #[test]
    fn a_failed_restart_keeps_the_save_and_offers_retry() {
        let d = Dir::new("restart", r#"{"version": 1}"#);
        let mut rt = d.window_with(Some(FAILING));
        press(&mut rt, "switch-history");
        press(&mut rt, "apply");
        assert_eq!(d.settings(), Some(json!({"history": true})), "saved");
        assert!(matches!(rt.state.pending, Some(Pending::Failed(_))));
        assert!(!rt.state.dirty());
        assert!(rt.find("restart-failed").is_some());
        assert!(rt.find("error").is_none(), "not shown as a failed save");
        assert!(rt.find("applied").is_none());

        // Retry runs the restart again: still failing, then working.
        press(&mut rt, "retry");
        assert!(matches!(rt.state.pending, Some(Pending::Failed(_))));
        rt.state.daemon = Some(WORKING);
        press(&mut rt, "retry");
        assert_eq!(rt.state.pending, None);
        assert_eq!(rt.state.status, Status::Applied);
        assert!(rt.find("retry").is_none());
        assert!(rt.find("restart-failed").is_none());
        assert!(rt.find("applied").is_some());
        assert_eq!(d.settings(), Some(json!({"history": true})));

        // A key the daemon does not read needs no restart.
        let mut rt = d.window_with(Some(FAILING));
        let before = restarts();
        rt.update(|s, _| s.set("picker", json!("gui")));
        rt.frame(1.0 / 60.0);
        press(&mut rt, "apply");
        assert_eq!(rt.state.status, Status::Applied);
        assert_eq!(rt.state.pending, None);
        assert_eq!(restarts(), before);
    }

    #[test]
    fn a_failed_restart_stays_until_a_restart_works() {
        let d = Dir::new("pending", r#"{"version": 1}"#);
        let mut rt = d.window_with(Some(FAILING));
        press(&mut rt, "switch-history");
        press(&mut rt, "apply");
        assert!(rt.find("restart-failed").is_some());

        // Another change keeps the warning; Apply, which restarts too,
        // takes Retry's place.
        press(&mut rt, "switch-pause_media");
        assert!(rt.find("restart-failed").is_some());
        assert!(rt.find("retry").is_none());
        assert!(rt.find("apply").is_some());
        // So does Discard, which brings Retry back.
        press(&mut rt, "discard");
        assert!(rt.find("restart-failed").is_some());
        assert!(rt.find("retry").is_some());
        // And an invalid value.
        rt.update(|s, _| s.set("prompt_tag", Value::String("x".repeat(65))));
        rt.frame(1.0 / 60.0);
        assert!(rt.find("restart-failed").is_some());
        press(&mut rt, "discard");

        // Applying a key the daemon does not read still retries the restart
        // the saved settings need.
        let before = restarts();
        rt.update(|s, _| s.set("picker", json!("gui")));
        rt.frame(1.0 / 60.0);
        press(&mut rt, "apply");
        assert_eq!(restarts(), before + 1);
        assert_eq!(
            d.settings(),
            Some(json!({"history": true, "picker": "gui"}))
        );
        assert!(matches!(rt.state.pending, Some(Pending::Failed(_))));
        assert!(rt.find("restart-failed").is_some());
        assert!(rt.find("applied").is_none());

        // Once a restart works, the warning goes.
        rt.state.daemon = Some(WORKING);
        press(&mut rt, "switch-pause_media");
        press(&mut rt, "apply");
        assert_eq!(rt.state.pending, None);
        assert!(rt.find("restart-failed").is_none());
        assert!(rt.find("applied").is_some());
    }

    #[test]
    fn a_daemon_started_outside_systemd_needs_a_restart_by_hand() {
        let d = Dir::new("manual", r#"{"version": 1}"#);
        let mut rt = d.window_with(Some(OUTSIDE_SYSTEMD));
        let before = restarts();
        press(&mut rt, "switch-history");
        press(&mut rt, "apply");
        assert_eq!(d.settings(), Some(json!({"history": true})), "saved");
        assert_eq!(restarts(), before, "try-restart would do nothing");
        assert_eq!(rt.state.pending, Some(Pending::Manual));
        assert!(rt.find("restart-manual").is_some());
        assert!(rt.find("applied").is_none(), "no claim it took effect");
        assert!(rt.find("error").is_none(), "not shown as a failed save");
        // The window cannot restart it: no Retry.
        assert!(rt.find("retry").is_none());
        // Still there after another change.
        press(&mut rt, "switch-pause_media");
        assert!(rt.find("restart-manual").is_some());
    }

    #[test]
    fn with_no_daemon_running_saving_is_enough() {
        let d = Dir::new("nodaemon", r#"{"version": 1}"#);
        let mut rt = d.window_with(Some(NOT_RUNNING));
        press(&mut rt, "switch-history");
        press(&mut rt, "apply");
        assert_eq!(d.settings(), Some(json!({"history": true})));
        assert_eq!(rt.state.pending, None);
        assert_eq!(rt.state.status, Status::Applied);
        assert!(rt.find("applied").is_some());
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

    fn escape(rt: &mut Runtime<Settings>) {
        rt.key(KeyEvent {
            key: Key::Escape,
            mods: Mods::default(),
        });
        for _ in 0..3 {
            rt.frame(1.0 / 60.0);
        }
    }

    #[test]
    fn escape_closes_a_window_with_nothing_to_apply() {
        let d = Dir::new("escape", r#"{"version": 1}"#);
        let mut rt = d.window();
        escape(&mut rt);
        assert!(rt.state.closed);

        // Also from a text field.
        let mut rt = d.window();
        press(&mut rt, "prompt-tag-field");
        escape(&mut rt);
        escape(&mut rt);
        assert!(rt.state.closed);

        // An open menu closes first.
        let mut rt = d.window();
        press(&mut rt, "picker-select-trigger");
        assert_eq!(rt.state.open, Some("picker"));
        escape(&mut rt);
        assert_eq!(rt.state.open, None);
        assert!(!rt.state.closed, "Escape only closed the menu");
        escape(&mut rt);
        assert!(rt.state.closed);
    }

    #[test]
    fn escape_with_unapplied_changes_asks_before_closing() {
        let d = Dir::new("escape-draft", r#"{"version": 1}"#);
        let mut rt = d.window();
        press(&mut rt, "switch-history");
        escape(&mut rt);
        assert!(!rt.state.closed, "the draft is not dropped yet");
        assert!(rt.find("close-anyway").is_some(), "the window asks");

        // Keep editing: the draft stays, and the question goes.
        press(&mut rt, "keep-editing");
        assert!(rt.state.dirty() && !rt.state.closed);
        assert!(rt.find("close-anyway").is_none());

        // Escape twice closes without writing anything.
        escape(&mut rt);
        escape(&mut rt);
        assert!(rt.state.closed);
        assert_eq!(d.settings(), None);

        // So does the close button.
        let mut rt = d.window();
        press(&mut rt, "switch-history");
        escape(&mut rt);
        press(&mut rt, "close-anyway");
        assert!(rt.state.closed);
        assert_eq!(d.settings(), None);

        // Holding Escape (auto-repeat) does not answer the question.
        let mut rt = d.window();
        press(&mut rt, "switch-history");
        escape(&mut rt);
        for _ in 0..5 {
            rt.repeat_key(KeyEvent {
                key: Key::Escape,
                mods: Mods::default(),
            });
            rt.frame(1.0 / 60.0);
        }
        assert!(!rt.state.closed && rt.state.dirty(), "still asking");
        assert!(rt.find("close-anyway").is_some());

        // A change after the question takes it back.
        let mut rt = d.window();
        press(&mut rt, "switch-history");
        escape(&mut rt);
        press(&mut rt, "switch-pause_media");
        assert!(rt.find("close-anyway").is_none());
        escape(&mut rt);
        assert!(!rt.state.closed, "asks again");
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

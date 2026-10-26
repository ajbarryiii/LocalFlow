//! `$XDG_CONFIG_HOME/localflow/config.json`. A missing file means defaults;
//! an invalid file stops the daemon. Error messages name fields, never their
//! values (macros are user content).

use std::path::{Path, PathBuf};

use lf_dictation::VoiceMacro;
use lf_keyboard::Rmlvo;
use serde_json::{Map, Value};

use crate::log::Level;

/// Largest accepted config file.
const MAX_CONFIG_BYTES: u64 = 1 << 20;
const MAX_MACROS: usize = 1000;
const MAX_MACRO_BYTES: usize = 4096;
/// `CPU_SETSIZE`: the most CPUs `sched_setaffinity` can address with a `cpu_set_t`.
pub const MAX_CPU: usize = 1024;
/// Longest recording the recognizer accepts.
pub const MAX_RECORDING_SECONDS: f64 = lf_asr::MAX_SECONDS as f64;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Precision {
    F32,
    Int8(u8),
}

impl Precision {
    pub fn parse(s: &str) -> Option<Precision> {
        Some(match s {
            "f32" => Precision::F32,
            "i8x1" => Precision::Int8(1),
            "i8x2" => Precision::Int8(2),
            "i8x3" => Precision::Int8(3),
            _ => return None,
        })
    }

    pub fn to_asr(self) -> lf_asr::Precision {
        match self {
            Precision::F32 => lf_asr::Precision::F32,
            Precision::Int8(n) => lf_asr::Precision::Int8(usize::from(n)),
        }
    }

    pub fn name(self) -> String {
        match self {
            Precision::F32 => "f32".into(),
            Precision::Int8(n) => format!("i8x{n}"),
        }
    }
}

/// How text is typed (`output`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Output {
    /// The Wayland virtual keyboard if the compositor offers it, else the
    /// RemoteDesktop portal, else uinput.
    Auto,
    /// The Wayland virtual keyboard (`zwp_virtual_keyboard_v1`, wlroots).
    Wayland,
    /// xdg-desktop-portal RemoteDesktop and libei (GNOME, KDE).
    Portal,
    /// A kernel uinput keyboard (anywhere, X11 included).
    Uinput,
}

impl Output {
    pub fn parse(s: &str) -> Option<Output> {
        Some(match s {
            "auto" => Output::Auto,
            "wayland" => Output::Wayland,
            "portal" => Output::Portal,
            "uinput" => Output::Uinput,
            _ => return None,
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Config {
    /// Directory holding `export.safetensors`, `manifest.json` and `tokenizer/`.
    pub export_path: PathBuf,
    pub precision: Precision,
    /// CPUs for the recognizer's pinned thread pool. `None`: one CPU per
    /// physical core the daemon may run on (SMT siblings skipped), whole L3
    /// domains largest first, at most 16 (`lf_asr::topology`).
    pub cpus: Option<Vec<usize>>,
    pub press_enter: bool,
    pub spoken_delimiters: bool,
    pub spoken_numbers: bool,
    pub voice_macros: Vec<VoiceMacro>,
    pub history: bool,
    /// Shorter recordings are discarded without transcription.
    pub min_recording_seconds: f64,
    /// Recording stops and transcribes automatically at this length.
    pub max_recording_seconds: f64,
    pub log_level: Level,
    /// PipeWire `node.name` to record from; `None` follows the default source.
    pub input_device: Option<String>,
    /// Pause after each typed key, in milliseconds (some apps drop fast input).
    pub key_delay_ms: u64,
    /// Pause playing media players (MPRIS) while recording.
    pub pause_media: bool,
    /// Put before prompt dictations (double-tap and hold); empty disables
    /// tagging.
    pub prompt_tag: String,
    /// A press this soon after a too-short hold makes a prompt recording;
    /// 0 disables double-tap.
    pub double_tap_ms: u64,
    /// The menu `localflowctl correct` and `dict review` use (the daemon
    /// ignores it).
    pub picker: crate::picker::Choice,
    /// Which text output types.
    pub output: Output,
    /// The XKB layout the desktop applies to typed keys, for the uinput
    /// output (and the portal when the desktop sends no keymap). Empty
    /// fields take libxkbcommon's defaults.
    pub keyboard_layout: Rmlvo,
    /// How the dictation key reaches the daemon.
    pub trigger: Trigger,
}

/// How the dictation key reaches the daemon.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Trigger {
    /// Desktop binds run `localflowctl press`, `release`, `toggle`.
    Commands,
    /// The daemon also binds shortcuts through the xdg-desktop-portal
    /// GlobalShortcuts interface (GNOME, KDE); `localflowctl` still works.
    Portal,
}

impl Trigger {
    pub fn parse(s: &str) -> Option<Trigger> {
        match s {
            "commands" => Some(Trigger::Commands),
            "portal" => Some(Trigger::Portal),
            _ => None,
        }
    }
}

/// Longest accepted `prompt_tag`, in characters.
pub const MAX_PROMPT_TAG_CHARS: usize = 64;
/// Accepted `double_tap_ms` range (besides 0).
pub const DOUBLE_TAP_MS: std::ops::RangeInclusive<u64> = 150..=1000;

/// Longest accepted `input_device` name.
const MAX_DEVICE_NAME: usize = 256;
/// Largest accepted `key_delay_ms`.
pub const MAX_KEY_DELAY_MS: u64 = 50;

impl Config {
    pub fn defaults(data_dir: &Path) -> Config {
        Config {
            export_path: data_dir.join("model"),
            precision: Precision::Int8(2),
            cpus: None,
            press_enter: true,
            spoken_delimiters: true,
            spoken_numbers: true,
            voice_macros: Vec::new(),
            history: false,
            min_recording_seconds: 0.3,
            max_recording_seconds: 300.0,
            log_level: Level::Info,
            input_device: None,
            key_delay_ms: 1,
            pause_media: true,
            prompt_tag: "[dictated]".into(),
            double_tap_ms: 400,
            picker: crate::picker::Choice::Auto,
            output: Output::Auto,
            keyboard_layout: Rmlvo::default(),
            trigger: Trigger::Commands,
        }
    }

    /// Reads `path`; a missing file yields the defaults.
    pub fn load(path: &Path, data_dir: &Path) -> Result<Config, String> {
        let meta = match std::fs::metadata(path) {
            Ok(m) => m,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Config::defaults(data_dir));
            }
            Err(e) => return Err(format!("config {}: {e}", path.display())),
        };
        if !meta.is_file() {
            return Err(format!("config {} is not a regular file", path.display()));
        }
        if meta.len() > MAX_CONFIG_BYTES {
            return Err(format!("config {} is larger than 1 MiB", path.display()));
        }
        let bytes = std::fs::read(path).map_err(|e| format!("config {}: {e}", path.display()))?;
        Config::parse(&bytes, data_dir).map_err(|e| format!("config {}: {e}", path.display()))
    }

    pub fn parse(bytes: &[u8], data_dir: &Path) -> Result<Config, String> {
        // serde_json errors quote no input, only line and column.
        let value: Value =
            serde_json::from_slice(bytes).map_err(|e| format!("invalid JSON: {e}"))?;
        let Value::Object(map) = value else {
            return Err("top level must be an object".into());
        };
        let mut c = Config::defaults(data_dir);
        for (key, v) in &map {
            match key.as_str() {
                "version" => {
                    if v.as_u64() != Some(1) {
                        return Err("version must be 1".into());
                    }
                }
                "export_path" => {
                    let s = v.as_str().ok_or("export_path must be a string")?;
                    let p = PathBuf::from(s);
                    if !p.is_absolute() {
                        return Err("export_path must be an absolute path".into());
                    }
                    c.export_path = p;
                }
                "precision" => {
                    c.precision = v
                        .as_str()
                        .and_then(Precision::parse)
                        .ok_or("precision must be one of f32, i8x1, i8x2, i8x3")?;
                }
                "cpus" => c.cpus = Some(parse_cpus(v)?),
                "press_enter" => c.press_enter = boolean(v, "press_enter")?,
                "spoken_delimiters" => c.spoken_delimiters = boolean(v, "spoken_delimiters")?,
                "spoken_numbers" => c.spoken_numbers = boolean(v, "spoken_numbers")?,
                "voice_macros" => c.voice_macros = parse_macros(v)?,
                "history" => c.history = boolean(v, "history")?,
                "pause_media" => c.pause_media = boolean(v, "pause_media")?,
                "min_recording_seconds" => {
                    c.min_recording_seconds = number(v, "min_recording_seconds")?;
                }
                "max_recording_seconds" => {
                    c.max_recording_seconds = number(v, "max_recording_seconds")?;
                }
                "log_level" => {
                    c.log_level = v
                        .as_str()
                        .and_then(Level::parse)
                        .ok_or("log_level must be one of error, warn, info, debug")?;
                }
                "input_device" => {
                    c.input_device = match v {
                        Value::Null => None,
                        Value::String(s)
                            if !s.is_empty()
                                && s.len() <= MAX_DEVICE_NAME
                                && !s.chars().any(char::is_control) =>
                        {
                            Some(s.clone())
                        }
                        _ => {
                            return Err(format!(
                                "input_device must be null or a PipeWire node name of 1-{MAX_DEVICE_NAME} bytes"
                            ));
                        }
                    };
                }
                "key_delay_ms" => {
                    c.key_delay_ms =
                        v.as_u64()
                            .filter(|&ms| ms <= MAX_KEY_DELAY_MS)
                            .ok_or_else(|| {
                                format!(
                                    "key_delay_ms must be an integer from 0 to {MAX_KEY_DELAY_MS}"
                                )
                            })?;
                }
                "prompt_tag" => {
                    // The error never quotes the value.
                    c.prompt_tag = v
                        .as_str()
                        .filter(|s| {
                            s.chars().count() <= MAX_PROMPT_TAG_CHARS
                                && !s.chars().any(|ch| {
                                    ch.is_control() || matches!(ch, '\u{2028}' | '\u{2029}')
                                })
                        })
                        .ok_or_else(|| {
                            format!(
                                "prompt_tag must be a string of at most {MAX_PROMPT_TAG_CHARS} \
                                 characters without control characters or newlines"
                            )
                        })?
                        .to_owned();
                }
                "double_tap_ms" => {
                    c.double_tap_ms = v
                        .as_u64()
                        .filter(|ms| *ms == 0 || DOUBLE_TAP_MS.contains(ms))
                        .ok_or_else(|| {
                            format!(
                                "double_tap_ms must be 0 (off) or an integer from {} to {}",
                                DOUBLE_TAP_MS.start(),
                                DOUBLE_TAP_MS.end()
                            )
                        })?;
                }
                "picker" => {
                    c.picker = v
                        .as_str()
                        .and_then(crate::picker::Choice::parse)
                        .ok_or_else(|| {
                            format!("picker must be one of {}", crate::picker::Choice::VALUES)
                        })?;
                }
                "output" => {
                    c.output = v
                        .as_str()
                        .and_then(Output::parse)
                        .ok_or("output must be one of auto, wayland, portal, uinput")?;
                }
                "keyboard_layout" => c.keyboard_layout = parse_layout(v)?,
                "trigger" => {
                    c.trigger = v
                        .as_str()
                        .and_then(Trigger::parse)
                        .ok_or("trigger must be one of commands, portal")?;
                }
                other => return Err(unknown_key(other)),
            }
        }
        if !(0.0..=10.0).contains(&c.min_recording_seconds) {
            return Err("min_recording_seconds must be between 0 and 10".into());
        }
        if !(1.0..=MAX_RECORDING_SECONDS).contains(&c.max_recording_seconds)
            || c.max_recording_seconds < c.min_recording_seconds
        {
            return Err(format!(
                "max_recording_seconds must be between 1 and {MAX_RECORDING_SECONDS} and at least min_recording_seconds"
            ));
        }
        Ok(c)
    }

    pub fn dictation_options(&self) -> lf_dictation::Options {
        lf_dictation::Options {
            press_enter: self.press_enter,
            spoken_delimiters: self.spoken_delimiters,
            spoken_numbers: self.spoken_numbers,
        }
    }
}

/// Never names the key: a misplaced macro (user content) could be one.
fn unknown_key(_key: &str) -> String {
    "unknown key; allowed keys are version, export_path, precision, cpus, press_enter, \
     spoken_delimiters, spoken_numbers, voice_macros, history, min_recording_seconds, \
     max_recording_seconds, log_level, input_device, key_delay_ms, pause_media, \
     prompt_tag, double_tap_ms, picker, output, keyboard_layout, trigger"
        .into()
}

/// Longest accepted `keyboard_layout` field.
const MAX_LAYOUT_FIELD: usize = 256;

/// `null`, or an object with any of `rules`, `model`, `layout`, `variant` and
/// `options` as strings. Errors name the field, never the value.
fn parse_layout(v: &Value) -> Result<Rmlvo, String> {
    let mut names = Rmlvo::default();
    let obj = match v {
        Value::Null => return Ok(names),
        Value::Object(obj) => obj,
        _ => return Err("keyboard_layout must be null or an object".into()),
    };
    for (key, value) in obj {
        let field = match key.as_str() {
            "rules" => &mut names.rules,
            "model" => &mut names.model,
            "layout" => &mut names.layout,
            "variant" => &mut names.variant,
            "options" => names.options.get_or_insert_with(String::new),
            _ => {
                return Err(
                    "keyboard_layout may only have rules, model, layout, variant and options"
                        .into(),
                );
            }
        };
        *field = value
            .as_str()
            .filter(|s| s.len() <= MAX_LAYOUT_FIELD && !s.chars().any(char::is_control))
            .ok_or_else(|| {
                format!(
                    "keyboard_layout.{key} must be a string of at most {MAX_LAYOUT_FIELD} bytes \
                     without control characters"
                )
            })?
            .to_owned();
    }
    Ok(names)
}

fn boolean(v: &Value, key: &str) -> Result<bool, String> {
    v.as_bool()
        .ok_or_else(|| format!("{key} must be true or false"))
}

fn number(v: &Value, key: &str) -> Result<f64, String> {
    v.as_f64()
        .filter(|x| x.is_finite())
        .ok_or_else(|| format!("{key} must be a number"))
}

/// An array of CPU numbers, or a list string such as "0-7,16-23".
fn parse_cpus(v: &Value) -> Result<Vec<usize>, String> {
    let mut cpus = Vec::new();
    match v {
        Value::Array(items) => {
            if items.len() > MAX_CPU {
                return Err("cpus: too many entries".into());
            }
            for item in items {
                let cpu = item
                    .as_u64()
                    .and_then(|n| usize::try_from(n).ok())
                    .ok_or("cpus must contain non-negative integers")?;
                cpus.push(cpu);
            }
        }
        Value::String(s) => cpus = parse_cpu_list(s)?,
        _ => return Err("cpus must be an array or a list string like \"0-15\"".into()),
    }
    if cpus.is_empty() {
        return Err("cpus must not be empty".into());
    }
    if let Some(&bad) = cpus.iter().find(|&&c| c >= MAX_CPU) {
        return Err(format!("cpus: CPU {bad} is out of range"));
    }
    let mut sorted = cpus.clone();
    sorted.sort_unstable();
    if sorted.windows(2).any(|w| w[0] == w[1]) {
        return Err("cpus must not repeat a CPU".into());
    }
    Ok(cpus)
}

pub fn parse_cpu_list(s: &str) -> Result<Vec<usize>, String> {
    let bad = || "cpus: invalid CPU list (expected e.g. \"0-7,16\")".to_string();
    let mut cpus = Vec::new();
    for part in s.split(',') {
        let part = part.trim();
        let num = |t: &str| -> Result<usize, String> {
            if t.is_empty() || !t.bytes().all(|b| b.is_ascii_digit()) || t.len() > 4 {
                return Err(bad());
            }
            t.parse().map_err(|_| bad())
        };
        match part.split_once('-') {
            Some((a, b)) => {
                let (a, b) = (num(a)?, num(b)?);
                if a > b || b >= MAX_CPU {
                    return Err(bad());
                }
                cpus.extend(a..=b);
            }
            None => cpus.push(num(part)?),
        }
        // Repeated ranges could otherwise expand without bound; duplicates
        // are rejected later anyway.
        if cpus.len() > MAX_CPU {
            return Err("cpus: too many entries".into());
        }
    }
    Ok(cpus)
}

fn parse_macros(v: &Value) -> Result<Vec<VoiceMacro>, String> {
    let items = v.as_array().ok_or("voice_macros must be an array")?;
    if items.len() > MAX_MACROS {
        return Err(format!("voice_macros: at most {MAX_MACROS} entries"));
    }
    items
        .iter()
        .enumerate()
        .map(|(i, item)| {
            let obj: &Map<String, Value> = item
                .as_object()
                .ok_or_else(|| format!("voice_macros[{i}] must be an object"))?;
            if obj.keys().any(|k| k != "command" && k != "payload") {
                return Err(format!("voice_macros[{i}] has a key other than command and payload"));
            }
            let field = |name: &str| -> Result<String, String> {
                let s = obj
                    .get(name)
                    .and_then(Value::as_str)
                    .ok_or_else(|| format!("voice_macros[{i}].{name} must be a string"))?;
                if s.len() > MAX_MACRO_BYTES {
                    return Err(format!("voice_macros[{i}].{name} is longer than {MAX_MACRO_BYTES} bytes"));
                }
                Ok(s.to_owned())
            };
            let m = VoiceMacro {
                command: field("command")?,
                payload: field("payload")?,
            };
            if !lf_dictation::command_can_match(&m.command) {
                return Err(format!(
                    "voice_macros[{i}].command is empty without punctuation and whitespace, so it can never match"
                ));
            }
            Ok(m)
        })
        .collect()
}

pub use lf_asr::topology::allowed_cpus;

/// Resolves the configured CPU list against the CPUs available to the process.
pub fn resolve_cpus(configured: Option<&[usize]>) -> Result<Vec<usize>, String> {
    let allowed = allowed_cpus();
    if allowed.is_empty() {
        return Err("cannot read the CPU affinity mask".into());
    }
    match configured {
        None => Ok(lf_asr::topology::Topology::read(&allowed).default_cpus()),
        Some(cpus) => {
            if let Some(&bad) = cpus.iter().find(|c| !allowed.contains(c)) {
                return Err(format!("cpus: CPU {bad} is not available to this process"));
            }
            Ok(cpus.to_vec())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(s: &str) -> Result<Config, String> {
        Config::parse(s.as_bytes(), Path::new("/data/localflow"))
    }

    #[test]
    fn empty_object_is_defaults() {
        let c = parse("{}").unwrap();
        assert_eq!(c, Config::defaults(Path::new("/data/localflow")));
        assert_eq!(c.export_path, Path::new("/data/localflow/model"));
        assert_eq!(c.precision, Precision::Int8(2));
        assert!(!c.history && c.press_enter && c.spoken_delimiters && c.spoken_numbers);
        assert_eq!(c.min_recording_seconds, 0.3);
    }

    #[test]
    fn full_config() {
        let c = parse(
            r#"{"version": 1, "export_path": "/models/export", "precision": "i8x2",
                "cpus": "0-3,8", "press_enter": false, "spoken_delimiters": false,
                "spoken_numbers": false,
                "voice_macros": [{"command": "Sign off", "payload": "Synthetic regards."}],
                "history": false, "min_recording_seconds": 0.5, "max_recording_seconds": 120,
                "log_level": "debug", "input_device": "alsa_input.usb-Synthetic_Mic-00.mono",
                "key_delay_ms": 3, "pause_media": false}"#,
        )
        .unwrap();
        assert!(!c.pause_media);
        assert!(parse("{}").unwrap().pause_media);
        assert!(parse(r#"{"pause_media": true}"#).unwrap().pause_media);
        assert_eq!(
            c.input_device.as_deref(),
            Some("alsa_input.usb-Synthetic_Mic-00.mono")
        );
        assert_eq!(c.key_delay_ms, 3);
        assert_eq!(
            parse(r#"{"input_device": null}"#).unwrap().input_device,
            None
        );
        assert_eq!(parse("{}").unwrap().key_delay_ms, 1);
        assert_eq!(c.export_path, Path::new("/models/export"));
        assert_eq!(c.precision, Precision::Int8(2));
        assert_eq!(c.cpus, Some(vec![0, 1, 2, 3, 8]));
        assert!(!c.press_enter && !c.spoken_delimiters && !c.spoken_numbers && !c.history);
        assert!(!c.dictation_options().spoken_numbers);
        assert_eq!(c.voice_macros.len(), 1);
        assert_eq!(c.min_recording_seconds, 0.5);
        assert_eq!(c.max_recording_seconds, 120.0);
        assert_eq!(c.log_level, Level::Debug);
        assert_eq!(
            parse(r#"{"cpus": [3, 1, 2]}"#).unwrap().cpus,
            Some(vec![3, 1, 2])
        );
    }

    #[test]
    fn rejects_invalid() {
        for bad in [
            "",
            "[]",
            "{",
            r#"{"version": 2}"#,
            r#"{"unknown": 1}"#,
            r#"{"export_path": "relative/path"}"#,
            r#"{"export_path": 5}"#,
            r#"{"precision": "i8x4"}"#,
            r#"{"precision": "I8X3"}"#,
            r#"{"cpus": []}"#,
            r#"{"cpus": [1, 1]}"#,
            r#"{"cpus": [-1]}"#,
            r#"{"cpus": [1.5]}"#,
            r#"{"cpus": [4096]}"#,
            r#"{"cpus": "0-"}"#,
            r#"{"cpus": "3-1"}"#,
            r#"{"cpus": "0-3,2"}"#,
            r#"{"cpus": "a"}"#,
            r#"{"cpus": "0-99999"}"#,
            r#"{"cpus": "0-1023,0-1023"}"#,
            r#"{"press_enter": "yes"}"#,
            r#"{"history": 1}"#,
            r#"{"voice_macros": {}}"#,
            r#"{"voice_macros": [{"command": "x"}]}"#,
            r#"{"voice_macros": [{"command": "x", "payload": "y", "extra": 1}]}"#,
            r#"{"voice_macros": [{"command": "?!", "payload": "y"}]}"#,
            r#"{"voice_macros": [{"command": "", "payload": "y"}]}"#,
            r#"{"min_recording_seconds": -1}"#,
            r#"{"min_recording_seconds": 11}"#,
            r#"{"max_recording_seconds": 0.5}"#,
            r#"{"max_recording_seconds": 601}"#,
            r#"{"min_recording_seconds": 5, "max_recording_seconds": 2}"#,
            r#"{"log_level": "trace"}"#,
            r#"{"input_device": ""}"#,
            r#"{"input_device": 3}"#,
            r#"{"input_device": "a\nb"}"#,
            r#"{"key_delay_ms": -1}"#,
            r#"{"key_delay_ms": 51}"#,
            r#"{"key_delay_ms": 1.5}"#,
            r#"{"pause_media": 1}"#,
            r#"{"pause_media": "true"}"#,
            r#"{"pause_media": null}"#,
            r#"{"prompt_tag": null}"#,
            r#"{"prompt_tag": 5}"#,
            r#"{"prompt_tag": "a\nb"}"#,
            r#"{"prompt_tag": "a\tb"}"#,
            r#"{"prompt_tag": "a\u0007"}"#,
            r#"{"prompt_tag": "a b"}"#,
            r#"{"double_tap_ms": 149}"#,
            r#"{"double_tap_ms": 1001}"#,
            r#"{"double_tap_ms": -1}"#,
            r#"{"double_tap_ms": 400.5}"#,
            r#"{"double_tap_ms": "400"}"#,
            r#"{"picker": "dmenu"}"#,
            r#"{"picker": "Rofi"}"#,
            r#"{"picker": null}"#,
            r#"{"picker": 1}"#,
        ] {
            assert!(parse(bad).is_err(), "accepted {bad}");
        }
        let long = format!(
            r#"{{"prompt_tag": "{}"}}"#,
            "x".repeat(MAX_PROMPT_TAG_CHARS + 1)
        );
        assert!(parse(&long).is_err());
        // The error never quotes the value.
        let err = parse(r#"{"prompt_tag": "synthetic\nsecret"}"#).unwrap_err();
        assert!(!err.contains("synthetic"), "{err}");
    }

    #[test]
    fn prompt_tag_and_double_tap() {
        let d = parse("{}").unwrap();
        assert_eq!(d.prompt_tag, "[dictated]");
        assert_eq!(d.double_tap_ms, 400);
        let c = parse(r#"{"prompt_tag": "", "double_tap_ms": 0}"#).unwrap();
        assert_eq!(c.prompt_tag, "");
        assert_eq!(c.double_tap_ms, 0);
        for ms in [150, 1000] {
            let c = parse(&format!(r#"{{"double_tap_ms": {ms}}}"#)).unwrap();
            assert_eq!(c.double_tap_ms, ms);
        }
        let exact = "é".repeat(MAX_PROMPT_TAG_CHARS);
        let c = parse(&format!(r#"{{"prompt_tag": "{exact}"}}"#)).unwrap();
        assert_eq!(c.prompt_tag, exact);
        let c = parse(r#"{"prompt_tag": "[voice note]"}"#).unwrap();
        assert_eq!(c.prompt_tag, "[voice note]");
    }

    #[test]
    fn picker() {
        use crate::picker::{Choice, Kind};
        assert_eq!(parse("{}").unwrap().picker, Choice::Auto);
        assert_eq!(parse(r#"{"picker": "auto"}"#).unwrap().picker, Choice::Auto);
        for k in Kind::ALL {
            let c = parse(&format!(r#"{{"picker": "{}"}}"#, k.name())).unwrap();
            assert_eq!(c.picker, Choice::Only(k));
        }
        let e = parse(r#"{"picker": "synthetic-secret"}"#).unwrap_err();
        assert!(
            !e.contains("ecret") && e.starts_with("picker must be one of auto"),
            "{e}"
        );
    }

    #[test]
    fn output_and_keyboard_layout() {
        let d = parse("{}").unwrap();
        assert_eq!(d.output, Output::Auto);
        assert_eq!(d.keyboard_layout, Rmlvo::default());
        for (name, output) in [
            ("auto", Output::Auto),
            ("wayland", Output::Wayland),
            ("portal", Output::Portal),
            ("uinput", Output::Uinput),
        ] {
            let c = parse(&format!(r#"{{"output": "{name}"}}"#)).unwrap();
            assert_eq!(c.output, output);
        }
        let c = parse(
            r#"{"keyboard_layout": {"rules": "evdev", "model": "pc105", "layout": "us,de",
                "variant": "dvorak,", "options": "grp:alt_shift_toggle"}}"#,
        )
        .unwrap();
        assert_eq!(
            c.keyboard_layout,
            Rmlvo {
                rules: "evdev".into(),
                model: "pc105".into(),
                layout: "us,de".into(),
                variant: "dvorak,".into(),
                options: Some("grp:alt_shift_toggle".into()),
            }
        );
        let c = parse(r#"{"keyboard_layout": {"layout": "de"}}"#).unwrap();
        assert_eq!(c.keyboard_layout.layout, "de");
        assert_eq!(c.keyboard_layout.options, None);
        let c = parse(r#"{"keyboard_layout": null}"#).unwrap();
        assert_eq!(c.keyboard_layout, Rmlvo::default());
        for bad in [
            r#"{"output": "clipboard"}"#,
            r#"{"output": "Auto"}"#,
            r#"{"output": null}"#,
            r#"{"output": 1}"#,
            r#"{"keyboard_layout": "us"}"#,
            r#"{"keyboard_layout": {"layout": 1}}"#,
            r#"{"keyboard_layout": {"layout": "u\ns"}}"#,
            r#"{"keyboard_layout": {"layout": "us\u0000"}}"#,
            r#"{"keyboard_layout": {"keymap": "us"}}"#,
        ] {
            assert!(parse(bad).is_err(), "accepted {bad}");
        }
        let long = format!(
            r#"{{"keyboard_layout": {{"layout": "{}"}}}}"#,
            "a".repeat(257)
        );
        assert!(parse(&long).is_err());
        // Errors name fields, never values or unknown keys.
        let e = parse(r#"{"keyboard_layout": {"Synthetic secret": "x"}}"#).unwrap_err();
        assert!(!e.contains("ecret"), "{e}");
        let e = parse(r#"{"keyboard_layout": {"variant": "synthetic\nsecret"}}"#).unwrap_err();
        assert!(
            e.contains("keyboard_layout.variant") && !e.contains("ecret"),
            "{e}"
        );
        let e = parse(r#"{"output": "synthetic secret"}"#).unwrap_err();
        assert!(!e.contains("ecret"), "{e}");
    }

    #[test]
    fn trigger() {
        assert_eq!(parse("{}").unwrap().trigger, Trigger::Commands);
        assert_eq!(
            parse(r#"{"trigger": "commands"}"#).unwrap().trigger,
            Trigger::Commands
        );
        assert_eq!(
            parse(r#"{"trigger": "portal"}"#).unwrap().trigger,
            Trigger::Portal
        );
        for bad in [
            r#"{"trigger": "Portal"}"#,
            r#"{"trigger": "synthetic-secret"}"#,
            r#"{"trigger": ""}"#,
            r#"{"trigger": null}"#,
            r#"{"trigger": true}"#,
            r#"{"trigger": ["portal"]}"#,
        ] {
            let e = parse(bad).unwrap_err();
            // Names the field and the choices, never the value.
            assert!(
                e.contains("trigger") && e.contains("commands, portal"),
                "{e}"
            );
            assert!(!e.contains("secret"), "{e}");
        }
        assert!(parse(r#"{"unknown": 1}"#).unwrap_err().contains("trigger"));
    }

    #[test]
    fn device_name_length_is_bounded() {
        let ok = format!(r#"{{"input_device": "{}"}}"#, "a".repeat(MAX_DEVICE_NAME));
        assert!(parse(&ok).is_ok());
        let long = format!(
            r#"{{"input_device": "{}"}}"#,
            "a".repeat(MAX_DEVICE_NAME + 1)
        );
        assert!(parse(&long).is_err());
    }

    #[test]
    fn errors_do_not_echo_macro_text() {
        let e = parse(r#"{"voice_macros": [{"command": "Synthetic secret?", "payload": 5}]}"#)
            .unwrap_err();
        assert!(!e.contains("secret"), "{e}");
        let long = "x".repeat(MAX_MACRO_BYTES + 1);
        let e = parse(&format!(
            r#"{{"voice_macros": [{{"command": "a", "payload": "{long}"}}]}}"#
        ))
        .unwrap_err();
        assert!(!e.contains("xxx"), "{e}");
        // A macro written as a {command: payload} map, or misplaced at the top level.
        for bad in [
            r#"{"voice_macros": [{"Synthetic secret": "Synthetic payload"}]}"#,
            r#"{"Synthetic secret": "Synthetic payload"}"#,
            r#"{"cpus": "Synthetic secret"}"#,
        ] {
            let e = parse(bad).unwrap_err();
            assert!(!e.contains("ecret") && !e.contains("payload\""), "{e}");
        }
        let e = parse(r#"{"privatephrase": "Synthetic payload"}"#).unwrap_err();
        assert!(
            !e.contains("privatephrase") && e.contains("allowed keys"),
            "{e}"
        );
    }

    #[test]
    fn missing_file_is_defaults() {
        let c = Config::load(
            Path::new("/nonexistent/localflow/config.json"),
            Path::new("/d"),
        )
        .unwrap();
        assert_eq!(c, Config::defaults(Path::new("/d")));
    }

    #[test]
    fn a_symlinked_read_only_config_loads() {
        // home-manager installs the config as a symlink into the read-only
        // Nix store: links are followed and neither owner nor mode matter.
        let t = crate::testing::TempDir::new("config-link");
        let target = t.path().join("store-config.json");
        std::fs::write(&target, br#"{"version": 1, "press_enter": false}"#).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o444)).unwrap();
        let path = t.path().join("config.json");
        std::os::unix::fs::symlink(&target, &path).unwrap();
        let c = Config::load(&path, Path::new("/d")).unwrap();
        assert!(!c.press_enter);
    }

    #[test]
    fn only_bounded_regular_files_load() {
        let t = crate::testing::TempDir::new("config-file");
        let path = t.path().join("config.json");

        // Exactly 1 MiB loads; one byte more does not.
        let mut body = vec![b' '; MAX_CONFIG_BYTES as usize - 2];
        body.extend_from_slice(b"{}");
        std::fs::write(&path, &body).unwrap();
        assert_eq!(
            Config::load(&path, Path::new("/d")).unwrap(),
            Config::defaults(Path::new("/d"))
        );
        body.insert(0, b' ');
        std::fs::write(&path, &body).unwrap();
        let e = Config::load(&path, Path::new("/d")).unwrap_err();
        assert!(e.contains("larger than 1 MiB"), "{e}");

        // A directory is refused.
        std::fs::remove_file(&path).unwrap();
        std::fs::create_dir(&path).unwrap();
        let e = Config::load(&path, Path::new("/d")).unwrap_err();
        assert!(e.contains("not a regular file"), "{e}");
        std::fs::remove_dir(&path).unwrap();

        // A FIFO is refused without blocking.
        let c = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
        // SAFETY: valid NUL-terminated path.
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        let e = Config::load(&path, Path::new("/d")).unwrap_err();
        assert!(e.contains("not a regular file"), "{e}");

        // A dangling symlink is a missing file.
        std::fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(t.path().join("nowhere"), &path).unwrap();
        assert_eq!(
            Config::load(&path, Path::new("/d")).unwrap(),
            Config::defaults(Path::new("/d"))
        );
    }

    #[test]
    fn default_cpus_come_from_the_affinity_mask() {
        let cpus = resolve_cpus(None).unwrap();
        assert!(!cpus.is_empty() && cpus.len() <= 16);
        assert!(cpus.iter().all(|c| allowed_cpus().contains(c)));
        assert!(resolve_cpus(Some(&[MAX_CPU - 1])).is_err() || allowed_cpus().len() == MAX_CPU);
    }
}

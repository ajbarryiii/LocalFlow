//! `localflowctl watch --waybar`: turns watch lines into Waybar custom-module
//! JSON, one object per line:
//!
//! ```text
//! {"text": "<glyph or dot wave>", "alt": "<class>", "class": "<class>", "tooltip": "LocalFlow: ..."}
//! ```
//!
//! Classes (and alts): idle, loading, recording, transcribing, typing,
//! nomic, offline. The text is always [`WIDTH`] characters, each one cell
//! of a monospace font, so the module and the clock beside it never move
//! between states:
//!
//! - Recording shows the last input levels as a wave of round dots, newest
//!   on the right; silence is a row of equal small dots.
//! - Every other state shows its glyph in the third cell ([`GLYPH_CELL`]).
//!   Glyphs are Font Awesome icons as Nerd Fonts carry them, drawn wider
//!   than one cell, so the glyph sits about in the middle; a bar config can
//!   replace them with `format-icons` keyed by `alt`.
//! - A prompt dictation (double-tap and hold) while recording, transcribing
//!   or typing puts [`PROMPT_MARKER`] in the first cell, and has two
//!   classes, e.g. `"class": ["recording", "prompt"]`, the state's alt, and
//!   a tooltip such as "LocalFlow: listening (prompt dictation)".
//!
//! The agent link's counts on watch lines (see `crate::protocol`):
//!
//! - While idle, loading or without a microphone, an agent needing approval
//!   adds the class `agent-approval`, else one waiting for input
//!   `agent-input`, and pending suggestions `suggestion` (in that order,
//!   after the state's class: `class` is then an array). The number of
//!   agents needing approval or input, when any, goes in the last two cells
//!   (at most 99).
//! - While recording, transcribing or typing, classes and text are as
//!   without them.
//! - In every state but offline, the tooltip gets a line each for agents,
//!   suggestions and project words, when there are any.

use std::collections::VecDeque;

/// nf-fa-microphone: ready.
pub const MIC_GLYPH: &str = "\u{f130}";
/// nf-fa-clock_o: the model is loading.
pub const LOADING_GLYPH: &str = "\u{f017}";
/// nf-fa-hourglass_half: transcribing.
pub const TRANSCRIBING_GLYPH: &str = "\u{f252}";
/// nf-fa-keyboard_o: typing.
pub const TYPING_GLYPH: &str = "\u{f11c}";
/// nf-fa-microphone_slash: no microphone.
pub const NO_MIC_GLYPH: &str = "\u{f131}";
/// nf-fa-power_off: the daemon is not running.
pub const OFFLINE_GLYPH: &str = "\u{f011}";
/// The first cell of a prompt dictation's text.
pub const PROMPT_MARKER: char = '\u{203a}';

/// Characters in every text: one cell each in a monospace (Nerd) font.
pub const WIDTH: usize = 6;
/// The cell of a state's glyph; the agent count takes the last two.
pub const GLYPH_CELL: usize = 2;
/// Levels kept while recording: a full row of dots.
pub const HISTORY: usize = WIDTH;

/// The wave's dots, smallest (silence) to largest, each centred in its cell
/// and narrower than it, so neighbours never touch: nf-md-circle_small,
/// U+2022 bullet, nf-md-circle_medium, nf-cod-circle_filled.
pub const DOTS: [char; 4] = ['\u{f09df}', '\u{2022}', '\u{f09de}', '\u{ea71}'];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Class {
    Idle,
    /// Idle while the model loads.
    Loading,
    Recording,
    Transcribing,
    Typing,
    /// Idle with no microphone.
    NoMic,
    /// The daemon is not running or the connection was lost.
    Offline,
}

impl Class {
    pub const ALL: [Class; 7] = [
        Class::Idle,
        Class::Loading,
        Class::Recording,
        Class::Transcribing,
        Class::Typing,
        Class::NoMic,
        Class::Offline,
    ];

    /// The class of one watch line's fields (the part after `ok `), or
    /// `None` for an unknown state. Busy states take precedence over a
    /// missing microphone, which takes precedence over loading.
    pub fn from_fields(fields: &str) -> Option<Class> {
        let (mut state, mut model, mut mic) = (None, None, None);
        for (k, v) in fields.split(' ').filter_map(|f| f.split_once('=')) {
            match k {
                "state" => state = Some(v),
                "model" => model = Some(v),
                "mic" => mic = Some(v),
                _ => {}
            }
        }
        Some(match state? {
            "recording" => Class::Recording,
            "transcribing" => Class::Transcribing,
            "typing" => Class::Typing,
            "idle" if mic == Some("absent") => Class::NoMic,
            "idle" if model == Some("loading") => Class::Loading,
            "idle" => Class::Idle,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            Class::Idle => "idle",
            Class::Loading => "loading",
            Class::Recording => "recording",
            Class::Transcribing => "transcribing",
            Class::Typing => "typing",
            Class::NoMic => "nomic",
            Class::Offline => "offline",
        }
    }

    fn tooltip(self) -> &'static str {
        match self {
            Class::Idle => "LocalFlow: ready",
            Class::Loading => "LocalFlow: loading the model",
            Class::Recording => "LocalFlow: listening",
            Class::Transcribing => "LocalFlow: transcribing",
            Class::Typing => "LocalFlow: typing",
            Class::NoMic => "LocalFlow: no microphone",
            Class::Offline => "LocalFlow isn\u{2019}t running",
        }
    }

    /// The glyph of every state but recording, which shows the wave.
    fn glyph(self) -> &'static str {
        match self {
            Class::Idle | Class::Recording => MIC_GLYPH,
            Class::Loading => LOADING_GLYPH,
            Class::Transcribing => TRANSCRIBING_GLYPH,
            Class::Typing => TYPING_GLYPH,
            Class::NoMic => NO_MIC_GLYPH,
            Class::Offline => OFFLINE_GLYPH,
        }
    }
}

/// Levels up to this (in 0..=100) are room noise: silence's dot.
const NOISE: f32 = 4.0;

/// One dot for a level of 0..=100: silence up to [`NOISE`], then a
/// square-root curve so quiet speech still shows.
pub fn dot(level: u8) -> char {
    let v = ((f32::from(level.min(100)) - NOISE).max(0.0) / (100.0 - NOISE)).sqrt();
    DOTS[(v * (DOTS.len() - 1) as f32).round() as usize]
}

/// A state's [`WIDTH`] cells: the prompt marker or a space, the glyph in
/// [`GLYPH_CELL`], and `count` (at most 99) in the last two.
fn field(prompt: bool, glyph: &str, count: u32) -> String {
    let marker = if prompt { PROMPT_MARKER } else { ' ' };
    let count = if count > 0 {
        count.min(99).to_string()
    } else {
        String::new()
    };
    format!("{marker} {glyph} {count:<2}")
}

/// A JSON string literal.
fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 || c == '\u{7f}' => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// A Waybar object: `class` is a string for one class, an array for more.
fn render(alt: Class, classes: &[&str], text: &str, tooltip: &str) -> String {
    let class = match classes {
        [one] => json_string(one),
        many => format!(
            "[{}]",
            many.iter()
                .map(|c| json_string(c))
                .collect::<Vec<_>>()
                .join(", ")
        ),
    };
    format!(
        "{{\"text\": {}, \"alt\": {}, \"class\": {}, \"tooltip\": {}}}",
        json_string(text),
        json_string(alt.name()),
        class,
        json_string(tooltip)
    )
}

/// The Waybar object for `class` showing `text`, without a newline.
pub fn object(class: Class, text: &str) -> String {
    render(class, &[class.name()], text, class.tooltip())
}

/// The extra class of prompt dictations.
pub const PROMPT_CLASS: &str = "prompt";
/// Extra classes while idle, loading or without a microphone: an agent
/// needs approval, or (with none needing approval) waits for input.
pub const AGENT_APPROVAL_CLASS: &str = "agent-approval";
pub const AGENT_INPUT_CLASS: &str = "agent-input";
/// Extra class while dictionary suggestions are pending.
pub const SUGGESTION_CLASS: &str = "suggestion";

/// The agent link's counts from a watch line.
#[derive(Clone, Copy, Debug, Default)]
struct Counts {
    suggestions: u32,
    words: u32,
    approval: u32,
    input: u32,
    working: u32,
    done: u32,
}

impl Counts {
    /// The tooltip lines after the state's, each only when it applies.
    fn tooltip_lines(&self) -> Vec<String> {
        let mut lines = Vec::new();
        let agents: Vec<String> = [
            (self.approval, "needs approval", "need approval"),
            (self.input, "waiting for input", "waiting for input"),
            (self.working, "working", "working"),
            (self.done, "done", "done"),
        ]
        .into_iter()
        .filter(|(n, ..)| *n > 0)
        .map(|(n, one, many)| format!("{n} {}", if n == 1 { one } else { many }))
        .collect();
        if !agents.is_empty() {
            lines.push(format!("Agents: {}", agents.join(", ")));
        }
        match self.suggestions {
            0 => {}
            1 => lines
                .push("1 dictionary suggestion from an agent (localflowctl dict review)".into()),
            n => lines.push(format!(
                "{n} dictionary suggestions from agents (localflowctl dict review)"
            )),
        }
        match self.words {
            0 => {}
            1 => lines.push("1 project word boosted".into()),
            n => lines.push(format!("{n} project words boosted")),
        }
        lines
    }
}

/// Turns a stream of watch lines into Waybar objects.
#[derive(Debug, Default)]
pub struct Indicator {
    /// Recent levels of the current recording, oldest first.
    levels: VecDeque<u8>,
    recording: bool,
}

impl Indicator {
    /// The object for one watch line's fields (the part after `ok `), or
    /// `None` for an unknown state.
    pub fn update(&mut self, fields: &str) -> Option<String> {
        let class = Class::from_fields(fields)?;
        let mut level = None;
        let mut prompt = false;
        let mut n = Counts::default();
        for (k, v) in fields.split(' ').filter_map(|f| f.split_once('=')) {
            let count = || v.parse::<u32>().unwrap_or(0);
            match k {
                "level" => level = v.parse::<u8>().ok(),
                "tag" => prompt = v == "prompt",
                "suggestions" => n.suggestions = count(),
                "words" => n.words = count(),
                "agent-approval" => n.approval = count(),
                "agent-input" => n.input = count(),
                "agent-working" => n.working = count(),
                "agent-done" => n.done = count(),
                _ => {}
            }
        }
        if class == Class::Recording {
            if !self.recording {
                self.levels.clear();
            }
            if let Some(l) = level {
                if self.levels.len() == HISTORY {
                    self.levels.pop_front();
                }
                self.levels.push_back(l);
            }
        }
        self.recording = class == Class::Recording;
        let busy = matches!(
            class,
            Class::Recording | Class::Transcribing | Class::Typing
        );
        let prompt = prompt && busy;
        let mut classes = vec![class.name()];
        let mut tooltip = class.tooltip().to_owned();
        if prompt {
            classes.push(PROMPT_CLASS);
            tooltip += " (prompt dictation)";
        }
        let mut waiting = 0;
        if !busy {
            if n.approval > 0 {
                classes.push(AGENT_APPROVAL_CLASS);
            } else if n.input > 0 {
                classes.push(AGENT_INPUT_CLASS);
            }
            if n.suggestions > 0 {
                classes.push(SUGGESTION_CLASS);
            }
            waiting = n.approval.saturating_add(n.input);
        }
        let text = match class {
            Class::Recording if prompt => format!("{PROMPT_MARKER}{}", self.wave(WIDTH - 1)),
            Class::Recording => self.wave(WIDTH),
            _ => field(prompt, class.glyph(), waiting),
        };
        for line in n.tooltip_lines() {
            tooltip.push('\n');
            tooltip += &line;
        }
        Some(render(class, &classes, &text, &tooltip))
    }

    /// The object shown while the daemon is unreachable.
    pub fn offline(&mut self) -> String {
        self.recording = false;
        object(Class::Offline, &field(false, Class::Offline.glyph(), 0))
    }

    /// The last `cells` levels as dots, newest on the right, padded with
    /// silence.
    fn wave(&self, cells: usize) -> String {
        let shown = self.levels.len().min(cells);
        std::iter::repeat_n(dot(0), cells - shown)
            .chain(
                self.levels
                    .iter()
                    .skip(self.levels.len() - shown)
                    .map(|&l| dot(l)),
            )
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn json(o: &str) -> serde_json::Value {
        serde_json::from_str(o).unwrap()
    }

    fn text(o: &str) -> String {
        json(o)["text"].as_str().unwrap().to_owned()
    }

    /// Dots for levels, oldest first.
    fn dots(levels: &[u8]) -> String {
        levels.iter().map(|&l| dot(l)).collect()
    }

    const SILENCE: char = DOTS[0];

    #[test]
    fn every_class_formats_as_waybar_json() {
        let mut ind = Indicator::default();
        let cases = [
            (
                "state=idle model=ready mic=present",
                "{\"text\": \"  \u{f130}   \", \"alt\": \"idle\", \"class\": \"idle\", \"tooltip\": \"LocalFlow: ready\"}",
            ),
            (
                "state=idle model=loading mic=unknown",
                "{\"text\": \"  \u{f017}   \", \"alt\": \"loading\", \"class\": \"loading\", \"tooltip\": \"LocalFlow: loading the model\"}",
            ),
            (
                "state=recording mode=hold model=ready mic=present level=100",
                "{\"text\": \"\u{f09df}\u{f09df}\u{f09df}\u{f09df}\u{f09df}\u{ea71}\", \"alt\": \"recording\", \"class\": \"recording\", \"tooltip\": \"LocalFlow: listening\"}",
            ),
            (
                "state=transcribing model=ready mic=present",
                "{\"text\": \"  \u{f252}   \", \"alt\": \"transcribing\", \"class\": \"transcribing\", \"tooltip\": \"LocalFlow: transcribing\"}",
            ),
            (
                "state=typing model=ready mic=present",
                "{\"text\": \"  \u{f11c}   \", \"alt\": \"typing\", \"class\": \"typing\", \"tooltip\": \"LocalFlow: typing\"}",
            ),
            (
                "state=idle model=loading mic=absent",
                "{\"text\": \"  \u{f131}   \", \"alt\": \"nomic\", \"class\": \"nomic\", \"tooltip\": \"LocalFlow: no microphone\"}",
            ),
        ];
        let mut seen = Vec::new();
        for (fields, want) in cases {
            assert_eq!(ind.update(fields).as_deref(), Some(want), "{fields}");
            seen.push(want);
        }
        let offline = ind.offline();
        assert_eq!(
            offline,
            "{\"text\": \"  \u{f011}   \", \"alt\": \"offline\", \"class\": \"offline\", \"tooltip\": \"LocalFlow isn\u{2019}t running\"}"
        );
        seen.push(&offline);
        // Every class appears, and every object is valid JSON with the four
        // fields.
        for class in Class::ALL {
            let tag = format!("\"class\": \"{}\"", class.name());
            assert!(seen.iter().any(|o| o.contains(&tag)), "{tag}");
        }
        for o in seen {
            let v = json(o);
            assert_eq!(v["alt"], v["class"]);
            assert!(v["text"].as_str().is_some_and(|t| !t.trim().is_empty()));
            assert!(v["tooltip"].as_str().unwrap().starts_with("LocalFlow"));
        }
        assert_eq!(ind.update("state=exploding model=ready"), None);
        assert_eq!(ind.update("model=ready"), None);
    }

    #[test]
    fn every_state_has_its_own_glyph() {
        // Stock Waybar has no colours: the glyph alone tells the states apart.
        let glyphs = [
            MIC_GLYPH,
            LOADING_GLYPH,
            TRANSCRIBING_GLYPH,
            TYPING_GLYPH,
            NO_MIC_GLYPH,
            OFFLINE_GLYPH,
        ];
        for (i, a) in glyphs.iter().enumerate() {
            assert_eq!(a.chars().count(), 1);
            for b in &glyphs[i + 1..] {
                assert_ne!(a, b);
            }
            assert!(!DOTS.contains(&a.chars().next().unwrap()));
            assert_ne!(a.chars().next(), Some(PROMPT_MARKER));
        }
    }

    #[test]
    fn every_text_is_the_same_width_with_the_glyph_in_the_same_cell() {
        let mut ind = Indicator::default();
        let lines = [
            "state=idle model=ready mic=present",
            "state=idle model=loading mic=present",
            "state=recording mode=hold model=ready mic=present",
            "state=recording mode=hold model=ready mic=present level=0",
            "state=recording mode=hold model=ready mic=present level=60",
            "state=recording mode=hold tag=prompt model=ready mic=present level=60",
            "state=transcribing tag=prompt model=ready mic=present",
            "state=transcribing model=ready mic=present",
            "state=typing tag=prompt model=ready mic=present",
            "state=typing model=ready mic=present",
            "state=idle model=ready mic=absent",
            "state=idle model=ready mic=present agent-approval=1",
            "state=idle model=ready mic=present agent-input=12 suggestions=3",
            "state=idle model=loading mic=absent agent-approval=999 agent-input=999",
        ];
        let mut texts: Vec<String> = lines
            .iter()
            .map(|l| text(&ind.update(l).unwrap()))
            .collect();
        texts.push(text(&ind.offline()));
        for t in &texts {
            assert_eq!(t.chars().count(), WIDTH, "{t:?}");
            let glyph = t.chars().nth(GLYPH_CELL).unwrap();
            assert_ne!(glyph, ' ', "{t:?}");
        }
        // The count stays in the last two cells, after a space.
        assert_eq!(texts[11], format!("  {MIC_GLYPH} 1 "));
        assert_eq!(texts[12], format!("  {MIC_GLYPH} 12"));
        assert_eq!(texts[13], format!("  {NO_MIC_GLYPH} 99"));
    }

    #[test]
    fn prompt_dictations_get_a_marker_and_a_second_class() {
        let mut ind = Indicator::default();
        let v = json(
            &ind.update("state=recording mode=hold tag=prompt model=ready mic=present level=100")
                .unwrap(),
        );
        assert_eq!(v["class"], serde_json::json!(["recording", "prompt"]));
        assert_eq!(v["alt"], "recording");
        assert_eq!(v["tooltip"], "LocalFlow: listening (prompt dictation)");
        assert_eq!(
            v["text"],
            format!("{PROMPT_MARKER}{}", dots(&[0, 0, 0, 0, 100]))
        );
        for (state, glyph, tooltip) in [
            ("transcribing", TRANSCRIBING_GLYPH, "transcribing"),
            ("typing", TYPING_GLYPH, "typing"),
        ] {
            let v = json(
                &ind.update(&format!("state={state} tag=prompt model=ready mic=present"))
                    .unwrap(),
            );
            assert_eq!(v["class"], serde_json::json!([state, "prompt"]));
            assert_eq!(v["alt"], state);
            assert_eq!(
                v["tooltip"],
                format!("LocalFlow: {tooltip} (prompt dictation)")
            );
            assert_eq!(v["text"], format!("{PROMPT_MARKER} {glyph}   "));
        }
        // Without the tag, or when idle, objects are exactly as before.
        assert_eq!(
            ind.update("state=typing model=ready mic=present").unwrap(),
            "{\"text\": \"  \u{f11c}   \", \"alt\": \"typing\", \"class\": \"typing\", \"tooltip\": \"LocalFlow: typing\"}"
        );
        assert_eq!(
            ind.update("state=idle tag=prompt model=ready mic=present")
                .unwrap(),
            "{\"text\": \"  \u{f130}   \", \"alt\": \"idle\", \"class\": \"idle\", \"tooltip\": \"LocalFlow: ready\"}"
        );
    }

    #[test]
    fn agent_link_counts_add_classes_a_count_and_tooltip_lines() {
        let mut ind = Indicator::default();
        let loud = format!("{SILENCE}{SILENCE}{SILENCE}{SILENCE}{SILENCE}\u{ea71}");
        let cases = [
            (
                "state=idle model=ready mic=present suggestions=3 words=12 agent-approval=2 agent-input=1 agent-working=1 agent-done=4".to_owned(),
                "{\"text\": \"  \u{f130} 3 \", \"alt\": \"idle\", \"class\": [\"idle\", \"agent-approval\", \"suggestion\"], \"tooltip\": \"LocalFlow: ready\\nAgents: 2 need approval, 1 waiting for input, 1 working, 4 done\\n3 dictionary suggestions from agents (localflowctl dict review)\\n12 project words boosted\"}".to_owned(),
            ),
            (
                "state=idle model=loading mic=unknown agent-input=1".into(),
                "{\"text\": \"  \u{f017} 1 \", \"alt\": \"loading\", \"class\": [\"loading\", \"agent-input\"], \"tooltip\": \"LocalFlow: loading the model\\nAgents: 1 waiting for input\"}".into(),
            ),
            (
                "state=idle model=ready mic=absent suggestions=1".into(),
                "{\"text\": \"  \u{f131}   \", \"alt\": \"nomic\", \"class\": [\"nomic\", \"suggestion\"], \"tooltip\": \"LocalFlow: no microphone\\n1 dictionary suggestion from an agent (localflowctl dict review)\"}".into(),
            ),
            (
                "state=idle model=ready mic=present agent-approval=1".into(),
                "{\"text\": \"  \u{f130} 1 \", \"alt\": \"idle\", \"class\": [\"idle\", \"agent-approval\"], \"tooltip\": \"LocalFlow: ready\\nAgents: 1 needs approval\"}".into(),
            ),
            // Working and done alone add no class and no count.
            (
                "state=idle model=ready mic=present agent-working=1 agent-done=1 words=1".into(),
                "{\"text\": \"  \u{f130}   \", \"alt\": \"idle\", \"class\": \"idle\", \"tooltip\": \"LocalFlow: ready\\nAgents: 1 working, 1 done\\n1 project word boosted\"}".into(),
            ),
            // Busy states keep their classes and text; only the tooltip grows.
            (
                "state=recording mode=hold model=ready mic=present level=100 agent-approval=1 suggestions=2".into(),
                format!("{{\"text\": \"{loud}\", \"alt\": \"recording\", \"class\": \"recording\", \"tooltip\": \"LocalFlow: listening\\nAgents: 1 needs approval\\n2 dictionary suggestions from agents (localflowctl dict review)\"}}"),
            ),
            (
                "state=transcribing model=ready mic=present agent-input=3 words=2".into(),
                "{\"text\": \"  \u{f252}   \", \"alt\": \"transcribing\", \"class\": \"transcribing\", \"tooltip\": \"LocalFlow: transcribing\\nAgents: 3 waiting for input\\n2 project words boosted\"}".into(),
            ),
            (
                "state=typing tag=prompt model=ready mic=present agent-input=2 suggestions=1".into(),
                "{\"text\": \"\u{203a} \u{f11c}   \", \"alt\": \"typing\", \"class\": [\"typing\", \"prompt\"], \"tooltip\": \"LocalFlow: typing (prompt dictation)\\nAgents: 2 waiting for input\\n1 dictionary suggestion from an agent (localflowctl dict review)\"}".into(),
            ),
        ];
        for (fields, want) in cases {
            let got = ind.update(&fields).unwrap();
            assert_eq!(got, want, "{fields}");
            assert!(
                json(&got)["tooltip"]
                    .as_str()
                    .unwrap()
                    .starts_with("LocalFlow: ")
            );
        }
        // Back to no counts: exactly the plain object again.
        assert_eq!(
            ind.update("state=idle model=ready mic=present").unwrap(),
            "{\"text\": \"  \u{f130}   \", \"alt\": \"idle\", \"class\": \"idle\", \"tooltip\": \"LocalFlow: ready\"}"
        );
        // Offline shows none of it.
        assert_eq!(
            ind.offline(),
            "{\"text\": \"  \u{f011}   \", \"alt\": \"offline\", \"class\": \"offline\", \"tooltip\": \"LocalFlow isn\u{2019}t running\"}"
        );
    }

    #[test]
    fn busy_states_take_precedence_over_no_microphone() {
        let mut ind = Indicator::default();
        for (state, class) in [
            ("recording", "recording"),
            ("transcribing", "transcribing"),
            ("typing", "typing"),
        ] {
            let o = ind
                .update(&format!("state={state} model=loading mic=absent"))
                .unwrap();
            assert!(o.contains(&format!("\"class\": \"{class}\"")), "{o}");
        }
    }

    #[test]
    fn the_dot_wave_scrolls_and_restarts_per_recording() {
        assert_eq!(dot(0), SILENCE);
        assert_eq!(dot(100), DOTS[3]);
        assert_eq!(dot(255), DOTS[3]);
        // Room noise stays a row of silence; the square-root curve lifts
        // quiet speech: 10% is already a dot up, 30% two.
        assert_eq!(dot(4), SILENCE);
        assert_eq!(dot(10), DOTS[1]);
        assert_eq!(dot(30), DOTS[2]);
        // Louder is never smaller.
        assert!((0..100).all(|l| DOTS.iter().position(|&d| d == dot(l))
            <= DOTS.iter().position(|&d| d == dot(l + 1))));
        let mut ind = Indicator::default();
        let rec = |l: u8| format!("state=recording mode=toggle model=ready mic=present level={l}");
        // A recording starts as silence: a row of equal small dots.
        assert_eq!(
            text(
                &ind.update("state=recording mode=toggle model=ready mic=present")
                    .unwrap()
            ),
            SILENCE.to_string().repeat(WIDTH)
        );
        assert_eq!(
            text(&ind.update(&rec(100)).unwrap()),
            dots(&[0, 0, 0, 0, 0, 100])
        );
        assert_eq!(
            text(&ind.update(&rec(25)).unwrap()),
            dots(&[0, 0, 0, 0, 100, 25])
        );
        for _ in 0..HISTORY {
            ind.update(&rec(0));
        }
        assert_eq!(
            text(&ind.update(&rec(100)).unwrap()),
            dots(&[0, 0, 0, 0, 0, 100])
        );
        // A recording line without a level keeps the wave.
        assert_eq!(
            text(&ind.update("state=recording mode=hold model=ready").unwrap()),
            dots(&[0, 0, 0, 0, 0, 100])
        );
        // A prompt dictation shows the newest levels after its marker.
        let prompt =
            |l: u8| format!("state=recording tag=prompt model=ready mic=present level={l}");
        assert_eq!(
            text(&ind.update(&prompt(25)).unwrap()),
            format!("{PROMPT_MARKER}{}", dots(&[0, 0, 0, 100, 25]))
        );
        // The next recording starts from silence.
        ind.update("state=transcribing model=ready mic=present");
        assert_eq!(
            text(&ind.update(&rec(25)).unwrap()),
            dots(&[0, 0, 0, 0, 0, 25])
        );
        ind.offline();
        assert_eq!(text(&ind.update(&rec(0)).unwrap()), dots(&[0; WIDTH]));
    }

    #[test]
    fn json_strings_are_escaped() {
        assert_eq!(json_string("a\"b\\c"), "\"a\\\"b\\\\c\"");
        assert_eq!(json_string("\n\t\u{1}\u{7f}"), "\"\\n\\t\\u0001\\u007f\"");
        assert_eq!(json_string("\u{f130}▁"), "\"\u{f130}▁\"");
        let v: serde_json::Value =
            serde_json::from_str(&json_string("x\"\\\n\u{1}\u{f130}")).unwrap();
        assert_eq!(v, "x\"\\\n\u{1}\u{f130}");
    }
}

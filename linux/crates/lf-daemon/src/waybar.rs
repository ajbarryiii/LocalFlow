//! `localflowctl watch --waybar`: turns watch lines into Waybar custom-module
//! JSON, one object per line:
//!
//! ```text
//! {"text": "<glyph or level graph>", "alt": "<class>", "class": "<class>", "tooltip": "LocalFlow: ..."}
//! ```
//!
//! Classes (and alts): idle, loading, recording, transcribing, typing,
//! nomic, offline. Recording shows the last [`HISTORY`] input levels as a
//! scrolling bar graph. Glyphs are Nerd Font icons; a bar config can replace
//! them with `format-icons` keyed by `alt`. A prompt dictation (double-tap
//! and hold) while recording, transcribing or typing has two classes, e.g.
//! `"class": ["recording", "prompt"]`, the state's alt, and a tooltip such
//! as "LocalFlow: recording (prompt)".
//!
//! The agent link's counts on watch lines (see `crate::protocol`):
//!
//! - While idle, loading or without a microphone, an agent needing approval
//!   adds the class `agent-approval`, else one waiting for input
//!   `agent-input`, and pending suggestions `suggestion` (in that order,
//!   after the state's class: `class` is then an array). The text gets a
//!   space and the number of agents needing approval or input, when any.
//! - While recording, transcribing or typing, classes and text are as
//!   without them.
//! - In every state but offline, the tooltip gets a line each for agents,
//!   suggestions and project words, when there are any.

use std::collections::VecDeque;

/// nf-fa-microphone.
pub const MIC_GLYPH: &str = "\u{f130}";
/// nf-fa-hourglass_half.
pub const BUSY_GLYPH: &str = "\u{f252}";
/// nf-fa-times (styled red by the bar's CSS).
pub const NO_MIC_GLYPH: &str = "\u{f00d}";
/// nf-fa-microphone_slash.
pub const OFFLINE_GLYPH: &str = "\u{f131}";

/// Levels shown while recording.
pub const HISTORY: usize = 8;

const BARS: [char; 8] = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];

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
            Class::Idle => "LocalFlow: idle",
            Class::Loading => "LocalFlow: loading model",
            Class::Recording => "LocalFlow: recording",
            Class::Transcribing => "LocalFlow: transcribing",
            Class::Typing => "LocalFlow: typing",
            Class::NoMic => "LocalFlow: no microphone",
            Class::Offline => "LocalFlow: offline",
        }
    }

    fn glyph(self) -> &'static str {
        match self {
            Class::Idle | Class::Loading | Class::Recording => MIC_GLYPH,
            Class::Transcribing | Class::Typing => BUSY_GLYPH,
            Class::NoMic => NO_MIC_GLYPH,
            Class::Offline => OFFLINE_GLYPH,
        }
    }
}

/// One bar for a level of 0..=100, on a square-root curve so quiet speech
/// still shows.
pub fn bar(level: u8) -> char {
    let v = (f32::from(level.min(100)) / 100.0).sqrt();
    BARS[(v * (BARS.len() - 1) as f32).round() as usize]
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

/// The object for a prompt dictation (double-tap and hold) in `class`
/// (recording, transcribing or typing): classes `[<class>, "prompt"]`, so a
/// bar style can tell it apart, and the alt of `class`.
pub fn prompt_object(class: Class, text: &str) -> String {
    render(
        class,
        &[class.name(), PROMPT_CLASS],
        text,
        &format!("{} (prompt)", class.tooltip()),
    )
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
        let mut text = match class {
            Class::Recording => self.graph(),
            _ => class.glyph().to_owned(),
        };
        let busy = matches!(
            class,
            Class::Recording | Class::Transcribing | Class::Typing
        );
        let mut classes = vec![class.name()];
        let mut tooltip = class.tooltip().to_owned();
        if prompt && busy {
            classes.push(PROMPT_CLASS);
            tooltip += " (prompt)";
        }
        if !busy {
            if n.approval > 0 {
                classes.push(AGENT_APPROVAL_CLASS);
            } else if n.input > 0 {
                classes.push(AGENT_INPUT_CLASS);
            }
            if n.suggestions > 0 {
                classes.push(SUGGESTION_CLASS);
            }
            let waiting = n.approval.saturating_add(n.input);
            if waiting > 0 {
                text = format!("{text} {waiting}");
            }
        }
        for line in n.tooltip_lines() {
            tooltip.push('\n');
            tooltip += &line;
        }
        Some(render(class, &classes, &text, &tooltip))
    }

    /// The object shown while the daemon is unreachable.
    pub fn offline(&mut self) -> String {
        self.recording = false;
        object(Class::Offline, Class::Offline.glyph())
    }

    /// The last [`HISTORY`] levels, newest on the right, padded with silence.
    fn graph(&self) -> String {
        let pad = HISTORY - self.levels.len();
        std::iter::repeat_n(bar(0), pad)
            .chain(self.levels.iter().map(|&l| bar(l)))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_class_formats_as_waybar_json() {
        let mut ind = Indicator::default();
        let cases = [
            (
                "state=idle model=ready mic=present",
                "{\"text\": \"\u{f130}\", \"alt\": \"idle\", \"class\": \"idle\", \"tooltip\": \"LocalFlow: idle\"}",
            ),
            (
                "state=idle model=loading mic=unknown",
                "{\"text\": \"\u{f130}\", \"alt\": \"loading\", \"class\": \"loading\", \"tooltip\": \"LocalFlow: loading model\"}",
            ),
            (
                "state=recording mode=hold model=ready mic=present level=100",
                "{\"text\": \"▁▁▁▁▁▁▁█\", \"alt\": \"recording\", \"class\": \"recording\", \"tooltip\": \"LocalFlow: recording\"}",
            ),
            (
                "state=transcribing model=ready mic=present",
                "{\"text\": \"\u{f252}\", \"alt\": \"transcribing\", \"class\": \"transcribing\", \"tooltip\": \"LocalFlow: transcribing\"}",
            ),
            (
                "state=typing model=ready mic=present",
                "{\"text\": \"\u{f252}\", \"alt\": \"typing\", \"class\": \"typing\", \"tooltip\": \"LocalFlow: typing\"}",
            ),
            (
                "state=idle model=loading mic=absent",
                "{\"text\": \"\u{f00d}\", \"alt\": \"nomic\", \"class\": \"nomic\", \"tooltip\": \"LocalFlow: no microphone\"}",
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
            "{\"text\": \"\u{f131}\", \"alt\": \"offline\", \"class\": \"offline\", \"tooltip\": \"LocalFlow: offline\"}"
        );
        seen.push(&offline);
        // Every class appears, and every object is valid JSON with the four
        // fields.
        for class in Class::ALL {
            let tag = format!("\"class\": \"{}\"", class.name());
            assert!(seen.iter().any(|o| o.contains(&tag)), "{tag}");
        }
        for o in seen {
            let v: serde_json::Value = serde_json::from_str(o).unwrap();
            assert_eq!(v["alt"], v["class"]);
            assert!(v["text"].as_str().is_some_and(|t| !t.is_empty()));
            assert!(v["tooltip"].as_str().unwrap().starts_with("LocalFlow: "));
        }
        assert_eq!(ind.update("state=exploding model=ready"), None);
        assert_eq!(ind.update("model=ready"), None);
    }

    #[test]
    fn prompt_dictations_get_a_second_class() {
        let mut ind = Indicator::default();
        let json = |o: String| -> serde_json::Value { serde_json::from_str(&o).unwrap() };
        let v = json(
            ind.update("state=recording mode=hold tag=prompt model=ready mic=present level=100")
                .unwrap(),
        );
        assert_eq!(v["class"], serde_json::json!(["recording", "prompt"]));
        assert_eq!(v["alt"], "recording");
        assert_eq!(v["tooltip"], "LocalFlow: recording (prompt)");
        assert_eq!(v["text"], "▁▁▁▁▁▁▁█");
        for (state, glyph) in [("transcribing", BUSY_GLYPH), ("typing", BUSY_GLYPH)] {
            let v = json(
                ind.update(&format!("state={state} tag=prompt model=ready mic=present"))
                    .unwrap(),
            );
            assert_eq!(v["class"], serde_json::json!([state, "prompt"]));
            assert_eq!(v["alt"], state);
            assert_eq!(v["tooltip"], format!("LocalFlow: {state} (prompt)"));
            assert_eq!(v["text"], glyph);
        }
        // Without the tag, or when idle, objects are exactly as before.
        assert_eq!(
            ind.update("state=typing model=ready mic=present").unwrap(),
            "{\"text\": \"\u{f252}\", \"alt\": \"typing\", \"class\": \"typing\", \"tooltip\": \"LocalFlow: typing\"}"
        );
        assert_eq!(
            ind.update("state=idle tag=prompt model=ready mic=present")
                .unwrap(),
            "{\"text\": \"\u{f130}\", \"alt\": \"idle\", \"class\": \"idle\", \"tooltip\": \"LocalFlow: idle\"}"
        );
    }

    #[test]
    fn agent_link_counts_add_classes_a_count_and_tooltip_lines() {
        let mut ind = Indicator::default();
        let cases = [
            (
                "state=idle model=ready mic=present suggestions=3 words=12 agent-approval=2 agent-input=1 agent-working=1 agent-done=4",
                "{\"text\": \"\u{f130} 3\", \"alt\": \"idle\", \"class\": [\"idle\", \"agent-approval\", \"suggestion\"], \"tooltip\": \"LocalFlow: idle\\nAgents: 2 need approval, 1 waiting for input, 1 working, 4 done\\n3 dictionary suggestions from agents (localflowctl dict review)\\n12 project words boosted\"}",
            ),
            (
                "state=idle model=loading mic=unknown agent-input=1",
                "{\"text\": \"\u{f130} 1\", \"alt\": \"loading\", \"class\": [\"loading\", \"agent-input\"], \"tooltip\": \"LocalFlow: loading model\\nAgents: 1 waiting for input\"}",
            ),
            (
                "state=idle model=ready mic=absent suggestions=1",
                "{\"text\": \"\u{f00d}\", \"alt\": \"nomic\", \"class\": [\"nomic\", \"suggestion\"], \"tooltip\": \"LocalFlow: no microphone\\n1 dictionary suggestion from an agent (localflowctl dict review)\"}",
            ),
            (
                "state=idle model=ready mic=present agent-approval=1",
                "{\"text\": \"\u{f130} 1\", \"alt\": \"idle\", \"class\": [\"idle\", \"agent-approval\"], \"tooltip\": \"LocalFlow: idle\\nAgents: 1 needs approval\"}",
            ),
            // Working and done alone add no class and no count.
            (
                "state=idle model=ready mic=present agent-working=1 agent-done=1 words=1",
                "{\"text\": \"\u{f130}\", \"alt\": \"idle\", \"class\": \"idle\", \"tooltip\": \"LocalFlow: idle\\nAgents: 1 working, 1 done\\n1 project word boosted\"}",
            ),
            // Busy states keep their classes and text; only the tooltip grows.
            (
                "state=recording mode=hold model=ready mic=present level=100 agent-approval=1 suggestions=2",
                "{\"text\": \"▁▁▁▁▁▁▁█\", \"alt\": \"recording\", \"class\": \"recording\", \"tooltip\": \"LocalFlow: recording\\nAgents: 1 needs approval\\n2 dictionary suggestions from agents (localflowctl dict review)\"}",
            ),
            (
                "state=transcribing model=ready mic=present agent-input=3 words=2",
                "{\"text\": \"\u{f252}\", \"alt\": \"transcribing\", \"class\": \"transcribing\", \"tooltip\": \"LocalFlow: transcribing\\nAgents: 3 waiting for input\\n2 project words boosted\"}",
            ),
            (
                "state=typing tag=prompt model=ready mic=present agent-input=2 suggestions=1",
                "{\"text\": \"\u{f252}\", \"alt\": \"typing\", \"class\": [\"typing\", \"prompt\"], \"tooltip\": \"LocalFlow: typing (prompt)\\nAgents: 2 waiting for input\\n1 dictionary suggestion from an agent (localflowctl dict review)\"}",
            ),
        ];
        for (fields, want) in cases {
            let got = ind.update(fields).unwrap();
            assert_eq!(got, want, "{fields}");
            let v: serde_json::Value = serde_json::from_str(&got).unwrap();
            assert!(v["tooltip"].as_str().unwrap().starts_with("LocalFlow: "));
        }
        // Back to no counts: exactly the plain object again.
        assert_eq!(
            ind.update("state=idle model=ready mic=present").unwrap(),
            "{\"text\": \"\u{f130}\", \"alt\": \"idle\", \"class\": \"idle\", \"tooltip\": \"LocalFlow: idle\"}"
        );
        // Offline shows none of it.
        assert_eq!(
            ind.offline(),
            "{\"text\": \"\u{f131}\", \"alt\": \"offline\", \"class\": \"offline\", \"tooltip\": \"LocalFlow: offline\"}"
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
    fn the_level_graph_scrolls_and_restarts_per_recording() {
        assert_eq!(bar(0), '▁');
        assert_eq!(bar(100), '█');
        assert_eq!(bar(255), '█');
        // The square-root curve lifts quiet levels: 4% is already a bar up.
        assert_eq!(bar(4), '▂');
        assert_eq!(bar(25), '▅');
        let text = |o: String| -> String {
            let v: serde_json::Value = serde_json::from_str(&o).unwrap();
            v["text"].as_str().unwrap().to_owned()
        };
        let mut ind = Indicator::default();
        let rec = |l: u8| format!("state=recording mode=toggle model=ready mic=present level={l}");
        assert_eq!(text(ind.update(&rec(100)).unwrap()), "▁▁▁▁▁▁▁█");
        assert_eq!(text(ind.update(&rec(25)).unwrap()), "▁▁▁▁▁▁█▅");
        for _ in 0..HISTORY {
            ind.update(&rec(0));
        }
        assert_eq!(text(ind.update(&rec(100)).unwrap()), "▁▁▁▁▁▁▁█");
        // A recording line without a level keeps the graph.
        assert_eq!(
            text(ind.update("state=recording mode=hold model=ready").unwrap()),
            "▁▁▁▁▁▁▁█"
        );
        // The next recording starts from silence.
        ind.update("state=transcribing model=ready mic=present");
        assert_eq!(text(ind.update(&rec(25)).unwrap()), "▁▁▁▁▁▁▁▅");
        ind.offline();
        assert_eq!(text(ind.update(&rec(0)).unwrap()), "▁▁▁▁▁▁▁▁");
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

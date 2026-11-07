//! `localflowctl watch --waybar`: turns watch lines into Waybar custom-module
//! JSON, one object per line:
//!
//! ```text
//! {"text": "<glyph or dot wave>", "alt": "<class>", "class": "<class>", "tooltip": "LocalFlow: ..."}
//! ```
//!
//! Classes (and alts): idle, loading, recording, transcribing, typing,
//! nomic, offline. The text always shows [`WIDTH`] characters, each one
//! cell of a monospace font, so the module and the clock beside it never
//! move between states:
//!
//! - Recording shows a wave of round dots that comes to rest in a full,
//!   bright anchor dot in the last cell, as the iPhone's wave ends in the
//!   mark's dot, so silence still reads as listening. The cells before it
//!   show the voice, newest on the right: one cell per two level lines
//!   ([`LINES_PER_CELL`]), the louder of the pair, through a follower that
//!   rises at once and falls by [`FALL`] a cell; silence is a row of small
//!   dim dots. The wave is Pango markup (Waybar's default for custom
//!   modules): one `<span font_family="monospace">` around its cells, so a
//!   proportional bar font still gives them equal widths, and a dot dimmer
//!   than full is `<span alpha="NN%">•</span>`. Its dots are standard
//!   characters (U+2022, U+25CF), so it needs no Nerd Font. A full dot is a
//!   little wider than its cell, so two never stand side by side: the
//!   second of two loud cells, and a loud cell beside the anchor, show as
//!   the brightest small dot ([`CAPPED`]).
//! - Every other state shows its glyph in the third cell ([`GLYPH_CELL`]).
//!   Glyphs are Font Awesome icons as Nerd Fonts carry them, drawn wider
//!   than one cell, so the glyph sits about in the middle; a bar config can
//!   replace them with `format-icons` keyed by `alt`.
//! - A prompt dictation (double-tap and hold) while recording, transcribing
//!   or typing puts [`PROMPT_MARKER`] in the first cell, and has two
//!   classes, e.g. `"class": ["recording", "prompt"]`, the state's alt, and
//!   a tooltip such as "LocalFlow: listening (prompt dictation)".
//!
//! Texts and tooltips hold nothing but fixed words, glyphs, digits and
//! those spans: nothing in them ever needs escaping.
//!
//! The agent link's counts on watch lines (see `crate::protocol`):
//!
//! - While idle, loading or without a microphone, an agent needing approval
//!   adds the class `agent-approval` and, unless the microphone is missing,
//!   shows [`APPROVAL_GLYPH`] in place of the state's glyph (no microphone
//!   comes first: nothing can be dictated until one is back); else one
//!   waiting for input adds `agent-input`
//!   (the glyph stays); pending suggestions add `suggestion` (in that order,
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
/// nf-fa-hand_paper_o (Font Awesome's raised hand): an agent needs you.
pub const APPROVAL_GLYPH: &str = "\u{f256}";
/// The first cell of a prompt dictation's text.
pub const PROMPT_MARKER: char = '\u{203a}';

/// Characters in every text: one cell each in a monospace (Nerd) font.
pub const WIDTH: usize = 6;
/// The cell of a state's glyph; the agent count takes the last two.
pub const GLYPH_CELL: usize = 2;
/// Cells of the voice kept while recording: every cell but the anchor's.
pub const HISTORY: usize = WIDTH - 1;

/// The wave's small dot, U+2022 bullet: in JetBrainsMono about 0.43 of a
/// cell across, as a resting dot on the iPhone is about half a full one.
pub const SMALL_DOT: char = '\u{2022}';
/// The wave's full dot, U+25CF black circle: 620 units of ink in a 600-unit
/// cell in JetBrainsMono (1221 in 1233 in DejaVu Sans Mono), so two side by
/// side would fuse; see [`CAPPED`]. Also the anchor in the last cell.
pub const FULL_DOT: char = '\u{25cf}';

/// The wave's steps, quietest first: a dot and its alpha in percent. As the
/// iPhone's DotWave, a dot at rest is half a full dot's size and dimmer,
/// and louder dots grow and brighten together. At rest it is 60%: at 50%
/// the 3 px dot was 2.6:1 on the black pill at 1x, darker than the idle
/// microphone; 60% is 3.4:1. Monospace fonts such as JetBrainsMono and
/// DejaVu Sans Mono draw both dots one cell wide, with no round dot between
/// their sizes (`·` is smaller than a resting one), so alpha carries the
/// steps between.
pub const STEPS: [(char, u8); 5] = [
    (SMALL_DOT, 60),
    (SMALL_DOT, 80),
    (SMALL_DOT, 100),
    (FULL_DOT, 80),
    (FULL_DOT, 100),
];
/// The step a full dot shows instead beside another full dot (the anchor
/// included): the brightest small dot, so the two stay apart and the cell
/// still reads as loud.
pub const CAPPED: usize = 2;

/// Level lines (every 66 ms while recording) per cell of the wave: a
/// syllable crosses its five cells in about 0.66 s, near the iPhone's
/// 0.75 s, instead of rushing through in 0.33 s.
pub const LINES_PER_CELL: usize = 2;
/// How far the followed level can fall in one cell (132 ms): to 35% of
/// itself, about the iPhone's 90 ms fall plus its softening. It rises at
/// once, so onsets show in the next cell, but a dip between syllables no
/// longer drops to rest and the end of a word fades over two cells.
pub const FALL: f32 = 0.35;

/// The font of the wave's cells: equal advances even in a proportional bar
/// font. On a monospace bar it is usually the same font.
pub const WAVE_FONT: &str = "monospace";

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

/// Levels up to this (in 0..=100) are room noise: a dot at rest.
const NOISE: f32 = 4.0;

/// The [`STEPS`] index for a level of 0..=100: at rest up to [`NOISE`],
/// then a square-root curve so quiet speech still shows.
pub fn step(level: u8) -> usize {
    let v = ((f32::from(level.min(100)) - NOISE).max(0.0) / (100.0 - NOISE)).sqrt();
    (v * (STEPS.len() - 1) as f32).round() as usize
}

/// One cell of the wave for a [`STEPS`] index, as Pango markup: the step's
/// dot, in a span with its alpha unless that is 100%.
pub fn dot(step: usize) -> String {
    match STEPS[step.min(STEPS.len() - 1)] {
        (glyph, 100) => glyph.to_string(),
        (glyph, alpha) => format!("<span alpha=\"{alpha}%\">{glyph}</span>"),
    }
}

/// Whether a step shows the full dot.
fn is_full(step: usize) -> bool {
    STEPS[step].0 == FULL_DOT
}

/// A text as Waybar shows it: without the wave's markup.
pub fn plain(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(i) = rest.find('<') {
        out.push_str(&rest[..i]);
        rest = rest[i..].split_once('>').map_or("", |(_, after)| after);
    }
    out.push_str(rest);
    out
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
            1 => lines.push("1 dictionary suggestion waiting".into()),
            n => lines.push(format!("{n} dictionary suggestions waiting")),
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
    /// The current recording's recent cells, oldest first: [`STEPS`]
    /// indices, a full dot after another already capped.
    cells: VecDeque<usize>,
    /// Levels of the cell still being heard (fewer than
    /// [`LINES_PER_CELL`]), and the loudest of them.
    heard: usize,
    loudest: u8,
    /// The followed level, 0..=100.
    follow: f32,
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
                *self = Indicator::default();
            }
            if let Some(l) = level {
                self.hear(l);
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
        let mut glyph = class.glyph();
        if !busy {
            if n.approval > 0 {
                classes.push(AGENT_APPROVAL_CLASS);
                if class != Class::NoMic {
                    glyph = APPROVAL_GLYPH;
                }
            } else if n.input > 0 {
                classes.push(AGENT_INPUT_CLASS);
            }
            if n.suggestions > 0 {
                classes.push(SUGGESTION_CLASS);
            }
            waiting = n.approval.saturating_add(n.input);
        }
        let text = match class {
            Class::Recording if prompt => self.wave(PROMPT_MARKER.to_string(), WIDTH - 2),
            Class::Recording => self.wave(String::new(), WIDTH - 1),
            _ => field(prompt, glyph, waiting),
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

    /// One level line while recording: every [`LINES_PER_CELL`] lines, the
    /// loudest of them goes through the follower into a new cell.
    fn hear(&mut self, level: u8) {
        self.loudest = self.loudest.max(level.min(100));
        self.heard += 1;
        if self.heard < LINES_PER_CELL {
            return;
        }
        self.follow = f32::from(self.loudest).max(self.follow * FALL);
        (self.heard, self.loudest) = (0, 0);
        let mut s = step(self.follow.round() as u8);
        if is_full(s) && self.cells.back().is_some_and(|&b| is_full(b)) {
            s = CAPPED;
        }
        if self.cells.len() == HISTORY {
            self.cells.pop_front();
        }
        self.cells.push_back(s);
    }

    /// `prefix`, the last `cells` cells, newest on the right and padded with
    /// dots at rest, then the anchor, in the monospace span. The newest
    /// cell sits beside the full anchor, so it is capped too.
    fn wave(&self, prefix: String, cells: usize) -> String {
        let shown = self.cells.len().min(cells);
        let mut steps: Vec<usize> = std::iter::repeat_n(0, cells - shown)
            .chain(self.cells.iter().skip(self.cells.len() - shown).copied())
            .collect();
        if let Some(newest) = steps.last_mut().filter(|s| is_full(**s)) {
            *newest = CAPPED;
        }
        let dots: String = steps.into_iter().map(dot).collect();
        format!("<span font_family=\"{WAVE_FONT}\">{prefix}{dots}{FULL_DOT}</span>")
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

    /// A recording's text: `prefix` (the prompt marker or nothing), the
    /// wave's cells for `steps` (oldest first), then the anchor, in the
    /// monospace span.
    fn wave_text(prefix: &str, steps: &[usize]) -> String {
        let cells: String = steps.iter().map(|&s| dot(s)).collect();
        format!("<span font_family=\"monospace\">{prefix}{cells}{FULL_DOT}</span>")
    }

    /// A plain recording's text for `steps`, one per wave cell.
    fn rec_text(steps: [usize; WIDTH - 1]) -> String {
        wave_text("", &steps)
    }

    /// The watch line of a plain recording at `level`.
    fn rec(level: u8) -> String {
        format!("state=recording mode=hold model=ready mic=present level={level}")
    }

    /// Feeds `levels` as recording lines; the text after the last.
    fn feed(ind: &mut Indicator, levels: &[u8]) -> String {
        let mut t = String::new();
        for &l in levels {
            t = text(&ind.update(&rec(l)).unwrap());
        }
        t
    }

    /// The step of each cell a text shows (the anchor and any prompt marker
    /// left out), read back from its markup.
    fn shown_steps(t: &str) -> Vec<usize> {
        let inner = t
            .strip_prefix("<span font_family=\"monospace\">")
            .and_then(|t| t.strip_suffix(&format!("{FULL_DOT}</span>")))
            .expect(t);
        let inner = inner.strip_prefix(PROMPT_MARKER).unwrap_or(inner);
        let mut out = Vec::new();
        let mut rest = inner;
        while !rest.is_empty() {
            let s = (0..STEPS.len())
                .find(|&s| rest.starts_with(&dot(s)))
                .expect(t);
            out.push(s);
            rest = &rest[dot(s).len()..];
        }
        out
    }

    fn full(s: usize) -> bool {
        STEPS[s].0 == FULL_DOT
    }

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
        let mut seen: Vec<String> = Vec::new();
        for (fields, want) in cases {
            assert_eq!(ind.update(fields).as_deref(), Some(want), "{fields}");
            seen.push(want.into());
        }
        // A recording's first line: listening, the wave still at rest.
        let recording = ind
            .update("state=recording mode=hold model=ready mic=present level=100")
            .unwrap();
        assert_eq!(
            recording,
            format!(
                "{{\"text\": {}, \"alt\": \"recording\", \"class\": \"recording\", \"tooltip\": \"LocalFlow: listening\"}}",
                json_string(&rec_text([0; WIDTH - 1]))
            )
        );
        seen.push(recording);
        let offline = ind.offline();
        assert_eq!(
            offline,
            "{\"text\": \"  \u{f011}   \", \"alt\": \"offline\", \"class\": \"offline\", \"tooltip\": \"LocalFlow isn\u{2019}t running\"}"
        );
        seen.push(offline);
        // Every class appears, and every object is valid JSON with the four
        // fields.
        for class in Class::ALL {
            let tag = format!("\"class\": \"{}\"", class.name());
            assert!(seen.iter().any(|o| o.contains(&tag)), "{tag}");
        }
        for o in &seen {
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
            APPROVAL_GLYPH,
        ];
        for (i, a) in glyphs.iter().enumerate() {
            assert_eq!(a.chars().count(), 1);
            for b in &glyphs[i + 1..] {
                assert_ne!(a, b);
            }
            let c = a.chars().next().unwrap();
            assert!(STEPS.iter().all(|&(d, _)| d != c));
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
            let shown = plain(t);
            assert_eq!(shown.chars().count(), WIDTH, "{t:?}");
            let glyph = shown.chars().nth(GLYPH_CELL).unwrap();
            assert_ne!(glyph, ' ', "{t:?}");
        }
        // The count stays in the last two cells, after a space.
        assert_eq!(texts[11], format!("  {APPROVAL_GLYPH} 1 "));
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
            wave_text(&PROMPT_MARKER.to_string(), &[0; WIDTH - 2])
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
        // A fresh recording's first line: the wave at rest.
        let loud = json_string(&rec_text([0; WIDTH - 1]));
        let cases = [
            (
                "state=idle model=ready mic=present suggestions=3 words=12 agent-approval=2 agent-input=1 agent-working=1 agent-done=4".to_owned(),
                "{\"text\": \"  \u{f256} 3 \", \"alt\": \"idle\", \"class\": [\"idle\", \"agent-approval\", \"suggestion\"], \"tooltip\": \"LocalFlow: ready\\nAgents: 2 need approval, 1 waiting for input, 1 working, 4 done\\n3 dictionary suggestions waiting\\n12 project words boosted\"}".to_owned(),
            ),
            (
                "state=idle model=loading mic=unknown agent-input=1".into(),
                "{\"text\": \"  \u{f017} 1 \", \"alt\": \"loading\", \"class\": [\"loading\", \"agent-input\"], \"tooltip\": \"LocalFlow: loading the model\\nAgents: 1 waiting for input\"}".into(),
            ),
            (
                "state=idle model=ready mic=absent suggestions=1".into(),
                "{\"text\": \"  \u{f131}   \", \"alt\": \"nomic\", \"class\": [\"nomic\", \"suggestion\"], \"tooltip\": \"LocalFlow: no microphone\\n1 dictionary suggestion waiting\"}".into(),
            ),
            (
                "state=idle model=ready mic=present agent-approval=1".into(),
                "{\"text\": \"  \u{f256} 1 \", \"alt\": \"idle\", \"class\": [\"idle\", \"agent-approval\"], \"tooltip\": \"LocalFlow: ready\\nAgents: 1 needs approval\"}".into(),
            ),
            // Working and done alone add no class and no count.
            (
                "state=idle model=ready mic=present agent-working=1 agent-done=1 words=1".into(),
                "{\"text\": \"  \u{f130}   \", \"alt\": \"idle\", \"class\": \"idle\", \"tooltip\": \"LocalFlow: ready\\nAgents: 1 working, 1 done\\n1 project word boosted\"}".into(),
            ),
            // Busy states keep their classes and text; only the tooltip grows.
            (
                "state=recording mode=hold model=ready mic=present level=100 agent-approval=1 suggestions=2".into(),
                format!("{{\"text\": {loud}, \"alt\": \"recording\", \"class\": \"recording\", \"tooltip\": \"LocalFlow: listening\\nAgents: 1 needs approval\\n2 dictionary suggestions waiting\"}}"),
            ),
            (
                "state=transcribing model=ready mic=present agent-input=3 words=2".into(),
                "{\"text\": \"  \u{f252}   \", \"alt\": \"transcribing\", \"class\": \"transcribing\", \"tooltip\": \"LocalFlow: transcribing\\nAgents: 3 waiting for input\\n2 project words boosted\"}".into(),
            ),
            (
                "state=typing tag=prompt model=ready mic=present agent-input=2 suggestions=1".into(),
                "{\"text\": \"\u{203a} \u{f11c}   \", \"alt\": \"typing\", \"class\": [\"typing\", \"prompt\"], \"tooltip\": \"LocalFlow: typing (prompt dictation)\\nAgents: 2 waiting for input\\n1 dictionary suggestion waiting\"}".into(),
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
        let last = STEPS.len() - 1;
        assert_eq!(step(0), 0);
        assert_eq!(step(100), last);
        assert_eq!(step(255), last);
        // Room noise stays at rest; the square-root curve lifts quiet
        // speech: 10% is already a step up, 30% two, and half-loud speech
        // reaches the full dot.
        assert_eq!(step(4), 0);
        assert_eq!(step(10), 1);
        assert_eq!(step(30), 2);
        assert_eq!(STEPS[step(50)].0, FULL_DOT);
        // Louder is never smaller or dimmer.
        assert!((0..100).all(|l| step(l) <= step(l + 1)));
        let mut ind = Indicator::default();
        // A recording starts as silence: a row of equal small dots.
        assert_eq!(
            text(
                &ind.update("state=recording mode=toggle model=ready mic=present")
                    .unwrap()
            ),
            rec_text([0; WIDTH - 1])
        );
        // Each new cell comes in on the right, beside the anchor.
        assert_eq!(feed(&mut ind, &[0, 30]), rec_text([0, 0, 0, 0, 2]));
        assert_eq!(feed(&mut ind, &[10, 10]), rec_text([0, 0, 0, 2, 1]));
        // Silence scrolls it out.
        feed(&mut ind, &[0; 4 * HISTORY]);
        assert_eq!(feed(&mut ind, &[30, 0]), rec_text([0, 0, 0, 0, 2]));
        // A recording line without a level keeps the wave.
        assert_eq!(
            text(&ind.update("state=recording mode=hold model=ready").unwrap()),
            rec_text([0, 0, 0, 0, 2])
        );
        // A prompt dictation shows the newest cells after its marker.
        let prompt =
            |l: u8| format!("state=recording tag=prompt model=ready mic=present level={l}");
        ind.update(&prompt(10));
        assert_eq!(
            text(&ind.update(&prompt(10)).unwrap()),
            wave_text(&PROMPT_MARKER.to_string(), &[0, 0, 2, 1])
        );
        // The next recording starts from silence: neither the last
        // recording's cells nor half a pair of its levels carry over.
        ind.update(&rec(100));
        ind.update("state=transcribing model=ready mic=present");
        assert_eq!(feed(&mut ind, &[0, 0]), rec_text([0; WIDTH - 1]));
        ind.offline();
        assert_eq!(feed(&mut ind, &[0, 0]), rec_text([0; WIDTH - 1]));
    }

    #[test]
    fn the_wave_rests_and_swells_as_the_iphones_does() {
        // At rest: the small dot, dimmed (about half as bright as a full
        // dot on the iPhone; 60% is the least that keeps a 3:1 contrast
        // on the black pill at 1x); at the top of the swell: the full dot
        // at full brightness.
        assert_eq!(STEPS[0], (SMALL_DOT, 60));
        assert_eq!(STEPS[STEPS.len() - 1], (FULL_DOT, 100));
        // Dots grow and brighten together, step by step.
        let size = |c: char| usize::from(c == FULL_DOT);
        for w in STEPS.windows(2) {
            let ((a, x), (b, y)) = (w[0], w[1]);
            assert!(size(a) <= size(b), "{w:?}");
            assert!(size(a) < size(b) || x < y, "{w:?}");
            assert!(x <= 100 && y <= 100);
        }
        // Standard characters only: no Nerd Font needed.
        for (c, _) in STEPS {
            let c = c as u32;
            assert!(!(0xe000..=0xf8ff).contains(&c) && c < 0xf0000);
        }
        assert_eq!(dot(0), "<span alpha=\"60%\">\u{2022}</span>");
        assert_eq!(dot(STEPS.len() - 1), "\u{25cf}");

        // Silence is a calm row of equal resting dots before the anchor.
        let mut ind = Indicator::default();
        let quiet = feed(&mut ind, &[0, 3, 2, 4, 1, 0, 2, 3, 0, 1, 4, 2]);
        assert_eq!(quiet, rec_text([0; WIDTH - 1]));
        assert_eq!(
            plain(&quiet),
            "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{25cf}"
        );
        // Speech undulates, in size as well as brightness.
        let speech = feed(&mut ind, &[40, 85, 6, 9, 30, 20, 2, 5, 60, 55, 30, 9]);
        let steps = shown_steps(&speech);
        assert!(
            steps.iter().any(|&s| full(s)) && steps.iter().any(|&s| !full(s)),
            "{speech}"
        );
        let mut distinct = steps.clone();
        distinct.sort();
        distinct.dedup();
        assert!(distinct.len() >= 3, "{steps:?}");
    }

    #[test]
    fn a_recording_always_ends_in_the_full_anchor_dot() {
        // Silence reads as listening: whatever the voice, the last cell is
        // the full dot at full brightness, as the iPhone's wave comes to
        // rest in the mark's dot; the wave takes the cells before it.
        let mut ind = Indicator::default();
        let first = text(
            &ind.update("state=recording mode=hold model=ready mic=present")
                .unwrap(),
        );
        assert_eq!(
            plain(&first),
            "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{25cf}"
        );
        let prompt = text(
            &ind.update("state=recording tag=prompt model=ready mic=present level=0")
                .unwrap(),
        );
        assert_eq!(
            plain(&prompt),
            "\u{203a}\u{2022}\u{2022}\u{2022}\u{2022}\u{25cf}"
        );
        let mut ind = Indicator::default();
        let mut seed = 7u32;
        for _ in 0..400 {
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            let t = text(&ind.update(&rec((seed >> 16) as u8 % 101)).unwrap());
            assert!(t.ends_with(&format!("{FULL_DOT}</span>")), "{t}");
            assert_eq!(shown_steps(&t).len(), WIDTH - 1, "{t}");
        }
    }

    #[test]
    fn the_wave_is_set_in_one_monospace_span() {
        // A proportional bar font draws `•` and `●` at different widths;
        // the span gives every cell of the wave the same advance, so the
        // clock beside the module holds still while you speak.
        let mut ind = Indicator::default();
        for line in [
            "state=recording mode=hold model=ready mic=present",
            "state=recording mode=hold model=ready mic=present level=90",
            "state=recording mode=hold tag=prompt model=ready mic=present level=40",
        ] {
            let t = text(&ind.update(line).unwrap());
            assert!(t.starts_with("<span font_family=\"monospace\">"), "{t}");
            assert!(t.ends_with("</span>"), "{t}");
            assert_eq!(t.matches("font_family").count(), 1, "{t}");
        }
        // Other states keep the bar's font, for Font Awesome's glyphs.
        for line in [
            "state=idle model=ready mic=present",
            "state=transcribing model=ready mic=present",
        ] {
            assert!(!text(&ind.update(line).unwrap()).contains('<'));
        }
    }

    #[test]
    fn one_cell_per_two_level_lines_with_the_louder_of_the_pair() {
        // Level lines come every 66 ms; a cell every second one makes a
        // syllable cross the wave in about 0.66 s, near the iPhone's 0.75 s.
        let silent = rec_text([0; WIDTH - 1]);
        for pair in [[30, 0], [0, 30], [30, 10]] {
            let mut ind = Indicator::default();
            assert_eq!(feed(&mut ind, &[0, 0, 0, 0]), silent);
            // The first line of a pair changes nothing: the same object,
            // which `watch --waybar` does not write again.
            let before = ind.update(&rec(0)).unwrap();
            assert_eq!(ind.update(&rec(0)).unwrap(), before);
            let held = ind.update(&rec(pair[0])).unwrap();
            assert_eq!(text(&held), silent, "{pair:?}");
            // The second adds one cell for the louder of the two.
            assert_eq!(
                feed(&mut ind, &[pair[1]]),
                rec_text([0, 0, 0, 0, 2]),
                "{pair:?}"
            );
        }
    }

    #[test]
    fn onsets_show_within_one_cell_and_silence_after_speech_decays() {
        // Speech arriving on either line of a pair shows by the line after
        // it at the latest: within one cell.
        for lines in [[60, 0], [0, 60]] {
            let mut ind = Indicator::default();
            feed(&mut ind, &[0, 0, 0, 0]);
            let t = feed(&mut ind, &lines);
            assert!(shown_steps(&t)[WIDTH - 2] > 0, "{lines:?} {t}");
        }
        // A loud cell beside the anchor is the brightest small dot, and
        // grows to the full dot one cell later (full dots never touch).
        let mut ind = Indicator::default();
        let loud = feed(&mut ind, &[0, 0, 100, 100]);
        assert_eq!(STEPS[shown_steps(&loud)[WIDTH - 2]], (SMALL_DOT, 100));
        let next = feed(&mut ind, &[0, 0]);
        assert_eq!(shown_steps(&next)[WIDTH - 3], STEPS.len() - 1);

        // After speech the wave falls a step or two a cell: the first cell
        // of silence is still lit, and it is at rest within three cells.
        let mut ind = Indicator::default();
        feed(&mut ind, &[100, 100]);
        let mut tail = Vec::new();
        for _ in 0..4 {
            tail.push(*shown_steps(&feed(&mut ind, &[0, 0])).last().unwrap());
        }
        assert!(tail[0] > 0, "{tail:?}");
        assert!(tail.windows(2).all(|w| w[1] <= w[0]), "{tail:?}");
        assert_eq!(tail[2..], [0, 0], "{tail:?}");
        // Speech rises at once even while the wave is falling.
        let up = feed(&mut ind, &[0, 0, 100, 0]);
        assert!(shown_steps(&up)[WIDTH - 2] >= 2, "{up}");
    }

    #[test]
    fn full_dots_never_touch() {
        // `●` is wider than its cell, so two side by side fuse into one
        // blob at 1x: the second of two loud cells, and a loud cell beside
        // the anchor, show as the brightest small dot instead.
        let capped = (0..STEPS.len()).rfind(|&s| !full(s)).unwrap();
        assert_eq!(STEPS[capped], (SMALL_DOT, 100));
        let mut ind = Indicator::default();
        let mut seed = 99u32;
        let mut fulls = 0;
        for i in 0..2000 {
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            let level = match i % 300 {
                // Stretches of sustained loud speech, and of silence.
                0..40 => 100,
                40..60 => 0,
                _ => (seed >> 16) as u8 % 101,
            };
            let line = if i % 500 < 250 {
                rec(level)
            } else {
                format!("state=recording tag=prompt model=ready mic=present level={level}")
            };
            let t = text(&ind.update(&line).unwrap());
            let shown: Vec<char> = plain(&t).chars().collect();
            assert!(shown.windows(2).all(|w| w != [FULL_DOT, FULL_DOT]), "{t}");
            fulls += shown.iter().filter(|&&c| c == FULL_DOT).count() - 1;
        }
        // Loud speech still shows full dots.
        assert!(fulls > 500, "{fulls}");
        // A lone loud syllable keeps its full dot all the way across.
        let mut ind = Indicator::default();
        feed(&mut ind, &[0, 0, 100, 100]);
        for cell in (0..WIDTH - 2).rev() {
            let t = feed(&mut ind, &[0, 0]);
            assert_eq!(shown_steps(&t)[cell], STEPS.len() - 1, "{t}");
        }
    }

    #[test]
    fn nothing_in_a_text_or_tooltip_needs_escaping() {
        // Every text and tooltip, across states, counts and levels.
        let mut ind = Indicator::default();
        let mut objects = vec![ind.offline()];
        for state in ["idle", "recording", "transcribing", "typing", "exploding"] {
            for extra in [
                "",
                " tag=prompt",
                " mic=absent",
                " model=loading",
                " agent-approval=3 agent-input=200 agent-working=1 agent-done=7 suggestions=1 words=40",
                " agent-input=1 suggestions=12 words=1",
            ] {
                for level in [0, 1, 4, 5, 9, 10, 29, 30, 49, 50, 77, 99, 100, 101, 255] {
                    let line = format!(
                        "state={state} mode=hold model=ready mic=present level={level}{extra}"
                    );
                    objects.extend(ind.update(&line));
                }
            }
        }
        assert!(objects.len() > 300);
        for o in &objects {
            let v = json(o);
            let (t, tip) = (v["text"].as_str().unwrap(), v["tooltip"].as_str().unwrap());
            // The only markup: the wave's one monospace span, and inside
            // it alpha spans, each around one dot.
            let mut rest = match t.strip_prefix("<span font_family=\"monospace\">") {
                Some(inner) => inner.strip_suffix("</span>").expect(t),
                None => t,
            };
            while let Some(i) = rest.find('<') {
                let (head, tail) = rest[i..].split_once("%\">").expect(t);
                let alpha = head.strip_prefix("<span alpha=\"").expect(t);
                assert!(alpha.parse::<u8>().is_ok_and(|a| a < 100), "{t:?}");
                let mut chars = tail.chars();
                let dot = chars.next();
                assert!(STEPS.iter().any(|&(d, _)| Some(d) == dot), "{t:?}");
                rest = chars.as_str().strip_prefix("</span>").expect(t);
            }
            let shown = plain(t);
            assert_eq!(shown.chars().count(), WIDTH, "{t:?}");
            for s in [shown.as_str(), tip] {
                assert!(!s.contains(['<', '>', '&']), "{s:?}");
            }
        }
    }

    #[test]
    fn an_agent_needing_approval_shows_the_hand_unless_the_microphone_is_missing() {
        let mut ind = Indicator::default();
        let cases = [
            (
                "idle model=ready mic=present agent-approval=1",
                APPROVAL_GLYPH,
                " 1 ",
            ),
            (
                "idle model=ready mic=present agent-approval=2 agent-input=3",
                APPROVAL_GLYPH,
                " 5 ",
            ),
            (
                "idle model=loading mic=present agent-approval=1",
                APPROVAL_GLYPH,
                " 1 ",
            ),
            // Without a microphone, its glyph stays: nothing can be
            // dictated until one is back. The count still shows.
            (
                "idle model=ready mic=absent agent-approval=1",
                NO_MIC_GLYPH,
                " 1 ",
            ),
            // Waiting for input only: the state's glyph and the count.
            (
                "idle model=ready mic=present agent-input=2",
                MIC_GLYPH,
                " 2 ",
            ),
            (
                "idle model=loading mic=present agent-input=1",
                LOADING_GLYPH,
                " 1 ",
            ),
            // Busy states keep their own glyph.
            (
                "transcribing model=ready mic=present agent-approval=1",
                TRANSCRIBING_GLYPH,
                "   ",
            ),
        ];
        for (fields, glyph, count) in cases {
            let t = text(&ind.update(&format!("state={fields}")).unwrap());
            assert_eq!(t, format!("  {glyph}{count}"), "{fields}");
        }
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

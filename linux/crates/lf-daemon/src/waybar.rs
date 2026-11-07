//! `localflowctl watch --waybar`: turns watch lines into Waybar custom-module
//! JSON, one object per line:
//!
//! ```text
//! {"text": "<glyph or dots>", "alt": "<class>", "class": "<class>", "tooltip": "LocalFlow: ..."}
//! ```
//!
//! Classes (and alts): idle, loading, recording, transcribing, typing,
//! nomic, offline. Every text is [`WIDTH`] cells of a monospace font wide,
//! so the module and the clock beside it never move between states. The
//! pill follows the iPhone keyboard's dictation island:
//!
//! - Recording shows a white wave that comes to rest in the mark's aurora
//!   dot (#6DFFA8, [`AURORA`]): a row of [`WAVE_DOTS`] half-size dots along
//!   the middle line, the voice's last half second, newest on the right
//!   beside the anchor. Each level line (every 66 ms) moves the row one dot
//!   to the left, through a follower that rises at once and falls quickly,
//!   so a syllable is a pulse that crosses the row and leaves it. Louder
//!   dots grow and brighten; in silence the row is calm, equal resting
//!   dots. As on the keyboard, the row rises out of the line at its left
//!   end ([`ENVELOPE`]). The anchor is always lit, so silence still reads
//!   as listening; its colour is set in the markup, so it is aurora on any
//!   bar, with or without the README's CSS. The wave's dots take the
//!   module's colour (white in the README's CSS).
//! - Transcribing shows the keyboard's wait: the row at rest, without the
//!   anchor, with a brighter, larger spot sweeping it left to right every
//!   1.1 s ([`shimmer`]). `localflowctl` draws a frame every
//!   [`SHIMMER_FRAME`] while it lasts ([`Indicator::next_frame`],
//!   [`Indicator::tick`]), and never in any other state. Its colour is the
//!   module's (glacier white, #ABF2FC, in the README's CSS).
//! - Every other state shows its glyph in the third cell ([`GLYPH_CELL`]).
//!   Glyphs are Font Awesome icons as Nerd Fonts carry them, drawn wider
//!   than one cell, so the glyph sits about in the middle; a bar config can
//!   replace them with `format-icons` keyed by `alt`.
//! - A prompt dictation (double-tap and hold) while recording, transcribing
//!   or typing puts [`PROMPT_MARKER`] in the first cell, and has two
//!   classes, e.g. `"class": ["recording", "prompt"]`, the state's alt, and
//!   a tooltip such as "LocalFlow: listening (prompt dictation)".
//!
//! The rows are Pango markup (Waybar's default for custom modules), in one
//! `<span font_family="monospace">`, so a proportional bar font still gives
//! their cells equal widths. A dot is a standard character (U+2022 or
//! U+25CF, so no Nerd Font is needed) in a span at half the bar font's size
//! ([`DOT_SIZE`]), followed by a space an eighth of a cell wide
//! ([`GAP_SIZE`]): eight dots and their gaps take five cells, and even two
//! full dots side by side stay apart. Dimmer dots add `alpha`, and each
//! size has its own `rise` so every dot sits on the bar's middle line. A
//! zero-width space ([`STRUT`]) at the bar font's size leads each row, so
//! its line is as tall as every other state's. The sizes are relative, so
//! a row is six cells as the markup measures it ([`cells`]); each size's
//! advance is rounded to whole pixels, so at some bar font sizes a row
//! comes out a pixel or two wider, which the README's CSS (`min-width`)
//! absorbs. `rise` is absolute, tuned for a bar font of about 13 px.
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
use std::time::Duration;

use crate::watch::LEVEL_INTERVAL;

/// nf-fa-microphone: ready.
pub const MIC_GLYPH: &str = "\u{f130}";
/// nf-fa-clock_o: the model is loading.
pub const LOADING_GLYPH: &str = "\u{f017}";
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

/// Cells in every text: characters of a monospace (Nerd) font.
pub const WIDTH: usize = 6;
/// The cell of a state's glyph; the agent count takes the last two.
pub const GLYPH_CELL: usize = 2;

/// The row's small dot, U+2022 bullet: in JetBrainsMono about 0.43 of a
/// cell across, as a resting dot on the keyboard is about half a full one.
pub const SMALL_DOT: char = '\u{2022}';
/// The row's full dot, U+25CF black circle (620 units of ink in a 600-unit
/// cell in JetBrainsMono, 1221 in 1233 in DejaVu Sans Mono). Also the
/// anchor.
pub const FULL_DOT: char = '\u{25cf}';
/// Leads every row, at the bar font's size: a zero-width space, so the row's
/// line is as tall as a glyph state's and its dots sit on the same middle
/// line (a row of smaller text alone is a shorter line, centred
/// differently).
pub const STRUT: char = '\u{200b}';

/// The steps of the row's dots, quietest first: a dot and its alpha in
/// percent. As on the keyboard, a resting dot is half a full one's size and
/// dimmer, and louder dots grow and brighten together. At rest it is 60%:
/// the 2 px dot is 4.8:1 on the black pill at 1x. Monospace fonts draw both
/// dots one cell wide, with no round dot between their sizes (`·` is
/// smaller than a resting one), so alpha carries the steps between.
pub const STEPS: [(char, u8); 5] = [
    (SMALL_DOT, 60),
    (SMALL_DOT, 80),
    (SMALL_DOT, 100),
    (FULL_DOT, 80),
    (FULL_DOT, 100),
];

/// The mark's dot the wave settles into, as the keyboard's (`BrandPalette`'s
/// aurora). Fixed in the markup, whatever the bar's CSS.
pub const AURORA: &str = "#6DFFA8";

/// Dots in the recording's row, and after a prompt dictation's marker.
pub const WAVE_DOTS: usize = 8;
pub const PROMPT_WAVE_DOTS: usize = 6;
/// Dots in the shimmer's row (it has no anchor), and after the marker.
pub const SHIMMER_DOTS: usize = 9;
pub const PROMPT_SHIMMER_DOTS: usize = 8;

/// A dot's size, relative to the bar font: two dots' cells in one cell.
pub const DOT_SIZE: &str = "50%";
/// The space after each dot: an eighth of a cell (1 px in a 13 px font), so
/// the row's pitch is five eighths of a cell and full dots never touch.
pub const GAP_SIZE: &str = "12.5%";
/// The anchor's size: larger than any dot of the wave, as the mark's dot.
pub const ANCHOR_SIZE: &str = "75%";
/// The space before the anchor, which with it fills the row's sixth cell
/// (after a prompt marker, [`PROMPT_ANCHOR_PAD`]).
pub const ANCHOR_PAD: &str = "25%";
pub const PROMPT_ANCHOR_PAD: &str = "50%";
/// The shimmer's room either side of its nine dots, centring them.
pub const SHIMMER_LEAD: &str = "25%";
pub const SHIMMER_TRAIL: &str = "12.5%";

/// Each glyph's `rise` in Pango units (1/1024 px; measured in JetBrainsMono
/// Bold at 12.9 px and DejaVu Sans Mono at 13 px): lifts the smaller dots
/// back onto the line a full-size glyph's middle sits on. Hinting snaps the
/// two dots differently, so each has its own.
const SMALL_RISE: u32 = 1792;
const FULL_RISE: u32 = 2560;
const ANCHOR_RISE: u32 = 1664;

/// The keyboard's follower (`DotWave.LevelFollower`): the time constants of
/// the rise and the fall, in seconds. Per level line it closes 93% of the
/// gap upwards and 52% downwards.
const RISE_TIME: f32 = 0.025;
const FALL_TIME: f32 = 0.09;

/// How far each dot of the row can lift ([`STEPS`] indices), oldest first:
/// the keyboard's envelope (`DotWave.envelope`) at each dot, as a ceiling.
/// None at the left end, so the voice rises out of the line there, all of
/// it from a little past the middle, a little less beside the anchor.
pub const ENVELOPE: [usize; WAVE_DOTS] = [0, 1, 2, 3, 4, 4, 4, 3];
/// The same for a prompt dictation's shorter row.
pub const PROMPT_ENVELOPE: [usize; PROMPT_WAVE_DOTS] = [0, 1, 3, 4, 4, 3];

/// One frame of the shimmer: ten a second.
pub const SHIMMER_FRAME: Duration = Duration::from_millis(100);
/// Frames in one sweep (1.1 s, as the keyboard's `shimmerPeriod`): the spot
/// moves one dot a frame, from one dot before the row to one past it.
pub const SWEEP_FRAMES: usize = 11;
/// The spot's steps at its centre and one and two dots away: the keyboard's
/// glow (a Gaussian a fifth of the row wide) at whole dots.
const SPOT: [usize; 3] = [4, 2, 1];

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

    /// The glyph of the states without a row of dots.
    fn glyph(self) -> &'static str {
        match self {
            Class::Idle | Class::Recording | Class::Transcribing => MIC_GLYPH,
            Class::Loading => LOADING_GLYPH,
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

/// One dot of a row for a [`STEPS`] index, as Pango markup: the dot at
/// [`DOT_SIZE`] with its rise (and its alpha unless that is 100%), then its
/// gap.
pub fn dot(step: usize) -> String {
    let (glyph, alpha) = STEPS[step.min(STEPS.len() - 1)];
    let rise = if glyph == FULL_DOT {
        FULL_RISE
    } else {
        SMALL_RISE
    };
    let alpha = if alpha == 100 {
        String::new()
    } else {
        format!(" alpha=\"{alpha}%\"")
    };
    format!(
        "<span size=\"{DOT_SIZE}\" rise=\"{rise}\"{alpha}>{glyph}</span>{}",
        space(GAP_SIZE)
    )
}

/// A space at `size`.
fn space(size: &str) -> String {
    format!("<span size=\"{size}\"> </span>")
}

/// `inner` as a row: in the monospace span, after the [`STRUT`].
fn row(inner: &str) -> String {
    format!("<span font_family=\"monospace\">{STRUT}{inner}</span>")
}

/// The shimmer's text `elapsed` after transcribing began (a prompt
/// dictation's after its marker): its row of resting dots with the spot
/// one dot further right every [`SHIMMER_FRAME`], from one dot before the
/// row to one past it, a sweep every [`SWEEP_FRAMES`] frames. The first
/// frame has the spot on the first dot, so it reads as working before any
/// timer runs. No anchor.
pub fn shimmer(elapsed: Duration, prompt: bool) -> String {
    let frame = (elapsed.as_millis() / SHIMMER_FRAME.as_millis()) as usize;
    let spot = ((frame + 1) % SWEEP_FRAMES) as isize - 1;
    let n = if prompt {
        PROMPT_SHIMMER_DOTS
    } else {
        SHIMMER_DOTS
    };
    let dots: String = (0..n as isize)
        .map(|i| dot(SPOT.get(i.abs_diff(spot)).copied().unwrap_or(0)))
        .collect();
    if prompt {
        row(&format!("{PROMPT_MARKER}{dots}"))
    } else {
        row(&format!(
            "{}{dots}{}",
            space(SHIMMER_LEAD),
            space(SHIMMER_TRAIL)
        ))
    }
}

/// A text as Waybar shows it: without the markup.
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

/// A text's width in cells of the bar's font, as its markup asks: each
/// character counts the `size` percentage in force (1 outside any), and the
/// [`STRUT`] none.
pub fn cells(text: &str) -> f64 {
    let mut sizes = vec![1.0];
    let mut width = 0.0;
    let mut rest = text;
    while let Some(c) = rest.chars().next() {
        if c == '<' {
            let (tag, after) = rest[1..].split_once('>').unwrap_or((rest, ""));
            rest = after;
            if tag.starts_with('/') {
                sizes.pop();
            } else {
                let top = *sizes.last().unwrap_or(&1.0);
                let size = tag
                    .split_once("size=\"")
                    .and_then(|(_, v)| v.split_once("%\""))
                    .and_then(|(v, _)| v.parse::<f64>().ok())
                    .map_or(top, |p| p / 100.0);
                sizes.push(size);
            }
            continue;
        }
        if c != STRUT {
            width += sizes.last().copied().unwrap_or(1.0);
        }
        rest = &rest[c.len_utf8()..];
    }
    width
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
    /// The current recording's recent dots, oldest first: [`STEPS`] indices
    /// of the followed level, one per level line.
    cells: VecDeque<usize>,
    /// The followed level, 0..=100.
    follow: f32,
    recording: bool,
    /// While transcribing: the shimmer's frame shown, counted from the
    /// start of the wait.
    frame: Option<u32>,
    /// The last watch line's fields, which a shimmer frame shows again.
    fields: String,
}

impl Indicator {
    /// The object for one watch line's fields (the part after `ok `), or
    /// `None` for an unknown state.
    pub fn update(&mut self, fields: &str) -> Option<String> {
        let class = Class::from_fields(fields)?;
        if class == Class::Recording {
            if !self.recording {
                *self = Indicator::default();
            }
            let level = fields
                .split(' ')
                .find_map(|f| f.strip_prefix("level="))
                .and_then(|v| v.parse::<u8>().ok());
            if let Some(l) = level {
                self.hear(l);
            }
        }
        self.recording = class == Class::Recording;
        // A wait starts its sweep at the first frame; another line while it
        // lasts (new counts) keeps the frame.
        self.frame = match class {
            Class::Transcribing => Some(self.frame.unwrap_or(0)),
            _ => None,
        };
        fields.clone_into(&mut self.fields);
        Some(self.show(class, fields))
    }

    /// While transcribing, how long after the wait began the shimmer's next
    /// frame is due; `None` in every other state, so no timer runs.
    pub fn next_frame(&self) -> Option<Duration> {
        self.frame.map(|f| SHIMMER_FRAME * (f + 1))
    }

    /// The object for the shimmer `elapsed` after the wait began, or `None`
    /// unless transcribing. A frame that is still showing comes back
    /// unchanged (`watch --waybar` does not write it again).
    pub fn tick(&mut self, elapsed: Duration) -> Option<String> {
        let shown = self.frame?;
        let due = (elapsed.as_millis() / SHIMMER_FRAME.as_millis()).min(u128::from(u32::MAX));
        self.frame = Some(shown.max(due as u32));
        let fields = std::mem::take(&mut self.fields);
        let object = self.show(Class::Transcribing, &fields);
        self.fields = fields;
        Some(object)
    }

    /// The object shown while the daemon is unreachable.
    pub fn offline(&mut self) -> String {
        self.recording = false;
        self.frame = None;
        object(Class::Offline, &field(false, Class::Offline.glyph(), 0))
    }

    /// The object for `fields` of `class`, with the wave and the shimmer as
    /// they stand.
    fn show(&self, class: Class, fields: &str) -> String {
        let mut prompt = false;
        let mut n = Counts::default();
        for (k, v) in fields.split(' ').filter_map(|f| f.split_once('=')) {
            let count = || v.parse::<u32>().unwrap_or(0);
            match k {
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
            Class::Recording => self.wave(prompt),
            Class::Transcribing => shimmer(SHIMMER_FRAME * self.frame.unwrap_or(0), prompt),
            _ => field(prompt, glyph, waiting),
        };
        for line in n.tooltip_lines() {
            tooltip.push('\n');
            tooltip += &line;
        }
        render(class, &classes, &text, &tooltip)
    }

    /// One level line while recording: the follower moves towards it (fast
    /// up, quickly down, over one [`LEVEL_INTERVAL`]), and its step is the
    /// row's newest dot.
    fn hear(&mut self, level: u8) {
        let target = f32::from(level.min(100));
        let constant = if target > self.follow {
            RISE_TIME
        } else {
            FALL_TIME
        };
        let share = 1.0 - (-LEVEL_INTERVAL.as_secs_f32() / constant).exp();
        self.follow += (target - self.follow) * share;
        if self.cells.len() == WAVE_DOTS {
            self.cells.pop_front();
        }
        self.cells.push_back(step(self.follow.round() as u8));
    }

    /// The recording's text: the prompt marker if any, the newest dots
    /// (padded at the left with dots at rest), each no higher than the
    /// envelope lets it lift there, then the anchor.
    fn wave(&self, prompt: bool) -> String {
        let envelope: &[usize] = if prompt { &PROMPT_ENVELOPE } else { &ENVELOPE };
        let n = envelope.len();
        let shown = self.cells.len().min(n);
        let dots: String = std::iter::repeat_n(0, n - shown)
            .chain(self.cells.iter().skip(self.cells.len() - shown).copied())
            .zip(envelope)
            .map(|(s, &most)| dot(s.min(most)))
            .collect();
        let (marker, pad) = if prompt {
            (PROMPT_MARKER.to_string(), PROMPT_ANCHOR_PAD)
        } else {
            (String::new(), ANCHOR_PAD)
        };
        row(&format!(
            "{marker}{dots}{}<span size=\"{ANCHOR_SIZE}\" rise=\"{ANCHOR_RISE}\" foreground=\"{AURORA}\">{FULL_DOT}</span>",
            space(pad)
        ))
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

    /// The watch line of a recording at `level`, a prompt dictation or not.
    fn rec_line(prompt: bool, level: u8) -> String {
        let tag = if prompt { " tag=prompt" } else { "" };
        format!("state=recording mode=hold{tag} model=ready mic=present level={level}")
    }

    /// The watch line of a plain recording at `level`.
    fn rec(level: u8) -> String {
        rec_line(false, level)
    }

    /// Feeds `levels` as recording lines; the text after the last.
    fn feed(ind: &mut Indicator, levels: &[u8]) -> String {
        feed_line(ind, false, levels)
    }

    fn feed_line(ind: &mut Indicator, prompt: bool, levels: &[u8]) -> String {
        let mut t = String::new();
        for &l in levels {
            t = text(&ind.update(&rec_line(prompt, l)).unwrap());
        }
        t
    }

    /// One character a text shows, with the Pango span attributes in force
    /// where it stands.
    #[derive(Clone, Debug, Default, PartialEq)]
    struct Glyph {
        c: char,
        font_family: Option<String>,
        size: Option<String>,
        rise: Option<String>,
        alpha: Option<String>,
        foreground: Option<String>,
    }

    impl Glyph {
        /// Its size as a share of the bar font's (1 outside a size span).
        fn scale(&self) -> f64 {
            self.size.as_deref().map_or(1.0, |s| {
                s.strip_suffix('%').unwrap().parse::<f64>().unwrap() / 100.0
            })
        }

        /// Its alpha in percent (100 outside an alpha span).
        fn alpha(&self) -> u8 {
            self.alpha
                .as_deref()
                .map_or(100, |a| a.strip_suffix('%').unwrap().parse().unwrap())
        }

        /// Its [`STEPS`] index, if it is one of the row's dots.
        fn step(&self) -> Option<usize> {
            STEPS
                .iter()
                .position(|&(c, a)| c == self.c && a == self.alpha())
        }
    }

    /// What a text shows, read back from its markup. Only `<span>` with
    /// the attributes the indicator uses is accepted.
    fn glyphs(t: &str) -> Vec<Glyph> {
        let mut stack = vec![Glyph::default()];
        let mut out = Vec::new();
        let mut rest = t;
        while let Some(c) = rest.chars().next() {
            if c != '<' {
                out.push(Glyph {
                    c,
                    ..stack.last().unwrap().clone()
                });
                rest = &rest[c.len_utf8()..];
                continue;
            }
            let (tag, after) = rest[1..].split_once('>').expect(t);
            rest = after;
            if tag == "/span" {
                stack.pop();
                assert!(!stack.is_empty(), "{t}");
                continue;
            }
            let mut g = stack.last().unwrap().clone();
            let mut attrs = tag.strip_prefix("span ").expect(t).trim();
            while !attrs.is_empty() {
                let (key, after) = attrs.split_once("=\"").expect(t);
                let (value, after) = after.split_once('"').expect(t);
                let value = Some(value.to_owned());
                match key {
                    "font_family" => g.font_family = value,
                    "size" => g.size = value,
                    "rise" => g.rise = value,
                    "alpha" => g.alpha = value,
                    "foreground" => g.foreground = value,
                    _ => panic!("unexpected attribute {key} in {t}"),
                }
                attrs = after.trim_start();
            }
            stack.push(g);
        }
        assert_eq!(stack.len(), 1, "unclosed span: {t}");
        out
    }

    /// The row's dots (half-size round dots), oldest first, as [`STEPS`]
    /// indices.
    fn dots(t: &str) -> Vec<usize> {
        glyphs(t)
            .iter()
            .filter(|g| g.size.as_deref() == Some(DOT_SIZE) && g.c != ' ')
            .map(|g| g.step().expect(t))
            .collect()
    }

    /// The anchor: the recording's aurora mark dot, if the text has one.
    fn anchor(t: &str) -> Option<Glyph> {
        glyphs(t)
            .into_iter()
            .find(|g| g.size.as_deref() == Some(ANCHOR_SIZE))
    }

    fn full(s: usize) -> bool {
        STEPS[s].0 == FULL_DOT
    }

    /// The index of the row's brightest, largest dot (the leftmost of a
    /// tie: a pulse's tail, newer, is on its right).
    fn peak(t: &str) -> usize {
        let d = dots(t);
        let top = *d.iter().max().unwrap();
        d.iter().position(|&s| s == top).unwrap()
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
        // Transcribing: the shimmer's first frame.
        let transcribing = ind
            .update("state=transcribing model=ready mic=present")
            .unwrap();
        assert_eq!(
            transcribing,
            format!(
                "{{\"text\": {}, \"alt\": \"transcribing\", \"class\": \"transcribing\", \"tooltip\": \"LocalFlow: transcribing\"}}",
                json_string(&shimmer(Duration::ZERO, false))
            )
        );
        seen.push(transcribing);
        // A recording's first line: listening, the wave still at rest.
        let recording = ind
            .update("state=recording mode=hold model=ready mic=present level=0")
            .unwrap();
        let v = json(&recording);
        assert_eq!(v["alt"], "recording");
        assert_eq!(v["tooltip"], "LocalFlow: listening");
        assert_eq!(dots(v["text"].as_str().unwrap()), [0; WAVE_DOTS]);
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
        // Stock Waybar has no colours: the glyph alone tells the states
        // apart. Recording and transcribing show dots instead: the wave with
        // its anchor, and the shimmer without one.
        let glyphs_ = [
            MIC_GLYPH,
            LOADING_GLYPH,
            TYPING_GLYPH,
            NO_MIC_GLYPH,
            OFFLINE_GLYPH,
            APPROVAL_GLYPH,
        ];
        for (i, a) in glyphs_.iter().enumerate() {
            assert_eq!(a.chars().count(), 1);
            for b in &glyphs_[i + 1..] {
                assert_ne!(a, b);
            }
            let c = a.chars().next().unwrap();
            assert!(STEPS.iter().all(|&(d, _)| d != c));
            assert_ne!(a.chars().next(), Some(PROMPT_MARKER));
        }
        let mut ind = Indicator::default();
        for line in [
            "state=transcribing model=ready mic=present",
            "state=recording mode=hold model=ready mic=present level=0",
        ] {
            let t = text(&ind.update(line).unwrap());
            for g in glyphs(&t) {
                assert!(
                    g.c == ' ' || g.c == STRUT || g.step().is_some() || g.c == FULL_DOT,
                    "{t}"
                );
            }
        }
    }

    #[test]
    fn every_text_is_six_cells_wide_with_the_glyph_in_the_same_cell() {
        let mut ind = Indicator::default();
        let lines = [
            "state=idle model=ready mic=present",
            "state=idle model=loading mic=present",
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
            assert_eq!(cells(t), WIDTH as f64, "{t:?}");
            let glyph = shown.chars().nth(GLYPH_CELL).unwrap();
            assert_ne!(glyph, ' ', "{t:?}");
        }
        // The count stays in the last two cells, after a space.
        assert_eq!(texts[5], format!("  {APPROVAL_GLYPH} 1 "));
        assert_eq!(texts[6], format!("  {MIC_GLYPH} 12"));
        assert_eq!(texts[7], format!("  {NO_MIC_GLYPH} 99"));

        // The wave and the shimmer mix sizes; they take exactly six cells of
        // the bar's font too, in every frame, so the clock never moves.
        let mut rows = Vec::new();
        for prompt in [false, true] {
            let mut ind = Indicator::default();
            for level in [0, 0, 60, 100, 30, 100, 100, 5, 0] {
                rows.push(text(&ind.update(&rec_line(prompt, level)).unwrap()));
            }
            let tag = if prompt { " tag=prompt" } else { "" };
            rows.push(text(
                &ind.update(&format!("state=transcribing{tag} model=ready mic=present"))
                    .unwrap(),
            ));
            for ms in (0..2400).step_by(50) {
                rows.push(shimmer(Duration::from_millis(ms), prompt));
            }
        }
        for t in &rows {
            assert_eq!(cells(t), WIDTH as f64, "{t}");
            let width: f64 = glyphs(t)
                .iter()
                .filter(|g| g.c != STRUT)
                .map(Glyph::scale)
                .sum();
            assert_eq!(width, WIDTH as f64, "{t}");
        }
    }

    #[test]
    fn prompt_dictations_get_a_marker_and_a_second_class() {
        let mut ind = Indicator::default();
        let v = json(&ind.update(&rec_line(true, 0)).unwrap());
        assert_eq!(v["class"], serde_json::json!(["recording", "prompt"]));
        assert_eq!(v["alt"], "recording");
        assert_eq!(v["tooltip"], "LocalFlow: listening (prompt dictation)");
        let t = v["text"].as_str().unwrap();
        // The marker leads, at full size, then a shorter row and the anchor.
        let shown: Vec<Glyph> = glyphs(t).into_iter().filter(|g| g.c != STRUT).collect();
        assert_eq!(shown[0].c, PROMPT_MARKER, "{t}");
        assert_eq!(shown[0].scale(), 1.0, "{t}");
        assert_eq!(dots(t), [0; PROMPT_WAVE_DOTS]);
        assert!(anchor(t).is_some(), "{t}");

        let v = json(
            &ind.update("state=transcribing tag=prompt model=ready mic=present")
                .unwrap(),
        );
        assert_eq!(v["class"], serde_json::json!(["transcribing", "prompt"]));
        assert_eq!(v["alt"], "transcribing");
        assert_eq!(v["tooltip"], "LocalFlow: transcribing (prompt dictation)");
        assert_eq!(v["text"], shimmer(Duration::ZERO, true));
        let t = v["text"].as_str().unwrap();
        assert_eq!(
            plain(t).trim_start_matches(STRUT).chars().next(),
            Some(PROMPT_MARKER)
        );
        assert_eq!(dots(t).len(), PROMPT_SHIMMER_DOTS);

        let v = json(
            &ind.update("state=typing tag=prompt model=ready mic=present")
                .unwrap(),
        );
        assert_eq!(v["class"], serde_json::json!(["typing", "prompt"]));
        assert_eq!(v["tooltip"], "LocalFlow: typing (prompt dictation)");
        assert_eq!(v["text"], format!("{PROMPT_MARKER} {TYPING_GLYPH}   "));
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
        let cases = [
            (
                "state=idle model=ready mic=present suggestions=3 words=12 agent-approval=2 agent-input=1 agent-working=1 agent-done=4",
                "{\"text\": \"  \u{f256} 3 \", \"alt\": \"idle\", \"class\": [\"idle\", \"agent-approval\", \"suggestion\"], \"tooltip\": \"LocalFlow: ready\\nAgents: 2 need approval, 1 waiting for input, 1 working, 4 done\\n3 dictionary suggestions waiting\\n12 project words boosted\"}",
            ),
            (
                "state=idle model=loading mic=unknown agent-input=1",
                "{\"text\": \"  \u{f017} 1 \", \"alt\": \"loading\", \"class\": [\"loading\", \"agent-input\"], \"tooltip\": \"LocalFlow: loading the model\\nAgents: 1 waiting for input\"}",
            ),
            (
                "state=idle model=ready mic=absent suggestions=1",
                "{\"text\": \"  \u{f131}   \", \"alt\": \"nomic\", \"class\": [\"nomic\", \"suggestion\"], \"tooltip\": \"LocalFlow: no microphone\\n1 dictionary suggestion waiting\"}",
            ),
            (
                "state=idle model=ready mic=present agent-approval=1",
                "{\"text\": \"  \u{f256} 1 \", \"alt\": \"idle\", \"class\": [\"idle\", \"agent-approval\"], \"tooltip\": \"LocalFlow: ready\\nAgents: 1 needs approval\"}",
            ),
            // Working and done alone add no class and no count.
            (
                "state=idle model=ready mic=present agent-working=1 agent-done=1 words=1",
                "{\"text\": \"  \u{f130}   \", \"alt\": \"idle\", \"class\": \"idle\", \"tooltip\": \"LocalFlow: ready\\nAgents: 1 working, 1 done\\n1 project word boosted\"}",
            ),
            (
                "state=typing tag=prompt model=ready mic=present agent-input=2 suggestions=1",
                "{\"text\": \"\u{203a} \u{f11c}   \", \"alt\": \"typing\", \"class\": [\"typing\", \"prompt\"], \"tooltip\": \"LocalFlow: typing (prompt dictation)\\nAgents: 2 waiting for input\\n1 dictionary suggestion waiting\"}",
            ),
        ];
        for (fields, want) in cases {
            let got = ind.update(fields).unwrap();
            assert_eq!(got, want, "{fields}");
        }
        // Busy states keep their classes and text; only the tooltip grows.
        let mut fresh = Indicator::default();
        let quiet = fresh.update(&rec(100)).unwrap();
        let mut ind = Indicator::default();
        let v = json(
            &ind.update("state=recording mode=hold model=ready mic=present level=100 agent-approval=1 suggestions=2")
                .unwrap(),
        );
        assert_eq!(v["text"], json(&quiet)["text"]);
        assert_eq!(v["class"], "recording");
        assert_eq!(
            v["tooltip"],
            "LocalFlow: listening\nAgents: 1 needs approval\n2 dictionary suggestions waiting"
        );
        let v = json(
            &ind.update("state=transcribing model=ready mic=present agent-input=3 words=2")
                .unwrap(),
        );
        assert_eq!(v["text"], shimmer(Duration::ZERO, false));
        assert_eq!(v["class"], "transcribing");
        assert_eq!(
            v["tooltip"],
            "LocalFlow: transcribing\nAgents: 3 waiting for input\n2 project words boosted"
        );
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
    fn the_wave_is_white_dots_that_rest_and_swell_as_the_keyboards_do() {
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
        assert!((0..100).all(|l| step(l) <= step(l + 1)));
        // At rest: the small dot, dimmed (60% keeps 3:1 on the black pill
        // at 1x); at the top of the swell: the full dot at full brightness.
        assert_eq!(STEPS[0], (SMALL_DOT, 60));
        assert_eq!(STEPS[last], (FULL_DOT, 100));
        let size = |c: char| usize::from(c == FULL_DOT);
        for w in STEPS.windows(2) {
            let ((a, x), (b, y)) = (w[0], w[1]);
            assert!(size(a) <= size(b), "{w:?}");
            assert!(size(a) < size(b) || x < y, "{w:?}");
            assert!(x <= 100 && y <= 100);
        }
        // Standard characters only: no Nerd Font needed.
        for c in STEPS.iter().map(|&(c, _)| c).chain([PROMPT_MARKER, STRUT]) {
            let c = c as u32;
            assert!(!(0xe000..=0xf8ff).contains(&c) && c < 0xf0000);
        }

        // Silence is a calm row of equal resting dots before the anchor.
        let mut ind = Indicator::default();
        let quiet = feed(&mut ind, &[0, 3, 2, 4, 1, 0, 2, 3, 0, 1, 4, 2]);
        assert_eq!(dots(&quiet), [0; WAVE_DOTS]);
        // The wave's dots take the bar's ink (white in the README's CSS):
        // only the anchor carries a colour of its own.
        let speech = feed(&mut ind, &[40, 85, 6, 9, 30, 20, 2, 5, 60, 55, 30, 9]);
        for g in glyphs(&speech) {
            if g.step().is_some() && g.size.as_deref() == Some(DOT_SIZE) {
                assert_eq!(g.foreground, None, "{speech}");
            }
        }
        // Speech undulates, in size as well as brightness.
        let d = dots(&speech);
        assert!(
            d.iter().any(|&s| full(s)) && d.iter().any(|&s| !full(s)),
            "{speech}"
        );
        let mut distinct = d.clone();
        distinct.sort();
        distinct.dedup();
        assert!(distinct.len() >= 3, "{d:?}");
    }

    #[test]
    fn a_recording_always_ends_in_the_aurora_anchor() {
        // Silence reads as listening: whatever the voice, the row ends in the
        // mark's dot, aurora in the markup itself (so even a bar without the
        // README's CSS shows it), larger than any dot of the wave and at full
        // brightness, as the keyboard's wave comes to rest in it.
        for prompt in [false, true] {
            let mut ind = Indicator::default();
            let mut seed = 7u32;
            for i in 0..400 {
                seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
                let level = if i == 0 { 0 } else { (seed >> 16) as u8 % 101 };
                let t = text(&ind.update(&rec_line(prompt, level)).unwrap());
                let a = anchor(&t).expect(&t);
                assert_eq!(a.c, FULL_DOT, "{t}");
                assert_eq!(a.foreground.as_deref(), Some(AURORA), "{t}");
                assert_eq!(a.alpha(), 100, "{t}");
                assert!(a.scale() > 0.5, "{t}");
                let g = glyphs(&t);
                assert_eq!(g.last(), Some(&a), "{t}");
                // Only the prompt marker and the zero-width strut keep the
                // bar font's size.
                assert!(
                    g.iter()
                        .all(|x| x.scale() <= a.scale() || matches!(x.c, PROMPT_MARKER | STRUT)),
                    "{t}"
                );
                assert_eq!(
                    g.iter().filter(|x| x.foreground.is_some()).count(),
                    1,
                    "{t}"
                );
                let want = if prompt { PROMPT_WAVE_DOTS } else { WAVE_DOTS };
                assert_eq!(dots(&t).len(), want, "{t}");
            }
        }
        assert_eq!(AURORA, "#6DFFA8");
    }

    #[test]
    fn the_rows_are_set_in_one_monospace_span() {
        // A proportional bar font draws `•` and `●` at different widths;
        // the span gives every cell the same advance, so the clock beside
        // the module holds still while you speak and while it transcribes.
        let mut ind = Indicator::default();
        for line in [
            "state=recording mode=hold model=ready mic=present",
            "state=recording mode=hold model=ready mic=present level=90",
            "state=recording mode=hold tag=prompt model=ready mic=present level=40",
            "state=transcribing model=ready mic=present",
            "state=transcribing tag=prompt model=ready mic=present",
        ] {
            let t = text(&ind.update(line).unwrap());
            assert!(t.starts_with("<span font_family=\"monospace\">"), "{t}");
            assert!(t.ends_with("</span>"), "{t}");
            assert_eq!(t.matches("font_family").count(), 1, "{t}");
            // It starts with a zero-width strut in the bar's own size, so
            // the line is as tall as every other state's and the dots sit
            // on the same middle line.
            let g = glyphs(&t);
            assert_eq!(g[0].c, STRUT, "{t}");
            assert_eq!(g[0].scale(), 1.0, "{t}");
        }
        // Other states keep the bar's font, for Font Awesome's glyphs.
        for line in [
            "state=idle model=ready mic=present",
            "state=typing model=ready mic=present",
        ] {
            assert!(!text(&ind.update(line).unwrap()).contains('<'));
        }
    }

    #[test]
    fn the_voice_crosses_the_row_one_dot_per_level_line() {
        // A level line every 66 ms moves the row one dot: a syllable crosses
        // its eight dots in about half a second, the newest beside the
        // anchor.
        assert_eq!(
            crate::watch::LEVEL_INTERVAL.as_millis() * WAVE_DOTS as u128,
            528
        );
        for prompt in [false, true] {
            let n = if prompt { PROMPT_WAVE_DOTS } else { WAVE_DOTS };
            let mut ind = Indicator::default();
            let rest = feed_line(&mut ind, prompt, &[0; 10]);
            assert_eq!(dots(&rest), vec![0; n]);
            // Every line changes the row (none is held back for a pair).
            let t = feed_line(&mut ind, prompt, &[100]);
            assert_ne!(t, rest);
            assert_eq!(peak(&t), n - 1, "{t}");
            // Then it moves left one dot per line, through the row (until
            // it sinks into the line at the left end).
            for k in 1..n - 3 {
                let t = feed_line(&mut ind, prompt, &[0]);
                assert_eq!(peak(&t), n - 1 - k, "{prompt} {k} {t}");
            }
        }
    }

    #[test]
    fn syllables_rise_at_once_and_fall_quickly() {
        // The keyboard's follower: 25 ms up, 90 ms down. A syllable shows
        // in the very next dot, and its tail is gone within four lines.
        let mut ind = Indicator::default();
        feed(&mut ind, &[0; 10]);
        let onset = feed(&mut ind, &[60]);
        assert!(dots(&onset)[WAVE_DOTS - 1] > 0, "{onset}");
        let mut ind = Indicator::default();
        feed(&mut ind, &[0; 10]);
        feed(&mut ind, &[100]);
        let mut tail = Vec::new();
        for _ in 0..5 {
            tail.push(dots(&feed(&mut ind, &[0]))[WAVE_DOTS - 1]);
        }
        assert!(tail[0] > 0, "{tail:?}");
        assert!(tail.windows(2).all(|w| w[1] <= w[0]), "{tail:?}");
        assert_eq!(tail[3..], [0, 0], "{tail:?}");
        // Two syllables 130 ms apart read as two pulses: a dip between them.
        let mut ind = Indicator::default();
        feed(&mut ind, &[0; 10]);
        let t = feed(&mut ind, &[100, 0, 0, 100, 0]);
        let d = dots(&t);
        let (a, b) = (WAVE_DOTS - 5, WAVE_DOTS - 2);
        assert!(full(d[a]) && full(d[b]), "{d:?}");
        assert!((a + 1..b).any(|i| d[i] < d[a].min(d[b])), "{d:?}");
        // Speech rises at once even while the row is falling.
        let up = feed(&mut ind, &[100]);
        assert!(full(dots(&up)[WAVE_DOTS - 1]), "{up}");
    }

    #[test]
    fn the_row_rises_out_of_the_line_at_its_left_end() {
        // As the keyboard's envelope: the oldest dot always rests, the next
        // ones lift less, and the dot beside the anchor a little less than
        // the middle, as the row settles into the mark's dot.
        for prompt in [false, true] {
            let mut ind = Indicator::default();
            let mut seed = 3u32;
            for _ in 0..500 {
                seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
                let t = text(
                    &ind.update(&rec_line(prompt, (seed >> 16) as u8 % 101))
                        .unwrap(),
                );
                let d = dots(&t);
                assert_eq!(d[0], 0, "{t}");
                assert!(d[1] <= 1, "{t}");
            }
            let loud = feed_line(&mut ind, prompt, &[100; 12]);
            let want: &[usize] = if prompt {
                &[0, 1, 3, 4, 4, 3]
            } else {
                &[0, 1, 2, 3, 4, 4, 4, 3]
            };
            assert_eq!(dots(&loud), want, "{loud}");
        }
    }

    #[test]
    fn the_envelope_is_the_keyboards() {
        // `DotWave.envelope` at each dot, as the most a full voice lifts it.
        fn smooth(a: f64, b: f64, x: f64) -> f64 {
            let t = ((x - a) / (b - a)).clamp(0.0, 1.0);
            t * t * (3.0 - 2.0 * t)
        }
        let envelope = |u: f64| smooth(0.0, 0.6, u) * (1.0 - 0.2 * smooth(0.85, 1.0, u));
        let top = (STEPS.len() - 1) as f64;
        for table in [&ENVELOPE[..], &PROMPT_ENVELOPE[..]] {
            let n = table.len();
            let want: Vec<usize> = (0..n)
                .map(|i| (top * envelope(i as f64 / (n - 1) as f64)).round() as usize)
                .collect();
            assert_eq!(table, want);
        }
    }

    #[test]
    fn a_new_recording_starts_from_silence() {
        let mut ind = Indicator::default();
        feed(&mut ind, &[100, 100, 100]);
        // A recording line without a level keeps the row.
        let before = feed(&mut ind, &[100]);
        assert_eq!(
            text(&ind.update("state=recording mode=hold model=ready").unwrap()),
            before
        );
        ind.update("state=transcribing model=ready mic=present");
        assert_eq!(dots(&feed(&mut ind, &[0])), [0; WAVE_DOTS]);
        feed(&mut ind, &[100, 100]);
        ind.offline();
        assert_eq!(dots(&feed(&mut ind, &[0])), [0; WAVE_DOTS]);
    }

    #[test]
    fn full_dots_never_touch() {
        // The row's dots are half-size, each followed by a gap an eighth of
        // a cell wide, so even the full dot (a little wider than its own
        // cell in both fonts measured: 620 units in 600 in JetBrainsMono,
        // 1221 in 1233 in DejaVu Sans Mono) clears the next one, and the
        // anchor clears the last.
        let (dot, gap) = (scale(DOT_SIZE), scale(GAP_SIZE));
        let pad = scale(ANCHOR_PAD);
        for ink in [620.0 / 600.0, 1221.0 / 1233.0] {
            let full = ink * dot;
            assert!(full < dot + gap, "{full}");
            // From the last dot's centre to the anchor's: half the dot's
            // cell, its gap, the pad and half the anchor's cell.
            let apart = dot / 2.0 + gap + pad + scale(ANCHOR_SIZE) / 2.0;
            assert!(full / 2.0 + ink * scale(ANCHOR_SIZE) / 2.0 < apart);
        }
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
            let t = text(&ind.update(&rec_line(i % 500 >= 250, level)).unwrap());
            let g = glyphs(&t);
            // Every dot of the row is followed by its gap.
            for (i, x) in g.iter().enumerate() {
                if x.size.as_deref() == Some(DOT_SIZE) && x.c != ' ' {
                    let next = &g[i + 1];
                    assert_eq!((next.c, next.size.as_deref()), (' ', Some(GAP_SIZE)), "{t}");
                }
            }
            fulls += dots(&t).iter().filter(|&&s| full(s)).count();
        }
        // Loud speech still shows full dots, side by side.
        assert!(fulls > 3000, "{fulls}");
    }

    /// A size attribute's share of the bar font's size.
    fn scale(size: &str) -> f64 {
        size.strip_suffix('%').unwrap().parse::<f64>().unwrap() / 100.0
    }

    #[test]
    fn sustained_loud_speech_holds_a_steady_wave() {
        // Seconds of loud speech: no dot changes size or brightness while
        // the row scrolls.
        for prompt in [false, true] {
            let mut ind = Indicator::default();
            let mut waves = Vec::new();
            for i in 0..60 {
                let t = text(&ind.update(&rec_line(prompt, 100)).unwrap());
                if i >= WAVE_DOTS {
                    waves.push(t);
                }
            }
            assert!(waves.iter().all(|t| *t == waves[0]), "{waves:#?}");
            // Loud speech that varies within the full dot's steps: the dots'
            // sizes hold still too.
            let mut ind = Indicator::default();
            let mut sizes = Vec::new();
            for (i, level) in [60, 100, 75, 90, 100, 65, 85]
                .iter()
                .cycle()
                .take(70)
                .enumerate()
            {
                let t = text(&ind.update(&rec_line(prompt, *level)).unwrap());
                if i >= WAVE_DOTS {
                    sizes.push(plain(&t));
                }
            }
            assert!(sizes.iter().all(|s| *s == sizes[0]), "{sizes:#?}");
        }
    }

    #[test]
    fn a_lone_peak_keeps_its_size_as_it_scrolls() {
        // One loud syllable between quiet ones keeps its full dot across the
        // row (a little dimmer beside the anchor and where the row starts to
        // rise), until it sinks into the line at the left end.
        for prompt in [false, true] {
            let n = if prompt { PROMPT_WAVE_DOTS } else { WAVE_DOTS };
            let mut ind = Indicator::default();
            feed_line(&mut ind, prompt, &[0; 10]);
            let mut at = vec![dots(&feed_line(&mut ind, prompt, &[100]))[n - 1]];
            for k in 1..n {
                at.push(dots(&feed_line(&mut ind, prompt, &[0]))[n - 1 - k]);
            }
            // at[k]: the peak's dot k lines later, from the anchor leftwards.
            assert!(at[..n - 3].iter().all(|&s| full(s)), "{prompt} {at:?}");
            assert!(at[1..n - 4].iter().all(|&s| s == STEPS.len() - 1), "{at:?}");
            assert_eq!(at[n - 1], 0, "{at:?}");
        }
    }

    #[test]
    fn the_shimmer_sweeps_a_resting_row_without_an_anchor() {
        let at = |ms: u64, prompt| shimmer(Duration::from_millis(ms), prompt);
        // Ten frames a second, a sweep every 1.1 s as on the keyboard.
        assert_eq!(
            SHIMMER_FRAME * SWEEP_FRAMES as u32,
            Duration::from_millis(1100)
        );
        assert!((83..=125).contains(&SHIMMER_FRAME.as_millis()));
        for prompt in [false, true] {
            let n = if prompt {
                PROMPT_SHIMMER_DOTS
            } else {
                SHIMMER_DOTS
            };
            // The first frame, before any timer: a row of resting dots with
            // the spot entering on the first.
            let first = dots(&at(0, prompt));
            assert_eq!(first.len(), n);
            assert_eq!(first[..4], [STEPS.len() - 1, 2, 1, 0]);
            assert!(first[3..].iter().all(|&s| s == 0), "{first:?}");
            // Then the spot (the one full dot, glowing either side) moves
            // one dot per frame to the right.
            for k in 1..n {
                let t = at(k as u64 * 100 + 30, prompt);
                let d = dots(&t);
                assert_eq!(peak(&t), k, "{t}");
                assert_eq!(d.iter().filter(|&&s| full(s)).count(), 1, "{t}");
                assert_eq!(d[k], STEPS.len() - 1, "{t}");
                // Away from it, the row rests.
                for (i, &s) in d.iter().enumerate() {
                    if i.abs_diff(k) > 2 {
                        assert_eq!(s, 0, "{t}");
                    }
                }
            }
            // It leaves one dot past the right end, comes back in one dot
            // before the left, and starts again.
            let frame = |k: usize| dots(&at(k as u64 * 100, prompt));
            let leaving = frame(SWEEP_FRAMES - 2);
            assert!(leaving.iter().all(|&s| !full(s)), "{leaving:?}");
            assert!(leaving[n - 1] > 0, "{leaving:?}");
            let entering = frame(SWEEP_FRAMES - 1);
            assert_eq!(entering[..3], [2, 1, 0]);
            assert!(entering[2..].iter().all(|&s| s == 0), "{entering:?}");
            assert_eq!(at(1100, prompt), at(0, prompt));
            assert_eq!(at(1100 * 7 + 450, prompt), at(450, prompt));
            // A frame holds until the next one is due.
            assert_eq!(at(99, prompt), at(0, prompt));
            assert_ne!(at(100, prompt), at(0, prompt));
            // No anchor and no colour of its own: the transcribing class
            // colours it (glacier white in the README's CSS).
            for ms in (0..1100).step_by(100) {
                let t = at(ms, prompt);
                assert!(anchor(&t).is_none(), "{t}");
                assert!(glyphs(&t).iter().all(|g| g.foreground.is_none()), "{t}");
            }
        }
    }

    #[test]
    fn the_shimmer_only_runs_while_transcribing() {
        let mut ind = Indicator::default();
        // No frames, and so no timer, in any other state.
        for line in [
            "state=idle model=ready mic=present",
            "state=idle model=loading mic=present",
            "state=recording mode=hold model=ready mic=present level=50",
            "state=typing model=ready mic=present",
            "state=idle model=ready mic=absent",
        ] {
            ind.update(line);
            assert_eq!(ind.next_frame(), None, "{line}");
            assert_eq!(ind.tick(Duration::from_millis(250)), None, "{line}");
        }
        ind.offline();
        assert_eq!(ind.next_frame(), None);
        assert_eq!(ind.tick(Duration::from_millis(250)), None);

        // Transcribing: the first frame at once, the next due one frame on.
        let first = ind
            .update("state=transcribing tag=prompt model=ready mic=present agent-input=1")
            .unwrap();
        assert_eq!(json(&first)["text"], shimmer(Duration::ZERO, true));
        assert_eq!(ind.next_frame(), Some(SHIMMER_FRAME));
        let second = ind.tick(SHIMMER_FRAME).unwrap();
        let v = json(&second);
        assert_eq!(v["text"], shimmer(SHIMMER_FRAME, true));
        // Everything else stays as the line said.
        assert_eq!(v["class"], json(&first)["class"]);
        assert_eq!(v["tooltip"], json(&first)["tooltip"]);
        assert_eq!(ind.next_frame(), Some(2 * SHIMMER_FRAME));
        // A late timer catches up with the clock.
        let late = ind
            .tick(SHIMMER_FRAME * 5 + Duration::from_millis(40))
            .unwrap();
        assert_eq!(json(&late)["text"], shimmer(SHIMMER_FRAME * 5, true));
        assert_eq!(ind.next_frame(), Some(6 * SHIMMER_FRAME));
        // Another transcribing line (new counts) does not restart it.
        let same = ind
            .update("state=transcribing tag=prompt model=ready mic=present agent-input=2")
            .unwrap();
        assert_eq!(json(&same)["text"], shimmer(SHIMMER_FRAME * 5, true));
        assert_eq!(ind.next_frame(), Some(6 * SHIMMER_FRAME));

        // It stops the moment the state changes.
        ind.update("state=typing model=ready mic=present");
        assert_eq!(ind.next_frame(), None);
        assert_eq!(ind.tick(SHIMMER_FRAME * 6), None);
        // The next dictation's wait starts its sweep again.
        let again = ind
            .update("state=transcribing model=ready mic=present")
            .unwrap();
        assert_eq!(json(&again)["text"], shimmer(Duration::ZERO, false));
        assert_eq!(ind.next_frame(), Some(SHIMMER_FRAME));
        assert!(ind.tick(SHIMMER_FRAME).is_some());
        ind.offline();
        assert_eq!(ind.next_frame(), None);
        ind.update("state=transcribing model=ready mic=present");
        ind.update(&rec(30));
        assert_eq!(ind.next_frame(), None);
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
                for level in [0u64, 1, 4, 5, 9, 10, 29, 30, 49, 50, 77, 99, 100, 101, 255] {
                    let line = format!(
                        "state={state} mode=hold model=ready mic=present level={level}{extra}"
                    );
                    objects.extend(ind.update(&line));
                    objects.extend(ind.tick(Duration::from_millis(level * 37)));
                }
            }
        }
        assert!(objects.len() > 300);
        for o in &objects {
            let v = json(o);
            let (t, tip) = (v["text"].as_str().unwrap(), v["tooltip"].as_str().unwrap());
            // The only markup: spans with the attributes `glyphs` reads,
            // around fixed characters.
            for g in glyphs(t) {
                assert!(
                    matches!(g.c, ' ' | STRUT | PROMPT_MARKER | '0'..='9' | '\u{e000}'..='\u{f8ff}')
                        || g.step().is_some(),
                    "{t:?}"
                );
            }
            for s in [plain(t).as_str(), tip] {
                assert!(!s.contains(['<', '>', '&']), "{s:?}");
            }
            assert_eq!(cells(t), WIDTH as f64, "{t:?}");
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
            // Busy states keep their own text.
            (
                "typing model=ready mic=present agent-approval=1",
                TYPING_GLYPH,
                "   ",
            ),
        ];
        for (fields, glyph, count) in cases {
            let t = text(&ind.update(&format!("state={fields}")).unwrap());
            assert_eq!(t, format!("  {glyph}{count}"), "{fields}");
        }
        let t = text(
            &ind.update("state=transcribing model=ready mic=present agent-approval=1")
                .unwrap(),
        );
        assert_eq!(t, shimmer(Duration::ZERO, false));
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

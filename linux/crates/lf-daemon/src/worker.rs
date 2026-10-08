//! The recognition worker: one thread that owns the recognizer and the text
//! output, and runs jobs in order. The control loop never waits for it,
//! except for at most one output call when it cancels (see [`CancelToken`]).

use std::panic::AssertUnwindSafe;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::Instant;

use lf_dictation::VoiceMacro;
use lf_io_api::TextOutput;
use unicode_segmentation::UnicodeSegmentation;

use crate::recognizer::{Recognizer, RecognizerFactory};

/// Text is typed in pieces of at most this many characters (one key tap
/// each), so cancel can stop a long dictation part-way. See [`chunks`].
pub const TYPE_CHUNK_CHARS: usize = 64;

/// Recorded audio. Overwritten with zeros when dropped, on every path
/// (including panics and jobs dropped unprocessed).
pub struct Audio(Vec<f32>);

impl Audio {
    pub fn new(samples: Vec<f32>) -> Audio {
        Audio(samples)
    }

    pub fn samples(&self) -> &[f32] {
        &self.0
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// Shortens the audio, wiping the removed samples.
    pub fn truncate(&mut self, len: usize) {
        if len < self.0.len() {
            scrub(&mut self.0[len..]);
            self.0.truncate(len);
        }
    }
}

impl Drop for Audio {
    fn drop(&mut self) {
        scrub(&mut self.0);
    }
}

/// Overwrites audio before it is freed.
pub fn scrub(samples: &mut [f32]) {
    for s in samples.iter_mut() {
        // SAFETY: `s` is a valid, aligned, exclusive reference.
        unsafe { std::ptr::write_volatile(s, 0.0) };
    }
}

/// Cancellation shared by the control loop and the worker. Output calls run
/// while holding the lock, so once [`CancelToken::cancel`] returns nothing
/// more is typed and Return is not pressed.
#[derive(Default)]
pub struct CancelToken {
    cancelled: AtomicBool,
    /// Held during each output call.
    output: Mutex<()>,
}

impl CancelToken {
    fn lock(&self) -> MutexGuard<'_, ()> {
        self.output.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Marks the job cancelled, then waits for an output call in progress.
    /// (The flag is set first: the mutex is not fair, so waiting for it
    /// while the worker types piece after piece could starve.)
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        drop(self.lock());
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    /// Runs `f` unless cancelled; `cancel` waits until `f` returns.
    pub fn run<R>(&self, f: impl FnOnce() -> R) -> Option<R> {
        let _guard = self.lock();
        if self.is_cancelled() { None } else { Some(f()) }
    }
}

pub struct Job {
    pub id: u64,
    /// Set by the control loop to abandon the job. Checked before
    /// recognition, after it, and around every output call.
    pub cancel: Arc<CancelToken>,
    pub kind: JobKind,
}

pub enum JobKind {
    /// `prompt`: a Hold to Prompt recording; the output gets
    /// [`Settings::prompt_tag`].
    Transcribe { audio: Audio, prompt: bool },
    /// Type the given text again (Paste Again). No Return, no history.
    Retype(String),
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Typed {
        raw: String,
        text: String,
        pressed_enter: bool,
        retype: bool,
    },
    /// Nothing to type: the recognizer heard nothing.
    Nothing,
    Cancelled,
    RecognizeFailed,
    OutputFailed,
}

#[derive(Debug, PartialEq, Eq)]
pub enum WorkerEvent {
    ModelReady,
    /// The worker cannot continue: the model failed to load or the thread
    /// panicked. The daemon exits.
    Fatal(String),
    /// Recognition finished and typing started.
    Typing(u64),
    Done(u64, Outcome),
}

#[derive(Clone, Debug)]
pub struct Settings {
    pub options: lf_dictation::Options,
    pub macros: Vec<VoiceMacro>,
    /// Characters typed per output call; see [`chunk_chars_for_key_delay`].
    pub type_chunk_chars: usize,
    /// Put before the output of prompt recordings (Hold to Prompt); empty
    /// disables tagging.
    pub prompt_tag: String,
}

/// Longest typing a cancel should wait for, per piece (key delays only; a
/// hung compositor is bounded by the typer's own timeout instead).
pub const PIECE_BUDGET_MS: u64 = 100;

/// Piece size so one piece takes at most [`PIECE_BUDGET_MS`] of key delay to
/// type (`lf-wayland` sleeps once per character, after its press and
/// release), between 1 and [`TYPE_CHUNK_CHARS`] characters. Cancel waits for
/// the piece in progress, so this bounds cancel latency at slow key delays.
pub fn chunk_chars_for_key_delay(key_delay_ms: u64) -> usize {
    if key_delay_ms == 0 {
        return TYPE_CHUNK_CHARS;
    }
    ((PIECE_BUDGET_MS / key_delay_ms) as usize).clamp(1, TYPE_CHUNK_CHARS)
}

pub fn spawn(
    factory: RecognizerFactory,
    output: Box<dyn TextOutput>,
    settings: Settings,
    jobs: Receiver<Job>,
    events: impl Fn(WorkerEvent) + Send + 'static,
) -> std::io::Result<JoinHandle<()>> {
    std::thread::Builder::new()
        .name("lf-recognizer".into())
        .spawn(move || {
            let body = AssertUnwindSafe(|| work(factory, output, &settings, jobs, &events));
            if std::panic::catch_unwind(body).is_err() {
                events(WorkerEvent::Fatal("the recognition thread panicked".into()));
            }
        })
}

fn work(
    factory: RecognizerFactory,
    mut output: Box<dyn TextOutput>,
    settings: &Settings,
    jobs: Receiver<Job>,
    events: &impl Fn(WorkerEvent),
) {
    let mut recognizer = match factory() {
        Ok(r) => r,
        Err(e) => {
            // Queued jobs (and their audio, wiped on drop) go with `jobs`.
            events(WorkerEvent::Fatal(format!("cannot load the model: {e}")));
            return;
        }
    };
    events(WorkerEvent::ModelReady);
    for job in jobs {
        let id = job.id;
        let outcome = run(job, recognizer.as_mut(), output.as_mut(), settings, events);
        events(WorkerEvent::Done(id, outcome));
    }
}

fn run(
    job: Job,
    recognizer: &mut dyn Recognizer,
    output: &mut dyn TextOutput,
    settings: &Settings,
    events: &impl Fn(WorkerEvent),
) -> Outcome {
    let cancel = &job.cancel;
    let (raw, text, enter, retype) = match job.kind {
        JobKind::Transcribe { audio, prompt } => {
            if cancel.is_cancelled() {
                return Outcome::Cancelled;
            }
            let start = Instant::now();
            let text = recognizer.transcribe(audio.samples());
            drop(audio);
            let text = match text {
                Ok(t) => t,
                Err(e) => {
                    crate::error!("recognition failed: {e}");
                    return Outcome::RecognizeFailed;
                }
            };
            crate::debug!("recognized in {:.0?}", start.elapsed());
            if cancel.is_cancelled() {
                return Outcome::Cancelled;
            }
            let tag = prompt.then_some(settings.prompt_tag.as_str());
            let r = lf_dictation::process(&text, &settings.macros, settings.options, tag);
            (r.raw_transcript, r.output, r.should_press_enter, false)
        }
        JobKind::Retype(text) => (String::new(), text, false, true),
    };
    if text.is_empty() && !enter {
        return Outcome::Nothing;
    }
    // Validate everything before the first key, so a bad character late in
    // the text (e.g. in a macro payload) cannot leave a prefix typed.
    if let Err(e) = output.check(&text) {
        crate::error!("typing refused: {e}");
        return Outcome::OutputFailed;
    }
    events(WorkerEvent::Typing(job.id));
    for piece in chunks(&text, settings.type_chunk_chars) {
        match cancel.run(|| output.type_text(piece)) {
            None => return Outcome::Cancelled,
            Some(Err(e)) => {
                crate::error!("typing failed: {e}");
                return Outcome::OutputFailed;
            }
            Some(Ok(())) => {}
        }
    }
    if enter {
        match cancel.run(|| output.press_enter()) {
            None => return Outcome::Cancelled,
            Some(Err(e)) => {
                crate::error!("pressing Return failed: {e}");
                return Outcome::OutputFailed;
            }
            Some(Ok(())) => {}
        }
    }
    Outcome::Typed {
        raw,
        text,
        pressed_enter: enter,
        retype,
    }
}

/// Splits `text` into pieces of at most `max` characters (one key tap each),
/// preferring grapheme-cluster boundaries and ending a piece after
/// whitespace. A cluster longer than `max` characters (e.g. a letter with
/// many combining marks) is split between its characters, so no piece can
/// take unboundedly long to type; `"\r\n"` is never split, since its halves
/// would each become a Return.
pub fn chunks(text: &str, max: usize) -> Vec<&str> {
    let max = max.max(1);
    let count = |a: usize, b: usize| text[a..b].chars().count();
    let mut pieces = Vec::new();
    let mut start = 0;
    let mut last_space_end = None;
    for (offset, g) in text.grapheme_indices(true) {
        let end = offset + g.len();
        if g != "\r\n" && g.chars().count() > max {
            if offset > start {
                pieces.push(&text[start..offset]);
            }
            let mut s = offset;
            for (i, (at, _)) in g.char_indices().enumerate() {
                if i > 0 && i % max == 0 {
                    pieces.push(&text[s..offset + at]);
                    s = offset + at;
                }
            }
            pieces.push(&text[s..end]);
            start = end;
            last_space_end = None;
            continue;
        }
        if count(start, end) > max && offset > start {
            let cut = last_space_end.filter(|&c| c > start).unwrap_or(offset);
            pieces.push(&text[start..cut]);
            start = cut;
            last_space_end = None;
            // Cutting at earlier whitespace may still leave too much.
            if count(start, end) > max && offset > start {
                pieces.push(&text[start..offset]);
                start = offset;
            }
        }
        if g.chars().next().is_some_and(char::is_whitespace) {
            last_space_end = Some(end);
        }
    }
    if start < text.len() {
        pieces.push(&text[start..]);
    }
    pieces
}

#[cfg(test)]
mod tests {
    use super::*;

    fn check(text: &str, max: usize) {
        let pieces = chunks(text, max);
        assert_eq!(pieces.concat(), text);
        for p in &pieces {
            assert!(!p.is_empty());
            assert!(p.chars().count() <= max || *p == "\r\n", "{max} {p:?}");
        }
    }

    #[test]
    fn whole_text_is_checked_before_the_first_piece() {
        use crate::testing::{FakeOutput, FakeRecognizer};
        let out = FakeOutput::default();
        let settings = Settings {
            options: lf_dictation::Options::default(),
            macros: Vec::new(),
            type_chunk_chars: 8,
            prompt_tag: "[dictated]".into(),
        };
        // Many pieces of printable text, then a control character at the end.
        let text = format!("{}\u{7}", "synthetic words ".repeat(5));
        let job = Job {
            id: 1,
            cancel: Arc::new(CancelToken::default()),
            kind: JobKind::Retype(text),
        };
        let mut rec = FakeRecognizer::returning("unused");
        let outcome = run(job, &mut rec, &mut out.clone(), &settings, &|_| {});
        assert_eq!(outcome, Outcome::OutputFailed);
        assert!(out.state().typed.is_empty(), "nothing may be typed");
    }

    #[test]
    fn piece_size_bounds_cancel_latency() {
        assert_eq!(chunk_chars_for_key_delay(0), TYPE_CHUNK_CHARS);
        assert_eq!(chunk_chars_for_key_delay(1), TYPE_CHUNK_CHARS);
        assert_eq!(chunk_chars_for_key_delay(5), 20);
        assert_eq!(chunk_chars_for_key_delay(50), 2);
        for ms in 0..=crate::config::MAX_KEY_DELAY_MS {
            let chars = chunk_chars_for_key_delay(ms) as u64;
            assert!((1..=TYPE_CHUNK_CHARS as u64).contains(&chars));
            // One full piece costs at most the budget in key delays.
            assert!(chars * ms <= PIECE_BUDGET_MS);
        }
    }

    #[test]
    fn chunks_cover_text_at_boundaries() {
        assert!(chunks("", 8).is_empty());
        assert_eq!(chunks("short", 8), ["short"]);
        assert_eq!(
            chunks("one two three four", 8),
            ["one two ", "three ", "four"]
        );
        assert_eq!(chunks("abcdefghij", 4), ["abcd", "efgh", "ij"]);
        // Clusters stay whole when they fit...
        let family = "👨\u{200d}👩\u{200d}👧";
        assert_eq!(chunks(family, 5), [family]);
        assert_eq!(
            chunks("e\u{301}e\u{301}e\u{301}", 3),
            ["e\u{301}", "e\u{301}", "e\u{301}"]
        );
        // ...and are split between characters only when longer than `max`.
        assert_eq!(chunks(family, 4), ["👨\u{200d}👩\u{200d}", "👧"]);
        let long = format!("e{}", "\u{301}".repeat(128));
        let pieces = chunks(&long, 2);
        assert_eq!(pieces.len(), 65);
        check(&long, 2);
        // CR LF is never split into two Returns.
        assert_eq!(chunks("a\r\nb", 1), ["a", "\r\n", "b"]);
        check("a\r\nb", 1);
        let text = "Synthetic dictation with several words, some punctuation, and émojis 🙂 too.";
        for max in 1..40 {
            check(text, max);
        }
    }

    #[test]
    fn chunks_recheck_after_a_whitespace_cut() {
        // Regression: the remainder after the whitespace cut plus a
        // multi-character cluster exceeded the limit.
        let family = "👨\u{200d}👩\u{200d}👧";
        let text = format!("a {}{family}", "b".repeat(60));
        assert_eq!(chunks(&text, 64), ["a ", &"b".repeat(60), family]);
        check(&text, 64);
        for max in 1..12 {
            check("ab é😀 cd 😀😀 e", max);
        }
    }

    #[test]
    fn audio_is_wiped() {
        let mut a = Audio::new(vec![0.5f32; 8]);
        a.truncate(3);
        assert_eq!(a.samples(), [0.5; 3]);
        let mut s = vec![0.5f32; 7];
        scrub(&mut s);
        assert!(s.iter().all(|&x| x == 0.0));
    }

    #[test]
    fn cancel_waits_for_the_output_call_in_progress() {
        let token = Arc::new(CancelToken::default());
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let t = Arc::clone(&token);
        let worker = std::thread::spawn(move || {
            t.run(|| {
                started_tx.send(()).unwrap();
                std::thread::sleep(std::time::Duration::from_millis(100));
                Instant::now()
            })
        });
        started_rx.recv().unwrap();
        token.cancel();
        let cancelled_at = Instant::now();
        let finished_at = worker.join().unwrap().unwrap();
        assert!(finished_at <= cancelled_at);
        assert!(token.is_cancelled());
        assert_eq!(token.run(|| ()), None);
    }
}

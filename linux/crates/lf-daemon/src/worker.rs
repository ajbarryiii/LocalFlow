// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.
//! The recognition worker: one thread that owns the recognizer and the text
//! output, and runs jobs in order. The control loop never waits for it,
//! except for at most one output call when it cancels (see [`CancelToken`]).

use std::borrow::Cow;
use std::panic::AssertUnwindSafe;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use lf_asr::Projection;
use lf_asr::dictionary::DictionaryEntry;
use lf_dictation::VoiceMacro;
use lf_dictation::correction::{Candidate, CandidateKind, Expected, apply_casing};
use lf_io_api::TextOutput;
use unicode_segmentation::UnicodeSegmentation;

use crate::dictionary::Snapshot;
use crate::recognizer::{Recognizer, RecognizerFactory};

/// Longest typed text kept for correction (UTF-8 bytes).
pub const MAX_SESSION_BYTES: usize = 4096;
/// Most candidates a correction tries (DESIGN §1.6).
pub const MAX_VERIFY_CANDIDATES: usize = 3;
/// Strengths tried for a candidate, in order.
pub const VERIFY_STRENGTHS: [f32; 7] = [1.0, 1.41, 2.0, 2.83, 4.0, 5.66, 8.0];
/// Verification stops once this much time has passed.
pub const VERIFY_BUDGET: Duration = Duration::from_secs(3);

/// What a typed dictation leaves for a later correction: in memory only,
/// never logged (its `Debug` shows no text).
pub struct Retained {
    /// The raw transcript after casing restoration.
    pub raw: String,
    /// What was typed.
    pub output: String,
    pub projection: Projection,
    /// The dictionary it was transcribed with.
    pub dictionary: Arc<Snapshot>,
}

impl std::fmt::Debug for Retained {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Retained({} frames, revision {})",
            self.projection.frames, self.dictionary.revision
        )
    }
}

impl PartialEq for Retained {
    fn eq(&self, o: &Self) -> bool {
        self.raw == o.raw
            && self.output == o.output
            && self.projection.frames == o.projection.frames
            && self.projection.data.iter().map(|v| v.to_bits()).eq(o
                .projection
                .data
                .iter()
                .map(|v| v.to_bits()))
            && Arc::ptr_eq(&self.dictionary, &o.dictionary)
    }
}

impl Eq for Retained {}

/// A verified correction: the word to suggest adding.
#[derive(Clone, PartialEq, Eq)]
pub struct Suggestion {
    pub word: String,
    /// Thousandths.
    pub strength: u32,
    pub casing: bool,
}

impl std::fmt::Debug for Suggestion {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Suggestion(strength {}, casing {})",
            self.strength, self.casing
        )
    }
}

/// Checks a correction against a retained dictation.
pub struct Verify {
    pub session: Arc<Retained>,
    /// In text order; at most [`MAX_VERIFY_CANDIDATES`] of those that can
    /// be attempted (casing, or mappable onto the transcript) are tried.
    pub candidates: Vec<Candidate>,
}

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
    /// [`Settings::prompt_tag`]. `dictionary` is boosted and its casing
    /// restored.
    Transcribe {
        audio: Audio,
        prompt: bool,
        dictionary: Arc<Snapshot>,
    },
    /// Type the given text again (Paste Again). No Return, no history.
    Retype(String),
    /// Check a correction (DESIGN §1.6); answered with
    /// [`WorkerEvent::Verified`]. A low-priority job: its cancel token is
    /// checked between decodes.
    Verify(Verify),
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Typed {
        raw: String,
        text: String,
        pressed_enter: bool,
        retype: bool,
        /// Kept for correction: a dictation (not a macro, no Return) of at
        /// most [`MAX_SESSION_BYTES`] without control characters.
        retained: Option<Box<Retained>>,
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
    /// A correction check finished (`None`: nothing to suggest, or it was
    /// cancelled or ran out of time).
    Verified(u64, Option<Suggestion>),
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
        if let JobKind::Verify(v) = job.kind {
            let found = verify(&v, &job.cancel, recognizer.as_mut());
            events(WorkerEvent::Verified(id, found));
            continue;
        }
        let outcome = run(job, recognizer.as_mut(), output.as_mut(), settings, events);
        events(WorkerEvent::Done(id, outcome));
    }
}

/// DESIGN §1.6: the first of at most [`MAX_VERIFY_CANDIDATES`] candidates
/// that verifies. A casing candidate is accepted at strength 1 without
/// audio; a replacement must be recovered by re-decoding the retained
/// projection with it boosted, trying [`VERIFY_STRENGTHS`] in order. Stops
/// when cancelled or after [`VERIFY_BUDGET`], checked before every decode.
pub fn verify(
    v: &Verify,
    cancel: &CancelToken,
    recognizer: &mut dyn Recognizer,
) -> Option<Suggestion> {
    verify_with_clock(v, cancel, recognizer, &mut Instant::now)
}

/// [`verify`] with the time taken from `now` (tests use a mocked clock).
/// DESIGN P8: a candidate is mapped onto the base transcript before any
/// decode, so an unmappable one costs neither decodes nor time; cancellation
/// and the budget are checked before every decode, again after it before
/// its result counts, and before accepting a casing candidate.
pub fn verify_with_clock(
    v: &Verify,
    cancel: &CancelToken,
    recognizer: &mut dyn Recognizer,
    now: &mut dyn FnMut() -> Instant,
) -> Option<Suggestion> {
    let start = now();
    let stop = |now: &mut dyn FnMut() -> Instant| {
        // The clock first, so the cancel flag is read as late as possible.
        let spent = now().saturating_duration_since(start) >= VERIFY_BUDGET;
        let over = spent || cancel.is_cancelled();
        if over {
            crate::debug!("correction check stopped");
        }
        over
    };
    let s = &v.session;
    // P8 detail: candidates that are not attempted (unmappable
    // replacements) are dropped first and never count toward the cap.
    let attempted = v
        .candidates
        .iter()
        .filter_map(|c| match c.kind {
            CandidateKind::Casing => Some((c, None)),
            CandidateKind::Replace => Expected::new(&s.raw, &s.output, c).map(|e| (c, Some(e))),
        })
        .take(MAX_VERIFY_CANDIDATES);
    for (c, expected) in attempted {
        let Some(expected) = expected else {
            // Casing: not mapped onto the transcript, no audio needed.
            if stop(now) {
                return None;
            }
            return Some(Suggestion {
                word: c.surface.clone(),
                strength: 1000,
                casing: true,
            });
        };
        for strength in VERIFY_STRENGTHS {
            if stop(now) {
                return None;
            }
            let extra = DictionaryEntry {
                text: c.surface.clone(),
                strength,
            };
            let n = match recognizer.redecode(&s.projection, &s.dictionary, &extra) {
                Ok(n) => n,
                Err(e) => {
                    crate::warn!("correction check failed: {e}");
                    return None;
                }
            };
            // A result that arrives cancelled or past the budget is dropped.
            if stop(now) {
                return None;
            }
            if expected.accepts(&n) {
                return Some(Suggestion {
                    word: c.surface.clone(),
                    strength: (strength * 1000.0).round() as u32,
                    casing: false,
                });
            }
        }
    }
    None
}

fn run(
    job: Job,
    recognizer: &mut dyn Recognizer,
    output: &mut dyn TextOutput,
    settings: &Settings,
    events: &impl Fn(WorkerEvent),
) -> Outcome {
    let cancel = &job.cancel;
    let (raw, text, enter, retype, keep) = match job.kind {
        JobKind::Transcribe {
            audio,
            prompt,
            dictionary,
        } => {
            if cancel.is_cancelled() {
                return Outcome::Cancelled;
            }
            let start = Instant::now();
            let heard = recognizer.transcribe(audio.samples(), &dictionary, true);
            drop(audio);
            let heard = match heard {
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
            // Casing restoration runs on the raw transcript, before the
            // post-processing (DESIGN §1.4).
            let text = apply_casing(&heard.text, &dictionary.dictionary.entries);
            let tag = prompt.then_some(settings.prompt_tag.as_str());
            let r = lf_dictation::process(&text, &settings.macros, settings.options, tag);
            let eligible = !r.used_macro
                && !r.should_press_enter
                && !r.output.is_empty()
                && r.output.len() <= MAX_SESSION_BYTES
                && !r.output.chars().any(crate::protocol::is_control);
            let keep = heard
                .projection
                .filter(|_| eligible)
                .map(|projection| (projection, dictionary));
            (
                r.raw_transcript,
                r.output,
                r.should_press_enter,
                false,
                keep,
            )
        }
        JobKind::Retype(text) => (String::new(), text, false, true, None),
        // Handled by `work`; never reaches here.
        JobKind::Verify(_) => return Outcome::Nothing,
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
    let typed = with_sentence_space(&text, enter);
    for piece in chunks(&typed, settings.type_chunk_chars) {
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
    let retained = keep.map(|(projection, dictionary)| {
        Box::new(Retained {
            raw: raw.clone(),
            output: text.clone(),
            projection,
            dictionary,
        })
    });
    Outcome::Typed {
        raw,
        text,
        pressed_enter: enter,
        retype,
        retained,
    }
}

/// The text to type: a space follows sentence-ending punctuation so the next
/// dictation does not jam against it (as in the Swift app). Not before
/// Return, which ends the line anyway.
fn with_sentence_space(text: &str, enter: bool) -> Cow<'_, str> {
    if !enter && text.ends_with(['.', '!', '?']) {
        Cow::Owned(format!("{text} "))
    } else {
        Cow::Borrowed(text)
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
    fn a_space_follows_a_finished_sentence() {
        use crate::testing::{FakeOutput, FakeRecognizer};
        let settings = Settings {
            options: lf_dictation::Options::default(),
            macros: Vec::new(),
            type_chunk_chars: TYPE_CHUNK_CHARS,
            prompt_tag: "[dictated]".into(),
        };
        let typed = |kind: JobKind, heard: &str| {
            let out = FakeOutput::default();
            let job = Job {
                id: 1,
                cancel: Arc::new(CancelToken::default()),
                kind,
            };
            let mut rec = FakeRecognizer::returning(heard);
            let outcome = run(job, &mut rec, &mut out.clone(), &settings, &|_| {});
            (out.text(), outcome)
        };
        let transcribe = || JobKind::Transcribe {
            audio: Audio::new(vec![0.1; 16]),
            prompt: false,
            dictionary: Arc::default(),
        };
        // So the next dictation does not jam against the prior sentence.
        for end in [".", "!", "?"] {
            let (text, _) = typed(transcribe(), &format!("Synthetic words{end}"));
            assert_eq!(text, format!("Synthetic words{end} "));
        }
        // The space is typed, not recorded as part of the dictation.
        let (_, outcome) = typed(transcribe(), "Synthetic words.");
        let Outcome::Typed {
            raw,
            text,
            pressed_enter: false,
            retype: false,
            retained: Some(retained),
        } = outcome
        else {
            panic!("{outcome:?}");
        };
        assert_eq!(
            (raw.as_str(), text.as_str()),
            ("Synthetic words.", "Synthetic words.")
        );
        assert_eq!(retained.output, "Synthetic words.");
        // Mid-sentence text, other punctuation and Return get no space.
        assert_eq!(typed(transcribe(), "Synthetic words").0, "Synthetic words");
        assert_eq!(
            typed(transcribe(), "Synthetic words,").0,
            "Synthetic words,"
        );
        assert_eq!(
            typed(transcribe(), "Synthetic words. Press enter.").0,
            "Synthetic words.\n"
        );
        // Paste Again types the space too.
        let (text, _) = typed(JobKind::Retype("Synthetic again?".into()), "unused");
        assert_eq!(text, "Synthetic again? ");
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

    /// Correction checks and retained dictations (DESIGN §1.6, §2.4).
    mod correction {
        use super::*;
        use crate::dictionary::{Dictionary, Snapshot};
        use crate::testing::{FakeOutput, FakeRecognizer, synthetic_tokenizer};
        use lf_dictation::correction::correction_candidates;

        const TYPED: &str = "we deployed it on cooper netties yesterday";
        const EDITED: &str = "we deployed it on Kubernetes yesterday";
        const RECOVERED: &str = "we deployed it on kubernetes yesterday";

        fn session(output: &str) -> Arc<Retained> {
            Arc::new(Retained {
                raw: output.into(),
                output: output.into(),
                projection: Projection {
                    data: vec![0.25; 8],
                    frames: 2,
                },
                dictionary: Arc::default(),
            })
        }

        fn job(before: &str, after: &str) -> Verify {
            Verify {
                session: session(before),
                candidates: correction_candidates(before, after, &[], &[], &synthetic_tokenizer()),
            }
        }

        fn recognizer(redecoded: &[(u32, &str)]) -> FakeRecognizer {
            let r = FakeRecognizer::returning(TYPED);
            r.state().redecoded = redecoded.iter().map(|&(m, t)| (m, t.into())).collect();
            r
        }

        #[test]
        fn strengths_are_tried_in_order_until_one_recovers_the_word() {
            let v = job(TYPED, EDITED);
            for (milli, decodes) in [
                (1000, 1),
                (1410, 2),
                (2830, 4),
                (4000, 5),
                (5660, 6),
                (8000, 7),
            ] {
                let mut rec = recognizer(&[(milli, RECOVERED)]);
                let s = verify(&v, &CancelToken::default(), &mut rec).unwrap();
                assert_eq!(
                    (s.word.as_str(), s.strength, s.casing),
                    ("Kubernetes", milli, false)
                );
                assert_eq!(rec.state().redecodes, decodes);
            }
            // Never recovered: seven decodes, nothing suggested.
            let mut rec = recognizer(&[]);
            assert_eq!(verify(&v, &CancelToken::default(), &mut rec), None);
            assert_eq!(rec.state().redecodes, 7);
        }

        #[test]
        fn casing_needs_no_audio() {
            let v = job("i like nixos", "i like NixOS");
            let mut rec = recognizer(&[]);
            let s = verify(&v, &CancelToken::default(), &mut rec).unwrap();
            assert_eq!(
                (s.word.as_str(), s.strength, s.casing),
                ("NixOS", 1000, true)
            );
            assert_eq!(rec.state().redecodes, 0);
        }

        #[test]
        fn at_most_three_candidates_with_seven_decodes_each() {
            let before = "aa bb cc dd ee ff gg hh ii jj kk ll";
            let after = "aa Xb cc Xd ee Xf gg Xh ii jj kk ll";
            let v = job(before, after);
            assert_eq!(v.candidates.len(), 4);
            let mut rec = recognizer(&[]);
            assert_eq!(verify(&v, &CancelToken::default(), &mut rec), None);
            assert_eq!(rec.state().redecodes, 21);
        }

        #[test]
        fn unattempted_candidates_do_not_count_toward_the_cap() {
            // "bb" is not in the transcript, so "Xb" cannot be mapped; the
            // three after it are all tried, and the third one recovers.
            let before = "aa bb cc dd ee ff gg hh ii jj kk ll";
            let mut v = job(before, "aa Xb cc Xd ee Xf gg Xh ii jj kk ll");
            v.session = Arc::new(Retained {
                raw: "aa zz cc dd ee ff gg hh ii jj kk ll".into(),
                ..Arc::try_unwrap(session(before)).ok().unwrap()
            });
            let words: Vec<&str> = v.candidates.iter().map(|c| c.surface.as_str()).collect();
            assert_eq!(words, ["Xb", "Xd", "Xf", "Xh"]);
            let mut rec = recognizer(&[(1000, "aa zz cc dd ee ff gg xh ii jj kk ll")]);
            let got = verify(&v, &CancelToken::default(), &mut rec).unwrap();
            assert_eq!(got.word, "Xh");
            assert_eq!(rec.state().redecodes, 7 + 7 + 1);
        }

        #[test]
        fn cancellation_stops_between_decodes() {
            let v = job(TYPED, EDITED);
            let token = Arc::new(CancelToken::default());
            token.cancel();
            let mut rec = recognizer(&[]);
            assert_eq!(verify(&v, &token, &mut rec), None);
            assert_eq!(rec.state().redecodes, 0);

            let token = Arc::new(CancelToken::default());
            let mut rec = recognizer(&[]);
            rec.state().redecode_delay = Duration::from_millis(100);
            let t = Arc::clone(&token);
            let canceller = std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(150));
                t.cancel();
            });
            let start = Instant::now();
            assert_eq!(verify(&v, &token, &mut rec), None);
            canceller.join().unwrap();
            assert!(rec.state().redecodes <= 3, "{}", rec.state().redecodes);
            assert!(start.elapsed() < Duration::from_millis(450));
        }

        #[test]
        fn the_time_budget_stops_verification() {
            let before = "aa bb cc dd ee ff gg hh ii jj kk ll";
            let v = job(before, "aa Xb cc Xd ee Xf gg Xh ii jj kk ll");
            let mut rec = recognizer(&[]);
            rec.state().redecode_delay = Duration::from_millis(300);
            let start = Instant::now();
            assert_eq!(verify(&v, &CancelToken::default(), &mut rec), None);
            // Decodes start every 0.3 s: seven for the first candidate, then
            // the second until 3 s have passed (21 without a budget).
            let n = rec.state().redecodes;
            assert!((9..=10).contains(&n), "{n}");
            assert!(start.elapsed() < VERIFY_BUDGET + Duration::from_millis(500));
        }

        /// A mocked clock: every finished re-decode of `rec` took `step`.
        fn decode_clock(rec: &FakeRecognizer, step: Duration) -> impl FnMut() -> Instant + use<> {
            let (t0, rec) = (Instant::now(), rec.clone());
            move || t0 + step * rec.state().redecodes as u32
        }

        #[test]
        fn a_result_past_the_budget_is_dropped() {
            let v = job(TYPED, EDITED);
            // Recovered by the fifth decode (4.0), which starts in budget.
            // At 0.7 s per decode it ends at 3.5 s: too late, dropped.
            let mut rec = recognizer(&[(4000, RECOVERED)]);
            let mut clock = decode_clock(&rec, Duration::from_millis(700));
            let got = verify_with_clock(&v, &CancelToken::default(), &mut rec, &mut clock);
            assert_eq!(got, None);
            assert_eq!(rec.state().redecodes, 5);
            // At 0.5 s per decode it ends at 2.5 s and counts.
            let mut rec = recognizer(&[(4000, RECOVERED)]);
            let mut clock = decode_clock(&rec, Duration::from_millis(500));
            let got = verify_with_clock(&v, &CancelToken::default(), &mut rec, &mut clock);
            assert_eq!(got.map(|s| s.strength), Some(4000));
            // No decode starts once the budget is spent: 0.5 s each, the
            // seventh would start at 3.0 s.
            let mut rec = recognizer(&[]);
            let mut clock = decode_clock(&rec, Duration::from_millis(500));
            assert_eq!(
                verify_with_clock(&v, &CancelToken::default(), &mut rec, &mut clock),
                None
            );
            assert_eq!(rec.state().redecodes, 6);
        }

        #[test]
        fn a_cancel_during_a_decode_drops_its_result() {
            let v = job(TYPED, EDITED);
            let token = CancelToken::default();
            let mut rec = recognizer(&[(1000, RECOVERED)]);
            // The clock is read after the decode: cancel arrives meanwhile.
            let r2 = rec.clone();
            let mut clock = || {
                if r2.state().redecodes > 0 {
                    token.cancel();
                }
                Instant::now()
            };
            assert_eq!(verify_with_clock(&v, &token, &mut rec, &mut clock), None);
            assert_eq!(rec.state().redecodes, 1);
        }

        #[test]
        fn casing_respects_the_budget_and_cancel() {
            let v = job("i like nixos", "i like NixOS");
            let t0 = Instant::now();
            // The clock reads 0 at the start and 3.1 s at the casing check.
            let mut times = [t0, t0 + Duration::from_millis(3100)].into_iter();
            let mut clock = move || times.next().unwrap_or(t0 + VERIFY_BUDGET * 2);
            let mut rec = recognizer(&[]);
            assert_eq!(
                verify_with_clock(&v, &CancelToken::default(), &mut rec, &mut clock),
                None
            );
            let token = CancelToken::default();
            token.cancel();
            assert_eq!(verify(&v, &token, &mut rec), None);
            assert!(verify(&v, &CancelToken::default(), &mut rec).is_some());
        }

        #[test]
        fn unmappable_candidates_cost_no_decodes_or_time() {
            // The typed text's corrected words are not in the transcript.
            let mut v = job(TYPED, EDITED);
            v.session = Arc::new(Retained {
                raw: "we deployed it on copper netties yesterday".into(),
                ..Arc::try_unwrap(session(TYPED)).ok().unwrap()
            });
            let mut rec = recognizer(&[]);
            let mut reads = 0;
            let mut clock = || {
                reads += 1;
                Instant::now()
            };
            assert_eq!(
                verify_with_clock(&v, &CancelToken::default(), &mut rec, &mut clock),
                None
            );
            assert_eq!(rec.state().redecodes, 0);
            // Only the start was read; no budget was spent on the candidate.
            assert_eq!(reads, 1);
            // A later mappable candidate still gets its decodes.
            let before = "aa bb cc dd ee ff gg";
            let mut v = job(before, "aa Xb cc dd Xe ff gg");
            v.session = Arc::new(Retained {
                raw: "aa zz cc dd ee ff gg".into(),
                ..Arc::try_unwrap(session(before)).ok().unwrap()
            });
            assert_eq!(v.candidates.len(), 2);
            let mut rec = recognizer(&[(1000, "aa zz cc dd xe ff gg")]);
            let got = verify(&v, &CancelToken::default(), &mut rec).unwrap();
            assert_eq!((got.word.as_str(), rec.state().redecodes), ("Xe", 1));
        }

        fn transcribe(
            heard: &str,
            dictionary: Arc<Snapshot>,
            settings: &Settings,
        ) -> (String, Outcome) {
            let out = FakeOutput::default();
            let job = Job {
                id: 1,
                cancel: Arc::new(CancelToken::default()),
                kind: JobKind::Transcribe {
                    audio: Audio::new(vec![0.1; 16]),
                    prompt: false,
                    dictionary,
                },
            };
            let mut rec = FakeRecognizer::returning(heard);
            let outcome = run(job, &mut rec, &mut out.clone(), settings, &|_| {});
            (out.text(), outcome)
        }

        fn settings() -> Settings {
            Settings {
                options: lf_dictation::Options::default(),
                macros: vec![VoiceMacro {
                    command: "sign off".into(),
                    payload: "Synthetic regards.".into(),
                }],
                type_chunk_chars: TYPE_CHUNK_CHARS,
                prompt_tag: "[dictated]".into(),
            }
        }

        fn kept(outcome: &Outcome) -> Option<&Retained> {
            match outcome {
                Outcome::Typed { retained, .. } => retained.as_deref(),
                _ => None,
            }
        }

        #[test]
        fn casing_is_restored_before_post_processing_and_kept() {
            let snap = Arc::new(Snapshot {
                revision: 9,
                dictionary: Dictionary {
                    entries: vec![DictionaryEntry {
                        text: "NixOS".into(),
                        strength: 1.0,
                    }],
                    ignore: Vec::new(),
                },
            });
            let (typed, outcome) = transcribe("i run nixos daily.", Arc::clone(&snap), &settings());
            assert_eq!(typed, "i run NixOS daily. ");
            let r = kept(&outcome).expect("kept for correction");
            assert_eq!(r.raw, "i run NixOS daily.");
            assert_eq!(r.output, "i run NixOS daily.");
            assert!(Arc::ptr_eq(&r.dictionary, &snap));
            assert_eq!(r.projection.frames, 1);
            // Debug shows no text.
            let d = format!("{outcome:?}");
            assert!(d.contains("Retained(1 frames, revision 9)"), "{d}");
        }

        #[test]
        fn macros_return_long_and_control_text_are_not_kept() {
            let s = settings();
            let long = "word ".repeat(MAX_SESSION_BYTES / 5 + 1);
            for heard in ["Sign off.", "Synthetic words. Press enter.", long.as_str()] {
                let (_, outcome) = transcribe(heard, Arc::default(), &s);
                assert!(
                    matches!(outcome, Outcome::Typed { retained: None, .. }),
                    "{heard:.40}"
                );
            }
            let (_, outcome) = transcribe("Synthetic words", Arc::default(), &s);
            assert!(kept(&outcome).is_some());
        }
    }
}

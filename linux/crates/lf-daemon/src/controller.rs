// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.
//! The dictation state machine, driven by control commands and worker events
//! on a single thread:
//!
//! ```text
//! idle --start--> recording --stop--> transcribing --text--> typing --done--> idle
//! ```
//!
//! - **Start / stop** follow [`SessionController`] (hold versus toggle).
//! - **Presses while transcribing or typing** are ignored (`note=ignored`),
//!   as in the Swift app; an active recording session can still be stopped.
//! - **Cancel** while recording discards the audio. While transcribing or
//!   typing it abandons the dictation: the worker drops the result, and the
//!   cancel waits for at most one output call in progress, so nothing is
//!   typed and Return is not pressed after the reply (text already typed
//!   stays). Cancel when idle is ignored.
//! - **Out-of-order press and release**: Hyprland runs each bind as its own
//!   `localflowctl` process, so their requests can arrive out of order.
//!   `localflowctl` stamps each request with `CLOCK_MONOTONIC` at start
//!   (`at=`). A press stamped no later than a release that matched no
//!   session is that release's own press, overtaken: it is ignored instead
//!   of starting a recording no release would stop. A release stamped
//!   before the press that started the current hold is stale and ignored.
//!   The newest unmatched release's stamp is kept (an older one never
//!   lowers it) until a press stamped after it arrives, so any number of
//!   overtaken presses are ignored. Known limitation: a *second* press that
//!   overtakes the *first* hold's release is ignored like any press during
//!   a hold, and the late first release then ends the recording, so that
//!   second hold's speech is lost (it needs a key pressed again within
//!   process start-up jitter of releasing it). Requests
//!   without (trusted) stamps are taken in arrival order.
//! - **Capture errors** at start or stop cancel the capture and return to
//!   idle with `error capture`.
//! - **The microphone never blocks this thread.** Capture calls run on their
//!   own thread (`crate::capture`). While one runs (*starting* or
//!   *stopping*), `status`, `watch`, text commands and the timers are served
//!   at once, and status reports the state from before the call (starting
//!   is idle, stopping is still recording), so it changes when the call
//!   completes, as when the call blocked. The reply of the request that made
//!   the call waits for it. `press`, `release`, `toggle` and `again` wait in
//!   arrival order, at most [`MAX_WAITING`] (the next is refused with
//!   `error busy`), and are then handled as if they had arrived after the
//!   call, with their own stamps. `cancel` acts at once: it discards the
//!   recording, and the requests waiting for the call are answered like the
//!   cancel (`note=cancelled`) without taking effect. A late result of a
//!   cancelled call is dropped (its audio wiped).
//! - **Empty** recordings and recordings shorter than
//!   `min_recording_seconds` are discarded without recognition
//!   (`note=empty` / `note=too-short`).
//! - Recording stops automatically at `max_recording_seconds`.
//! - While the model loads, recording works; the dictation is transcribed
//!   once the model is ready.
//! - After a cancel, a new dictation may start while the worker is still
//!   finishing the abandoned one; its job runs next.
//! - **Media** (`pause_media`): playing media players are paused when a
//!   recording starts (the request goes out just before the microphone
//!   starts, and never waits) and resumed when the recording ends, on every
//!   path: stop, cancel, maximum length, capture errors and shutdown. The
//!   resume goes out after the microphone has stopped, so resumed audio
//!   cannot leak into the recording. See `media.rs`.
//! - **Stamps** more than [`STAMP_FUTURE_TOLERANCE`] ahead of the daemon's
//!   own clock are treated as absent: they never set or move any marker, so
//!   no request can make later valid ones be ignored. (An old stamp only
//!   makes its own request look old, so it still orders.) Taps and prompts
//!   also need a stamp at most [`STAMP_MAX_AGE`] old.
//! - **Double-tap and hold (Hold to Prompt)**: a quick *tap* of the hold
//!   key, then a press within `double_tap` that is held, makes a *prompt
//!   recording*, whose dictation gets the prompt tag (`tag=prompt` in
//!   replies while it is recorded, transcribed and typed). An ordinary hold
//!   must never be tagged by mistake, so any doubt means no tag:
//!   - **Timing** must agree on both clocks: the press must be received
//!     within `double_tap` of the tap's release being received, on the
//!     daemon's own clock that includes suspend (`CLOCK_BOOTTIME`, so
//!     suspend expires a pending tap), *and* stamped within `double_tap`
//!     after the release's stamp (so requests delivered late and bunched
//!     together are not mistaken for a quick double tap). The release's
//!     receive time is read on receipt, before the capture stops, so a
//!     delay there can only expire a tap.
//!   - **A tap arms** only when, from idle, a press with a trusted stamp
//!     newer than the last release that stopped a recording started a hold
//!     recording, that recording's own release (trusted stamp, not stale)
//!     stopped it, and it was discarded as too short or empty.
//!   - **A prompt starts** only from such a press (idle, trusted stamp,
//!     newer than that release) received in time after a tap.
//!   - **Everything else** arms nothing and clears a pending tap: every
//!     other request except `status` (ignored ones included), unstamped
//!     requests, out-of-order pairs, presses while busy.
//!
//!   A too-short prompt recording is itself a tap, so tapping on keeps the
//!   next hold a prompt. While a tap is pending, media stay paused until the
//!   window ends, so a double tap does not make the music stutter; every
//!   recording start still sends a (harmless, repeated) pause, so a player
//!   started during the window is paused too.
//! - **Agent link** (`crate::link`): suggestions, project words and the
//!   agent report expire by the timer. Dictation boosts the dictionary plus
//!   the project words (the dictionary's strength wins); resolving a
//!   suggestion with add or ignore is a dictionary change and ends the
//!   correction session, project words never do.

use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::mpsc::Sender;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// How far an `at=` stamp may be ahead of the daemon's clock and still be
/// trusted (the stamp is taken before the request is sent, so a correct one
/// is never ahead; this allows for rounding).
pub const STAMP_FUTURE_TOLERANCE: Duration = Duration::from_millis(50);
/// How far an `at=` stamp may be behind the daemon's clock and still be
/// trusted.
pub const STAMP_MAX_AGE: Duration = Duration::from_secs(2);

/// `CLOCK_BOOTTIME`: like `CLOCK_MONOTONIC`, but counting suspend.
pub fn boottime() -> Duration {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `ts` is a valid timespec to write.
    unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &mut ts) };
    Duration::new(ts.tv_sec as u64, ts.tv_nsec as u32)
}

use lf_asr::dictionary::{self as rules, DEFAULT_STRENGTH};
use lf_dictation::correction::correction_candidates;
use lf_io_api::{IoError, SAMPLE_RATE};

use crate::capture::{Call, CaptureEvent, CapturePort, Done};

use crate::dictionary::{ChangeError, Snapshot, Store};
use crate::history::{Entry, History};
use crate::link::{self, AgentReport, ProjectWords, Suggestions};
use crate::media::{MediaSink, NoMedia};
use crate::protocol::{
    AGENTS_DEFAULT_TTL, Activity, AgentCounts, Args, Command, CorrectionResult, ErrorCode, Extra,
    Note, Reply, Request, Resolve, State, Status, SuggestOutcome, WORDS_DEFAULT_TTL,
};
use crate::server::Responder;
use crate::session::{Action, Event, Mode, SessionController};
use crate::worker::{
    Audio, CancelToken, Job, JobKind, Outcome, Retained, Suggestion, Verify, WorkerEvent,
};

/// How many requests may wait for a capture call (see the module docs).
pub const MAX_WAITING: usize = 32;

/// How long after a dictation is typed it can still be corrected
/// (`correct-begin` / `correct-submit`); then its session is discarded.
pub const CORRECTION_WINDOW: Duration = Duration::from_secs(120);

/// The last typed dictation, kept for `localflowctl correct` (DESIGN
/// §2.4). In memory only; it never reaches logs, `watch`, history or
/// `Debug` output.
struct CorrectionSession {
    id: u64,
    created: Instant,
    retained: Arc<Retained>,
}

/// The current correction check (`correct-submit` / `correct-result`).
struct Check {
    job: u64,
    cancel: Arc<CancelToken>,
    state: CheckState,
}

enum CheckState {
    Pending,
    Done(Option<Suggestion>),
    /// Its session was discarded.
    Stale,
}

/// Where the controller sends recognition jobs.
pub trait JobSink: Send {
    fn submit(&mut self, job: Job);
}

impl JobSink for Sender<Job> {
    fn submit(&mut self, job: Job) {
        // If the worker has exited, the daemon is shutting down.
        let _ = self.send(job);
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub min_recording: Duration,
    pub max_recording: Duration,
    /// Double-tap window for Hold to Prompt; zero disables it.
    pub double_tap: Duration,
}

impl Limits {
    fn samples(d: Duration) -> usize {
        (d.as_secs_f64() * f64::from(SAMPLE_RATE)).round() as usize
    }
}

enum Phase {
    Idle,
    /// `start` sent for recording `generation`; reported as idle.
    Starting {
        generation: u64,
        prompt: bool,
        tap_eligible: bool,
    },
    Recording {
        generation: u64,
        since: Instant,
        /// A prompt recording (double-tap and hold).
        prompt: bool,
        /// Started from idle by a press with a fresh stamp: discarded as
        /// too short by its own release, it is a tap.
        tap_eligible: bool,
    },
    /// `stop` sent; reported as still recording, in `mode`.
    Stopping {
        generation: u64,
        since: Instant,
        prompt: bool,
        mode: Option<Mode>,
        /// See [`Controller::stop_recording`].
        hold_release: bool,
        /// When the stop was asked for.
        at: Instant,
        /// The tap this recording is if it turns out too short or empty.
        tap: Option<Tap>,
    },
    /// A job the worker is running for the current dictation.
    Busy {
        id: u64,
        cancel: Arc<CancelToken>,
        typing: bool,
        prompt: bool,
        /// The revision of the dictionary (without project words) when the
        /// job was submitted.
        base: u64,
    },
}

/// The dictionary merged with the project words, for transcription; reused
/// while neither changed, so the recognizer's graph cache stays valid.
struct Merged {
    /// The dictionary's revision.
    base: u64,
    /// [`ProjectWords::generation`].
    generation: u64,
    snapshot: Arc<Snapshot>,
}

pub struct Controller {
    session: SessionController,
    capture: Box<dyn CapturePort>,
    /// Numbers recordings, so a late result of a cancelled one is dropped.
    generation: u64,
    /// The reply of the request that made the capture call in flight.
    in_flight: Option<Responder>,
    /// Requests waiting for that call, in arrival order.
    waiting: VecDeque<(Request, Responder)>,
    jobs: Box<dyn JobSink>,
    phase: Phase,
    model_ready: bool,
    next_id: u64,
    limits: Limits,
    history: Option<History>,
    /// The last dictated text, in memory only, for `again`.
    last_output: Option<String>,
    /// Stamp of the last release that matched no session.
    orphan_release_at: Option<u64>,
    /// Stamp of the press that started the current hold.
    hold_press_at: Option<u64>,
    /// Stamp of the last release that stopped a recording. Only a press
    /// stamped after it can start a tap or a prompt (a replayed press
    /// cannot).
    last_release_at: Option<u64>,
    media: Box<dyn MediaSink>,
    /// A pause was sent and its resume not yet.
    media_paused: bool,
    /// A resume held back after a tap, due at this time unless the next
    /// press keeps the media paused.
    media_resume_at: Option<Instant>,
    /// The last tap, while a double tap may follow.
    tap: Option<Tap>,
    /// The recording being started is a prompt recording.
    start_prompt: bool,
    /// Maps request receive times to `CLOCK_MONOTONIC` ns: an `Instant` and
    /// the ns it stands for (see [`clock_anchor`]).
    clock: (Instant, u64),
    /// Receive time for double-tap timing; `CLOCK_BOOTTIME`, so suspend
    /// counts (tests inject their own).
    boot: Box<dyn Fn() -> Duration + Send>,
    /// The custom dictionary; without one, dictionary commands are
    /// unavailable and dictation boosts nothing.
    dictionary: Option<Store>,
    empty_dictionary: Arc<Snapshot>,
    correction: Option<CorrectionSession>,
    next_session: u64,
    check: Option<Check>,
    /// Set when the daemon cannot go on (see [`Controller::take_fatal`]).
    fatal: Option<String>,
    /// Dictionary suggestions from agents (see `crate::link`).
    suggestions: Suggestions,
    /// Project words, boosted with the dictionary.
    words: ProjectWords,
    merged: Option<Merged>,
    /// The live agent status report.
    agents: Option<AgentReport>,
}

/// A hold too short to dictate; a quick second press makes a prompt.
#[derive(Clone, Copy, Debug)]
struct Tap {
    /// When its release was received ([`Controller::boot`]), read on
    /// receipt, before the capture stopped.
    received: Duration,
    /// Its release's (fresh) stamp.
    released: u64,
}

/// Pairs an `Instant` with the `CLOCK_MONOTONIC` ns it stands for. The two
/// clocks are read one after the other, so `sample` reads the ns clock
/// before and after the `Instant`; of up to `attempts` samples, the one
/// with the tightest bracket wins and its midpoint is used. The error is
/// therefore at most half that bracket, however the thread was scheduled.
pub fn clock_anchor(
    attempts: usize,
    mut sample: impl FnMut() -> (u64, Instant, u64),
) -> (Instant, u64) {
    /// Good enough to stop early.
    const TIGHT_NS: u64 = 20_000;
    let mut best: Option<(u64, Instant, u64)> = None;
    for _ in 0..attempts.max(1) {
        let (before, instant, after) = sample();
        let width = after.saturating_sub(before);
        if best.is_none_or(|(w, _, _)| width < w) {
            best = Some((width, instant, before + width / 2));
        }
        if width <= TIGHT_NS {
            break;
        }
    }
    let (_, instant, ns) = best.expect("at least one attempt");
    (instant, ns)
}

fn sample_clocks() -> (u64, Instant, u64) {
    let before = crate::protocol::monotonic_ns();
    let instant = Instant::now();
    (before, instant, crate::protocol::monotonic_ns())
}

impl Controller {
    pub fn new(
        capture: Box<dyn CapturePort>,
        jobs: Box<dyn JobSink>,
        limits: Limits,
        history: Option<History>,
    ) -> Controller {
        Controller {
            session: SessionController::default(),
            capture,
            generation: 0,
            in_flight: None,
            waiting: VecDeque::new(),
            jobs,
            phase: Phase::Idle,
            model_ready: false,
            next_id: 1,
            limits,
            history,
            last_output: None,
            orphan_release_at: None,
            hold_press_at: None,
            last_release_at: None,
            media: Box::new(NoMedia),
            media_paused: false,
            media_resume_at: None,
            tap: None,
            start_prompt: false,
            clock: clock_anchor(100, sample_clocks),
            boot: Box::new(boottime),
            dictionary: None,
            empty_dictionary: Arc::default(),
            correction: None,
            next_session: 1,
            check: None,
            fatal: None,
            suggestions: Suggestions::default(),
            words: ProjectWords::default(),
            merged: None,
            agents: None,
        }
    }

    /// Why the daemon must stop, once a request has made it impossible to
    /// go on (a dictionary save that could not be undone). The control loop
    /// sends the request's reply, then stops with this error, so the daemon
    /// exits non-zero and reloads the dictionary when restarted. The text
    /// carries no content.
    pub fn take_fatal(&mut self) -> Option<String> {
        self.fatal.take()
    }

    /// Uses `store` for dictation and the dictionary commands.
    pub fn with_dictionary(mut self, store: Store) -> Controller {
        self.dictionary = Some(store);
        self
    }

    fn dictionary_snapshot(&self) -> Arc<Snapshot> {
        self.dictionary
            .as_ref()
            .map_or_else(|| Arc::clone(&self.empty_dictionary), Store::snapshot)
    }

    /// What dictation boosts: the dictionary plus the project words. The
    /// same snapshot while neither changed, a new revision when the merged
    /// words do; the dictionary's own snapshot without project words.
    fn transcription_snapshot(&mut self) -> Arc<Snapshot> {
        let base = self.dictionary_snapshot();
        if self.words.is_empty() {
            return base;
        }
        let generation = self.words.generation();
        if let Some(m) = &self.merged
            && m.base == base.revision
            && m.generation == generation
        {
            return Arc::clone(&m.snapshot);
        }
        let dictionary = self.words.merge(&base.dictionary);
        let snapshot = match &self.merged {
            // The same words loaded again: keep the revision.
            Some(m) if m.snapshot.dictionary == dictionary => Arc::clone(&m.snapshot),
            _ => Arc::new(Snapshot {
                revision: crate::dictionary::next_revision(),
                dictionary,
            }),
        };
        self.merged = Some(Merged {
            base: base.revision,
            generation,
            snapshot: Arc::clone(&snapshot),
        });
        snapshot
    }

    /// The agent link's counts, for watch lines.
    pub fn activity(&self) -> Activity {
        Activity {
            suggestions: u32::try_from(self.suggestions.len()).unwrap_or(u32::MAX),
            words: u32::try_from(self.words.count()).unwrap_or(u32::MAX),
            agents: self.agents.map_or_else(AgentCounts::default, |a| a.counts),
        }
    }

    /// Drops suggestions, project word sets and an agent report whose time
    /// is up.
    fn expire_link(&mut self, now: Instant) {
        self.suggestions.expire(now);
        self.words.expire(now);
        if self.agents.is_some_and(|a| now >= a.expires) {
            self.agents = None;
        }
    }

    /// Drops the correction session and stops (or makes stale) its check:
    /// on a new recording, any cancel, a dictionary change and expiry.
    fn discard_correction(&mut self) {
        if self.correction.take().is_some() {
            crate::debug!("correction session discarded");
        }
        if let Some(c) = &mut self.check
            && !matches!(c.state, CheckState::Stale)
        {
            // The verification job holds no output lock, so this never waits.
            c.cancel.cancel();
            c.state = CheckState::Stale;
        }
    }

    fn expire_correction(&mut self, now: Instant) {
        if self
            .correction
            .as_ref()
            .is_some_and(|s| now.saturating_duration_since(s.created) >= CORRECTION_WINDOW)
        {
            crate::debug!("correction window ended");
            self.discard_correction();
        }
    }

    /// The text commands (see `crate::protocol`). They never touch a
    /// recording or a pending double tap.
    fn text_command(&mut self, command: Command, args: Args, now: Instant) -> Reply {
        self.expire_correction(now);
        self.expire_link(now);
        let result = match command {
            Command::CorrectBegin => match &self.correction {
                Some(s) => Ok(Some(Extra::Correction {
                    id: s.id,
                    text: s.retained.output.clone(),
                })),
                None => Err(ErrorCode::NoRecent),
            },
            Command::CorrectSubmit => self.submit_correction(args).map(Some),
            Command::CorrectResult => self.correction_result(args).map(Some),
            Command::DictAdd
            | Command::DictRemove
            | Command::DictIgnore
            | Command::DictUnignore => self.change_dictionary(command, args).map(|()| None),
            Command::SuggestAdd => self.suggest_add(args, now).map(Some),
            Command::SuggestNext => self.suggest_next().map(Some),
            Command::SuggestResolve => self.suggest_resolve(args).map(|()| None),
            Command::WordsSet => self.words_set(args, now).map(Some),
            Command::WordsClear => match args.set {
                Some(set) if self.words.clear(&set) => {
                    crate::info!("project words cleared");
                    Ok(None)
                }
                Some(_) => Err(ErrorCode::NotFound),
                None => Err(ErrorCode::BadRequest),
            },
            Command::AgentsSet => {
                let ttl = args.ttl.unwrap_or(AGENTS_DEFAULT_TTL);
                self.agents = Some(AgentReport {
                    counts: AgentCounts {
                        approval: args.approval.unwrap_or(0),
                        input: args.input.unwrap_or(0),
                        working: args.working.unwrap_or(0),
                        done: args.done.unwrap_or(0),
                    },
                    expires: now + Duration::from_secs(ttl),
                });
                Ok(None)
            }
            Command::AgentsClear => {
                self.agents = None;
                Ok(None)
            }
            _ => Err(ErrorCode::UnknownCommand),
        };
        match result {
            Ok(Some(extra)) => Reply::With(self.status(), extra),
            Ok(None) => self.ok(None),
            Err(code) => Reply::Error(code),
        }
    }

    /// Computes the correction's candidates (DESIGN §1.5) and queues their
    /// check; the reply never waits for it.
    fn submit_correction(&mut self, args: Args) -> Result<Extra, ErrorCode> {
        let (Some(id), Some(text)) = (args.id, args.text) else {
            return Err(ErrorCode::BadRequest);
        };
        let retained = match &self.correction {
            Some(s) if s.id == id => Arc::clone(&s.retained),
            _ => return Err(ErrorCode::Stale),
        };
        if text.len() > crate::worker::MAX_SESSION_BYTES {
            return Err(ErrorCode::TooLong);
        }
        let Some(store) = &self.dictionary else {
            return Err(ErrorCode::Unavailable);
        };
        let snap = store.snapshot();
        // All of them: the worker drops the ones it cannot attempt before
        // taking at most three (DESIGN P8).
        let candidates = correction_candidates(
            &retained.output,
            &text,
            &snap.dictionary.entries,
            &snap.dictionary.ignore,
            store.tokenizer(),
        );
        drop(text);
        if let Some(c) = &self.check
            && matches!(c.state, CheckState::Pending)
        {
            c.cancel.cancel();
        }
        let job = self.next_id;
        self.next_id += 1;
        let cancel = Arc::new(CancelToken::default());
        crate::info!("correction submitted ({} candidates)", candidates.len());
        let state = if candidates.is_empty() {
            CheckState::Done(None)
        } else {
            self.jobs.submit(Job {
                id: job,
                cancel: Arc::clone(&cancel),
                kind: JobKind::Verify(Verify {
                    session: retained,
                    candidates,
                }),
            });
            CheckState::Pending
        };
        self.check = Some(Check { job, cancel, state });
        Ok(Extra::Job(job))
    }

    fn correction_result(&self, args: Args) -> Result<Extra, ErrorCode> {
        let job = args.job.ok_or(ErrorCode::BadRequest)?;
        let Some(c) = self.check.as_ref().filter(|c| c.job == job) else {
            return Err(ErrorCode::UnknownJob);
        };
        Ok(Extra::Result(match &c.state {
            CheckState::Pending => CorrectionResult::Pending,
            CheckState::Done(None) => CorrectionResult::None,
            CheckState::Done(Some(s)) => CorrectionResult::Suggest {
                word: s.word.clone(),
                strength: s.strength,
                casing: s.casing,
            },
            CheckState::Stale => return Err(ErrorCode::Stale),
        }))
    }

    fn change_dictionary(&mut self, command: Command, args: Args) -> Result<(), ErrorCode> {
        if self.dictionary.is_none() {
            return Err(ErrorCode::Unavailable);
        }
        let word = args.word.ok_or(ErrorCode::BadRequest)?;
        self.apply_change(command.name(), |store| match command {
            Command::DictAdd => store.add(
                &word,
                args.strength
                    .map_or(DEFAULT_STRENGTH, |milli| milli as f32 / 1000.0),
            ),
            Command::DictRemove => store.remove(&word),
            Command::DictIgnore => store.ignore(&word),
            _ => store.unignore(&word),
        })
    }

    /// Applies one dictionary change (`what` names it in the log): any
    /// published change ends the correction session; errors map to codes.
    fn apply_change(
        &mut self,
        what: &str,
        change: impl FnOnce(&mut Store) -> Result<(), ChangeError>,
    ) -> Result<(), ErrorCode> {
        let Some(store) = &mut self.dictionary else {
            return Err(ErrorCode::Unavailable);
        };
        let before = store.snapshot().revision;
        let changed = change(store);
        // Any published change (also one recovered from disk after a failed
        // save) makes the session's frozen dictionary out of date.
        if store.snapshot().revision != before {
            self.discard_correction();
        }
        match changed {
            Ok(()) => {
                crate::info!("dictionary changed ({what})");
                Ok(())
            }
            Err(ChangeError::InvalidEntry(e)) => {
                crate::info!("dictionary entry refused: {}", e.name());
                Err(ErrorCode::InvalidEntry)
            }
            Err(ChangeError::Full) => Err(ErrorCode::Full),
            Err(ChangeError::NotFound) => Err(ErrorCode::NotFound),
            Err(ChangeError::BadWord) => Err(ErrorCode::BadRequest),
            Err(ChangeError::Storage) => Err(ErrorCode::Storage),
            Err(ChangeError::Unrecoverable) => {
                self.fatal = Some(
                    "the dictionary could not be saved or restored; restart to reload it".into(),
                );
                Err(ErrorCode::Storage)
            }
        }
    }

    /// `suggest-add`: queues a word for review unless the dictionary or the
    /// ignore list already has it.
    fn suggest_add(&mut self, args: Args, now: Instant) -> Result<Extra, ErrorCode> {
        let Some(store) = &self.dictionary else {
            return Err(ErrorCode::Unavailable);
        };
        let word = args.word.ok_or(ErrorCode::BadRequest)?;
        let entry = rules::validate(&word, DEFAULT_STRENGTH, store.tokenizer()).map_err(|e| {
            crate::info!("suggestion refused: {}", e.name());
            ErrorCode::InvalidEntry
        })?;
        drop(word);
        let key = entry.key();
        let snap = store.snapshot();
        if snap.dictionary.entries.iter().any(|e| e.key() == key) {
            return Ok(Extra::Outcome(SuggestOutcome::Present));
        }
        if snap.dictionary.ignore.contains(&key) {
            return Ok(Extra::Outcome(SuggestOutcome::Ignored));
        }
        let before = self.suggestions.len();
        self.suggestions
            .add(entry, now)
            .map_err(|link::Full| ErrorCode::Full)?;
        if self.suggestions.len() != before {
            crate::info!("dictionary suggestion queued");
        }
        Ok(Extra::Outcome(SuggestOutcome::Queued))
    }

    /// `suggest-next`: the oldest pending suggestion, once those added to
    /// the dictionary or the ignore list since are dropped.
    fn suggest_next(&mut self) -> Result<Extra, ErrorCode> {
        let Some(store) = &self.dictionary else {
            return Err(ErrorCode::Unavailable);
        };
        let snap = store.snapshot();
        self.suggestions.drop_keys(|key| {
            snap.dictionary.entries.iter().any(|e| e.key() == key)
                || snap.dictionary.ignore.iter().any(|k| k == key)
        });
        let p = self.suggestions.oldest().ok_or(ErrorCode::NotFound)?;
        Ok(Extra::Suggestion {
            id: p.id,
            word: p.entry.text.clone(),
        })
    }

    /// `suggest-resolve`: adds, ignores or dismisses a pending suggestion.
    /// It stays pending when the change fails.
    fn suggest_resolve(&mut self, args: Args) -> Result<(), ErrorCode> {
        if self.dictionary.is_none() {
            return Err(ErrorCode::Unavailable);
        }
        let (Some(id), Some(action)) = (args.id, args.action) else {
            return Err(ErrorCode::BadRequest);
        };
        let word = match self.suggestions.get(id) {
            Some(p) => p.entry.text.clone(),
            None => return Err(ErrorCode::Stale),
        };
        match action {
            Resolve::Add => {
                self.apply_change("suggestion added", |s| s.add(&word, DEFAULT_STRENGTH))?;
            }
            Resolve::Ignore => self.apply_change("suggestion ignored", |s| s.ignore(&word))?,
            Resolve::Dismiss => crate::info!("dictionary suggestion dismissed"),
        }
        self.suggestions.remove(id);
        Ok(())
    }

    /// `words-set`: loads (or replaces, or with nothing loaded removes) a
    /// project word set. Never a dictionary change: the correction session
    /// stays.
    fn words_set(&mut self, args: Args, now: Instant) -> Result<Extra, ErrorCode> {
        let Some(store) = &self.dictionary else {
            return Err(ErrorCode::Unavailable);
        };
        let (Some(set), Some(words)) = (args.set, args.words) else {
            return Err(ErrorCode::BadRequest);
        };
        let (entries, skipped) = link::parse_words(&words, store.tokenizer());
        drop(words);
        let loaded = u32::try_from(entries.len()).unwrap_or(u32::MAX);
        let ttl = Duration::from_secs(args.ttl.unwrap_or(WORDS_DEFAULT_TTL));
        self.words
            .set(&set, entries, now + ttl)
            .map_err(|link::Full| ErrorCode::Full)?;
        crate::info!("project words set ({loaded} loaded, {skipped} skipped)");
        Ok(Extra::Loaded { loaded, skipped })
    }

    /// Replaces the clock anchor (tests use synthetic times).
    #[cfg(test)]
    fn set_clock(&mut self, instant: Instant, ns: u64) {
        self.clock = (instant, ns);
    }

    /// Replaces the double-tap receive clock (tests use synthetic times).
    #[cfg(test)]
    fn set_boot_clock(&mut self, boot: Box<dyn Fn() -> Duration + Send>) {
        self.boot = boot;
    }

    /// A request's stamp for ordering press and release, or `None`: absent,
    /// or ahead of the daemon's clock (impossible for a real stamp; such a
    /// value would otherwise mark later, valid requests as stale). An old
    /// stamp only makes its own request look old, so it is kept.
    fn ordering_stamp(&self, at: Option<u64>, now: Instant) -> Option<u64> {
        let at = at?;
        let ahead = u128::from(at.saturating_sub(self.clock_ns(now)));
        (ahead <= STAMP_FUTURE_TOLERANCE.as_nanos()).then_some(at)
    }

    /// Whether a request's stamp is trustworthy enough for a tap or a
    /// prompt: present, not ahead of the daemon's clock, and recent.
    fn fresh_stamp(&self, at: Option<u64>, now: Instant) -> Option<u64> {
        let at = self.ordering_stamp(at, now)?;
        let behind = u128::from(self.clock_ns(now).saturating_sub(at));
        (behind <= STAMP_MAX_AGE.as_nanos()).then_some(at)
    }

    /// `now` on the `CLOCK_MONOTONIC` ns scale of `at=` stamps.
    fn clock_ns(&self, now: Instant) -> u64 {
        let (anchor, ns) = self.clock;
        match now.checked_duration_since(anchor) {
            Some(d) => ns.saturating_add(d.as_nanos().min(u128::from(u64::MAX)) as u64),
            None => ns.saturating_sub(
                anchor
                    .duration_since(now)
                    .as_nanos()
                    .min(u128::from(u64::MAX)) as u64,
            ),
        }
    }

    /// Pauses media players while recording through `media`.
    pub fn with_media(mut self, media: Box<dyn MediaSink>) -> Controller {
        self.media = media;
        self
    }

    /// Called when a recording starts. Media still held paused after a tap
    /// stay paused (no resume in between); the pause request goes out again
    /// anyway, so a player started meanwhile, or one a failed earlier pause
    /// missed, is paused too (the media thread leaves paused players alone).
    fn pause_media(&mut self) {
        self.media_resume_at = None;
        self.media_paused = true;
        self.media.pause();
    }

    /// Called whenever a recording ends, after the capture has stopped.
    fn resume_media(&mut self) {
        self.media_resume_at = None;
        if self.media_paused {
            self.media_paused = false;
            self.media.resume();
        }
    }

    pub fn status(&self) -> Status {
        let state = match self.phase {
            Phase::Idle | Phase::Starting { .. } => State::Idle,
            Phase::Recording { .. } | Phase::Stopping { .. } => State::Recording,
            Phase::Busy { typing: false, .. } => State::Transcribing,
            Phase::Busy { typing: true, .. } => State::Typing,
        };
        Status {
            state,
            mode: match self.phase {
                Phase::Recording { .. } => self.session.active_mode(),
                Phase::Stopping { mode, .. } => mode,
                _ => None,
            },
            prompt: matches!(
                self.phase,
                Phase::Recording { prompt: true, .. }
                    | Phase::Stopping { prompt: true, .. }
                    | Phase::Busy { prompt: true, .. }
            ),
            model_ready: self.model_ready,
        }
    }

    fn double_tap_enabled(&self) -> bool {
        !self.limits.double_tap.is_zero()
    }

    /// Whether a press (received now, stamped `at`) follows `tap` closely
    /// enough for a prompt, on both clocks: received within the window of
    /// the tap's release being received (counting suspend), and stamped
    /// within the window after the tap's release stamp (so presses whose
    /// delivery was delayed and then bunched together do not count).
    fn follows(&self, tap: Tap, at: Option<u64>) -> bool {
        let window = self.limits.double_tap;
        let Some(press) = at else {
            return false;
        };
        (self.boot)().saturating_sub(tap.received) <= window
            && press >= tap.released
            && u128::from(press - tap.released) <= window.as_nanos()
    }

    /// Whether a press stamped `at` could start a tap or a prompt: the
    /// controller is idle, double-tap is on, and the stamp is fresh and
    /// newer than the last release that stopped a recording (so a replayed
    /// or reordered press cannot).
    fn press_eligible(&self, at: Option<u64>, now: Instant) -> bool {
        self.double_tap_enabled()
            && matches!(self.phase, Phase::Idle)
            && self
                .fresh_stamp(at, now)
                .is_some_and(|press| self.last_release_at.is_none_or(|r| press > r))
    }

    /// Whether the microphone is present (see `AudioCapture::input_available`).
    pub fn input_available(&self) -> Option<bool> {
        self.capture.input_available()
    }

    /// The capture's input level in [0, 1]; 0 when not recording (nor while
    /// the microphone starts or stops).
    pub fn input_level(&self) -> f32 {
        match self.phase {
            Phase::Recording { .. } => self.capture.level(),
            _ => 0.0,
        }
    }

    fn ok(&self, note: Option<Note>) -> Reply {
        Reply::Ok(self.status(), note)
    }

    /// A request without a stamp (tests; see [`Controller::handle_request`]).
    #[cfg(test)]
    pub fn handle_command(&mut self, cmd: Command, now: Instant) -> Reply {
        self.handle_request(Request::new(cmd), now)
    }

    /// Handles `req` and returns its reply, which must come at once (an
    /// [`crate::capture::Inline`] capture always answers at once).
    #[cfg(test)]
    pub fn handle_request(&mut self, req: Request, now: Instant) -> Reply {
        let (tx, rx) = std::sync::mpsc::channel();
        self.request(req, tx.into(), now);
        rx.try_recv().expect("the reply waits for the capture")
    }

    fn capture_busy(&self) -> bool {
        matches!(self.phase, Phase::Starting { .. } | Phase::Stopping { .. })
    }

    /// Handles `req` and answers through `reply`, at once or, if `req` made
    /// or must wait for a capture call, once that is done (see the module
    /// docs).
    pub fn request(&mut self, req: Request, reply: Responder, now: Instant) {
        let entered = Instant::now();
        let waits = matches!(
            req.command,
            Command::Press | Command::Release | Command::Toggle | Command::Again
        );
        if waits && self.capture_busy() {
            if self.waiting.len() < MAX_WAITING {
                self.waiting.push_back((req, reply));
            } else {
                reply.send(Reply::Error(ErrorCode::Busy));
            }
            return;
        }
        self.serve(req, reply, now);
        self.collect(now, entered);
    }

    fn serve(&mut self, req: Request, reply: Responder, now: Instant) {
        let busy = self.capture_busy();
        let r = self.handle(req, now);
        if !busy && self.capture_busy() {
            self.in_flight = Some(reply);
        } else {
            reply.send(r);
        }
    }

    /// Applies a capture result (see [`Controller::request`]).
    pub fn handle_capture(&mut self, event: CaptureEvent, now: Instant) {
        let entered = Instant::now();
        self.apply(event, now);
        self.collect(now, entered);
    }

    /// Applies results the port has at once; `entered` is when the caller
    /// got `now`, so time spent in an inline call counts.
    fn collect(&mut self, now: Instant, entered: Instant) {
        while let Some(event) = self.capture.poll() {
            self.apply(event, now + entered.elapsed());
        }
    }

    fn apply(&mut self, event: CaptureEvent, now: Instant) {
        let starting = match self.phase {
            Phase::Starting { generation, .. } if generation == event.generation => true,
            Phase::Stopping { generation, .. } if generation == event.generation => false,
            // A cancelled recording's; any audio is wiped here.
            _ => return,
        };
        let result = match event.done {
            Done::Started(r) if starting => self.started(r, now),
            Done::Stopped(r) if !starting => self.stopped(r, now),
            _ => return,
        };
        if let Some(reply) = self.in_flight.take() {
            reply.send(match result {
                Ok(note) => self.ok(note),
                Err(code) => Reply::Error(code),
            });
        }
        self.end_request();
        while !self.capture_busy() {
            let Some((req, reply)) = self.waiting.pop_front() else {
                break;
            };
            self.serve(req, reply, now);
        }
    }

    /// Answers the request that made the capture call and those waiting
    /// for it like the cancel that ended the recording.
    fn abandon_waiting(&mut self) {
        let reply = self.ok(Some(Note::Cancelled));
        for r in self.in_flight.take().into_iter().chain(
            std::mem::take(&mut self.waiting)
                .into_iter()
                .map(|(_, r)| r),
        ) {
            r.send(reply.clone());
        }
    }

    fn end_request(&mut self) {
        if self.session.active_mode() != Some(Mode::Hold) {
            self.hold_press_at = None;
        }
    }

    fn handle(&mut self, req: Request, now: Instant) -> Reply {
        if req.command.is_text() {
            return self.text_command(req.command, req.args, now);
        }
        // Stamps from the future are dropped here, once: nothing below can
        // store one.
        let at = self.ordering_stamp(req.at, now);
        // A pending tap survives only `status`; the release that arms the
        // next one sets it again.
        let tap = match req.command {
            Command::Status | Command::Watch => self.tap,
            _ => self.tap.take(),
        };
        let result = match req.command {
            // The socket hands `watch` connections to the control loop's
            // watcher list; one that reaches here only reads the status.
            Command::Status | Command::Watch => Ok(None),
            // Handled above.
            Command::CorrectBegin
            | Command::CorrectSubmit
            | Command::CorrectResult
            | Command::DictAdd
            | Command::DictRemove
            | Command::DictIgnore
            | Command::DictUnignore
            | Command::SuggestAdd
            | Command::SuggestNext
            | Command::SuggestResolve
            | Command::WordsSet
            | Command::WordsClear
            | Command::AgentsSet
            | Command::AgentsClear => Ok(None),
            Command::Press => {
                let overtaken = match (self.orphan_release_at, at) {
                    (Some(release), Some(press)) => press <= release,
                    _ => false,
                };
                if overtaken {
                    // The orphan stays: any further press it overtook is
                    // ignored too.
                    crate::info!("press arrived after its own release; ignored");
                    Ok(Some(Note::Ignored))
                } else {
                    if at.is_some() {
                        // Stamped after the orphan release: a new press.
                        self.orphan_release_at = None;
                    }
                    let eligible = self.press_eligible(req.at, now);
                    self.start_prompt = eligible && tap.is_some_and(|t| self.follows(t, req.at));
                    let idle = matches!(self.phase, Phase::Idle);
                    let result = self.shortcut(&[Event::HoldActivated], now);
                    self.start_prompt = false;
                    if idle && let Phase::Starting { tap_eligible, .. } = &mut self.phase {
                        // A new hold: its own press stamp, never an older one.
                        *tap_eligible = eligible;
                        self.hold_press_at = at;
                    }
                    result
                }
            }
            Command::Release => {
                // Read on receipt: stopping the capture below can block (or
                // the machine can suspend meanwhile), which may only ever
                // expire a tap, never make a later press look closer.
                let received = (self.boot)();
                let stale = match (self.hold_press_at, at) {
                    (Some(press), Some(release)) => {
                        release < press && self.session.active_mode() == Some(Mode::Hold)
                    }
                    _ => false,
                };
                if stale {
                    crate::info!("release from before the current press; ignored");
                    Ok(Some(Note::Ignored))
                } else {
                    let unmatched = self.session.active_mode().is_none();
                    // The hold recording this release may stop, if it can
                    // become a tap.
                    let tap_eligible = self.session.active_mode() == Some(Mode::Hold)
                        && matches!(
                            self.phase,
                            Phase::Recording {
                                tap_eligible: true,
                                ..
                            }
                        );
                    let recording = matches!(self.phase, Phase::Recording { .. });
                    let result = self.shortcut(&[Event::HoldDeactivated], now);
                    let stopped = recording && !matches!(self.phase, Phase::Recording { .. });
                    if unmatched && at.is_some() {
                        // The newest one: an older stamp never lowers it.
                        self.orphan_release_at = self.orphan_release_at.max(at);
                    }
                    if stopped && at.is_some() {
                        self.last_release_at = self.last_release_at.max(at);
                    }
                    // Armed when the stop finds the recording too short or
                    // empty (see `apply`).
                    let released = self.fresh_stamp(req.at, now);
                    if tap_eligible
                        && let Phase::Stopping { tap, .. } = &mut self.phase
                        && let Some(released) = released
                    {
                        *tap = Some(Tap { received, released });
                    }
                    result
                }
            }
            Command::Toggle => {
                self.shortcut(&[Event::ToggleActivated, Event::ToggleDeactivated], now)
            }
            Command::Cancel => Ok(self.cancel()),
            Command::Again => Ok(self.again()),
        };
        self.end_request();
        match result {
            Ok(note) => self.ok(note),
            Err(code) => Reply::Error(code),
        }
    }

    fn is_busy(&self) -> bool {
        matches!(self.phase, Phase::Busy { .. })
    }

    fn shortcut(&mut self, events: &[Event], now: Instant) -> Result<Option<Note>, ErrorCode> {
        let mut acted = false;
        let mut note = None;
        for &event in events {
            let mode = self.session.active_mode();
            let Some(action) = self.session.handle(event, self.is_busy()) else {
                continue;
            };
            acted = true;
            match action {
                // Logged once the microphone runs.
                Action::Start(_) => self.start_recording(self.start_prompt)?,
                Action::Stop => {
                    note = self.stop_recording(now, event == Event::HoldDeactivated, mode)?;
                }
                Action::SwitchedToToggle => crate::info!("recording switched to toggle mode"),
            }
        }
        Ok(if acted { note } else { Some(Note::Ignored) })
    }

    fn start_recording(&mut self, prompt: bool) -> Result<(), ErrorCode> {
        if !matches!(self.phase, Phase::Idle) {
            // The session controller prevents this; stay consistent anyway.
            self.session.reset();
            return Err(ErrorCode::Capture);
        }
        // A new dictation ends the last one's correction session and stops
        // any check of it between two decodes.
        self.discard_correction();
        // Only a message to the media thread: players pause while the
        // device starts (a Bluetooth headset switches profile meanwhile).
        self.pause_media();
        self.generation += 1;
        self.phase = Phase::Starting {
            generation: self.generation,
            prompt,
            tap_eligible: false,
        };
        // Done when audio flows (seconds, for a sleeping device); see
        // `started`.
        self.capture.send(self.generation, Call::Start);
        Ok(())
    }

    /// `start` returned. The recording window counts from now, not from
    /// the request.
    fn started(
        &mut self,
        result: Result<(), IoError>,
        now: Instant,
    ) -> Result<Option<Note>, ErrorCode> {
        let Phase::Starting {
            generation,
            prompt,
            tap_eligible,
        } = self.phase
        else {
            unreachable!("only called while starting");
        };
        if let Err(e) = result {
            // The capture thread already closed the stream.
            self.phase = Phase::Idle;
            self.resume_media();
            self.session.reset();
            crate::error!("microphone capture failed to start: {e}");
            return Err(ErrorCode::Capture);
        }
        self.phase = Phase::Recording {
            generation,
            since: now,
            prompt,
            tap_eligible,
        };
        if let Some(mode) = self.session.active_mode() {
            crate::info!(
                "recording ({}{})",
                mode.name(),
                if prompt { ", prompt" } else { "" }
            );
        }
        Ok(None)
    }

    /// Stops recording; recognition is queued when the audio arrives (see
    /// `stopped`). The session must already be reset (it is, after
    /// `Action::Stop`); `mode` is the one it had. `hold_release`: stopped by
    /// releasing a hold, so a too-short recording is a tap that a second
    /// press may follow; media then stay paused for the double-tap window.
    fn stop_recording(
        &mut self,
        now: Instant,
        hold_release: bool,
        mode: Option<Mode>,
    ) -> Result<Option<Note>, ErrorCode> {
        let Phase::Recording {
            generation,
            since,
            prompt,
            ..
        } = self.phase
        else {
            self.session.reset();
            return Ok(Some(Note::Ignored));
        };
        self.phase = Phase::Stopping {
            generation,
            since,
            prompt,
            mode,
            hold_release,
            at: now,
            tap: None,
        };
        self.capture.send(generation, Call::Stop);
        Ok(None)
    }

    /// `stop` returned: discards a recording too short or empty (arming the
    /// tap it may be), or queues recognition.
    fn stopped(
        &mut self,
        result: Result<Audio, IoError>,
        done: Instant,
    ) -> Result<Option<Note>, ErrorCode> {
        let Phase::Stopping {
            since,
            prompt,
            hold_release,
            at: now,
            tap,
            ..
        } = std::mem::replace(&mut self.phase, Phase::Idle)
        else {
            unreachable!("only called while stopping");
        };
        let mut audio = match result {
            Ok(a) => a,
            Err(e) => {
                self.resume_media();
                crate::error!("microphone capture failed: {e}");
                return Err(ErrorCode::Capture);
            }
        };
        crate::debug!(
            "recording stopped after {:.2?}",
            now.saturating_duration_since(since)
        );
        let discarded = if audio.is_empty() {
            crate::info!("recording was empty; discarded");
            Some(Note::Empty)
        } else if audio.len() < Limits::samples(self.limits.min_recording) {
            crate::info!("recording shorter than the minimum; discarded");
            Some(Note::TooShort)
        } else {
            None
        };
        if discarded.is_some() && hold_release && self.double_tap_enabled() {
            // A tap: a second press may follow at once. Keep media paused
            // until the window ends (see `tick`) rather than resume now and
            // pause again.
            if self.media_paused {
                self.media_resume_at = Some(now + self.limits.double_tap);
            }
        } else {
            self.resume_media();
        }
        if discarded.is_some() {
            if tap.is_some() {
                self.tap = tap;
            }
            return Ok(discarded);
        }
        let now = done;
        audio.truncate(Limits::samples(self.limits.max_recording));
        let id = self.next_id;
        self.next_id += 1;
        let cancel = Arc::new(CancelToken::default());
        self.expire_link(now);
        let base = self.dictionary_snapshot().revision;
        let dictionary = self.transcription_snapshot();
        self.jobs.submit(Job {
            id,
            cancel: Arc::clone(&cancel),
            kind: JobKind::Transcribe {
                audio,
                prompt,
                dictionary,
            },
        });
        self.phase = Phase::Busy {
            id,
            cancel,
            typing: false,
            prompt,
            base,
        };
        if !self.model_ready {
            crate::info!("transcription waits for the model to finish loading");
        }
        Ok(None)
    }

    fn cancel(&mut self) -> Option<Note> {
        self.discard_correction();
        self.session.reset();
        match std::mem::replace(&mut self.phase, Phase::Idle) {
            Phase::Idle => Some(Note::Ignored),
            Phase::Starting { generation, .. }
            | Phase::Recording { generation, .. }
            | Phase::Stopping { generation, .. } => {
                // Runs after a call in flight; its late result is dropped.
                self.capture.send(generation, Call::Cancel);
                // The audio is discarded, so resuming before the stream
                // has closed cannot reach a dictation.
                self.resume_media();
                self.abandon_waiting();
                crate::info!("recording cancelled");
                Some(Note::Cancelled)
            }
            Phase::Busy { cancel, typing, .. } => {
                cancel.cancel();
                crate::info!(
                    "{} cancelled",
                    if typing { "typing" } else { "transcription" }
                );
                Some(Note::Cancelled)
            }
        }
    }

    fn again(&mut self) -> Option<Note> {
        if !matches!(self.phase, Phase::Idle) {
            return Some(Note::Ignored);
        }
        let Some(text) = self.last_output.clone() else {
            return Some(Note::Ignored);
        };
        let id = self.next_id;
        self.next_id += 1;
        let cancel = Arc::new(CancelToken::default());
        self.jobs.submit(Job {
            id,
            cancel: Arc::clone(&cancel),
            kind: JobKind::Retype(text),
        });
        self.phase = Phase::Busy {
            id,
            cancel,
            typing: true,
            prompt: false,
            base: self.dictionary_snapshot().revision,
        };
        None
    }

    /// Applies a worker event. Returns an error when the daemon cannot
    /// continue (the model failed to load).
    pub fn handle_worker(&mut self, event: WorkerEvent) -> Result<(), String> {
        match event {
            WorkerEvent::ModelReady => {
                self.model_ready = true;
                Ok(())
            }
            WorkerEvent::Fatal(e) => Err(e),
            WorkerEvent::Typing(job) => {
                if let Phase::Busy { id, typing, .. } = &mut self.phase
                    && *id == job
                {
                    *typing = true;
                }
                Ok(())
            }
            WorkerEvent::Done(job, outcome) => {
                let current = matches!(self.phase, Phase::Busy { id, .. } if id == job);
                if !current {
                    crate::debug!("an abandoned dictation finished");
                    return Ok(());
                }
                let (prompt, base) = match self.phase {
                    Phase::Busy { prompt, base, .. } => (prompt, base),
                    _ => (false, 0),
                };
                self.phase = Phase::Idle;
                self.finish(outcome, prompt, base);
                Ok(())
            }
            WorkerEvent::Verified(job, found) => {
                if let Some(c) = &mut self.check
                    && c.job == job
                    && matches!(c.state, CheckState::Pending)
                {
                    crate::info!(
                        "correction checked: {}",
                        if found.is_some() {
                            "a suggestion"
                        } else {
                            "nothing to suggest"
                        }
                    );
                    c.state = CheckState::Done(found);
                }
                Ok(())
            }
        }
    }

    /// `base`: the dictionary's revision when the job was submitted.
    fn finish(&mut self, outcome: Outcome, prompt: bool, base: u64) {
        match outcome {
            Outcome::Typed {
                raw,
                text,
                pressed_enter,
                retype,
                retained,
            } => {
                // A dictionary change after this job was submitted leaves its
                // snapshot out of date: such a dictation is not kept, as a
                // change ends any session (DESIGN §2.4). Project words are no
                // dictionary change: they never end a session.
                let current = self.dictionary_snapshot().revision;
                let retained = retained.filter(|_| {
                    let fresh = base == current;
                    if !fresh {
                        crate::debug!("dictionary changed during the dictation; not kept");
                    }
                    fresh
                });
                if let Some(r) = retained {
                    // Replaces the previous dictation's session.
                    self.discard_correction();
                    self.correction = Some(CorrectionSession {
                        id: self.next_session,
                        created: Instant::now(),
                        retained: Arc::from(r),
                    });
                    self.next_session += 1;
                }
                crate::info!(
                    "{}{}{}",
                    if retype {
                        "typed again"
                    } else {
                        "dictation typed"
                    },
                    if prompt { " (prompt)" } else { "" },
                    if pressed_enter {
                        " and Return pressed"
                    } else {
                        ""
                    }
                );
                if retype || text.is_empty() {
                    return;
                }
                if let Some(h) = &mut self.history {
                    let time = SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .map_or(0, |d| d.as_secs());
                    if let Err(e) = h.push(Entry {
                        time,
                        raw,
                        text: text.clone(),
                    }) {
                        crate::warn!("history: {e}");
                    }
                }
                self.last_output = Some(text);
            }
            Outcome::Nothing => crate::info!("nothing recognized"),
            Outcome::Cancelled => crate::info!("dictation cancelled"),
            Outcome::RecognizeFailed => crate::warn!("dictation dropped: recognition failed"),
            Outcome::OutputFailed => crate::warn!("dictation dropped: typing failed"),
        }
    }

    /// When [`Controller::tick`] next needs to run.
    pub fn next_deadline(&self) -> Option<Instant> {
        let max = match self.phase {
            Phase::Recording { since, .. } => Some(since + self.limits.max_recording),
            _ => None,
        };
        let correction = self
            .correction
            .as_ref()
            .map(|s| s.created + CORRECTION_WINDOW);
        [
            max,
            self.media_resume_at,
            correction,
            self.suggestions.next_expiry(),
            self.words.next_expiry(),
            self.agents.map(|a| a.expires),
        ]
        .into_iter()
        .flatten()
        .min()
    }

    /// Stops a recording that reached the maximum length, and resumes media
    /// held paused after a tap once no second press came in time.
    pub fn tick(&mut self, now: Instant) {
        if let Phase::Recording { since, .. } = self.phase
            && now.saturating_duration_since(since) >= self.limits.max_recording
        {
            crate::info!("maximum recording length reached");
            let mode = self.session.active_mode();
            self.session.reset();
            // The hold is over: its press stamp must not mark a later one.
            self.hold_press_at = None;
            let _ = self.stop_recording(now, false, mode);
            self.collect(now, Instant::now());
        }
        if self.media_resume_at.is_some_and(|t| now >= t) {
            self.resume_media();
        }
        // Enforced by this timer, not only when the session is next used.
        self.expire_correction(now);
        // Likewise suggestions, project words and the agent report.
        self.expire_link(now);
        // An expired tap goes (a press would find it expired anyway).
        if let Some(t) = self.tap
            && (self.boot)().saturating_sub(t.received) > self.limits.double_tap
        {
            self.tap = None;
        }
    }

    /// Discards any recording (resuming media) and abandons any job.
    pub fn shutdown(&mut self) {
        self.cancel();
        // Never left set outside a recording; kept as a backstop.
        self.resume_media();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::capture::Inline;
    use crate::session::Mode;
    use crate::testing::{FakeCapture, TempDir};
    use std::sync::Mutex;

    #[derive(Clone, Default)]
    struct Jobs(Arc<Mutex<Vec<Job>>>);

    impl JobSink for Jobs {
        fn submit(&mut self, job: Job) {
            self.0.lock().unwrap().push(job);
        }
    }

    impl Jobs {
        fn take(&self) -> Vec<Job> {
            std::mem::take(&mut *self.0.lock().unwrap())
        }
    }

    const SECOND: usize = SAMPLE_RATE as usize;

    struct Rig {
        c: Controller,
        cap: FakeCapture,
        jobs: Jobs,
        t: Instant,
        /// When the rig started; stands for [`BASE`] on the stamp clock.
        t0: Instant,
        /// The injected `CLOCK_BOOTTIME` of double-tap rigs, in ms since `t0`.
        boot: Arc<std::sync::atomic::AtomicU64>,
        /// Time spent suspended so far, in ms (`boot` runs ahead of `t`).
        suspended_ms: u64,
    }

    /// The stamp (`CLOCK_MONOTONIC` ns) of `Rig::t0` in double-tap tests.
    const BASE: u64 = 1_000_000_000_000;

    fn rig_with(history: Option<History>) -> Rig {
        let cap = FakeCapture::with_samples(vec![0.1; SECOND]);
        let jobs = Jobs::default();
        let mut c = Controller::new(
            Box::new(Inline::new(Box::new(cap.clone()))),
            Box::new(jobs.clone()),
            Limits {
                min_recording: Duration::from_millis(300),
                max_recording: Duration::from_secs(10),
                double_tap: Duration::ZERO,
            },
            history,
        );
        c.handle_worker(WorkerEvent::ModelReady).unwrap();
        let t = Instant::now();
        Rig {
            c,
            cap,
            jobs,
            t,
            t0: t,
            boot: Arc::default(),
            suspended_ms: 0,
        }
    }

    fn rig() -> Rig {
        rig_with(None)
    }

    impl Rig {
        fn cmd(&mut self, cmd: Command) -> Reply {
            self.t += Duration::from_millis(10);
            let ms = self.t.saturating_duration_since(self.t0).as_millis() as u64;
            self.boot
                .store(ms + self.suspended_ms, std::sync::atomic::Ordering::SeqCst);
            self.c.handle_command(cmd, self.t)
        }

        fn state(&self) -> State {
            self.c.status().state
        }

        fn note(&mut self, cmd: Command) -> Option<Note> {
            match self.cmd(cmd) {
                Reply::Ok(_, note) => note,
                Reply::With(..) => panic!("{cmd:?}: unexpected fields"),
                Reply::Error(e) => panic!("{cmd:?}: error {e:?}"),
            }
        }

        fn typed(&self, text: &str) -> Outcome {
            Outcome::Typed {
                raw: text.into(),
                text: text.into(),
                pressed_enter: false,
                retype: false,
                retained: None,
            }
        }
    }

    #[test]
    fn hold_dictation() {
        let mut r = rig();
        assert_eq!(r.note(Command::Press), None);
        assert_eq!(r.state(), State::Recording);
        assert_eq!(r.c.status().mode, Some(Mode::Hold));
        assert_eq!(r.note(Command::Release), None);
        assert_eq!(r.state(), State::Transcribing);
        let jobs = r.jobs.take();
        assert_eq!(jobs.len(), 1);
        assert!(
            matches!(&jobs[0].kind, JobKind::Transcribe { audio: s, prompt: false, .. } if s.len() == SECOND)
        );
        r.c.handle_worker(WorkerEvent::Typing(jobs[0].id)).unwrap();
        assert_eq!(r.state(), State::Typing);
        let typed = r.typed("synthetic");
        r.c.handle_worker(WorkerEvent::Done(jobs[0].id, typed))
            .unwrap();
        assert_eq!(r.state(), State::Idle);
        assert_eq!(r.c.last_output.as_deref(), Some("synthetic"));
    }

    #[test]
    fn toggle_dictation_and_hold_switch() {
        let mut r = rig();
        assert_eq!(r.note(Command::Toggle), None);
        assert_eq!(r.c.status().mode, Some(Mode::Toggle));
        // Hold key events do nothing in toggle mode.
        assert_eq!(r.note(Command::Press), Some(Note::Ignored));
        assert_eq!(r.note(Command::Release), Some(Note::Ignored));
        assert_eq!(r.state(), State::Recording);
        assert_eq!(r.note(Command::Toggle), None);
        assert_eq!(r.state(), State::Transcribing);

        let mut r = rig();
        r.note(Command::Press);
        assert_eq!(r.note(Command::Toggle), None);
        assert_eq!(r.c.status().mode, Some(Mode::Toggle));
        // Releasing the hold key no longer stops.
        assert_eq!(r.note(Command::Release), Some(Note::Ignored));
        assert_eq!(r.state(), State::Recording);
        r.note(Command::Toggle);
        assert_eq!(r.state(), State::Transcribing);
        assert_eq!(r.cap.state().starts, 1);
        assert_eq!(r.cap.state().stops, 1);
    }

    #[test]
    fn presses_while_busy_are_ignored() {
        let mut r = rig();
        r.note(Command::Press);
        r.note(Command::Release);
        for cmd in [
            Command::Press,
            Command::Release,
            Command::Toggle,
            Command::Again,
        ] {
            assert_eq!(r.note(cmd), Some(Note::Ignored), "{cmd:?}");
            assert_eq!(r.state(), State::Transcribing);
        }
        assert_eq!(r.cap.state().starts, 1);
    }

    #[test]
    fn release_without_press_is_ignored() {
        let mut r = rig();
        assert_eq!(r.note(Command::Release), Some(Note::Ignored));
        assert_eq!(r.note(Command::Status), None);
        assert_eq!(r.state(), State::Idle);
    }

    #[test]
    fn cancel_in_each_state() {
        let mut r = rig();
        assert_eq!(r.note(Command::Cancel), Some(Note::Ignored));

        r.note(Command::Press);
        assert_eq!(r.note(Command::Cancel), Some(Note::Cancelled));
        assert_eq!(r.state(), State::Idle);
        assert_eq!(r.cap.state().cancels, 1);
        assert!(!r.cap.state().recording);
        // The release that follows a cancelled hold does nothing.
        assert_eq!(r.note(Command::Release), Some(Note::Ignored));
        assert!(r.jobs.take().is_empty());

        r.note(Command::Toggle);
        assert_eq!(r.note(Command::Cancel), Some(Note::Cancelled));
        // The session was reset, so the next toggle starts again.
        assert_eq!(r.note(Command::Toggle), None);
        assert_eq!(r.state(), State::Recording);
        r.note(Command::Toggle);

        // Transcribing.
        let job = r.jobs.take().pop().unwrap();
        assert_eq!(r.note(Command::Cancel), Some(Note::Cancelled));
        assert!(job.cancel.is_cancelled());
        assert_eq!(r.state(), State::Idle);
        // A new dictation can start while the worker finishes the old job.
        r.note(Command::Press);
        assert_eq!(r.state(), State::Recording);
        let stale = r.typed("stale");
        r.c.handle_worker(WorkerEvent::Done(job.id, stale)).unwrap();
        assert_eq!(r.state(), State::Recording);
        assert_eq!(r.c.last_output, None);
        r.note(Command::Release);

        // Typing.
        let job = r.jobs.take().pop().unwrap();
        r.c.handle_worker(WorkerEvent::Typing(job.id)).unwrap();
        assert_eq!(r.note(Command::Cancel), Some(Note::Cancelled));
        assert!(job.cancel.is_cancelled());
        r.c.handle_worker(WorkerEvent::Done(job.id, Outcome::Cancelled))
            .unwrap();
        assert_eq!(r.state(), State::Idle);
    }

    #[test]
    fn short_and_empty_recordings_are_discarded() {
        let mut r = rig();
        r.cap.state().samples = vec![0.1; SECOND * 29 / 100];
        r.note(Command::Press);
        assert_eq!(r.note(Command::Release), Some(Note::TooShort));
        assert_eq!(r.state(), State::Idle);

        r.cap.state().samples = vec![];
        r.note(Command::Toggle);
        assert_eq!(r.note(Command::Toggle), Some(Note::Empty));
        assert_eq!(r.state(), State::Idle);
        assert!(r.jobs.take().is_empty());

        r.cap.state().samples = vec![0.1; SECOND * 3 / 10];
        r.note(Command::Press);
        assert_eq!(r.note(Command::Release), None);
        assert_eq!(r.jobs.take().len(), 1);
    }

    #[test]
    fn capture_errors_return_to_idle() {
        let mut r = rig();
        r.cap.state().fail_start = true;
        assert_eq!(r.cmd(Command::Press), Reply::Error(ErrorCode::Capture));
        assert_eq!(r.state(), State::Idle);
        assert_eq!(r.c.session.active_mode(), None);
        // The half-open stream was cancelled.
        assert!(!r.cap.state().recording);
        assert_eq!(r.cmd(Command::Toggle), Reply::Error(ErrorCode::Capture));
        assert_eq!(r.c.session.active_mode(), None);
        assert!(!r.cap.state().recording);
        assert_eq!(r.cap.state().cancels, 2);
        r.cap.state().fail_start = false;

        r.cap.state().fail_stop = true;
        r.note(Command::Press);
        assert_eq!(r.cmd(Command::Release), Reply::Error(ErrorCode::Capture));
        assert_eq!(r.state(), State::Idle);
        assert!(!r.cap.state().recording);
        assert_eq!(r.cap.state().cancels, 3);
        r.cap.state().fail_stop = false;
        // Fully recovered.
        r.note(Command::Press);
        assert_eq!(r.note(Command::Release), None);
    }

    fn stamped(r: &mut Rig, command: Command, at: u64) -> Option<Note> {
        r.t += Duration::from_millis(10);
        match r.c.handle_request(
            Request {
                command,
                at: Some(at),
                args: Default::default(),
            },
            r.t,
        ) {
            Reply::Ok(_, note) => note,
            Reply::With(..) => panic!("{command:?}: unexpected fields"),
            Reply::Error(e) => panic!("{command:?}: {e:?}"),
        }
    }

    #[test]
    fn press_overtaken_by_its_release_is_ignored() {
        let mut r = rig();
        // A short tap: press at 100, release at 105, delivered release first.
        assert_eq!(stamped(&mut r, Command::Release, 105), Some(Note::Ignored));
        // However late it arrives, the press is older than the release.
        r.t += Duration::from_millis(400);
        assert_eq!(stamped(&mut r, Command::Press, 100), Some(Note::Ignored));
        assert_eq!(r.state(), State::Idle);
        assert_eq!(r.cap.state().starts, 0);

        // A press after an unmatched release (e.g. cancel, release, press
        // again quickly) is a new hold.
        r.note(Command::Press);
        r.note(Command::Cancel);
        assert_eq!(stamped(&mut r, Command::Release, 200), Some(Note::Ignored));
        assert_eq!(stamped(&mut r, Command::Press, 201), None);
        assert_eq!(r.state(), State::Recording);
        // A stale release from before this press does not stop it.
        assert_eq!(stamped(&mut r, Command::Release, 199), Some(Note::Ignored));
        assert_eq!(r.state(), State::Recording);
        assert_eq!(stamped(&mut r, Command::Release, 900), None);
        assert_eq!(r.state(), State::Transcribing);
        let job = r.jobs.take().pop().unwrap();
        r.c.handle_worker(WorkerEvent::Done(job.id, Outcome::Nothing))
            .unwrap();
        // The release that ended the hold is not an orphan.
        assert_eq!(stamped(&mut r, Command::Press, 901), None);
        assert_eq!(r.state(), State::Recording);
        // Unstamped requests are taken in arrival order.
        r.note(Command::Cancel);
        assert_eq!(r.note(Command::Release), Some(Note::Ignored));
        assert_eq!(r.note(Command::Press), None);
        assert_eq!(r.state(), State::Recording);
    }

    #[test]
    fn slow_capture_start_does_not_eat_the_recording_window() {
        let mut r = rig();
        r.cap.state().start_delay = Duration::from_millis(120);
        let before = r.t;
        r.note(Command::Toggle);
        // The 10 s window starts after `start` returned, not at the request.
        let deadline = r.c.next_deadline().unwrap();
        let window_start = before + Duration::from_millis(10);
        assert!(deadline >= window_start + Duration::from_millis(120) + Duration::from_secs(10));
        r.c.tick(window_start + Duration::from_secs(10));
        assert_eq!(r.state(), State::Recording);
    }

    #[test]
    fn maximum_length_stops_and_truncates() {
        let mut r = rig();
        r.cap.state().samples = vec![0.1; SECOND * 12];
        r.note(Command::Toggle);
        let deadline = r.c.next_deadline().unwrap();
        r.c.tick(deadline - Duration::from_millis(1));
        assert_eq!(r.state(), State::Recording);
        r.c.tick(deadline);
        assert_eq!(r.state(), State::Transcribing);
        assert_eq!(r.c.session.active_mode(), None);
        let job = r.jobs.take().pop().unwrap();
        assert!(
            matches!(&job.kind, JobKind::Transcribe { audio: s, prompt: false, .. } if s.len() == SECOND * 10)
        );
        // The toggle that would have stopped it now does nothing.
        assert_eq!(r.note(Command::Toggle), Some(Note::Ignored));
    }

    #[test]
    fn records_while_model_loads() {
        let cap = FakeCapture::with_samples(vec![0.1; SECOND]);
        let jobs = Jobs::default();
        let mut c = Controller::new(
            Box::new(Inline::new(Box::new(cap))),
            Box::new(jobs.clone()),
            Limits {
                min_recording: Duration::ZERO,
                max_recording: Duration::from_secs(10),
                double_tap: Duration::ZERO,
            },
            None,
        );
        assert!(!c.status().model_ready);
        let t = Instant::now();
        c.handle_command(Command::Press, t);
        c.handle_command(Command::Release, t);
        assert_eq!(c.status().state, State::Transcribing);
        assert_eq!(jobs.take().len(), 1);
        c.handle_worker(WorkerEvent::ModelReady).unwrap();
        assert!(c.status().model_ready);
        assert!(c.handle_worker(WorkerEvent::Fatal("x".into())).is_err());
    }

    #[test]
    fn again_retypes_last_dictation() {
        let mut r = rig();
        assert_eq!(r.note(Command::Again), Some(Note::Ignored));
        r.note(Command::Press);
        r.note(Command::Release);
        let job = r.jobs.take().pop().unwrap();
        let typed = r.typed("synthetic again");
        r.c.handle_worker(WorkerEvent::Done(job.id, typed)).unwrap();

        assert_eq!(r.note(Command::Again), None);
        assert_eq!(r.state(), State::Typing);
        let job = r.jobs.take().pop().unwrap();
        assert!(matches!(&job.kind, JobKind::Retype(t) if t == "synthetic again"));
        assert_eq!(r.note(Command::Press), Some(Note::Ignored));
        r.c.handle_worker(WorkerEvent::Done(
            job.id,
            Outcome::Typed {
                raw: String::new(),
                text: "synthetic again".into(),
                pressed_enter: false,
                retype: true,
                retained: None,
            },
        ))
        .unwrap();
        assert_eq!(r.state(), State::Idle);
    }

    /// Records media requests, with whether the microphone was running at
    /// the time.
    #[derive(Clone)]
    struct Media {
        cap: FakeCapture,
        log: Arc<Mutex<Vec<(&'static str, bool)>>>,
    }

    impl MediaSink for Media {
        fn pause(&mut self) {
            let recording = self.cap.state().recording;
            self.log.lock().unwrap().push(("pause", recording));
        }

        fn resume(&mut self) {
            let recording = self.cap.state().recording;
            self.log.lock().unwrap().push(("resume", recording));
        }
    }

    impl Media {
        fn take(&self) -> Vec<(&'static str, bool)> {
            std::mem::take(&mut *self.log.lock().unwrap())
        }
    }

    fn media_rig() -> (Rig, Media) {
        media_rig_with(Duration::ZERO)
    }

    /// A rig with media and a double-tap window.
    fn media_rig_with(double_tap: Duration) -> (Rig, Media) {
        let mut r = rig();
        let media = Media {
            cap: r.cap.clone(),
            log: Arc::default(),
        };
        r.c = Controller::new(
            Box::new(Inline::new(Box::new(r.cap.clone()))),
            Box::new(r.jobs.clone()),
            Limits {
                min_recording: Duration::from_millis(300),
                max_recording: Duration::from_secs(10),
                double_tap,
            },
            None,
        )
        .with_media(Box::new(media.clone()));
        r.c.handle_worker(WorkerEvent::ModelReady).unwrap();
        r.c.set_clock(r.t0, BASE);
        let boot = Arc::clone(&r.boot);
        r.c.set_boot_clock(Box::new(move || {
            Duration::from_millis(boot.load(std::sync::atomic::Ordering::SeqCst))
        }));
        (r, media)
    }

    // The pause goes out before the microphone starts; the resume after it
    // stopped.
    const PAUSE: (&str, bool) = ("pause", false);
    const RESUME: (&str, bool) = ("resume", false);

    #[test]
    fn media_pauses_for_each_recording_and_resumes_after_stop() {
        let (mut r, media) = media_rig();
        r.note(Command::Press);
        assert_eq!(media.take(), [PAUSE]);
        r.note(Command::Release);
        assert_eq!(media.take(), [RESUME]);
        // Nothing more while transcribing, typing or idle.
        for cmd in [Command::Press, Command::Toggle, Command::Status] {
            r.note(cmd);
        }
        let job = r.jobs.take().pop().unwrap();
        r.c.handle_worker(WorkerEvent::Typing(job.id)).unwrap();
        let typed = r.typed("synthetic");
        r.c.handle_worker(WorkerEvent::Done(job.id, typed)).unwrap();
        r.note(Command::Again);
        r.note(Command::Cancel);
        assert_eq!(media.take(), []);

        // Toggle, and a hold switched to toggle: one pause, one resume.
        r.note(Command::Toggle);
        r.note(Command::Toggle);
        assert_eq!(media.take(), [PAUSE, RESUME]);
        let job = r.jobs.take().pop().unwrap();
        r.c.handle_worker(WorkerEvent::Done(job.id, Outcome::Nothing))
            .unwrap();
        r.note(Command::Press);
        r.note(Command::Toggle);
        r.note(Command::Release);
        assert_eq!(media.take(), [PAUSE]);
        r.note(Command::Toggle);
        assert_eq!(media.take(), [RESUME]);
    }

    #[test]
    fn media_resumes_on_every_end_of_a_recording() {
        // Cancel.
        let (mut r, media) = media_rig();
        r.note(Command::Press);
        r.note(Command::Cancel);
        assert_eq!(media.take(), [PAUSE, RESUME]);

        // Too short and empty recordings, discarded.
        r.cap.state().samples = vec![0.1; SECOND / 10];
        r.note(Command::Press);
        assert_eq!(r.note(Command::Release), Some(Note::TooShort));
        r.cap.state().samples = vec![];
        r.note(Command::Toggle);
        assert_eq!(r.note(Command::Toggle), Some(Note::Empty));
        assert_eq!(media.take(), [PAUSE, RESUME, PAUSE, RESUME]);

        // Maximum length.
        r.cap.state().samples = vec![0.1; SECOND];
        r.note(Command::Toggle);
        let deadline = r.c.next_deadline().unwrap();
        r.c.tick(deadline);
        assert_eq!(r.state(), State::Transcribing);
        assert_eq!(media.take(), [PAUSE, RESUME]);
        r.note(Command::Cancel);

        // Capture fails to start: paused for the attempt, resumed after the
        // half-open stream was closed.
        r.cap.state().fail_start = true;
        assert_eq!(r.cmd(Command::Press), Reply::Error(ErrorCode::Capture));
        assert_eq!(media.take(), [PAUSE, RESUME]);
        r.cap.state().fail_start = false;

        // Capture fails to stop.
        r.cap.state().fail_stop = true;
        r.note(Command::Press);
        assert_eq!(r.cmd(Command::Release), Reply::Error(ErrorCode::Capture));
        assert_eq!(media.take(), [PAUSE, RESUME]);
        r.cap.state().fail_stop = false;

        // Shutdown while recording.
        r.note(Command::Toggle);
        r.c.shutdown();
        assert_eq!(media.take(), [PAUSE, RESUME]);
        // Shutdown when idle sends nothing.
        r.c.shutdown();
        assert_eq!(media.take(), []);
    }

    // ---------------------------------------------------- double-tap

    const WINDOW: Duration = Duration::from_millis(400);
    const MS: u64 = 1_000_000;

    fn tap_rig() -> (Rig, Media) {
        media_rig_with(WINDOW)
    }

    /// A request stamped `at_ms` after `t0`, received 5 ms later (or 1 ms
    /// after the previous request, if that is later: requests delivered out
    /// of order).
    fn at(r: &mut Rig, command: Command, at_ms: u64) -> Reply {
        let recv = (r.t + Duration::from_millis(1))
            .max(r.t0 + Duration::from_millis(at_ms + 5))
            .saturating_duration_since(r.t0);
        at_recv(r, command, at_ms, recv.as_millis() as u64)
    }

    /// A request stamped `at_ms` after `t0` and received `recv_ms` after it.
    fn at_recv(r: &mut Rig, command: Command, at_ms: u64, recv_ms: u64) -> Reply {
        raw_at(r, command, Some(BASE + at_ms * MS), recv_ms)
    }

    /// A request with any stamp (or none), received `recv_ms` after `t0`
    /// (plus any time suspended, on the boot clock).
    fn raw_at(r: &mut Rig, command: Command, at: Option<u64>, recv_ms: u64) -> Reply {
        r.t = r.t0 + Duration::from_millis(recv_ms);
        r.boot.store(
            recv_ms + r.suspended_ms,
            std::sync::atomic::Ordering::SeqCst,
        );
        r.c.handle_request(
            Request {
                command,
                at,
                args: Default::default(),
            },
            r.t,
        )
    }

    fn short(r: &Rig) {
        r.cap.state().samples = vec![0.1; SECOND / 10];
    }

    fn long(r: &Rig) {
        r.cap.state().samples = vec![0.1; SECOND];
    }

    fn prompt(r: &Rig) -> bool {
        r.c.status().prompt
    }

    /// A press/release tap too short to dictate, from `ms` to `ms + 80`.
    fn tap(r: &mut Rig, ms: u64) {
        short(r);
        assert!(
            matches!(at(r, Command::Press, ms), Reply::Ok(s, None) if s.state == State::Recording)
        );
        assert_eq!(
            note_of(at(r, Command::Release, ms + 80)),
            Some(Note::TooShort)
        );
    }

    fn note_of(reply: Reply) -> Option<Note> {
        match reply {
            Reply::Ok(_, note) => note,
            Reply::With(..) => panic!("unexpected fields"),
            Reply::Error(e) => panic!("error {e:?}"),
        }
    }

    /// The prompt flag of the single queued transcription job.
    fn job_prompt(r: &Rig) -> bool {
        let jobs = r.jobs.take();
        assert_eq!(jobs.len(), 1);
        match &jobs[0].kind {
            JobKind::Transcribe { prompt, .. } => *prompt,
            _ => panic!("not a transcription"),
        }
    }

    #[test]
    fn a_double_tap_and_hold_is_a_prompt_dictation() {
        let (mut r, _) = tap_rig();
        tap(&mut r, 1000);
        assert!(!prompt(&r));
        let reply = at(&mut r, Command::Press, 1300);
        assert_eq!(
            reply.to_line(),
            "localflow/1 ok state=recording mode=hold tag=prompt model=ready\n"
        );
        long(&r);
        let reply = at(&mut r, Command::Release, 3000);
        assert_eq!(
            reply.to_line(),
            "localflow/1 ok state=transcribing tag=prompt model=ready\n"
        );
        let jobs = r.jobs.take();
        let JobKind::Transcribe { prompt: true, .. } = jobs[0].kind else {
            panic!("not a prompt job");
        };
        r.c.handle_worker(WorkerEvent::Typing(jobs[0].id)).unwrap();
        assert!(prompt(&r) && r.state() == State::Typing);
        let typed = r.typed("[dictated] synthetic");
        r.c.handle_worker(WorkerEvent::Done(jobs[0].id, typed))
            .unwrap();
        assert!(!prompt(&r));
        assert_eq!(
            r.cmd(Command::Status).to_line(),
            "localflow/1 ok state=idle model=ready\n"
        );

        // The window is inclusive; one past it is an ordinary hold.
        tap(&mut r, 10_000);
        at(&mut r, Command::Press, 10_080 + 400);
        assert!(prompt(&r));
        at(&mut r, Command::Cancel, 10_600);
        tap(&mut r, 20_000);
        at(&mut r, Command::Press, 20_080 + 401);
        assert!(!prompt(&r));
        long(&r);
        at(&mut r, Command::Release, 22_000);
        assert!(!job_prompt(&r));
    }

    #[test]
    fn a_first_hold_long_enough_to_dictate_never_starts_a_double_tap() {
        let (mut r, _) = tap_rig();
        long(&r);
        at(&mut r, Command::Press, 1000);
        at(&mut r, Command::Release, 2000);
        let job = r.jobs.take().pop().unwrap();
        r.c.handle_worker(WorkerEvent::Done(job.id, Outcome::Nothing))
            .unwrap();
        at(&mut r, Command::Press, 2100);
        assert!(!prompt(&r));
        assert_eq!(r.state(), State::Recording);
    }

    #[test]
    fn other_commands_end_a_pending_double_tap() {
        // Cancel and again (both ignored when idle) still reset it.
        for cmd in [Command::Cancel, Command::Again] {
            let (mut r, _) = tap_rig();
            tap(&mut r, 1000);
            at(&mut r, cmd, 1150);
            at(&mut r, Command::Press, 1200);
            assert!(!prompt(&r), "{cmd:?}");
        }
        // A toggle in between (even one too short to dictate).
        let (mut r, _) = tap_rig();
        tap(&mut r, 1000);
        at(&mut r, Command::Toggle, 1100);
        assert_eq!(
            note_of(at(&mut r, Command::Toggle, 1150)),
            Some(Note::TooShort)
        );
        at(&mut r, Command::Press, 1200);
        assert!(!prompt(&r));
        // A toggle never starts a prompt recording itself.
        let (mut r, _) = tap_rig();
        tap(&mut r, 1000);
        at(&mut r, Command::Toggle, 1100);
        assert!(!prompt(&r) && r.state() == State::Recording);
        // Status does not count.
        let (mut r, _) = tap_rig();
        tap(&mut r, 1000);
        at(&mut r, Command::Status, 1100);
        at(&mut r, Command::Press, 1200);
        assert!(prompt(&r));
        // A capture error uses up the tap.
        let (mut r, _) = tap_rig();
        tap(&mut r, 1000);
        r.cap.state().fail_start = true;
        assert_eq!(
            at(&mut r, Command::Press, 1200),
            Reply::Error(ErrorCode::Capture)
        );
        r.cap.state().fail_start = false;
        at(&mut r, Command::Press, 1250);
        assert!(!prompt(&r));
        // Cancel during the prompt recording discards it; nothing carries on.
        let (mut r, _) = tap_rig();
        tap(&mut r, 1000);
        at(&mut r, Command::Press, 1200);
        assert!(prompt(&r));
        assert_eq!(
            note_of(at(&mut r, Command::Cancel, 1500)),
            Some(Note::Cancelled)
        );
        assert!(!prompt(&r) && r.state() == State::Idle);
        at(&mut r, Command::Press, 1600);
        assert!(!prompt(&r));
    }

    #[test]
    fn an_overtaken_press_never_arms_a_tap() {
        // The release overtakes its press while idle: nothing is recorded,
        // and the next hold is ordinary.
        let (mut r, _) = tap_rig();
        assert_eq!(
            note_of(at(&mut r, Command::Release, 1080)),
            Some(Note::Ignored)
        );
        assert_eq!(
            note_of(at(&mut r, Command::Press, 1000)),
            Some(Note::Ignored)
        );
        assert_eq!(r.cap.state().starts, 0);
        at(&mut r, Command::Press, 1300);
        assert!(!prompt(&r));

        // The same pair while typing, then a hold once typing is done
        // (regression: this hold was tagged).
        let (mut r, _) = tap_rig();
        long(&r);
        at(&mut r, Command::Press, 0);
        at(&mut r, Command::Release, 900);
        let job = r.jobs.take().pop().unwrap();
        r.c.handle_worker(WorkerEvent::Typing(job.id)).unwrap();
        at(&mut r, Command::Release, 1080);
        at(&mut r, Command::Press, 1000);
        let typed = r.typed("synthetic");
        r.c.handle_worker(WorkerEvent::Done(job.id, typed)).unwrap();
        at(&mut r, Command::Press, 1200);
        assert!(!prompt(&r) && r.state() == State::Recording);

        // A reset (cancel, toggle, again) between an orphan release and its
        // delayed press: still no tap.
        for reset in [Command::Cancel, Command::Again] {
            let (mut r, _) = tap_rig();
            at(&mut r, Command::Release, 1080);
            at(&mut r, reset, 1090);
            at(&mut r, Command::Press, 1000);
            at(&mut r, Command::Press, 1200);
            assert!(!prompt(&r), "{reset:?}");
        }

        // A stale release (from before the current press) leaves the
        // prompt recording alone.
        let (mut r, _) = tap_rig();
        tap(&mut r, 1000);
        at(&mut r, Command::Press, 1200);
        assert!(prompt(&r));
        assert_eq!(
            note_of(at(&mut r, Command::Release, 1100)),
            Some(Note::Ignored)
        );
        assert!(prompt(&r) && r.state() == State::Recording);
    }

    #[test]
    fn implausible_stamps_never_make_a_prompt() {
        // A release stamped a minute in the future arms nothing, so a hold
        // a minute later is ordinary (regression).
        let (mut r, _) = tap_rig();
        short(&r);
        at(&mut r, Command::Press, 1000);
        assert_eq!(
            note_of(at_recv(&mut r, Command::Release, 61_080, 1090)),
            Some(Note::TooShort)
        );
        at(&mut r, Command::Press, 61_280);
        assert!(!prompt(&r));
        // Just within the tolerance is trusted.
        let (mut r, _) = tap_rig();
        short(&r);
        at(&mut r, Command::Press, 1000);
        at_recv(&mut r, Command::Release, 1130, 1090);
        at(&mut r, Command::Press, 1300);
        assert!(prompt(&r));

        // A release stamped too long ago arms nothing.
        let (mut r, _) = tap_rig();
        short(&r);
        at(&mut r, Command::Press, 5000);
        r.cap.state().samples = vec![0.1; SECOND / 10];
        at_recv(&mut r, Command::Release, 5000, 7_100);
        at(&mut r, Command::Press, 7_200);
        assert!(!prompt(&r));

        // A press stamped ahead of the daemon's clock is not trusted.
        let (mut r, _) = tap_rig();
        tap(&mut r, 1000);
        at_recv(&mut r, Command::Press, 1300, 1200);
        assert!(!prompt(&r));

        // The tap expires by arrival times too: this press's stamp is within
        // the window, but it arrived 500 ms after the tap's release did.
        let (mut r, _) = tap_rig();
        tap(&mut r, 1000);
        at_recv(&mut r, Command::Press, 1300, 1585);
        assert!(!prompt(&r));
        // tick drops an expired tap.
        let (mut r, _) = tap_rig();
        tap(&mut r, 1000);
        r.c.tick(r.t);
        assert!(r.c.tap.is_some());
        r.boot
            .store(1085 + 401, std::sync::atomic::Ordering::SeqCst);
        r.c.tick(r.t);
        assert!(r.c.tap.is_none());
    }

    #[test]
    fn the_clock_anchor_bounds_its_error() {
        // A sample whose second read came 300 ms late (descheduled), then
        // a tight one: the tight one wins.
        let t0 = Instant::now();
        let mut samples = vec![
            (5_000_000, t0, 5_000_000 + 300 * MS),
            (7_000_000, t0 + Duration::from_millis(2), 7_000_010),
        ]
        .into_iter();
        let (i, ns) = clock_anchor(10, || samples.next().unwrap());
        assert_eq!(i, t0 + Duration::from_millis(2));
        assert_eq!(ns, 7_000_005);
        // Never tight: the narrowest of all attempts.
        let mut k = 0u64;
        let (_, ns) = clock_anchor(3, || {
            k += 1;
            (k * 1_000_000, t0, k * 1_000_000 + (4 - k) * MS)
        });
        assert_eq!(ns, 3_000_000 + MS / 2);
    }

    #[test]
    fn a_skewed_clock_sample_does_not_skew_stamp_checks() {
        // The first sample is skewed by 300 ms (the thread was descheduled
        // between the first stamp-clock read and the `Instant` read), which
        // alone would put the daemon's clock 150 ms behind and make every
        // correct stamp look 150 ms in the future (untrusted). The tight
        // second sample is used instead.
        let (mut r, _) = tap_rig();
        let t0 = r.t0;
        let truth = |i: Instant| BASE + i.saturating_duration_since(t0).as_nanos() as u64;
        let mut samples = vec![
            (truth(t0) - 300 * MS, t0, truth(t0)),
            (
                truth(t0) + 1_000,
                t0 + Duration::from_micros(1),
                truth(t0) + 2_000,
            ),
        ]
        .into_iter();
        let (i, ns) = clock_anchor(10, || samples.next().unwrap());
        r.c.set_clock(i, ns);

        // Correctly stamped double tap: trusted, so a prompt.
        tap(&mut r, 1000);
        at(&mut r, Command::Press, 1300);
        assert!(prompt(&r));
        at(&mut r, Command::Cancel, 1400);
        // 600 ms apart: an ordinary hold.
        tap(&mut r, 2000);
        at(&mut r, Command::Press, 2680);
        assert!(!prompt(&r));
    }

    #[test]
    fn unstamped_requests_never_take_part_in_double_tap() {
        // They cannot be ordered or checked for replays.
        let (mut r, _) = tap_rig();
        short(&r);
        r.note(Command::Press);
        assert_eq!(r.note(Command::Release), Some(Note::TooShort));
        r.note(Command::Press);
        assert!(!prompt(&r), "unstamped tap, unstamped press");
        r.note(Command::Cancel);

        // Unstamped tap, stamped press.
        r.t = r.t0 + Duration::from_millis(1000);
        r.note(Command::Press);
        r.note(Command::Release);
        at(&mut r, Command::Press, 1050);
        assert!(!prompt(&r), "unstamped tap, stamped press");
        at(&mut r, Command::Cancel, 1100);

        // Stamped tap, unstamped press.
        tap(&mut r, 2000);
        r.note(Command::Press);
        assert!(!prompt(&r), "stamped tap, unstamped press");
    }

    /// An ordinary dictation from `press_ms` to `release_ms`, finished.
    fn dictation(r: &mut Rig, press_ms: u64, release_ms: u64) {
        long(r);
        at_recv(r, Command::Press, press_ms, press_ms + 5);
        assert_eq!(
            note_of(at_recv(r, Command::Release, release_ms, release_ms + 5)),
            None
        );
        let job = r.jobs.take().pop().unwrap();
        r.c.handle_worker(WorkerEvent::Done(job.id, Outcome::Nothing))
            .unwrap();
    }

    #[test]
    fn a_replayed_hold_arms_no_tap() {
        // Round 10: duplicates of a finished hold's press and release.
        let (mut r, _) = tap_rig();
        dictation(&mut r, 1000, 2000);
        short(&r);
        // The duplicate press may record a fragment (harmless)...
        at_recv(&mut r, Command::Press, 1000, 2100);
        assert!(!prompt(&r));
        // ...which its duplicate release discards, arming nothing: the press
        // is not newer than the last release that stopped a recording.
        assert_eq!(
            note_of(at_recv(&mut r, Command::Release, 2000, 2110)),
            Some(Note::TooShort)
        );
        assert!(r.c.tap.is_none());
        long(&r);
        at_recv(&mut r, Command::Press, 2200, 2205);
        assert!(!prompt(&r) && r.state() == State::Recording);
        // A duplicate press during the hold changes nothing.
        assert_eq!(
            note_of(at_recv(&mut r, Command::Press, 2200, 2210)),
            Some(Note::Ignored)
        );
        assert!(!prompt(&r) && r.state() == State::Recording);
    }

    #[test]
    fn a_replay_keeps_the_orphan_release_protection() {
        // Round 11: a finished hold, an orphan release, a replay of the old
        // press, then that release's own delayed press.
        let (mut r, _) = tap_rig();
        dictation(&mut r, 1000, 1800);
        let starts = r.cap.state().starts;
        short(&r);
        at_recv(&mut r, Command::Release, 2000, 2005);
        assert_eq!(
            note_of(at_recv(&mut r, Command::Press, 1000, 2010)),
            Some(Note::Ignored)
        );
        // The delayed press is still recognised as overtaken.
        assert_eq!(
            note_of(at_recv(&mut r, Command::Press, 1950, 2015)),
            Some(Note::Ignored)
        );
        assert_eq!(r.cap.state().starts, starts, "no phantom recording");
        at_recv(&mut r, Command::Release, 2000, 2020);
        long(&r);
        at_recv(&mut r, Command::Press, 2200, 2205);
        assert!(!prompt(&r) && r.state() == State::Recording);
    }

    #[test]
    fn an_unstamped_opener_arms_no_tap() {
        // Round 11: an unstamped press, then a stamped (duplicate) release
        // that discards the fragment.
        let (mut r, _) = tap_rig();
        dictation(&mut r, 1000, 2000);
        short(&r);
        raw_at(&mut r, Command::Press, None, 2100);
        assert_eq!(r.state(), State::Recording);
        assert_eq!(
            note_of(at_recv(&mut r, Command::Release, 2000, 2110)),
            Some(Note::TooShort)
        );
        assert!(r.c.tap.is_none());
        at_recv(&mut r, Command::Press, 2200, 2205);
        assert!(!prompt(&r));
    }

    #[test]
    fn garbage_stamps_never_wedge_anything() {
        // Round 11: a press stamped far in the future (here after a tap)
        // must not make later, valid presses be ignored.
        let (mut r, _) = tap_rig();
        tap(&mut r, 1000);
        short(&r);
        raw_at(&mut r, Command::Press, Some(u64::MAX), 1200);
        assert!(!prompt(&r), "an untrusted stamp starts no prompt");
        assert_eq!(r.state(), State::Recording);
        at_recv(&mut r, Command::Cancel, 1300, 1305);
        long(&r);
        assert_eq!(
            at_recv(&mut r, Command::Press, 1500, 1505).to_line(),
            "localflow/1 ok state=recording mode=hold model=ready\n"
        );
        // A future-stamped release stops the hold like an unstamped one
        // (no stale check), and leaves no orphan marker behind.
        assert_eq!(
            note_of(raw_at(&mut r, Command::Release, Some(u64::MAX), 2500)),
            None
        );
        let job = r.jobs.take().pop().unwrap();
        r.c.handle_worker(WorkerEvent::Done(job.id, Outcome::Nothing))
            .unwrap();
        raw_at(&mut r, Command::Release, Some(u64::MAX - 1), 2600);
        at_recv(&mut r, Command::Press, 2700, 2705);
        assert_eq!(r.state(), State::Recording, "not taken as overtaken");
        // Very old stamps are kept for ordering only: still not wedged.
        raw_at(&mut r, Command::Release, Some(1), 2800);
        let job = r.jobs.take().pop();
        if let Some(job) = job {
            r.c.handle_worker(WorkerEvent::Done(job.id, Outcome::Nothing))
                .unwrap();
        }
        r.c.handle_command(Command::Cancel, r.t);
        at_recv(&mut r, Command::Press, 3000, 3005);
        assert_eq!(r.state(), State::Recording);
    }

    #[test]
    fn bunched_late_delivery_needs_both_windows() {
        // Round 12: requests delivered late and bunched together. The
        // tap's press 1000 (received 1900), release 1080 (received 1980),
        // then an ordinary hold pressed at 1700, received at 1985: 5 ms
        // apart on arrival, but 620 ms apart on the key. Not a prompt.
        let (mut r, _) = tap_rig();
        short(&r);
        at_recv(&mut r, Command::Press, 1000, 1900);
        assert_eq!(
            note_of(at_recv(&mut r, Command::Release, 1080, 1980)),
            Some(Note::TooShort)
        );
        assert!(r.c.tap.is_some());
        at_recv(&mut r, Command::Press, 1700, 1985);
        assert!(!prompt(&r));

        // The same late delivery of a real double tap (pressed 220 ms
        // after the release) is a prompt.
        let (mut r, _) = tap_rig();
        short(&r);
        at_recv(&mut r, Command::Press, 1000, 1900);
        at_recv(&mut r, Command::Release, 1080, 1980);
        at_recv(&mut r, Command::Press, 1300, 1985);
        assert!(prompt(&r));
    }

    #[test]
    fn a_delay_while_stopping_the_capture_can_only_expire_a_tap() {
        // Round 12: the machine suspends (an hour) while the tap's release
        // is being handled, after it was received but before the capture
        // has stopped. The tap's time is when the release arrived, so a
        // press right after resume is far outside the window.
        let (mut r, _) = tap_rig();
        let boot = Arc::clone(&r.boot);
        let cap = r.cap.clone();
        let stops_before = cap.state().stops;
        r.c.set_boot_clock(Box::new(move || {
            let suspended = if cap.state().stops > stops_before {
                3_600_000
            } else {
                0
            };
            Duration::from_millis(boot.load(std::sync::atomic::Ordering::SeqCst) + suspended)
        }));
        short(&r);
        at(&mut r, Command::Press, 1000);
        assert_eq!(
            note_of(at(&mut r, Command::Release, 1080)),
            Some(Note::TooShort)
        );
        // Stamps 120 ms apart (the monotonic clock stops in suspend), but
        // received an hour apart by the boot clock.
        at(&mut r, Command::Press, 1200);
        assert!(!prompt(&r));
    }

    #[test]
    fn an_older_orphan_release_never_lowers_the_newest() {
        // Round 12: orphan release 2000, then a release stamped long ago,
        // then the first release's own delayed press (1950): still
        // recognised as overtaken, so no phantom recording.
        let (mut r, _) = tap_rig();
        at_recv(&mut r, Command::Release, 2000, 2005);
        raw_at(&mut r, Command::Release, Some(BASE + MS), 2010);
        assert_eq!(
            note_of(at_recv(&mut r, Command::Press, 1950, 2015)),
            Some(Note::Ignored)
        );
        assert_eq!(r.cap.state().starts, 0);
        assert_eq!(r.state(), State::Idle);
        // A later press works.
        at_recv(&mut r, Command::Press, 2100, 2105);
        assert_eq!(r.state(), State::Recording);
    }

    #[test]
    fn suspend_expires_a_pending_tap() {
        let (mut r, _) = tap_rig();
        tap(&mut r, 1000);
        // Suspended for three hours right after the tap: the monotonic
        // clock (and the stamps) moved on by 100 ms only.
        r.suspended_ms += 3 * 60 * 60 * 1000;
        at(&mut r, Command::Press, 1180);
        assert!(!prompt(&r));
        // tick drops it too.
        let (mut r, _) = tap_rig();
        tap(&mut r, 1000);
        r.boot
            .store(1085 + 3_600_000, std::sync::atomic::Ordering::SeqCst);
        r.c.tick(r.t);
        assert!(r.c.tap.is_none());
    }

    #[test]
    fn a_hold_ended_by_the_maximum_length_leaves_no_press_stamp_behind() {
        let (mut r, _) = tap_rig();
        long(&r);
        at_recv(&mut r, Command::Press, 1000, 1005);
        let deadline = r.c.next_deadline().unwrap();
        r.t = deadline;
        r.c.tick(deadline);
        assert_eq!(r.state(), State::Transcribing);
        let job = r.jobs.take().pop().unwrap();
        r.c.handle_worker(WorkerEvent::Done(job.id, Outcome::Nothing))
            .unwrap();

        // A new hold; the old hold's delayed release must not stop it
        // (regression: it did, discarding the new recording as too short).
        at_recv(&mut r, Command::Press, 11_700, 11_705);
        short(&r);
        assert_eq!(
            note_of(at_recv(&mut r, Command::Release, 11_500, 11_710)),
            Some(Note::Ignored)
        );
        assert_eq!(r.state(), State::Recording);
        // A duplicate of the new press does not restart it as a prompt.
        at_recv(&mut r, Command::Press, 11_700, 11_720);
        assert!(!prompt(&r) && r.state() == State::Recording);
        // Its own release stops and transcribes it.
        long(&r);
        assert_eq!(
            note_of(at_recv(&mut r, Command::Release, 13_000, 13_005)),
            None
        );
        assert_eq!(r.state(), State::Transcribing);
        assert!(!job_prompt(&r));
    }

    #[test]
    fn tapping_on_keeps_the_next_hold_a_prompt() {
        let (mut r, _) = tap_rig();
        tap(&mut r, 1000);
        // The second tap is itself a (prompt) recording too short to use:
        // it is a tap again, so a third press is still a prompt.
        tap(&mut r, 1300);
        at(&mut r, Command::Press, 1600);
        assert!(prompt(&r));
        at(&mut r, Command::Cancel, 1700);

        // Two taps too far apart: only the second one counts.
        tap(&mut r, 5000);
        tap(&mut r, 6000);
        at(&mut r, Command::Press, 6300);
        assert!(prompt(&r));
    }

    #[test]
    fn a_prompt_recording_keeps_its_tag_through_the_maximum_length() {
        let (mut r, _) = tap_rig();
        tap(&mut r, 1000);
        long(&r);
        at(&mut r, Command::Press, 1200);
        let deadline = r.c.next_deadline().unwrap();
        r.c.tick(deadline);
        assert_eq!(r.state(), State::Transcribing);
        assert!(prompt(&r));
        assert!(job_prompt(&r));
    }

    #[test]
    fn disabled_double_tap_never_tags() {
        let (mut r, media) = media_rig();
        tap(&mut r, 1000);
        // Media resumed at once, as before.
        assert_eq!(media.take(), [PAUSE, RESUME]);
        at(&mut r, Command::Press, 1200);
        assert!(!prompt(&r));
    }

    #[test]
    fn media_stay_paused_through_a_double_tap() {
        let (mut r, media) = tap_rig();
        tap(&mut r, 1000);
        // Held paused for the window after the tap.
        assert_eq!(media.take(), [PAUSE]);
        let resume_at = r.t + WINDOW;
        assert_eq!(r.c.next_deadline(), Some(resume_at));
        r.c.tick(resume_at - Duration::from_millis(1));
        assert_eq!(media.take(), []);
        // The second press keeps them paused: no resume in between, and a
        // repeated pause request so players started meanwhile (or missed
        // by a failed pause) are paused too.
        at(&mut r, Command::Press, 1300);
        assert_eq!(media.take(), [PAUSE]);
        // Only the maximum length remains (counted from when the capture
        // started, a little after the request).
        assert!(r.c.next_deadline().unwrap() >= r.t + Duration::from_secs(10));
        long(&r);
        at(&mut r, Command::Release, 3000);
        assert_eq!(media.take(), [RESUME]);
        assert_eq!(r.c.next_deadline(), None);
    }

    #[test]
    fn media_resume_after_the_window_when_no_second_press_comes() {
        let (mut r, media) = tap_rig();
        tap(&mut r, 1000);
        assert_eq!(media.take(), [PAUSE]);
        let resume_at = r.c.next_deadline().unwrap();
        r.c.tick(resume_at);
        assert_eq!(media.take(), [RESUME]);
        assert_eq!(r.c.next_deadline(), None);
        // A press after that is a new recording with a new pause.
        at(&mut r, Command::Press, 3000);
        assert_eq!(media.take(), [PAUSE]);
        at(&mut r, Command::Cancel, 3100);
        assert_eq!(media.take(), [RESUME]);

        // A too-short toggle is not a tap: resumed at once.
        short(&r);
        at(&mut r, Command::Toggle, 4000);
        at(&mut r, Command::Toggle, 4050);
        assert_eq!(media.take(), [PAUSE, RESUME]);

        // Shutdown during the window resumes.
        tap(&mut r, 5000);
        assert_eq!(media.take(), [PAUSE]);
        r.c.shutdown();
        assert_eq!(media.take(), [RESUME]);
        assert_eq!(r.c.next_deadline(), None);
    }

    #[test]
    fn history_records_typed_dictations_only() {
        let t = TempDir::new("controller-history");
        let dir = t.path().join("localflow");
        let mut r = rig_with(Some(History::open(&dir).unwrap()));
        for outcome in [
            r.typed("first synthetic"),
            Outcome::Nothing,
            Outcome::RecognizeFailed,
            Outcome::OutputFailed,
            Outcome::Typed {
                raw: "press enter".into(),
                text: String::new(),
                pressed_enter: true,
                retype: false,
                retained: None,
            },
            r.typed("second synthetic"),
        ] {
            r.note(Command::Press);
            r.note(Command::Release);
            let job = r.jobs.take().pop().unwrap();
            r.c.handle_worker(WorkerEvent::Done(job.id, outcome))
                .unwrap();
        }
        let texts: Vec<String> = History::open(&dir)
            .unwrap()
            .entries()
            .map(|e| e.text.clone())
            .collect();
        assert_eq!(texts, ["first synthetic", "second synthetic"]);
    }

    /// The correction session and the dictionary commands (DESIGN §2.4-§2.5).
    mod correction {
        use super::*;
        use crate::dictionary::Setting;
        use crate::protocol::{CorrectionResult, Extra};
        use crate::testing::synthetic_tokenizer;
        use crate::worker::{Retained, Suggestion};
        use lf_asr::Projection;

        pub(super) const TYPED: &str = "we deployed it on cooper netties yesterday";
        pub(super) const EDITED: &str = "we deployed it on Kubernetes yesterday";

        /// A rig with a dictionary in `dir`.
        pub(super) fn dict_rig(dir: &TempDir) -> Rig {
            let mut r = rig();
            let store = Store::open(&Setting {
                dir: dir.path().join("data"),
                tokenizer: Arc::new(synthetic_tokenizer()),
            })
            .unwrap();
            r.c.dictionary = Some(store);
            r
        }

        pub(super) fn send(r: &mut Rig, command: Command, f: impl FnOnce(&mut Args)) -> Reply {
            r.t += Duration::from_millis(10);
            let mut args = Args::default();
            f(&mut args);
            r.c.handle_request(Request::with_args(command, args), r.t)
        }

        /// What the worker keeps of a job transcribed with `dictionary`.
        fn retained(output: &str, dictionary: Arc<Snapshot>) -> Box<Retained> {
            Box::new(Retained {
                raw: output.into(),
                output: output.into(),
                projection: Projection {
                    data: vec![],
                    frames: 0,
                },
                dictionary,
            })
        }

        /// Starts and stops a dictation: its queued job.
        pub(super) fn record(r: &mut Rig) -> Job {
            r.note(Command::Toggle);
            r.note(Command::Toggle);
            r.jobs.take().pop().unwrap()
        }

        /// Finishes `job` as typed `output`; the worker keeps it if `keep`.
        pub(super) fn finish(r: &mut Rig, job: Job, output: &str, keep: bool) {
            let JobKind::Transcribe { dictionary, .. } = job.kind else {
                panic!("not a transcription");
            };
            r.c.handle_worker(WorkerEvent::Done(
                job.id,
                Outcome::Typed {
                    raw: output.into(),
                    text: output.into(),
                    pressed_enter: false,
                    retype: false,
                    retained: keep.then(|| retained(output, dictionary)),
                },
            ))
            .unwrap();
            assert_eq!(r.state(), State::Idle);
        }

        /// Dictates `output` to completion; the worker keeps it if `keep`.
        pub(super) fn dictate(r: &mut Rig, output: &str, keep: bool) {
            let job = record(r);
            finish(r, job, output, keep);
        }

        #[test]
        fn a_dictation_transcribed_with_an_old_dictionary_is_not_kept() {
            let dir = TempDir::new("corr-late");
            let mut r = dict_rig(&dir);
            // An earlier session, ended by the change below.
            dictate(&mut r, "earlier synthetic", true);
            let job = record(&mut r);
            // The dictionary changes while the job runs.
            dict(&mut r, Command::DictAdd, "Synthetic").unwrap();
            finish(&mut r, job, TYPED, true);
            assert_eq!(begin(&mut r), Err(ErrorCode::NoRecent));
            // The next dictation, with the current dictionary, is kept.
            dictate(&mut r, TYPED, true);
            assert_eq!(begin(&mut r).unwrap().1, TYPED);
            // A failed save changes nothing, so a session survives it.
            let data = dir.path().join("data");
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&data, std::fs::Permissions::from_mode(0o500)).unwrap();
            let job = record(&mut r);
            assert_eq!(
                dict(&mut r, Command::DictAdd, "Other"),
                Err(ErrorCode::Storage)
            );
            std::fs::set_permissions(&data, std::fs::Permissions::from_mode(0o700)).unwrap();
            finish(&mut r, job, "kept synthetic", true);
            assert_eq!(begin(&mut r).unwrap().1, "kept synthetic");
        }

        /// `correct-begin`: the session id and text.
        pub(super) fn begin(r: &mut Rig) -> Result<(u64, String), ErrorCode> {
            match send(r, Command::CorrectBegin, |_| {}) {
                Reply::With(_, Extra::Correction { id, text }) => Ok((id, text)),
                Reply::Error(e) => Err(e),
                other => panic!("{other:?}"),
            }
        }

        pub(super) fn submit(r: &mut Rig, id: u64, text: &str) -> Result<u64, ErrorCode> {
            match send(r, Command::CorrectSubmit, |a| {
                a.id = Some(id);
                a.text = Some(text.into());
            }) {
                Reply::With(_, Extra::Job(job)) => Ok(job),
                Reply::Error(e) => Err(e),
                other => panic!("{other:?}"),
            }
        }

        pub(super) fn result(r: &mut Rig, job: u64) -> Result<CorrectionResult, ErrorCode> {
            match send(r, Command::CorrectResult, |a| a.job = Some(job)) {
                Reply::With(_, Extra::Result(res)) => Ok(res),
                Reply::Error(e) => Err(e),
                other => panic!("{other:?}"),
            }
        }

        pub(super) fn dict(r: &mut Rig, command: Command, word: &str) -> Result<(), ErrorCode> {
            match send(r, command, |a| a.word = Some(word.into())) {
                Reply::Ok(_, None) => Ok(()),
                Reply::Error(e) => Err(e),
                other => panic!("{other:?}"),
            }
        }

        /// The queued verification job, if any.
        pub(super) fn verify_job(r: &Rig) -> Option<Job> {
            let mut jobs = r.jobs.take();
            assert!(jobs.len() <= 1);
            jobs.pop().filter(|j| matches!(j.kind, JobKind::Verify(_)))
        }

        #[test]
        fn a_typed_dictation_can_be_corrected_and_checked() {
            let dir = TempDir::new("corr-flow");
            let mut r = dict_rig(&dir);
            assert_eq!(begin(&mut r), Err(ErrorCode::NoRecent));
            dictate(&mut r, TYPED, true);
            let (id, text) = begin(&mut r).unwrap();
            assert_eq!(text, TYPED);
            // The reply carries the usual status.
            assert!(matches!(
                send(&mut r, Command::CorrectBegin, |_| {}),
                Reply::With(s, _) if s.state == State::Idle && s.model_ready
            ));

            assert_eq!(submit(&mut r, id + 1, EDITED), Err(ErrorCode::Stale));
            let job = submit(&mut r, id, EDITED).unwrap();
            let queued = verify_job(&r).expect("a verification job");
            assert_eq!(queued.id, job);
            let JobKind::Verify(v) = &queued.kind else {
                unreachable!()
            };
            assert_eq!(v.candidates.len(), 1);
            assert_eq!(v.candidates[0].surface, "Kubernetes");
            assert_eq!(v.session.output, TYPED);
            // The reply came at once; the check is pending.
            assert!(result(&mut r, job).unwrap() == CorrectionResult::Pending);
            assert_eq!(result(&mut r, job + 7), Err(ErrorCode::UnknownJob));
            // A result for another job is ignored.
            r.c.handle_worker(WorkerEvent::Verified(job + 7, None))
                .unwrap();
            assert!(result(&mut r, job).unwrap() == CorrectionResult::Pending);
            r.c.handle_worker(WorkerEvent::Verified(
                job,
                Some(Suggestion {
                    word: "Kubernetes".into(),
                    strength: 1410,
                    casing: false,
                }),
            ))
            .unwrap();
            assert!(
                result(&mut r, job).unwrap()
                    == CorrectionResult::Suggest {
                        word: "Kubernetes".into(),
                        strength: 1410,
                        casing: false
                    }
            );
            // Adding the word changes the dictionary: the session ends.
            assert_eq!(
                send(&mut r, Command::DictAdd, |a| {
                    a.word = Some("Kubernetes".into());
                    a.strength = Some(1410);
                }),
                r.c.ok(None)
            );
            assert_eq!(result(&mut r, job), Err(ErrorCode::Stale));
            assert_eq!(begin(&mut r), Err(ErrorCode::NoRecent));
            let snap = r.c.dictionary_snapshot();
            assert_eq!(snap.dictionary.entries.len(), 1);
            assert_eq!(snap.dictionary.entries[0].strength, 1.41);
        }

        #[test]
        fn nothing_to_check_is_none_at_once() {
            let dir = TempDir::new("corr-none");
            let mut r = dict_rig(&dir);
            dictate(&mut r, TYPED, true);
            let (id, _) = begin(&mut r).unwrap();
            for edit in [TYPED, "", "something else entirely different here"] {
                let job = submit(&mut r, id, edit).unwrap();
                assert!(verify_job(&r).is_none());
                assert!(result(&mut r, job).unwrap() == CorrectionResult::None);
            }
            // A dictation that was not kept (a macro, Return) is not offered,
            // and its start ended the previous session.
            dictate(&mut r, "synthetic macro payload", false);
            assert_eq!(begin(&mut r), Err(ErrorCode::NoRecent));
        }

        #[test]
        fn a_new_submission_cancels_the_previous_check() {
            let dir = TempDir::new("corr-resubmit");
            let mut r = dict_rig(&dir);
            dictate(&mut r, TYPED, true);
            let (id, _) = begin(&mut r).unwrap();
            submit(&mut r, id, EDITED).unwrap();
            let first = verify_job(&r).unwrap();
            let second = submit(&mut r, id, EDITED).unwrap();
            assert!(first.cancel.is_cancelled());
            assert_eq!(result(&mut r, first.id), Err(ErrorCode::UnknownJob));
            assert!(result(&mut r, second).unwrap() == CorrectionResult::Pending);
        }

        #[test]
        fn the_session_ends_on_expiry_recording_cancel_and_dictionary_changes() {
            let dir = TempDir::new("corr-end");
            type End = fn(&mut Rig);
            let ends: [(&str, End); 6] = [
                ("expiry", |r| {
                    let due = r.c.next_deadline().unwrap();
                    assert!(due <= Instant::now() + CORRECTION_WINDOW);
                    r.c.tick(due);
                }),
                ("recording", |r| assert_eq!(r.note(Command::Press), None)),
                ("cancel", |r| {
                    assert_eq!(r.note(Command::Cancel), Some(Note::Ignored))
                }),
                ("add", |r| dict(r, Command::DictAdd, "Synthetic").unwrap()),
                ("ignore", |r| dict(r, Command::DictIgnore, "Other").unwrap()),
                ("new dictation", |r| dictate(r, "second synthetic", true)),
            ];
            for (what, end) in ends {
                let mut r = dict_rig(&dir);
                dictate(&mut r, TYPED, true);
                let (id, _) = begin(&mut r).unwrap();
                let job = submit(&mut r, id, EDITED).unwrap();
                let check = verify_job(&r).unwrap();
                end(&mut r);
                assert!(check.cancel.is_cancelled(), "{what}");
                assert_eq!(result(&mut r, job), Err(ErrorCode::Stale), "{what}");
                assert_eq!(submit(&mut r, id, EDITED), Err(ErrorCode::Stale), "{what}");
                // A late answer from the cancelled check changes nothing.
                r.c.handle_worker(WorkerEvent::Verified(job, None)).unwrap();
                assert_eq!(result(&mut r, job), Err(ErrorCode::Stale), "{what}");
                if what == "new dictation" {
                    assert_eq!(begin(&mut r).unwrap().1, "second synthetic");
                } else {
                    assert_eq!(begin(&mut r), Err(ErrorCode::NoRecent), "{what}");
                }
            }
        }

        #[test]
        fn expiry_is_enforced_by_the_timer() {
            let dir = TempDir::new("corr-timer");
            let mut r = dict_rig(&dir);
            assert_eq!(r.c.next_deadline(), None);
            let before = Instant::now();
            dictate(&mut r, TYPED, true);
            let due = r.c.next_deadline().expect("expiry is scheduled");
            assert!(due >= before + CORRECTION_WINDOW && due <= Instant::now() + CORRECTION_WINDOW);
            r.c.tick(due - Duration::from_millis(1));
            assert!(r.c.correction.is_some());
            r.c.tick(due);
            // Dropped by the timer itself, with no request needed.
            assert!(r.c.correction.is_none());
            assert_eq!(r.c.next_deadline(), None);
        }

        #[test]
        fn transcriptions_get_the_current_dictionary() {
            let dir = TempDir::new("corr-snap");
            let mut r = dict_rig(&dir);
            let snap = |r: &mut Rig| {
                r.note(Command::Toggle);
                r.note(Command::Toggle);
                let job = r.jobs.take().pop().unwrap();
                r.c.handle_worker(WorkerEvent::Done(job.id, Outcome::Nothing))
                    .unwrap();
                match job.kind {
                    JobKind::Transcribe { dictionary, .. } => dictionary,
                    _ => panic!("not a transcription"),
                }
            };
            let empty = snap(&mut r);
            assert!(empty.dictionary.entries.is_empty());
            dict(&mut r, Command::DictAdd, "NixOS").unwrap();
            let one = snap(&mut r);
            assert_eq!(one.dictionary.entries.len(), 1);
            assert!(one.revision != empty.revision);
            // Unchanged dictionary, same snapshot.
            assert!(Arc::ptr_eq(&one, &snap(&mut r)));
        }

        #[test]
        fn dictionary_command_errors() {
            let dir = TempDir::new("corr-dict");
            let mut r = dict_rig(&dir);
            assert_eq!(
                dict(&mut r, Command::DictAdd, "1234"),
                Err(ErrorCode::InvalidEntry)
            );
            assert_eq!(
                dict(&mut r, Command::DictAdd, "caf\u{e9}"),
                Err(ErrorCode::InvalidEntry)
            );
            assert_eq!(
                dict(&mut r, Command::DictRemove, "absent"),
                Err(ErrorCode::NotFound)
            );
            assert_eq!(
                dict(&mut r, Command::DictUnignore, "absent"),
                Err(ErrorCode::NotFound)
            );
            dict(&mut r, Command::DictAdd, "Synthetic").unwrap();
            // A failed write: nothing changes and the session survives.
            dictate(&mut r, TYPED, true);
            let data = dir.path().join("data");
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&data, std::fs::Permissions::from_mode(0o500)).unwrap();
            assert_eq!(
                dict(&mut r, Command::DictAdd, "Other"),
                Err(ErrorCode::Storage)
            );
            assert_eq!(
                dict(&mut r, Command::DictRemove, "Synthetic"),
                Err(ErrorCode::Storage)
            );
            std::fs::set_permissions(&data, std::fs::Permissions::from_mode(0o700)).unwrap();
            assert_eq!(r.c.dictionary_snapshot().dictionary.entries.len(), 1);
            assert!(begin(&mut r).is_ok());
            // Without a dictionary the commands are unavailable.
            let mut plain = rig();
            assert_eq!(
                dict(&mut plain, Command::DictAdd, "x"),
                Err(ErrorCode::Unavailable)
            );
        }

        #[test]
        fn text_commands_leave_a_pending_double_tap_alone() {
            let dir = TempDir::new("corr-tap");
            let mut r = dict_rig(&dir);
            r.c.tap = Some(Tap {
                received: Duration::ZERO,
                released: 1,
            });
            let _ = begin(&mut r);
            let _ = dict(&mut r, Command::DictRemove, "absent");
            assert!(r.c.tap.is_some());
        }
    }

    /// The agent link: dictionary suggestions, project words and agent
    /// reports (linux/AGENT-LINK.md).
    mod agent_link {
        use super::correction::{
            EDITED, TYPED, begin, dict, dict_rig, dictate, finish, record, result, send, submit,
            verify_job,
        };
        use super::*;
        use crate::link::{MAX_SET_WORDS, MAX_SUGGESTIONS, SUGGESTION_TTL};
        use crate::protocol::{Activity, AgentCounts, Extra, Resolve, SuggestOutcome};

        fn suggest(r: &mut Rig, word: &str) -> Result<SuggestOutcome, ErrorCode> {
            match send(r, Command::SuggestAdd, |a| a.word = Some(word.into())) {
                Reply::With(_, Extra::Outcome(o)) => Ok(o),
                Reply::Error(e) => Err(e),
                other => panic!("{other:?}"),
            }
        }

        fn next(r: &mut Rig) -> Result<(u64, String), ErrorCode> {
            match send(r, Command::SuggestNext, |_| {}) {
                Reply::With(_, Extra::Suggestion { id, word }) => Ok((id, word)),
                Reply::Error(e) => Err(e),
                other => panic!("{other:?}"),
            }
        }

        fn resolve(r: &mut Rig, id: u64, action: Resolve) -> Result<(), ErrorCode> {
            match send(r, Command::SuggestResolve, |a| {
                a.id = Some(id);
                a.action = Some(action);
            }) {
                Reply::Ok(_, None) => Ok(()),
                Reply::Error(e) => Err(e),
                other => panic!("{other:?}"),
            }
        }

        fn words(
            r: &mut Rig,
            set: &str,
            w: &str,
            ttl: Option<u64>,
        ) -> Result<(u32, u32), ErrorCode> {
            match send(r, Command::WordsSet, |a| {
                a.set = Some(set.into());
                a.words = Some(w.into());
                a.ttl = ttl;
            }) {
                Reply::With(_, Extra::Loaded { loaded, skipped }) => Ok((loaded, skipped)),
                Reply::Error(e) => Err(e),
                other => panic!("{other:?}"),
            }
        }

        fn clear(r: &mut Rig, set: &str) -> Result<(), ErrorCode> {
            match send(r, Command::WordsClear, |a| a.set = Some(set.into())) {
                Reply::Ok(_, None) => Ok(()),
                Reply::Error(e) => Err(e),
                other => panic!("{other:?}"),
            }
        }

        fn agents(r: &mut Rig, f: impl FnOnce(&mut Args)) -> Reply {
            send(r, Command::AgentsSet, f)
        }

        fn pending(r: &Rig) -> u32 {
            r.c.activity().suggestions
        }

        /// The dictionary a dictation is transcribed with.
        fn transcribed(r: &mut Rig) -> Arc<Snapshot> {
            let job = record(r);
            r.c.handle_worker(WorkerEvent::Done(job.id, Outcome::Nothing))
                .unwrap();
            match job.kind {
                JobKind::Transcribe { dictionary, .. } => dictionary,
                _ => panic!("not a transcription"),
            }
        }

        fn boosted(s: &Snapshot) -> Vec<(String, f32)> {
            s.dictionary
                .entries
                .iter()
                .map(|e| (e.text.clone(), e.strength))
                .collect()
        }

        /// An invented word for each `i`: "Zq" and two letters.
        fn word(i: usize) -> String {
            let l = |n: usize| (b'a' + (n % 26) as u8) as char;
            format!("Zq{}{}", l(i / 26), l(i))
        }

        #[test]
        fn suggestions_are_queued_once_and_reviewed_oldest_first() {
            let dir = TempDir::new("link-queue");
            let mut r = dict_rig(&dir);
            assert_eq!(next(&mut r), Err(ErrorCode::NotFound));
            assert_eq!(suggest(&mut r, "Zorblax"), Ok(SuggestOutcome::Queued));
            assert_eq!(suggest(&mut r, "Quuxwell"), Ok(SuggestOutcome::Queued));
            // Its key is pending: not queued twice, and it keeps its place.
            assert_eq!(suggest(&mut r, " zorblax "), Ok(SuggestOutcome::Queued));
            assert_eq!(pending(&r), 2);
            // In the dictionary or on the ignore list: never queued.
            dict(&mut r, Command::DictAdd, "Blorft").unwrap();
            dict(&mut r, Command::DictIgnore, "Glimmux").unwrap();
            assert_eq!(suggest(&mut r, "BLORFT"), Ok(SuggestOutcome::Present));
            assert_eq!(suggest(&mut r, "glimmux"), Ok(SuggestOutcome::Ignored));
            // Validated like dict-add.
            assert_eq!(suggest(&mut r, "1234"), Err(ErrorCode::InvalidEntry));
            assert_eq!(suggest(&mut r, "caf\u{e9}"), Err(ErrorCode::InvalidEntry));
            assert_eq!(pending(&r), 2);

            let (first, w) = next(&mut r).unwrap();
            assert_eq!(w, "Zorblax");
            // `suggest-next` only reads.
            assert_eq!(next(&mut r).unwrap(), (first, "Zorblax".into()));
            resolve(&mut r, first, Resolve::Dismiss).unwrap();
            assert_eq!(
                resolve(&mut r, first, Resolve::Dismiss),
                Err(ErrorCode::Stale)
            );
            let (second, w) = next(&mut r).unwrap();
            assert_eq!(w, "Quuxwell");
            assert_ne!(second, first);
            resolve(&mut r, second, Resolve::Add).unwrap();
            assert_eq!(next(&mut r), Err(ErrorCode::NotFound));
            assert_eq!(pending(&r), 0);
            let added = r.c.dictionary_snapshot();
            assert!(
                added
                    .dictionary
                    .entries
                    .iter()
                    .any(|e| e.text == "Quuxwell" && e.strength == 1.0)
            );
            assert_eq!(suggest(&mut r, "quuxwell"), Ok(SuggestOutcome::Present));

            // Dismissed words may be suggested again; ignored ones not.
            assert_eq!(suggest(&mut r, "Zorblax"), Ok(SuggestOutcome::Queued));
            let (third, _) = next(&mut r).unwrap();
            assert!(third > second);
            resolve(&mut r, third, Resolve::Ignore).unwrap();
            assert!(
                r.c.dictionary_snapshot()
                    .dictionary
                    .ignore
                    .contains(&"zorblax".to_string())
            );
            assert_eq!(suggest(&mut r, "Zorblax"), Ok(SuggestOutcome::Ignored));
            assert_eq!(resolve(&mut r, 999, Resolve::Add), Err(ErrorCode::Stale));
        }

        #[test]
        fn at_most_sixteen_suggestions_each_for_a_day() {
            let dir = TempDir::new("link-cap");
            let mut r = dict_rig(&dir);
            dict(&mut r, Command::DictAdd, "Blorft").unwrap();
            let first_at = r.t + Duration::from_millis(10);
            for i in 0..MAX_SUGGESTIONS {
                assert_eq!(suggest(&mut r, &word(i)), Ok(SuggestOutcome::Queued));
            }
            let last_at = r.t;
            assert_eq!(pending(&r), 16);
            assert_eq!(suggest(&mut r, "Zorblax"), Err(ErrorCode::Full));
            // A pending or present word is no growth.
            assert_eq!(suggest(&mut r, &word(3)), Ok(SuggestOutcome::Queued));
            assert_eq!(suggest(&mut r, "Blorft"), Ok(SuggestOutcome::Present));
            let (first, _) = next(&mut r).unwrap();

            // Each expires a day after it was queued, by the timer.
            assert_eq!(r.c.next_deadline(), Some(first_at + SUGGESTION_TTL));
            r.c.tick(first_at + SUGGESTION_TTL - Duration::from_millis(1));
            assert_eq!(pending(&r), 16);
            r.c.tick(first_at + SUGGESTION_TTL);
            assert_eq!(pending(&r), 15);
            assert_eq!(resolve(&mut r, first, Resolve::Add), Err(ErrorCode::Stale));
            assert_eq!(next(&mut r).unwrap().1, word(1));
            assert_eq!(suggest(&mut r, "Zorblax"), Ok(SuggestOutcome::Queued));
            r.c.tick(last_at + SUGGESTION_TTL);
            assert_eq!(pending(&r), 1);
            assert_eq!(next(&mut r).unwrap().1, "Zorblax");
        }

        #[test]
        fn suggest_next_drops_words_added_or_ignored_since() {
            let dir = TempDir::new("link-since");
            let mut r = dict_rig(&dir);
            for w in ["Zorblax", "Quuxwell", "Glimmux"] {
                suggest(&mut r, w).unwrap();
            }
            dict(&mut r, Command::DictAdd, "zorblax").unwrap();
            dict(&mut r, Command::DictIgnore, "QUUXWELL").unwrap();
            assert_eq!(next(&mut r).unwrap().1, "Glimmux");
            assert_eq!(pending(&r), 1);
        }

        #[test]
        fn resolving_with_add_or_ignore_ends_the_correction_session() {
            let dir = TempDir::new("link-session");
            for (action, ends) in [
                (Resolve::Add, true),
                (Resolve::Ignore, true),
                (Resolve::Dismiss, false),
            ] {
                let mut r = dict_rig(&dir);
                dictate(&mut r, TYPED, true);
                let (id, _) = begin(&mut r).unwrap();
                let job = submit(&mut r, id, EDITED).unwrap();
                let check = verify_job(&r).unwrap();
                suggest(&mut r, "Zorblax").unwrap();
                let (s, _) = next(&mut r).unwrap();
                resolve(&mut r, s, action).unwrap();
                assert_eq!(check.cancel.is_cancelled(), ends, "{action:?}");
                if ends {
                    assert_eq!(begin(&mut r), Err(ErrorCode::NoRecent), "{action:?}");
                    assert_eq!(result(&mut r, job), Err(ErrorCode::Stale));
                } else {
                    assert_eq!(begin(&mut r).unwrap().0, id);
                    assert!(result(&mut r, job).unwrap() == CorrectionResult::Pending);
                }
                drop(r);
                std::fs::remove_dir_all(dir.path().join("data")).unwrap();
            }
        }

        #[test]
        fn a_failed_resolution_keeps_the_suggestion_pending() {
            let dir = TempDir::new("link-fail");
            let mut r = dict_rig(&dir);
            dict(&mut r, Command::DictAdd, "Blorft").unwrap();
            suggest(&mut r, "Zorblax").unwrap();
            let (id, _) = next(&mut r).unwrap();
            dictate(&mut r, TYPED, true);
            let data = dir.path().join("data");
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&data, std::fs::Permissions::from_mode(0o500)).unwrap();
            assert_eq!(resolve(&mut r, id, Resolve::Add), Err(ErrorCode::Storage));
            assert_eq!(
                resolve(&mut r, id, Resolve::Ignore),
                Err(ErrorCode::Storage)
            );
            std::fs::set_permissions(&data, std::fs::Permissions::from_mode(0o700)).unwrap();
            assert_eq!(pending(&r), 1);
            assert_eq!(next(&mut r).unwrap(), (id, "Zorblax".into()));
            // Nothing changed, so the session survived too.
            assert!(begin(&mut r).is_ok());
            resolve(&mut r, id, Resolve::Add).unwrap();
            assert_eq!(pending(&r), 0);
        }

        #[test]
        fn without_a_dictionary_only_agent_reports_work() {
            let mut r = rig();
            assert_eq!(suggest(&mut r, "Zorblax"), Err(ErrorCode::Unavailable));
            assert_eq!(next(&mut r), Err(ErrorCode::Unavailable));
            assert_eq!(
                resolve(&mut r, 1, Resolve::Dismiss),
                Err(ErrorCode::Unavailable)
            );
            assert_eq!(
                words(&mut r, "repo", "Zorblax", None),
                Err(ErrorCode::Unavailable)
            );
            assert_eq!(clear(&mut r, "repo"), Err(ErrorCode::NotFound));
            assert_eq!(agents(&mut r, |a| a.approval = Some(1)), r.c.ok(None));
            assert_eq!(r.c.activity().agents.approval, 1);
        }

        #[test]
        fn project_words_are_counted_capped_and_replaced() {
            let dir = TempDir::new("link-words");
            let mut r = dict_rig(&dir);
            // Empty pieces, repeats, invalid entries are skipped.
            assert_eq!(
                words(
                    &mut r,
                    "repo",
                    "Zorblax, Quuxwell ,,zorblax,1234,caf\u{e9},  New   Thing  ",
                    None
                ),
                Ok((3, 4))
            );
            assert_eq!(r.c.activity().words, 3);
            // At most 64 per set.
            let many: Vec<String> = (0..MAX_SET_WORDS + 2).map(word).collect();
            assert_eq!(words(&mut r, "big", &many.join(","), None), Ok((64, 2)));
            assert_eq!(r.c.activity().words, 67);
            // The same name replaces the set.
            assert_eq!(words(&mut r, "repo", "Glimmux", None), Ok((1, 0)));
            assert_eq!(r.c.activity().words, 65);
            // At most four sets; replacing one of them is still fine.
            assert_eq!(words(&mut r, "c", "Blorft", None), Ok((1, 0)));
            assert_eq!(words(&mut r, "d", "Blorft", None), Ok((1, 0)));
            assert_eq!(words(&mut r, "e", "Blorft", None), Err(ErrorCode::Full));
            assert_eq!(words(&mut r, "c", "Blorft,Quuxwell", None), Ok((2, 0)));
            assert_eq!(r.c.activity().words, 68);
            // Nothing loaded removes the set.
            assert_eq!(words(&mut r, "c", "1234, ,", None), Ok((0, 3)));
            assert_eq!(r.c.activity().words, 66);
            assert_eq!(words(&mut r, "e", "Blorft", None), Ok((1, 0)));
            assert_eq!(words(&mut r, "never", "1234", None), Ok((0, 1)));
            assert_eq!(clear(&mut r, "never"), Err(ErrorCode::NotFound));
            clear(&mut r, "big").unwrap();
            assert_eq!(clear(&mut r, "big"), Err(ErrorCode::NotFound));
            assert_eq!(r.c.activity().words, 3);
            // Project words never touch the dictionary.
            assert!(r.c.dictionary_snapshot().dictionary.entries.is_empty());
            assert!(
                !dir.path()
                    .join("data")
                    .join(crate::dictionary::FILE_NAME)
                    .exists()
            );
        }

        #[test]
        fn project_words_expire_by_the_timer() {
            let dir = TempDir::new("link-expiry");
            let mut r = dict_rig(&dir);
            assert_eq!(r.c.next_deadline(), None);
            words(&mut r, "a", "Zorblax", None).unwrap();
            let a_at = r.t;
            words(&mut r, "b", "Quuxwell,Glimmux", Some(60)).unwrap();
            let b_at = r.t;
            assert_eq!(r.c.next_deadline(), Some(b_at + Duration::from_secs(60)));
            r.c.tick(b_at + Duration::from_secs(60) - Duration::from_millis(1));
            assert_eq!(r.c.activity().words, 3);
            r.c.tick(b_at + Duration::from_secs(60));
            assert_eq!(r.c.activity().words, 1);
            let default = Duration::from_secs(crate::protocol::WORDS_DEFAULT_TTL);
            assert_eq!(r.c.next_deadline(), Some(a_at + default));
            // Setting it again restarts its time.
            words(&mut r, "a", "Zorblax", Some(120)).unwrap();
            let again = r.t;
            assert_eq!(r.c.next_deadline(), Some(again + Duration::from_secs(120)));
            r.c.tick(again + Duration::from_secs(120));
            assert_eq!(r.c.activity().words, 0);
            assert_eq!(r.c.next_deadline(), None);
            assert_eq!(clear(&mut r, "a"), Err(ErrorCode::NotFound));
        }

        #[test]
        fn dictation_boosts_project_words_at_strength_one() {
            let dir = TempDir::new("link-boost");
            let mut r = dict_rig(&dir);
            send(&mut r, Command::DictAdd, |a| {
                a.word = Some("Zorblax".into());
                a.strength = Some(2000);
            });
            let plain = transcribed(&mut r);
            assert!(Arc::ptr_eq(&plain, &r.c.dictionary_snapshot()));
            words(&mut r, "repo", "zorblax, Quuxwell, New Thing", None).unwrap();
            let one = transcribed(&mut r);
            // The dictionary's strength wins for a word in both.
            assert_eq!(
                boosted(&one),
                [
                    ("Zorblax".to_string(), 2.0),
                    ("Quuxwell".into(), 1.0),
                    ("New Thing".into(), 1.0)
                ]
            );
            assert_ne!(one.revision, plain.revision);
            // Unchanged: the same snapshot, so the graph cache stays valid.
            assert!(Arc::ptr_eq(&one, &transcribed(&mut r)));
            // A set loaded again with the same words changes nothing either.
            words(&mut r, "repo", "zorblax, Quuxwell, New Thing", Some(600)).unwrap();
            assert!(Arc::ptr_eq(&one, &transcribed(&mut r)));
            // A second set; a word in both sets is boosted once.
            words(&mut r, "other", "quuxwell, Glimmux", None).unwrap();
            let two = transcribed(&mut r);
            assert_eq!(boosted(&two).len(), 4);
            assert!(two.revision != one.revision);
            // A dictionary change gives a new revision too.
            dict(&mut r, Command::DictAdd, "Blorft").unwrap();
            let three = transcribed(&mut r);
            assert_eq!(boosted(&three).len(), 5);
            assert!(three.revision != two.revision);
            assert!(Arc::ptr_eq(&three, &transcribed(&mut r)));
            clear(&mut r, "other").unwrap();
            let four = transcribed(&mut r);
            assert_eq!(boosted(&four).len(), 4);
            assert!(four.revision != three.revision);
            // Without sets, the dictionary itself.
            clear(&mut r, "repo").unwrap();
            let five = transcribed(&mut r);
            assert!(Arc::ptr_eq(&five, &r.c.dictionary_snapshot()));
            assert_eq!(boosted(&five).len(), 2);
            // The revisions seen so far are all distinct but for reuse.
            let revs = [
                plain.revision,
                one.revision,
                two.revision,
                three.revision,
                four.revision,
            ];
            for (i, a) in revs.iter().enumerate() {
                assert!(!revs[i + 1..].contains(a));
            }
            assert!(five.revision != plain.revision);
        }

        #[test]
        fn project_words_never_end_a_correction_session() {
            let dir = TempDir::new("link-keep");
            let mut r = dict_rig(&dir);
            dictate(&mut r, TYPED, true);
            let (id, _) = begin(&mut r).unwrap();
            let job = submit(&mut r, id, EDITED).unwrap();
            let check = verify_job(&r).unwrap();
            words(&mut r, "repo", "Zorblax", None).unwrap();
            words(&mut r, "repo", "Quuxwell", None).unwrap();
            clear(&mut r, "repo").unwrap();
            words(&mut r, "repo", "Glimmux", Some(60)).unwrap();
            r.c.tick(r.t + Duration::from_secs(60));
            assert_eq!(r.c.activity().words, 0);
            assert!(!check.cancel.is_cancelled());
            assert_eq!(begin(&mut r).unwrap().0, id);
            assert!(result(&mut r, job).unwrap() == CorrectionResult::Pending);

            // A dictation finishing after project words changed is kept.
            let job = record(&mut r);
            words(&mut r, "repo", "Zorblax", None).unwrap();
            finish(&mut r, job, "kept synthetic", true);
            assert_eq!(begin(&mut r).unwrap().1, "kept synthetic");

            // Correction suggestions see the dictionary only: a project word
            // is still a candidate.
            words(&mut r, "k8s", "Kubernetes", None).unwrap();
            dictate(&mut r, TYPED, true);
            let (id, _) = begin(&mut r).unwrap();
            submit(&mut r, id, EDITED).unwrap();
            let JobKind::Verify(v) = verify_job(&r).unwrap().kind else {
                unreachable!()
            };
            assert_eq!(v.candidates.len(), 1);
            assert_eq!(v.candidates[0].surface, "Kubernetes");
        }

        #[test]
        fn agent_reports_replace_each_other_and_expire() {
            let mut r = rig();
            assert_eq!(r.c.activity(), Activity::default());
            agents(&mut r, |a| {
                a.approval = Some(1);
                a.input = Some(2);
            });
            let at = r.t;
            assert_eq!(
                r.c.activity().agents,
                AgentCounts {
                    approval: 1,
                    input: 2,
                    working: 0,
                    done: 0
                }
            );
            let default = Duration::from_secs(crate::protocol::AGENTS_DEFAULT_TTL);
            assert_eq!(r.c.next_deadline(), Some(at + default));
            // A new report replaces it, counts missing from it are zero.
            agents(&mut r, |a| {
                a.working = Some(3);
                a.ttl = Some(5);
            });
            let at = r.t;
            assert_eq!(
                r.c.activity().agents,
                AgentCounts {
                    working: 3,
                    ..AgentCounts::default()
                }
            );
            assert_eq!(r.c.next_deadline(), Some(at + Duration::from_secs(5)));
            r.c.tick(at + Duration::from_secs(5) - Duration::from_millis(1));
            assert_eq!(r.c.activity().agents.working, 3);
            r.c.tick(at + Duration::from_secs(5));
            assert_eq!(r.c.activity().agents, AgentCounts::default());
            assert_eq!(r.c.next_deadline(), None);
            agents(&mut r, |a| a.done = Some(4));
            assert_eq!(r.c.activity().agents.done, 4);
            assert_eq!(send(&mut r, Command::AgentsClear, |_| {}), r.c.ok(None));
            assert_eq!(r.c.activity(), Activity::default());
            assert_eq!(r.c.next_deadline(), None);
            // Clearing nothing is fine.
            assert_eq!(send(&mut r, Command::AgentsClear, |_| {}), r.c.ok(None));
        }
    }

    /// A capture the test drives by hand: it records the calls, and the
    /// test delivers their results.
    #[derive(Clone, Default)]
    struct Calls(Arc<Mutex<Vec<(u64, Call)>>>);

    impl CapturePort for Calls {
        fn send(&mut self, generation: u64, call: Call) {
            self.0.lock().unwrap().push((generation, call));
        }
        fn poll(&mut self) -> Option<CaptureEvent> {
            None
        }
        fn level(&self) -> f32 {
            0.0
        }
        fn input_available(&self) -> Option<bool> {
            None
        }
    }

    impl Calls {
        fn take(&self) -> Vec<(u64, Call)> {
            std::mem::take(&mut *self.0.lock().unwrap())
        }
    }

    fn manual(r: &mut Rig) -> Calls {
        let calls = Calls::default();
        r.c.capture = Box::new(calls.clone());
        calls
    }

    /// Sends a request (stamped `at_ms` after `t0`, if given) received
    /// `recv_ms` after `t0`; its reply arrives on the returned channel.
    fn ask(
        r: &mut Rig,
        command: Command,
        at_ms: Option<u64>,
        recv_ms: u64,
    ) -> std::sync::mpsc::Receiver<Reply> {
        r.t = r.t0 + Duration::from_millis(recv_ms);
        r.boot.store(recv_ms, std::sync::atomic::Ordering::SeqCst);
        let (tx, rx) = std::sync::mpsc::channel();
        let req = Request {
            command,
            at: at_ms.map(|ms| BASE + ms * MS),
            args: Default::default(),
        };
        r.c.request(req, tx.into(), r.t);
        rx
    }

    fn deliver(r: &mut Rig, generation: u64, done: Done, recv_ms: u64) {
        r.t = r.t0 + Duration::from_millis(recv_ms);
        r.boot.store(recv_ms, std::sync::atomic::Ordering::SeqCst);
        r.c.handle_capture(CaptureEvent { generation, done }, r.t);
    }

    fn short_audio() -> Done {
        Done::Stopped(Ok(Audio::new(vec![0.1; SECOND / 10])))
    }

    /// The second press of a double tap that arrives while the tap's
    /// microphone is still stopping waits, then is judged with its own
    /// stamp as if it had arrived after the stop: a prompt recording.
    #[test]
    fn a_press_waiting_behind_the_stop_of_a_tap_still_makes_a_prompt() {
        let (mut r, _) = tap_rig();
        let calls = manual(&mut r);
        let press = ask(&mut r, Command::Press, Some(1000), 1005);
        assert!(press.try_recv().is_err(), "waits for the microphone");
        assert_eq!(r.state(), State::Idle);
        assert_eq!(calls.take(), [(1, Call::Start)]);
        deliver(&mut r, 1, Done::Started(Ok(())), 1010);
        assert_eq!(note_of(press.try_recv().unwrap()), None);

        let release = ask(&mut r, Command::Release, Some(1080), 1085);
        assert_eq!(calls.take(), [(1, Call::Stop)]);
        let second = ask(&mut r, Command::Press, Some(1200), 1205);
        assert!(second.try_recv().is_err());
        // Stopping reads as still recording.
        assert_eq!(r.state(), State::Recording);
        assert_eq!(calls.take(), []);
        deliver(&mut r, 1, short_audio(), 1300);
        assert_eq!(note_of(release.try_recv().unwrap()), Some(Note::TooShort));
        assert_eq!(calls.take(), [(2, Call::Start)]);
        deliver(&mut r, 2, Done::Started(Ok(())), 1310);
        assert_eq!(
            second.try_recv().unwrap().to_line(),
            "localflow/1 ok state=recording mode=hold tag=prompt model=ready\n"
        );
    }

    /// A cancelled recording's capture results are dropped, however late
    /// they come, and never touch the next recording.
    #[test]
    fn late_results_of_a_cancelled_recording_are_dropped() {
        let mut r = rig();
        let calls = manual(&mut r);
        let press = ask(&mut r, Command::Press, None, 10);
        assert_eq!(r.note(Command::Cancel), Some(Note::Cancelled));
        assert_eq!(note_of(press.try_recv().unwrap()), Some(Note::Cancelled));
        let again = ask(&mut r, Command::Press, None, 30);
        assert_eq!(
            calls.take(),
            [(1, Call::Start), (1, Call::Cancel), (2, Call::Start)]
        );
        deliver(&mut r, 1, Done::Started(Ok(())), 40);
        assert!(again.try_recv().is_err());
        deliver(&mut r, 2, Done::Started(Ok(())), 50);
        assert_eq!(note_of(again.try_recv().unwrap()), None);
        deliver(&mut r, 1, short_audio(), 60);
        assert_eq!(r.state(), State::Recording);
        let release = ask(&mut r, Command::Release, None, 70);
        assert_eq!(calls.take(), [(2, Call::Stop)]);
        let audio = Done::Stopped(Ok(Audio::new(vec![0.1; SECOND])));
        deliver(&mut r, 2, audio, 80);
        assert_eq!(note_of(release.try_recv().unwrap()), None);
        assert_eq!(r.state(), State::Transcribing);
        assert_eq!(r.jobs.take().len(), 1);
    }
}

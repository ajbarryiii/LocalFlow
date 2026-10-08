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

use lf_io_api::{AudioCapture, SAMPLE_RATE};

use crate::history::{Entry, History};
use crate::media::{MediaSink, NoMedia};
use crate::protocol::{Command, ErrorCode, Note, Reply, Request, State, Status};
use crate::session::{Action, Event, Mode, SessionController};
use crate::worker::{Audio, CancelToken, Job, JobKind, Outcome, WorkerEvent};

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
    Recording {
        since: Instant,
        /// A prompt recording (double-tap and hold).
        prompt: bool,
        /// Started from idle by a press with a fresh stamp: discarded as
        /// too short by its own release, it is a tap.
        tap_eligible: bool,
    },
    /// A job the worker is running for the current dictation.
    Busy {
        id: u64,
        cancel: Arc<CancelToken>,
        typing: bool,
        prompt: bool,
    },
}

pub struct Controller {
    session: SessionController,
    capture: Box<dyn AudioCapture>,
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
        capture: Box<dyn AudioCapture>,
        jobs: Box<dyn JobSink>,
        limits: Limits,
        history: Option<History>,
    ) -> Controller {
        Controller {
            session: SessionController::default(),
            capture,
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
        }
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
            Phase::Idle => State::Idle,
            Phase::Recording { .. } => State::Recording,
            Phase::Busy { typing: false, .. } => State::Transcribing,
            Phase::Busy { typing: true, .. } => State::Typing,
        };
        Status {
            state,
            mode: match self.phase {
                Phase::Recording { .. } => self.session.active_mode(),
                _ => None,
            },
            prompt: matches!(
                self.phase,
                Phase::Recording { prompt: true, .. } | Phase::Busy { prompt: true, .. }
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

    /// The capture's input level in [0, 1]; 0 when not recording.
    pub fn input_level(&self) -> f32 {
        match self.phase {
            Phase::Recording { .. } => self.capture.level(),
            _ => 0.0,
        }
    }

    fn ok(&self, note: Option<Note>) -> Reply {
        Reply::Ok(self.status(), note)
    }

    /// A request without a stamp.
    pub fn handle_command(&mut self, cmd: Command, now: Instant) -> Reply {
        self.handle_request(Request::new(cmd), now)
    }

    pub fn handle_request(&mut self, req: Request, now: Instant) -> Reply {
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
                    if idle && let Phase::Recording { tap_eligible, .. } = &mut self.phase {
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
                    let discarded = matches!(result, Ok(Some(Note::TooShort | Note::Empty)));
                    if tap_eligible
                        && stopped
                        && discarded
                        && let Some(released) = self.fresh_stamp(req.at, now)
                    {
                        self.tap = Some(Tap { received, released });
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
        if self.session.active_mode() != Some(Mode::Hold) {
            self.hold_press_at = None;
        }
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
            let Some(action) = self.session.handle(event, self.is_busy()) else {
                continue;
            };
            acted = true;
            match action {
                Action::Start(mode) => {
                    let prompt = self.start_prompt;
                    self.start_recording(now, prompt)?;
                    crate::info!(
                        "recording ({}{})",
                        mode.name(),
                        if prompt { ", prompt" } else { "" }
                    );
                }
                Action::Stop => {
                    note = self.stop_recording(now, event == Event::HoldDeactivated)?;
                }
                Action::SwitchedToToggle => crate::info!("recording switched to toggle mode"),
            }
        }
        Ok(if acted { note } else { Some(Note::Ignored) })
    }

    fn start_recording(&mut self, now: Instant, prompt: bool) -> Result<(), ErrorCode> {
        if !matches!(self.phase, Phase::Idle) {
            // The session controller prevents this; stay consistent anyway.
            self.session.reset();
            return Err(ErrorCode::Capture);
        }
        // Only a message to the media thread: players pause while the
        // device starts (a Bluetooth headset switches profile meanwhile).
        self.pause_media();
        // `start` blocks until audio flows (seconds, for a sleeping device).
        // The recording window counts from then, not from the request.
        let started = Instant::now();
        if let Err(e) = self.capture.start() {
            // A partial start must not leave the microphone open.
            self.capture.cancel();
            self.resume_media();
            self.session.reset();
            crate::error!("microphone capture failed to start: {e}");
            return Err(ErrorCode::Capture);
        }
        self.phase = Phase::Recording {
            since: now + started.elapsed(),
            prompt,
            tap_eligible: false,
        };
        Ok(())
    }

    /// Stops recording and queues recognition. The session must already be
    /// reset (it is, after `Action::Stop`). `hold_release`: stopped by
    /// releasing a hold, so a too-short recording is a tap that a second
    /// press may follow; media then stay paused for the double-tap window.
    fn stop_recording(
        &mut self,
        now: Instant,
        hold_release: bool,
    ) -> Result<Option<Note>, ErrorCode> {
        let Phase::Recording { since, prompt, .. } = self.phase else {
            self.session.reset();
            return Ok(Some(Note::Ignored));
        };
        self.phase = Phase::Idle;
        let stopped = self.capture.stop();
        if stopped.is_err() {
            // Make sure the stream is closed whatever state it is in.
            self.capture.cancel();
        }
        let mut audio = match stopped {
            Ok(s) => Audio::new(s),
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
            return Ok(discarded);
        }
        audio.truncate(Limits::samples(self.limits.max_recording));
        let id = self.next_id;
        self.next_id += 1;
        let cancel = Arc::new(CancelToken::default());
        self.jobs.submit(Job {
            id,
            cancel: Arc::clone(&cancel),
            kind: JobKind::Transcribe { audio, prompt },
        });
        self.phase = Phase::Busy {
            id,
            cancel,
            typing: false,
            prompt,
        };
        if !self.model_ready {
            crate::info!("transcription waits for the model to finish loading");
        }
        Ok(None)
    }

    fn cancel(&mut self) -> Option<Note> {
        self.session.reset();
        match std::mem::replace(&mut self.phase, Phase::Idle) {
            Phase::Idle => Some(Note::Ignored),
            Phase::Recording { .. } => {
                self.capture.cancel();
                self.resume_media();
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
                let prompt = matches!(self.phase, Phase::Busy { prompt: true, .. });
                self.phase = Phase::Idle;
                self.finish(outcome, prompt);
                Ok(())
            }
        }
    }

    fn finish(&mut self, outcome: Outcome, prompt: bool) {
        match outcome {
            Outcome::Typed {
                raw,
                text,
                pressed_enter,
                retype,
            } => {
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
        match (max, self.media_resume_at) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }
    }

    /// Stops a recording that reached the maximum length, and resumes media
    /// held paused after a tap once no second press came in time.
    pub fn tick(&mut self, now: Instant) {
        if let Phase::Recording { since, .. } = self.phase
            && now.saturating_duration_since(since) >= self.limits.max_recording
        {
            crate::info!("maximum recording length reached");
            self.session.reset();
            // The hold is over: its press stamp must not mark a later one.
            self.hold_press_at = None;
            let _ = self.stop_recording(now, false);
        }
        if self.media_resume_at.is_some_and(|t| now >= t) {
            self.resume_media();
        }
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
            Box::new(cap.clone()),
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
                Reply::Error(e) => panic!("{cmd:?}: error {e:?}"),
            }
        }

        fn typed(&self, text: &str) -> Outcome {
            Outcome::Typed {
                raw: text.into(),
                text: text.into(),
                pressed_enter: false,
                retype: false,
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
            matches!(&jobs[0].kind, JobKind::Transcribe { audio: s, prompt: false } if s.len() == SECOND)
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
            },
            r.t,
        ) {
            Reply::Ok(_, note) => note,
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
            matches!(&job.kind, JobKind::Transcribe { audio: s, prompt: false } if s.len() == SECOND * 10)
        );
        // The toggle that would have stopped it now does nothing.
        assert_eq!(r.note(Command::Toggle), Some(Note::Ignored));
    }

    #[test]
    fn records_while_model_loads() {
        let cap = FakeCapture::with_samples(vec![0.1; SECOND]);
        let jobs = Jobs::default();
        let mut c = Controller::new(
            Box::new(cap),
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
            Box::new(r.cap.clone()),
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
        r.c.handle_request(Request { command, at }, r.t)
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
            Reply::Error(e) => panic!("error {e:?}"),
        }
    }

    /// The prompt flag of the single queued transcription job.
    fn job_prompt(r: &Rig) -> bool {
        let jobs = r.jobs.take();
        assert_eq!(jobs.len(), 1);
        match &jobs[0].kind {
            JobKind::Transcribe { prompt, .. } => *prompt,
            JobKind::Retype(_) => panic!("not a transcription"),
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
}

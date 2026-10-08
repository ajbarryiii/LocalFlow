//! Pauses media players while recording (config `pause_media`), on a thread
//! of its own so D-Bus never delays the control loop.
//!
//! - The controller calls `pause` when a recording starts and `resume` when
//!   it ends, whichever way it ends (see `controller.rs`). Neither blocks:
//!   each sets the wanted state (an atomic flag) and wakes the thread.
//! - The thread works towards the latest wanted state through
//!   [`lf_media::Pauser`]: pause what plays, later play what it paused and
//!   is still paused. Wake-ups that queued up while it was busy collapse
//!   into one, so a very short recording does not stop and restart the
//!   music.
//! - Both passes check the wanted state before every D-Bus call and stop
//!   as soon as it changes. A resume still running when the next recording
//!   starts therefore stops (the players it did not reach stay paused), and
//!   that recording's pause pass re-pauses any it already resumed. At most
//!   the one call in flight (bounded by the call timeout) can land after
//!   the change, e.g. a `Play` just as the next recording starts.
//! - When the controller goes away (daemon shutdown, or a panic in the
//!   control loop), the channel closes and the thread resumes whatever it
//!   still holds paused, then exits. [`MediaJoin::join`] waits for that, for
//!   a bounded time.
//! - No session bus is a warning, not a failure; every pass tries again.
//! - Logs carry counts only, never player names or metadata.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::Duration;

use lf_io_api::{MediaError, MediaPlayers};
use lf_media::{Pauser, Report, Timing};

/// What the controller tells the media thread. Never blocks.
pub trait MediaSink: Send {
    fn pause(&mut self);
    fn resume(&mut self);
}

/// For `pause_media: false` and `--fake-io`.
pub struct NoMedia;

impl MediaSink for NoMedia {
    fn pause(&mut self) {}
    fn resume(&mut self) {}
}

pub struct MediaSender {
    wake: Sender<()>,
    /// Media should be paused (a recording runs).
    want_paused: Arc<AtomicBool>,
}

impl MediaSink for MediaSender {
    fn pause(&mut self) {
        self.want_paused.store(true, Ordering::SeqCst);
        let _ = self.wake.send(());
    }

    fn resume(&mut self) {
        self.want_paused.store(false, Ordering::SeqCst);
        let _ = self.wake.send(());
    }
}

/// After a resume left players paused because of transient failures, it is
/// retried this many times, this far apart, while no recording runs.
const RESUME_RETRIES: u32 = 3;
const RESUME_RETRY_DELAY: Duration = Duration::from_secs(1);

/// Owns the media thread.
pub struct MediaJoin {
    /// Disconnects when the thread ends (also on a panic).
    done: Receiver<()>,
    thread: JoinHandle<()>,
}

impl MediaJoin {
    /// Waits up to `timeout` for the thread to resume what it paused and
    /// exit; it does so once the [`MediaSender`] is dropped. A thread still
    /// busy after that (several players that hang on every call) is left to
    /// finish on its own, and the players it did not reach stay paused.
    /// Returns whether it finished.
    pub fn join(self, timeout: Duration) -> bool {
        match self.done.recv_timeout(timeout) {
            Err(RecvTimeoutError::Disconnected) | Ok(()) => {
                let _ = self.thread.join();
                true
            }
            Err(RecvTimeoutError::Timeout) => {
                crate::warn!("media players: still busy at shutdown; not waiting");
                false
            }
        }
    }
}

pub fn spawn(
    players: Box<dyn MediaPlayers>,
    timing: Timing,
) -> std::io::Result<(MediaSender, MediaJoin)> {
    let (wake, woken) = mpsc::channel();
    let (done_tx, done) = mpsc::channel::<()>();
    let want_paused = Arc::new(AtomicBool::new(false));
    let want = Arc::clone(&want_paused);
    let thread = std::thread::Builder::new()
        .name("lf-media".into())
        .spawn(move || {
            let _done = done_tx;
            run(Pauser::new(players, timing), &woken, &want);
        })?;
    Ok((
        MediaSender { wake, want_paused },
        MediaJoin { done, thread },
    ))
}

/// Whether the backend worked last time, to warn once per outage.
struct Health(Option<bool>);

impl Health {
    fn ok(&mut self) {
        if self.0 == Some(false) {
            crate::info!("media players: D-Bus session bus available again");
        }
        self.0 = Some(true);
    }

    fn failed(&mut self, e: MediaError) {
        if self.0 != Some(false) {
            crate::warn!("media players cannot be paused: {e}");
        } else {
            crate::debug!("media players cannot be paused: {e}");
        }
        self.0 = Some(false);
    }
}

fn run(mut pauser: Pauser<Box<dyn MediaPlayers>>, woken: &Receiver<()>, want: &AtomicBool) {
    let mut health = Health(None);
    let wanted = || want.load(Ordering::SeqCst);
    // Connect early, so the first recording does not wait for it, and say
    // at startup when the bus is missing.
    match pauser.probe() {
        Ok(_) => health.ok(),
        Err(e) => health.failed(e),
    }
    let mut retries_left = 0;
    loop {
        // While players wait for a retried resume (after transient
        // failures), wake up on a timer too.
        let woke = if retries_left > 0 && !wanted() && pauser.paused() > 0 {
            match woken.recv_timeout(RESUME_RETRY_DELAY) {
                Ok(()) => true,
                Err(RecvTimeoutError::Timeout) => {
                    retries_left -= 1;
                    false
                }
                Err(RecvTimeoutError::Disconnected) => break,
            }
        } else {
            match woken.recv() {
                Ok(()) => true,
                Err(_) => break,
            }
        };
        while woken.try_recv().is_ok() {}
        if wanted() {
            retries_left = 0;
            match pauser.pause_playing(&|| !wanted()) {
                Ok(r) => {
                    health.ok();
                    log_report("paused", r);
                }
                Err(e) => health.failed(e),
            }
        } else if pauser.paused() > 0 {
            let r = pauser.resume(&wanted);
            if woke && r.pending > 0 {
                retries_left = RESUME_RETRIES;
            }
            log_report("resumed", r);
        }
    }
    // The controller is gone: shutdown, or the control loop died.
    if pauser.paused() > 0 {
        log_report("resumed", pauser.resume(&|| false));
    }
}

fn log_report(what: &str, r: Report) {
    if r.changed > 0 {
        crate::info!("{what} {} media player(s)", r.changed);
    }
    if r.skipped > 0 {
        crate::debug!("media players: {} left alone", r.skipped);
    }
    if r.failed > 0 {
        crate::debug!("media players: {} with failed or timed-out calls", r.failed);
    }
    if r.pending > 0 {
        crate::debug!("media players: {} kept paused for a retry", r.pending);
    }
    if r.stopped {
        crate::debug!("media players: pass superseded by a newer request");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lf_io_api::PlaybackStatus::{Paused, Playing};
    use lf_media::fake::{Call, FakePlayers};
    use std::sync::Mutex;
    use std::time::Instant;

    const A: &str = "org.mpris.MediaPlayer2.synthetic_a";
    const B: &str = "org.mpris.MediaPlayer2.synthetic_b";
    const C: &str = "org.mpris.MediaPlayer2.synthetic_c";

    fn wait_for(f: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !f() {
            assert!(Instant::now() < deadline, "timed out");
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    fn start(fake: &FakePlayers) -> (MediaSender, MediaJoin) {
        spawn(Box::new(fake.clone()), Timing::default()).unwrap()
    }

    #[test]
    fn pauses_and_resumes_in_order() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        let (mut tx, join) = start(&fake);
        tx.pause();
        wait_for(|| fake.status_of(A) == Some(Paused));
        tx.resume();
        wait_for(|| fake.status_of(A) == Some(Playing));
        drop(tx);
        assert!(join.join(Duration::from_secs(5)));
        assert_eq!(fake.calls(Call::Pause, A), 1);
        assert_eq!(fake.calls(Call::Play, A), 1);
    }

    #[test]
    fn closing_the_channel_resumes_what_is_paused() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        let (mut tx, join) = start(&fake);
        tx.pause();
        wait_for(|| fake.status_of(A) == Some(Paused));
        drop(tx);
        assert!(join.join(Duration::from_secs(5)));
        // Resumed before `join` returned.
        assert_eq!(fake.status_of(A), Some(Playing));
    }

    #[test]
    fn queued_requests_collapse_into_the_latest() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        // Hold the startup probe until the requests have queued up.
        let (release, gate) = std::sync::mpsc::channel::<()>();
        let gate = Mutex::new(Some(gate));
        fake.state().hook = Some(Arc::new(move |call, _| {
            if call == Call::List
                && let Some(gate) = gate.lock().unwrap().take()
            {
                let _ = gate.recv();
            }
        }));
        let (mut tx, join) = start(&fake);
        tx.pause();
        tx.resume();
        tx.pause();
        tx.resume();
        release.send(()).unwrap();
        drop(tx);
        assert!(join.join(Duration::from_secs(5)));
        // The music was never stopped.
        assert_eq!(fake.calls(Call::Pause, A), 0);
        assert_eq!(fake.status_of(A), Some(Playing));
    }

    #[test]
    fn a_resume_still_running_when_recording_restarts_gives_way() {
        let fake = FakePlayers::default();
        for p in [A, B, C] {
            fake.add(p, Playing);
        }
        let (tx, join) = start(&fake);
        let tx = Arc::new(Mutex::new(tx));
        tx.lock().unwrap().pause();
        wait_for(|| [A, B, C].iter().all(|p| fake.status_of(p) == Some(Paused)));
        // The next recording starts just as the resume pass reads B.
        let armed = Arc::new(AtomicBool::new(true));
        let (hook_tx, hook_armed) = (Arc::clone(&tx), Arc::clone(&armed));
        fake.state().hook = Some(Arc::new(move |call, name| {
            if call == Call::Status && name == B && hook_armed.swap(false, Ordering::SeqCst) {
                hook_tx.lock().unwrap().pause();
            }
        }));
        tx.lock().unwrap().resume();
        // A was played; B and C were not, and A is paused again.
        wait_for(|| !armed.load(Ordering::SeqCst));
        wait_for(|| fake.calls(Call::Pause, A) == 2);
        wait_for(|| fake.status_of(A) == Some(Paused));
        assert_eq!(fake.calls(Call::Play, A), 1);
        assert_eq!(fake.calls(Call::Play, B), 0);
        assert_eq!(fake.calls(Call::Play, C), 0);
        assert!([A, B, C].iter().all(|p| fake.status_of(p) == Some(Paused)));
        // The end of that recording resumes all three.
        tx.lock().unwrap().resume();
        wait_for(|| [A, B, C].iter().all(|p| fake.status_of(p) == Some(Playing)));
        fake.state().hook = None;
        drop(tx);
        assert!(join.join(Duration::from_secs(5)));
    }

    #[test]
    fn a_pause_still_running_when_recording_ends_gives_way() {
        let fake = FakePlayers::default();
        for p in [A, B, C] {
            fake.add(p, Playing);
        }
        let (tx, join) = start(&fake);
        let tx = Arc::new(Mutex::new(tx));
        // The recording ends while the pause pass pauses A.
        let hook_tx = Arc::clone(&tx);
        fake.state().hook = Some(Arc::new(move |call, name| {
            if call == Call::Pause && name == A {
                hook_tx.lock().unwrap().resume();
            }
        }));
        tx.lock().unwrap().pause();
        wait_for(|| fake.calls(Call::Play, A) == 1);
        wait_for(|| fake.status_of(A) == Some(Playing));
        // B and C were never paused.
        assert_eq!(fake.calls(Call::Pause, B), 0);
        assert_eq!(fake.calls(Call::Pause, C), 0);
        fake.state().hook = None;
        drop(tx);
        assert!(join.join(Duration::from_secs(5)));
        assert!([A, B, C].iter().all(|p| fake.status_of(p) == Some(Playing)));
    }

    #[test]
    fn transient_resume_failures_are_retried_while_idle() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        let (mut tx, join) = start(&fake);
        tx.pause();
        wait_for(|| fake.status_of(A) == Some(Paused));
        // The resume pass and its own retry both time out.
        fake.update(A, |p| p.transient_failures = 2);
        tx.resume();
        // A later retry, with no request, succeeds.
        wait_for(|| fake.status_of(A) == Some(Playing));
        drop(tx);
        assert!(join.join(Duration::from_secs(5)));
    }

    #[test]
    fn no_bus_is_not_fatal_and_is_retried() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        fake.state().fail_list = Some(MediaError::Unavailable);
        let (mut tx, join) = start(&fake);
        tx.pause();
        wait_for(|| fake.state().lists >= 2);
        tx.resume();
        fake.state().fail_list = None;
        tx.pause();
        wait_for(|| fake.status_of(A) == Some(Paused));
        tx.resume();
        wait_for(|| fake.status_of(A) == Some(Playing));
        drop(tx);
        assert!(join.join(Duration::from_secs(5)));
    }

    #[test]
    fn join_is_bounded_when_players_hang() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        let (mut tx, join) = start(&fake);
        tx.pause();
        wait_for(|| fake.status_of(A) == Some(Paused));
        // Every call now takes 2 s.
        fake.state().delay = Duration::from_secs(2);
        drop(tx);
        let t = Instant::now();
        assert!(!join.join(Duration::from_millis(200)));
        assert!(t.elapsed() < Duration::from_secs(1));
    }
}

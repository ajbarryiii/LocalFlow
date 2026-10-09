//! Pauses media players while LocalFlow records, and resumes them after.
//!
//! - [`Mpris`]: the [`MediaPlayers`] backend, MPRIS over the D-Bus session
//!   bus through `zbus`, with a bound on every call.
//! - [`Pauser`]: the policy. It pauses the players that are playing and
//!   remembers them; on resume it plays only those that still report
//!   `Paused`, so a player the user resumed, stopped or closed meanwhile is
//!   left alone.
//! - [`fake::FakePlayers`]: an in-memory backend for tests.
//!
//! Both passes take a `stop` predicate, checked before every call: the
//! caller uses it to abandon a pass that a newer request (a new recording,
//! or the end of the current one) has made obsolete. An abandoned resume
//! keeps the players it did not get to, which stay paused and remembered.
//!
//! Nothing here reads track metadata, and nothing logs: callers get counts
//! ([`Report`]) and [`MediaError`] kinds.

pub mod fake;
mod mpris;

use std::time::{Duration, Instant};

use lf_io_api::{MediaError, MediaPlayers, PlaybackStatus, PlayerId};

pub use mpris::{MAX_PLAYERS, Mpris, MprisConfig};

/// Counts of players from one pause or resume pass.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Report {
    /// Players paused or resumed.
    pub changed: usize,
    /// Players left alone: not playing (pause), or no longer paused (resume).
    pub skipped: usize,
    /// Players whose calls failed or timed out (each counted once per pass),
    /// including players that went away.
    pub failed: usize,
    /// Resume only: players kept paused and remembered after transient
    /// failures, for a later retry.
    pub pending: usize,
    /// The pass was stopped early.
    pub stopped: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct Timing {
    /// How long a pause pass waits for the players it paused to report
    /// `Paused`. Players apply `Pause` asynchronously; without the wait, a
    /// resume right after a very short recording could still read `Playing`,
    /// skip the player, and leave it paused for good.
    pub confirm: Duration,
    /// How long a resume pass keeps watching players whose pause was never
    /// confirmed and that still read `Playing`, in case the pause lands late.
    pub settle: Duration,
    /// Interval between status reads while confirming or settling.
    pub poll: Duration,
    /// For this long after a successful `Play`, a pause pass pauses the
    /// player even if it still reads `Paused`: the `Play` may not have
    /// landed yet, and would otherwise start the music mid-recording.
    pub recent: Duration,
}

impl Default for Timing {
    fn default() -> Timing {
        Timing {
            confirm: Duration::from_millis(300),
            settle: Duration::from_millis(700),
            poll: Duration::from_millis(20),
            recent: Duration::from_secs(2),
        }
    }
}

/// A player this pauser paused (or tried to: a timed-out `Pause` may have
/// landed).
struct Held {
    id: PlayerId,
    /// Seen `Paused` after the pause.
    confirmed: bool,
}

enum Attempt {
    Changed,
    Skipped,
    Failed,
    /// Failed in a way that may be transient (timeout, connection lost).
    Retry,
    /// Still `Playing`, but its pause was never confirmed: it may land late.
    Settle,
    /// `stop` turned true; the player was not touched.
    Stopped,
}

fn transient(e: MediaError) -> bool {
    matches!(e, MediaError::TimedOut | MediaError::Unavailable)
}

pub struct Pauser<P> {
    players: P,
    held: Vec<Held>,
    /// Players resumed by a successful `Play`, and when.
    recent: Vec<(PlayerId, Instant)>,
    timing: Timing,
}

impl<P: MediaPlayers> Pauser<P> {
    pub fn new(players: P, timing: Timing) -> Pauser<P> {
        Pauser {
            players,
            held: Vec::new(),
            recent: Vec::new(),
            timing,
        }
    }

    /// Number of players paused by this pauser and not resumed yet.
    pub fn paused(&self) -> usize {
        self.held.len()
    }

    /// Lists the players, only to find out whether the backend works.
    pub fn probe(&mut self) -> Result<usize, MediaError> {
        self.players.players().map(|p| p.len())
    }

    fn hold(&mut self, id: PlayerId) {
        match self.held.iter_mut().find(|h| h.id == id) {
            Some(h) => h.confirmed = false,
            None => self.held.push(Held {
                id,
                confirmed: false,
            }),
        }
    }

    /// Pauses every player that is playing and remembers it, including
    /// remembered players the user started again, and players resumed
    /// moments ago whose `Play` may not have landed. Fails only when the
    /// players cannot be listed (no session bus, say).
    ///
    /// A `Pause` that timed out or lost its connection may still have
    /// reached the player, so the player is remembered: resume plays it only
    /// if it then reports `Paused`. A refused `Pause` (or a player gone) had
    /// no effect, and the player is not remembered; any older claim on it is
    /// dropped too, since the user evidently took it over.
    pub fn pause_playing(&mut self, stop: &dyn Fn() -> bool) -> Result<Report, MediaError> {
        let mut report = Report::default();
        let now = Instant::now();
        let recent_for = self.timing.recent;
        self.recent
            .retain(|(_, at)| now.saturating_duration_since(*at) < recent_for);
        for id in self.players.players()? {
            if stop() {
                report.stopped = true;
                break;
            }
            let recent = self.recent.iter().any(|(r, _)| *r == id);
            let pause = match self.players.status(&id) {
                Ok(PlaybackStatus::Playing) => true,
                Ok(PlaybackStatus::Paused) => recent,
                Ok(PlaybackStatus::Stopped) => false,
                Err(_) => {
                    report.failed += 1;
                    continue;
                }
            };
            if !pause {
                report.skipped += 1;
                continue;
            }
            if stop() {
                report.stopped = true;
                break;
            }
            self.recent.retain(|(r, _)| *r != id);
            match self.players.pause(&id) {
                Ok(()) => {
                    report.changed += 1;
                    self.hold(id);
                }
                Err(e) if transient(e) => {
                    report.failed += 1;
                    self.hold(id);
                }
                Err(_) => {
                    report.failed += 1;
                    self.held.retain(|h| h.id != id);
                }
            }
        }
        if !report.stopped {
            self.confirm(stop);
        }
        Ok(report)
    }

    /// Waits until the unconfirmed players report `Paused`, for at most
    /// `confirm` plus one call.
    fn confirm(&mut self, stop: &dyn Fn() -> bool) {
        let deadline = Instant::now() + self.timing.confirm;
        let mut pending: Vec<usize> = (0..self.held.len())
            .filter(|&i| !self.held[i].confirmed)
            .collect();
        while !pending.is_empty() {
            let mut next = Vec::new();
            for i in pending {
                if stop() || Instant::now() >= deadline {
                    return;
                }
                match self.players.status(&self.held[i].id) {
                    Ok(PlaybackStatus::Paused) => self.held[i].confirmed = true,
                    Ok(PlaybackStatus::Playing) => next.push(i),
                    _ => {}
                }
            }
            pending = next;
            let left = deadline.saturating_duration_since(Instant::now());
            if pending.is_empty() || left.is_zero() {
                return;
            }
            std::thread::sleep(self.timing.poll.min(left));
        }
    }

    fn play(&mut self, id: &PlayerId) -> Result<(), MediaError> {
        let result = self.players.play(id);
        if result.is_ok() {
            self.recent.push((id.clone(), Instant::now()));
        }
        result
    }

    fn attempt(&mut self, held: &Held, stop: &dyn Fn() -> bool) -> Attempt {
        match self.players.status(&held.id) {
            Ok(PlaybackStatus::Paused) if stop() => Attempt::Stopped,
            Ok(PlaybackStatus::Paused) => match self.play(&held.id) {
                Ok(()) => Attempt::Changed,
                Err(e) if transient(e) => Attempt::Retry,
                Err(_) => Attempt::Failed,
            },
            Ok(PlaybackStatus::Playing) if !held.confirmed => Attempt::Settle,
            Ok(PlaybackStatus::Playing | PlaybackStatus::Stopped) => Attempt::Skipped,
            Err(e) if transient(e) => Attempt::Retry,
            Err(_) => Attempt::Failed,
        }
    }

    /// Plays the players this pauser paused that still report `Paused`, and
    /// forgets them. Players that play, stopped or went away are left alone.
    ///
    /// - A transient failure (timeout, lost connection) is retried once, at
    ///   the end of the pass; a player that still fails stays remembered
    ///   (`Report::pending`) for a later pass.
    /// - A player whose pause was never confirmed and that still reads
    ///   `Playing` is watched for up to `settle`, and played if its pause
    ///   lands meanwhile.
    /// - If `stop` turns true (a new recording started), the pass ends and
    ///   the players it did not play stay remembered.
    pub fn resume(&mut self, stop: &dyn Fn() -> bool) -> Report {
        let mut report = Report::default();
        let mut todo: Vec<Held> = std::mem::take(&mut self.held);
        let mut settle = Vec::new();
        let mut unresolved = Vec::new();
        for retrying in [false, true] {
            let mut retry = Vec::new();
            let mut queue = std::mem::take(&mut todo).into_iter();
            while let Some(held) = queue.next() {
                let attempt = if stop() {
                    Attempt::Stopped
                } else {
                    self.attempt(&held, stop)
                };
                match attempt {
                    Attempt::Changed => report.changed += 1,
                    Attempt::Skipped => report.skipped += 1,
                    Attempt::Failed => report.failed += 1,
                    Attempt::Retry if retrying => {
                        report.failed += 1;
                        unresolved.push(held);
                    }
                    Attempt::Retry => retry.push(held),
                    Attempt::Settle => settle.push(held),
                    Attempt::Stopped => {
                        report.stopped = true;
                        self.held.push(held);
                        self.held.extend(queue);
                        self.held.extend(retry);
                        self.held.extend(settle);
                        self.held.extend(unresolved);
                        return report;
                    }
                }
            }
            todo = retry;
        }
        report.pending = unresolved.len();
        self.held.extend(unresolved);
        self.settle(settle, stop, &mut report);
        report
    }

    fn settle(&mut self, mut watch: Vec<Held>, stop: &dyn Fn() -> bool, report: &mut Report) {
        let deadline = Instant::now() + self.timing.settle;
        while !watch.is_empty() {
            let mut next = Vec::new();
            let mut queue = watch.into_iter();
            while let Some(held) = queue.next() {
                if stop() {
                    report.stopped = true;
                    self.held.push(held);
                    self.held.extend(queue);
                    self.held.extend(next);
                    return;
                }
                if Instant::now() >= deadline {
                    // Never paused: the player ignored the pause.
                    report.skipped += 1 + queue.len() + next.len();
                    return;
                }
                match self.players.status(&held.id) {
                    Ok(PlaybackStatus::Playing) => next.push(held),
                    Ok(PlaybackStatus::Paused) if stop() => {
                        report.stopped = true;
                        self.held.push(held);
                        self.held.extend(queue);
                        self.held.extend(next);
                        return;
                    }
                    Ok(PlaybackStatus::Paused) => match self.play(&held.id) {
                        Ok(()) => report.changed += 1,
                        Err(e) if transient(e) => {
                            report.failed += 1;
                            report.pending += 1;
                            self.held.push(held);
                        }
                        Err(_) => report.failed += 1,
                    },
                    Ok(PlaybackStatus::Stopped) => report.skipped += 1,
                    Err(e) if transient(e) => {
                        report.failed += 1;
                        report.pending += 1;
                        self.held.push(held);
                    }
                    Err(_) => report.failed += 1,
                }
            }
            watch = next;
            if watch.is_empty() {
                return;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            std::thread::sleep(self.timing.poll.min(left));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake::{Call, FakePlayers};
    use PlaybackStatus::{Paused, Playing, Stopped};
    use std::cell::Cell;

    const NEVER: &dyn Fn() -> bool = &|| false;

    fn timing(confirm_ms: u64, settle_ms: u64) -> Timing {
        Timing {
            confirm: Duration::from_millis(confirm_ms),
            settle: Duration::from_millis(settle_ms),
            poll: Duration::from_millis(10),
            recent: Duration::from_secs(2),
        }
    }

    fn pauser(fake: &FakePlayers) -> Pauser<FakePlayers> {
        Pauser::new(fake.clone(), timing(200, 200))
    }

    fn report(changed: usize, skipped: usize, failed: usize) -> Report {
        Report {
            changed,
            skipped,
            failed,
            ..Report::default()
        }
    }

    const A: &str = "org.mpris.MediaPlayer2.a";
    const B: &str = "org.mpris.MediaPlayer2.b";
    const C: &str = "org.mpris.MediaPlayer2.c";
    const D: &str = "org.mpris.MediaPlayer2.d";

    #[test]
    fn pauses_only_playing_players_and_resumes_them() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        fake.add(B, Paused);
        fake.add(C, Stopped);
        fake.add(D, Playing);
        let mut p = pauser(&fake);
        assert_eq!(p.pause_playing(NEVER).unwrap(), report(2, 2, 0));
        assert_eq!(p.paused(), 2);
        assert_eq!(fake.status_of(A), Some(Paused));
        assert_eq!(fake.status_of(D), Some(Paused));
        for name in [B, C] {
            assert_eq!(fake.calls(Call::Pause, name), 0);
        }

        assert_eq!(p.resume(NEVER), report(2, 0, 0));
        assert_eq!(p.paused(), 0);
        assert_eq!(fake.status_of(A), Some(Playing));
        assert_eq!(fake.status_of(D), Some(Playing));
        // The player the user had paused, and the stopped one, stay so.
        assert_eq!(fake.status_of(B), Some(Paused));
        assert_eq!(fake.status_of(C), Some(Stopped));
        for name in [B, C] {
            assert_eq!(fake.calls(Call::Play, name), 0);
        }
        // A second resume does nothing.
        assert_eq!(p.resume(NEVER), Report::default());
    }

    #[test]
    fn nothing_playing_means_nothing_to_resume() {
        let fake = FakePlayers::default();
        let mut p = pauser(&fake);
        assert_eq!(p.pause_playing(NEVER).unwrap(), Report::default());
        fake.add(A, Paused);
        assert_eq!(p.resume(NEVER), Report::default());
        assert_eq!(fake.calls(Call::Play, A), 0);
    }

    #[test]
    fn players_the_user_changed_meanwhile_are_left_alone() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        fake.add(B, Playing);
        let mut p = pauser(&fake);
        assert_eq!(p.pause_playing(NEVER).unwrap().changed, 2);
        fake.set(A, Playing);
        fake.set(B, Stopped);
        assert_eq!(p.resume(NEVER), report(0, 2, 0));
        assert_eq!(fake.calls(Call::Play, A), 0);
        assert_eq!(fake.calls(Call::Play, B), 0);
        assert_eq!(fake.status_of(B), Some(Stopped));
    }

    #[test]
    fn a_player_that_went_away_is_skipped_and_its_successor_untouched() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        fake.add(B, Playing);
        let mut p = pauser(&fake);
        p.pause_playing(NEVER).unwrap();
        fake.remove(A);
        // A new instance under the same well-known name, paused by the user.
        fake.add(A, Paused);
        assert_eq!(p.resume(NEVER), report(1, 0, 1));
        assert_eq!(fake.status_of(A), Some(Paused));
        assert_eq!(fake.calls(Call::Play, A), 0);
        assert_eq!(fake.status_of(B), Some(Playing));
    }

    #[test]
    fn listing_errors_fail_the_pass_and_player_errors_are_counted() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        fake.add(B, Playing);
        fake.state().fail_list = Some(MediaError::Unavailable);
        let mut p = pauser(&fake);
        assert_eq!(p.pause_playing(NEVER), Err(MediaError::Unavailable));
        assert!(p.probe().is_err());
        assert_eq!(p.paused(), 0);
        assert_eq!(fake.status_of(A), Some(Playing));

        fake.state().fail_list = None;
        fake.update(B, |p| p.fail = Some(MediaError::Rejected));
        assert_eq!(p.pause_playing(NEVER).unwrap(), report(1, 0, 1));
        assert_eq!(p.paused(), 1);
        assert_eq!(p.resume(NEVER).changed, 1);
        assert_eq!(fake.status_of(A), Some(Playing));
        assert_eq!(fake.calls(Call::Play, B), 0);
    }

    #[test]
    fn a_refused_pause_is_not_remembered() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        let mut p = pauser(&fake);
        // E.g. AccessDenied from the bus, or the player's own error.
        fake.update(A, |p| p.fail_pause = Some(MediaError::Rejected));
        assert_eq!(p.pause_playing(NEVER).unwrap(), report(0, 0, 1));
        assert_eq!(fake.calls(Call::Pause, A), 1);
        assert_eq!(p.paused(), 0);
        // Likewise a player gone between the status read and the pause.
        fake.update(A, |p| p.fail_pause = Some(MediaError::Gone));
        assert_eq!(p.pause_playing(NEVER).unwrap(), report(0, 0, 1));
        assert_eq!(p.paused(), 0);
        // The user pauses it: never resumed by LocalFlow.
        fake.set(A, Paused);
        assert_eq!(p.resume(NEVER), Report::default());
        assert_eq!(fake.calls(Call::Play, A), 0);
    }

    #[test]
    fn a_timed_out_pause_is_remembered_and_resumed_only_if_paused() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        fake.add(B, Playing);
        fake.update(A, |p| p.fail_pause_after_applying = true);
        fake.update(B, |p| p.ignore_pause = true);
        let mut p = pauser(&fake);
        assert_eq!(p.pause_playing(NEVER).unwrap(), report(1, 0, 1));
        assert_eq!(p.paused(), 2);
        // B never paused: watched for `settle`, then left alone.
        assert_eq!(p.resume(NEVER), report(1, 1, 0));
        assert_eq!(fake.status_of(A), Some(Playing));
        assert_eq!(fake.calls(Call::Play, B), 0);
    }

    #[test]
    fn a_short_recording_waits_for_the_pause_to_take_effect() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        // The player reports the old status for three more reads.
        fake.state().lag = 3;
        let mut p = pauser(&fake);
        p.pause_playing(NEVER).unwrap();
        // Three lagging reads, then one showing the pause.
        assert_eq!(fake.calls(Call::Status, A), 5);
        // Resume right away: the player is seen as paused and is played.
        assert_eq!(p.resume(NEVER).changed, 1);
        assert_eq!(fake.status_of(A), Some(Playing));
    }

    #[test]
    fn a_pause_that_lands_after_the_confirm_window_is_still_resumed() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        fake.state().lag = 3;
        // No confirmation wait at all: resume reads `Playing` first.
        let mut p = Pauser::new(fake.clone(), timing(0, 500));
        p.pause_playing(NEVER).unwrap();
        assert_eq!(p.resume(NEVER), report(1, 0, 0));
        assert_eq!(fake.status_of(A), Some(Playing));
        assert_eq!(fake.calls(Call::Play, A), 1);
    }

    #[test]
    fn the_confirm_wait_is_bounded() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        fake.add(B, Playing);
        fake.update(A, |p| p.ignore_pause = true);
        fake.update(B, |p| p.ignore_pause = true);
        let mut p = Pauser::new(fake.clone(), timing(100, 0));
        let t = Instant::now();
        p.pause_playing(NEVER).unwrap();
        let waited = t.elapsed();
        assert!(waited >= Duration::from_millis(100), "{waited:?}");
        assert!(waited < Duration::from_millis(400), "{waited:?}");

        // With slow reads, the deadline is checked before each one: at most
        // one read past it.
        fake.state().delay = Duration::from_millis(80);
        let mut p = Pauser::new(fake.clone(), timing(100, 0));
        let t = Instant::now();
        p.pause_playing(NEVER).unwrap();
        // List, 2 x (status + pause), then reads until the deadline.
        let waited = t.elapsed();
        assert!(
            waited < Duration::from_millis(5 * 80 + 100 + 2 * 80 + 60),
            "{waited:?}"
        );
    }

    #[test]
    fn transient_resume_failures_are_retried_once() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        fake.add(B, Playing);
        let mut p = pauser(&fake);
        p.pause_playing(NEVER).unwrap();
        fake.update(A, |p| p.transient_failures = 1);
        fake.update(B, |p| p.transient_failures = 2);
        assert_eq!(
            p.resume(NEVER),
            Report {
                changed: 1,
                failed: 1,
                pending: 1,
                ..Report::default()
            }
        );
        assert_eq!(fake.status_of(A), Some(Playing));
        // B failed twice: still paused and still remembered...
        assert_eq!(fake.status_of(B), Some(Paused));
        assert_eq!(p.paused(), 1);
        // ...so a later pass resumes it.
        assert_eq!(p.resume(NEVER), report(1, 0, 0));
        assert_eq!(fake.status_of(B), Some(Playing));
        assert_eq!(p.paused(), 0);
    }

    #[test]
    fn a_play_that_has_not_landed_is_paused_by_the_next_recording() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        let mut p = pauser(&fake);
        p.pause_playing(NEVER).unwrap();
        // The player acknowledges `Play` but applies it late.
        fake.state().lag = 3;
        assert_eq!(p.resume(NEVER).changed, 1);
        // The next recording starts at once: A still reads `Paused`, but it
        // was resumed moments ago, so it is paused again and remembered.
        assert_eq!(p.pause_playing(NEVER).unwrap().changed, 1);
        assert_eq!(fake.status_of(A), Some(Paused));
        assert_eq!(p.paused(), 1);
        fake.state().lag = 0;
        assert_eq!(p.resume(NEVER).changed, 1);
        assert_eq!(fake.status_of(A), Some(Playing));

        // Long after a resume, a paused player is the user's: left alone.
        let mut p = Pauser::new(
            fake.clone(),
            Timing {
                recent: Duration::ZERO,
                ..timing(200, 200)
            },
        );
        p.pause_playing(NEVER).unwrap();
        p.resume(NEVER);
        fake.set(A, Paused);
        assert_eq!(p.pause_playing(NEVER).unwrap(), report(0, 1, 0));
    }

    #[test]
    fn a_refused_re_pause_drops_the_old_claim() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        let mut p = pauser(&fake);
        p.pause_playing(NEVER).unwrap();
        // The user starts A again; the next pause is refused.
        fake.set(A, Playing);
        fake.update(A, |p| p.fail_pause = Some(MediaError::Rejected));
        assert_eq!(p.pause_playing(NEVER).unwrap(), report(0, 0, 1));
        assert_eq!(p.paused(), 0);
        // The user pauses it by hand: LocalFlow does not resume it.
        fake.set(A, Paused);
        assert_eq!(p.resume(NEVER), Report::default());
        assert_eq!(fake.calls(Call::Play, A), 0);
    }

    #[test]
    fn the_settle_wait_is_bounded_with_slow_reads() {
        let fake = FakePlayers::default();
        for name in [A, B, C] {
            fake.add(name, Playing);
            fake.update(name, |p| p.ignore_pause = true);
        }
        let mut p = Pauser::new(fake.clone(), timing(0, 100));
        p.pause_playing(NEVER).unwrap();
        fake.state().delay = Duration::from_millis(80);
        let t = Instant::now();
        // Three first reads, then at most one read past the deadline.
        assert_eq!(p.resume(NEVER).skipped, 3);
        let took = t.elapsed();
        assert!(
            took < Duration::from_millis(3 * 80 + 100 + 80 + 100),
            "{took:?}"
        );
    }

    #[test]
    fn a_new_pause_re_pauses_remembered_players_the_user_restarted() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        fake.add(B, Playing);
        let mut p = pauser(&fake);
        p.pause_playing(NEVER).unwrap();
        // Before any resume, the user starts A again; then a new player.
        fake.set(A, Playing);
        fake.add(C, Playing);
        assert_eq!(p.pause_playing(NEVER).unwrap(), report(2, 1, 0));
        assert_eq!(fake.status_of(A), Some(Paused));
        assert_eq!(fake.status_of(C), Some(Paused));
        assert_eq!(p.paused(), 3);
        assert_eq!(p.resume(NEVER).changed, 3);
    }

    #[test]
    fn a_stopped_resume_keeps_the_rest_paused_and_remembered() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        fake.add(B, Playing);
        fake.add(C, Playing);
        let mut p = pauser(&fake);
        p.pause_playing(NEVER).unwrap();
        // A new recording starts after the first player was resumed.
        let plays = || fake.calls(Call::Play, A) + fake.calls(Call::Play, B);
        let r = p.resume(&|| plays() >= 1);
        assert!(r.stopped);
        assert_eq!(r.changed, 1);
        assert_eq!(p.paused(), 2);
        assert_eq!(fake.status_of(B), Some(Paused));
        assert_eq!(fake.status_of(C), Some(Paused));
        // That recording's pause pass re-pauses A; its end resumes all.
        assert_eq!(p.pause_playing(NEVER).unwrap().changed, 1);
        assert_eq!(p.resume(NEVER).changed, 3);
    }

    #[test]
    fn a_stopped_pause_pauses_no_further_players() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        fake.add(B, Playing);
        let mut p = pauser(&fake);
        let r = p
            .pause_playing(&|| fake.calls(Call::Pause, A) >= 1)
            .unwrap();
        assert!(r.stopped);
        assert_eq!(fake.status_of(B), Some(Playing));
        assert_eq!(p.resume(NEVER).changed, 1);
        assert_eq!(fake.status_of(A), Some(Playing));
    }

    #[test]
    fn a_stopped_settle_keeps_the_player() {
        let fake = FakePlayers::default();
        fake.add(A, Playing);
        fake.update(A, |p| p.ignore_pause = true);
        let mut p = Pauser::new(fake.clone(), timing(0, 1000));
        p.pause_playing(NEVER).unwrap();
        let reads = Cell::new(0);
        let r = p.resume(&|| {
            reads.set(reads.get() + 1);
            reads.get() > 3
        });
        assert!(r.stopped);
        assert_eq!(p.paused(), 1);
    }
}

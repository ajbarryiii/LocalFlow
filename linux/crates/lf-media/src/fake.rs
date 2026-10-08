//! An in-memory [`MediaPlayers`] for tests. It never touches D-Bus.

use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use lf_io_api::{MediaError, MediaPlayers, PlaybackStatus, PlayerId};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Call {
    /// Listing the players (hook only; not recorded in `calls`).
    List,
    Status,
    Pause,
    Play,
}

#[derive(Debug)]
pub struct FakePlayer {
    /// Well-known name, e.g. `org.mpris.MediaPlayer2.synthetic`.
    pub name: String,
    /// The connection's unique name; a new one for every player added.
    unique: String,
    /// What the player reports.
    status: PlaybackStatus,
    /// A status change not visible yet, and how many more reads show the
    /// old status.
    pending: Option<(PlaybackStatus, usize)>,
    /// Every call fails with this error, without effect.
    pub fail: Option<MediaError>,
    /// The next this many calls fail with `TimedOut`, without effect.
    pub transient_failures: usize,
    /// `Pause` fails with this error, without effect.
    pub fail_pause: Option<MediaError>,
    /// `Pause` is applied, then fails with `TimedOut` (a lost reply).
    pub fail_pause_after_applying: bool,
    /// `Pause` succeeds but has no effect (MPRIS `CanPause` false).
    pub ignore_pause: bool,
}

/// Called before every call with its kind and the player's well-known name
/// (empty for `List`), outside the state lock. Tests use it to act at an
/// exact point of a pass, or to block a call.
pub type Hook = Arc<dyn Fn(Call, &str) + Send + Sync>;

#[derive(Default)]
pub struct FakeState {
    pub hook: Option<Hook>,
    pub players: Vec<FakePlayer>,
    /// Listing players fails with this error (`Unavailable`: no bus).
    pub fail_list: Option<MediaError>,
    /// Reads that still show the old status after `Pause` or `Play`.
    pub lag: usize,
    /// Delay of every call, like a slow bus.
    pub delay: Duration,
    /// Every call made, with the player's well-known name.
    pub calls: Vec<(Call, String)>,
    pub lists: usize,
    next_unique: u64,
}

/// Clones share state.
#[derive(Clone, Default)]
pub struct FakePlayers(pub Arc<Mutex<FakeState>>);

impl FakePlayers {
    pub fn state(&self) -> MutexGuard<'_, FakeState> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Adds a player (a new process, even if the name was used before).
    pub fn add(&self, name: &str, status: PlaybackStatus) {
        let mut s = self.state();
        s.next_unique += 1;
        let unique = format!(":fake.{}", s.next_unique);
        s.players.push(FakePlayer {
            name: name.to_owned(),
            unique,
            status,
            pending: None,
            fail: None,
            transient_failures: 0,
            fail_pause: None,
            fail_pause_after_applying: false,
            ignore_pause: false,
        });
    }

    /// The player quits.
    pub fn remove(&self, name: &str) {
        self.state().players.retain(|p| p.name != name);
    }

    /// The user changes the player's state, which takes effect at once.
    pub fn set(&self, name: &str, status: PlaybackStatus) {
        self.update(name, |p| {
            p.status = status;
            p.pending = None;
        });
    }

    /// Changes the player named `name`. Panics if there is none.
    pub fn update(&self, name: &str, f: impl FnOnce(&mut FakePlayer)) {
        let mut s = self.state();
        let p = s
            .players
            .iter_mut()
            .find(|p| p.name == name)
            .expect("no such fake player");
        f(p);
    }

    /// The status the player settles in, ignoring any lag.
    pub fn status_of(&self, name: &str) -> Option<PlaybackStatus> {
        let s = self.state();
        let p = s.players.iter().find(|p| p.name == name)?;
        Some(p.pending.map_or(p.status, |(status, _)| status))
    }

    /// Number of `call`s made to players named `name`.
    pub fn calls(&self, call: Call, name: &str) -> usize {
        self.state()
            .calls
            .iter()
            .filter(|(c, n)| *c == call && n == name)
            .count()
    }

    /// Runs the hook (outside the lock), then the delay, before a call.
    fn before(&self, call: Call, name: &str) {
        let (hook, delay) = {
            let s = self.state();
            (s.hook.clone(), s.delay)
        };
        if let Some(hook) = hook {
            hook(call, name);
        }
        if !delay.is_zero() {
            std::thread::sleep(delay);
        }
    }

    fn with_player<R>(
        &mut self,
        id: &PlayerId,
        call: Call,
        f: impl FnOnce(&mut FakePlayer, usize) -> Result<R, MediaError>,
    ) -> Result<R, MediaError> {
        let name = {
            let s = self.state();
            s.players
                .iter()
                .find(|p| p.unique == id.name)
                .map(|p| p.name.clone())
        };
        self.before(call, name.as_deref().unwrap_or(""));
        let mut s = self.state();
        let lag = s.lag;
        let Some(p) = s.players.iter_mut().find(|p| p.unique == id.name) else {
            return Err(MediaError::Gone);
        };
        let name = p.name.clone();
        let result = if let Some(e) = p.fail {
            Err(e)
        } else if p.transient_failures > 0 {
            p.transient_failures -= 1;
            Err(MediaError::TimedOut)
        } else {
            f(p, lag)
        };
        s.calls.push((call, name));
        result
    }
}

fn change(p: &mut FakePlayer, to: PlaybackStatus, lag: usize) {
    p.pending = (lag > 0).then_some((to, lag));
    if lag == 0 {
        p.status = to;
    }
}

impl MediaPlayers for FakePlayers {
    fn players(&mut self) -> Result<Vec<PlayerId>, MediaError> {
        self.before(Call::List, "");
        let mut s = self.state();
        s.lists += 1;
        if let Some(e) = s.fail_list {
            return Err(e);
        }
        Ok(s.players
            .iter()
            .map(|p| PlayerId {
                session: 1,
                name: p.unique.clone(),
            })
            .collect())
    }

    fn status(&mut self, player: &PlayerId) -> Result<PlaybackStatus, MediaError> {
        self.with_player(player, Call::Status, |p, _| {
            match p.pending {
                // This read still shows the old status.
                Some((to, left)) if left > 0 => p.pending = Some((to, left - 1)),
                Some((to, _)) => {
                    p.status = to;
                    p.pending = None;
                }
                None => {}
            }
            Ok(p.status)
        })
    }

    fn pause(&mut self, player: &PlayerId) -> Result<(), MediaError> {
        self.with_player(player, Call::Pause, |p, lag| {
            if let Some(e) = p.fail_pause {
                return Err(e);
            }
            if p.ignore_pause {
                return Ok(());
            }
            change(p, PlaybackStatus::Paused, lag);
            if p.fail_pause_after_applying {
                return Err(MediaError::TimedOut);
            }
            Ok(())
        })
    }

    fn play(&mut self, player: &PlayerId) -> Result<(), MediaError> {
        self.with_player(player, Call::Play, |p, lag| {
            change(p, PlaybackStatus::Playing, lag);
            Ok(())
        })
    }
}

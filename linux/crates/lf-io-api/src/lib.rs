//! Interfaces between the LocalFlow daemon and the desktop: microphone capture,
//! text insertion and media players. The daemon depends only on these traits;
//! real backends (PipeWire, the Wayland virtual keyboard, MPRIS) and test
//! fakes implement them.
//!
//! Privacy contract for every implementation:
//! - Captured audio stays in memory. It is never written to disk or logged.
//! - Text passed to [`TextOutput`] is never logged or persisted.
//! - Errors carry no audio, transcript or window content.

pub mod sys;
pub mod wipe;

use std::fmt;

pub const SAMPLE_RATE: u32 = 16_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IoError(pub String);

impl fmt::Display for IoError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for IoError {}

/// Receives a recording's audio while it is captured.
pub trait AudioSink: Send {
    /// The next samples of the recording, in order: 16 kHz mono f32 in
    /// [-1, 1], never empty. Called on the capture's own thread, so it must
    /// not block for long. The slice is the capture's buffer, wiped after the
    /// call; a sink that keeps samples must wipe its copy too.
    fn audio(&mut self, samples: &[f32]);
}

/// Collects everything delivered to it (tests and smoke tools). Clones share
/// the samples, which are wiped when the last clone is dropped.
#[derive(Clone, Default)]
pub struct CollectSink(std::sync::Arc<std::sync::Mutex<wipe::Wiped>>);

impl CollectSink {
    /// Takes the samples collected so far, still wiped when dropped.
    pub fn take(&self) -> wipe::Wiped {
        let mut s = self.0.lock().unwrap_or_else(|e| e.into_inner());
        std::mem::take(&mut *s)
    }
}

impl AudioSink for CollectSink {
    fn audio(&mut self, samples: &[f32]) {
        let mut s = self.0.lock().unwrap_or_else(|e| e.into_inner());
        wipe::push_wiping(&mut s.0, samples);
    }
}

/// Microphone capture. One recording at a time.
pub trait AudioCapture: Send {
    /// Starts capturing from the configured input and delivers the audio to
    /// `sink` as it arrives, until `stop` or `cancel` returns. Fails if a
    /// recording is already running or the device cannot be opened; the sink
    /// is then dropped.
    fn start(&mut self, sink: Box<dyn AudioSink>) -> Result<(), IoError>;

    /// Stops recording: delivers the last samples to the sink, drops it, and
    /// returns how many samples were delivered since `start`.
    fn stop(&mut self) -> Result<usize, IoError>;

    /// Stops recording and drops the sink. Audio already delivered is the
    /// receiver's to discard. Idempotent.
    fn cancel(&mut self);

    /// Recent input level in [0, 1] for a level indicator; 0 when idle.
    fn level(&self) -> f32 {
        0.0
    }

    /// Whether the configured input exists: `Some(true)` present,
    /// `Some(false)` absent, `None` unknown (not tracked, or the audio server
    /// cannot be reached). The default tracks nothing.
    fn input_available(&self) -> Option<bool> {
        None
    }

    /// Starts tracking [`AudioCapture::input_available`] and calls `notify`,
    /// from any thread, whenever it may have changed. Called at most once.
    /// The default tracks nothing and never calls `notify`.
    fn watch_input(&mut self, notify: Box<dyn Fn() + Send + Sync>) {
        let _ = notify;
    }
}

/// Text insertion into the focused window.
pub trait TextOutput: Send {
    /// Checks, without typing anything, that [`TextOutput::type_text`] would
    /// accept every character of `text`. Callers that type a text in pieces
    /// call this on the whole text first, so a bad character late in the text
    /// cannot leave an earlier part typed. The default accepts everything.
    fn check(&self, text: &str) -> Result<(), IoError> {
        let _ = text;
        Ok(())
    }

    /// Types `text` (any Unicode) into the focused window.
    fn type_text(&mut self, text: &str) -> Result<(), IoError>;

    /// Presses and releases Return.
    fn press_enter(&mut self) -> Result<(), IoError>;
}

/// Playback state of a media player (MPRIS `PlaybackStatus`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlaybackStatus {
    Playing,
    Paused,
    Stopped,
}

/// One running media player. It names a single process connection, not a
/// well-known name, so a player that quits and starts again is a different
/// player. `session` identifies the bus instance the name belongs to.
///
/// Player names are not user content, but they reveal which applications
/// run, so they are never logged: `Debug` prints no name.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct PlayerId {
    pub session: u64,
    pub name: String,
}

impl fmt::Debug for PlayerId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("PlayerId(..)")
    }
}

/// Why a [`MediaPlayers`] call failed. The kinds matter to the caller: a
/// call that timed out may still have taken effect, one that was rejected
/// did not.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaError {
    /// No bus, or the connection failed (possibly in the middle of a call).
    Unavailable,
    /// The player has gone away.
    Gone,
    /// No answer in time; the call may or may not have taken effect.
    TimedOut,
    /// The player or the bus refused the call, or answered nonsense; a
    /// refused call had no effect.
    Rejected,
}

impl fmt::Display for MediaError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            MediaError::Unavailable => "D-Bus session bus not available",
            MediaError::Gone => "media player is gone",
            MediaError::TimedOut => "D-Bus call timed out",
            MediaError::Rejected => "media player refused the call",
        })
    }
}

impl std::error::Error for MediaError {}

/// Media players on the desktop (MPRIS over D-Bus), which the daemon pauses
/// while it records. Implementations bound every call in time.
///
/// Privacy contract: implementations never read track metadata (titles,
/// artists, URLs), and errors carry no player names or messages from
/// players.
pub trait MediaPlayers: Send {
    /// The players present now, each once.
    fn players(&mut self) -> Result<Vec<PlayerId>, MediaError>;

    fn status(&mut self, player: &PlayerId) -> Result<PlaybackStatus, MediaError>;

    fn pause(&mut self, player: &PlayerId) -> Result<(), MediaError>;

    fn play(&mut self, player: &PlayerId) -> Result<(), MediaError>;
}

impl<T: MediaPlayers + ?Sized> MediaPlayers for Box<T> {
    fn players(&mut self) -> Result<Vec<PlayerId>, MediaError> {
        (**self).players()
    }

    fn status(&mut self, player: &PlayerId) -> Result<PlaybackStatus, MediaError> {
        (**self).status(player)
    }

    fn pause(&mut self, player: &PlayerId) -> Result<(), MediaError> {
        (**self).pause(player)
    }

    fn play(&mut self, player: &PlayerId) -> Result<(), MediaError> {
        (**self).play(player)
    }
}

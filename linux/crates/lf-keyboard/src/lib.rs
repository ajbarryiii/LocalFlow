//! Typing text as key presses through the desktop's keyboard layout, for
//! the text outputs that cannot upload their own keymap: libei (through the
//! RemoteDesktop portal, in `lf-portal`) and the kernel's uinput
//! ([`uinput`]).
//!
//! - [`layout`] maps characters to keys and modifiers through an XKB layout.
//! - [`type_strokes`] sends those strokes to a [`KeySink`] under the same
//!   rules as the Wayland virtual keyboard (`lf-wayland`): a pause after
//!   each character, every wait bounded, and the whole call bounded by one
//!   deadline.
//!
//! Privacy: text is never logged, persisted or included in errors; errors
//! name character positions only.

pub mod layout;
pub mod uinput;

use std::time::{Duration, Instant};

use lf_io_api::IoError;
use lf_io_api::sys::{pause, wait_budget};

pub use layout::{Layout, Rmlvo, Stroke, Token};

/// Keys sent between round trips with the receiver (see [`KeySink::sync`]),
/// so a fast sender cannot run far ahead of it.
pub const STROKES_PER_SYNC: usize = 32;

/// Where key events go.
pub trait KeySink {
    /// Queues one key event (an evdev code, pressed or released) as a frame
    /// of its own.
    fn key(&mut self, code: u32, pressed: bool) -> Result<(), IoError>;

    /// Sends everything queued, waiting at most until `deadline`.
    fn flush(&mut self, deadline: Instant) -> Result<(), IoError>;

    /// Waits until the receiver has processed everything sent, at most until
    /// `deadline`. The default only flushes.
    fn sync(&mut self, deadline: Instant) -> Result<(), IoError> {
        self.flush(deadline)
    }
}

/// Timing for [`type_strokes`].
#[derive(Clone, Copy, Debug)]
pub struct Pace {
    /// Pause after each stroke (modifiers, press and release).
    pub key_delay: Duration,
    /// Upper bound for any single wait on the receiver.
    pub timeout: Duration,
    /// Deadline for the whole call, if any.
    pub deadline: Option<Instant>,
}

/// Types `strokes`: for each, presses its modifiers, taps its key, releases
/// the modifiers in reverse, flushes, and pauses for the key delay (never
/// past the deadline). Syncs every [`STROKES_PER_SYNC`] strokes and at the
/// end. A failure leaves keys possibly held; callers drop the device or
/// connection then, which releases them.
pub fn type_strokes(sink: &mut dyn KeySink, strokes: &[Stroke], pace: Pace) -> Result<(), IoError> {
    let until = |pace: &Pace| -> Result<Instant, IoError> {
        let now = Instant::now();
        Ok(now + wait_budget(pace.timeout, pace.deadline, now)?)
    };
    for (i, stroke) in strokes.iter().enumerate() {
        let deadline = until(&pace)?;
        for &m in &stroke.mods {
            sink.key(m, true)?;
        }
        sink.key(stroke.code, true)?;
        sink.key(stroke.code, false)?;
        for &m in stroke.mods.iter().rev() {
            sink.key(m, false)?;
        }
        sink.flush(deadline)?;
        pause(pace.key_delay, pace.deadline);
        if (i + 1) % STROKES_PER_SYNC == 0 {
            sink.sync(until(&pace)?)?;
        }
    }
    sink.sync(until(&pace)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Recorder {
        events: Vec<(u32, bool)>,
        flushes: usize,
        syncs: usize,
    }

    impl KeySink for Recorder {
        fn key(&mut self, code: u32, pressed: bool) -> Result<(), IoError> {
            self.events.push((code, pressed));
            Ok(())
        }
        fn flush(&mut self, _: Instant) -> Result<(), IoError> {
            self.flushes += 1;
            Ok(())
        }
        fn sync(&mut self, _: Instant) -> Result<(), IoError> {
            self.syncs += 1;
            Ok(())
        }
    }

    fn pace(delay_ms: u64, deadline: Option<Instant>) -> Pace {
        Pace {
            key_delay: Duration::from_millis(delay_ms),
            timeout: Duration::from_secs(1),
            deadline,
        }
    }

    #[test]
    fn modifiers_wrap_the_key_and_release_in_reverse() {
        let mut r = Recorder::default();
        let strokes = [
            Stroke {
                mods: vec![],
                code: 30,
            },
            Stroke {
                mods: vec![42, 100],
                code: 16,
            },
        ];
        type_strokes(&mut r, &strokes, pace(0, None)).unwrap();
        assert_eq!(
            r.events,
            vec![
                (30, true),
                (30, false),
                (42, true),
                (100, true),
                (16, true),
                (16, false),
                (100, false),
                (42, false)
            ]
        );
        assert_eq!(r.flushes, 2);
        assert_eq!(r.syncs, 1);
    }

    #[test]
    fn syncs_every_few_strokes() {
        let mut r = Recorder::default();
        let strokes = vec![
            Stroke {
                mods: vec![],
                code: 30
            };
            STROKES_PER_SYNC * 2 + 1
        ];
        type_strokes(&mut r, &strokes, pace(0, None)).unwrap();
        assert_eq!(r.syncs, 3);
        assert_eq!(r.flushes, STROKES_PER_SYNC * 2 + 1);
    }

    #[test]
    fn key_delay_never_outlasts_the_deadline() {
        let mut r = Recorder::default();
        let strokes = vec![
            Stroke {
                mods: vec![],
                code: 30
            };
            20
        ];
        let start = Instant::now();
        let err = type_strokes(
            &mut r,
            &strokes,
            pace(50, Some(start + Duration::from_millis(120))),
        )
        .unwrap_err();
        let took = start.elapsed();
        assert!(err.0.contains("time limit"), "{err}");
        assert!(took < Duration::from_millis(400), "{took:?}");
        // Some strokes went out before the deadline, not all.
        assert!(!r.events.is_empty() && r.events.len() < 40);
    }
}

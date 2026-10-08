//! Desktop backends for `localflowd`: PipeWire microphone capture
//! (`lf-pipewire`), Wayland virtual-keyboard typing (`lf-wayland`) and MPRIS
//! media players (`lf-media`), all behind the `lf-io-api` traits.
//!
//! Logging: `lf-wayland` routes `wayland-backend` diagnostics, which can quote
//! compositor messages, to the `log` facade. This daemon installs no `log`
//! logger (it has its own `crate::log`), so those messages are discarded. Keep
//! it that way, or filter the `wayland_backend` target at every level.
//! `WAYLAND_DEBUG` would print the protocol stream (including keys derived
//! from typed text) straight to stderr; `localflowd` clears it at startup.
//! `zbus` (media players) reports through `tracing`, which likewise has no
//! subscriber here.

use std::time::Duration;

use lf_io_api::{AudioCapture, MediaPlayers, TextOutput};
use lf_media::{Mpris, MprisConfig};
use lf_pipewire::{CaptureConfig, Overflow, PipeWireCapture};
use lf_wayland::{TyperConfig, WaylandTyper};

use crate::config::Config;
use crate::warn;

pub type Backends = (Box<dyn AudioCapture>, Box<dyn TextOutput>);

/// Seconds of audio the capture keeps beyond the daemon's own recording
/// limit, so the daemon's limit (which stops and transcribes) acts first.
const CAPTURE_MARGIN_SECONDS: f64 = 2.0;

/// Capture settings for `config`: the configured input (or the default
/// source), and a memory bound just above the daemon's recording limit but
/// never above what the recognizer accepts.
pub fn capture_config(config: &Config) -> CaptureConfig {
    let max =
        (config.max_recording_seconds + CAPTURE_MARGIN_SECONDS).min(lf_asr::MAX_SECONDS as f64);
    CaptureConfig {
        target: config.input_device.clone(),
        max_duration: Duration::from_secs_f64(max),
        overflow: Overflow::Truncate,
        ..CaptureConfig::default()
    }
}

/// Upper bound for any single wait on the compositor. A local compositor
/// answers a round trip in well under a millisecond.
const COMPOSITOR_TIMEOUT: Duration = Duration::from_secs(1);

/// Upper bound for one whole output call, all waits and key delays
/// included. Typing runs under the cancel lock, so this bounds how long a
/// cancel can wait even when the compositor hangs; it stays well below
/// `localflowctl`'s 6 s deadline. A normal piece needs at most about 100 ms
/// of key delays (see `worker::chunk_chars_for_key_delay`).
pub const OUTPUT_CALL_TIMEOUT: Duration = Duration::from_secs(2);

pub fn typer_config(config: &Config) -> TyperConfig {
    TyperConfig {
        key_delay: Duration::from_millis(config.key_delay_ms),
        timeout: COMPOSITOR_TIMEOUT,
        call_timeout: Some(OUTPUT_CALL_TIMEOUT),
        ..TyperConfig::default()
    }
}

/// The real desktop backends. Nothing is opened yet: the microphone opens on
/// the first recording. The compositor connection is tried once here so a
/// missing virtual-keyboard protocol shows up at startup, but a failure is
/// only a warning because the typer reconnects on first use (the compositor
/// may start after the daemon).
pub fn desktop(config: &Config) -> Backends {
    let mut typer = WaylandTyper::new(typer_config(config));
    if let Err(e) = typer.connect() {
        warn!("text output not available yet ({e}); will retry when typing");
    }
    (
        Box::new(PipeWireCapture::new(capture_config(config))),
        Box::new(typer),
    )
}

/// Upper bound for one D-Bus call to the bus or a media player. A player
/// that hangs costs the media thread this much per call, never the control
/// loop.
pub const MEDIA_CALL_TIMEOUT: Duration = Duration::from_millis(250);

/// Upper bound for connecting to the session bus.
pub const MEDIA_CONNECT_TIMEOUT: Duration = Duration::from_secs(1);

/// MPRIS players on the session bus. Nothing is opened yet: the media
/// thread connects when it starts.
pub fn media() -> Box<dyn MediaPlayers> {
    Box::new(Mpris::new(MprisConfig {
        address: None,
        call_timeout: MEDIA_CALL_TIMEOUT,
        connect_timeout: MEDIA_CONNECT_TIMEOUT,
    }))
}

/// Records silence for as long as a recording lasts and discards text.
/// Never opens a microphone or touches the desktop.
pub fn fake() -> Backends {
    (
        Box::new(crate::testing::SilenceCapture::default()),
        Box::new(crate::testing::DiscardOutput),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn capture_bound_follows_the_recording_limit() {
        let mut c = Config::defaults(Path::new("/data/localflow"));
        c.max_recording_seconds = 120.0;
        c.input_device = Some("synthetic.node".into());
        let cc = capture_config(&c);
        assert_eq!(cc.max_duration, Duration::from_secs(122));
        assert_eq!(cc.target.as_deref(), Some("synthetic.node"));
        assert!(matches!(cc.overflow, Overflow::Truncate));
        // Never above the recognizer's limit.
        c.max_recording_seconds = lf_asr::MAX_SECONDS as f64;
        assert_eq!(
            capture_config(&c).max_duration,
            Duration::from_secs(lf_asr::MAX_SECONDS as u64)
        );
    }

    #[test]
    fn key_delay_comes_from_config() {
        let mut c = Config::defaults(Path::new("/data/localflow"));
        c.key_delay_ms = 7;
        let t = typer_config(&c);
        assert_eq!(t.key_delay, Duration::from_millis(7));
        assert_eq!(t.timeout, COMPOSITOR_TIMEOUT);
        assert_eq!(t.call_timeout, Some(OUTPUT_CALL_TIMEOUT));
        // Even the slowest legal piece fits the call budget many times over.
        let max_delay = crate::config::MAX_KEY_DELAY_MS;
        let piece = crate::worker::chunk_chars_for_key_delay(max_delay) as u64;
        assert!(Duration::from_millis(piece * max_delay) * 10 <= OUTPUT_CALL_TIMEOUT);
    }
}

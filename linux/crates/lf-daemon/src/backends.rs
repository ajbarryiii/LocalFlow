//! Desktop backends for `localflowd`: PipeWire microphone capture
//! (`lf-pipewire`), typing (the Wayland virtual keyboard in `lf-wayland`, the
//! RemoteDesktop portal and libei in `lf-portal`, or uinput in
//! `lf-keyboard`; see [`select_output`]) and MPRIS media players
//! (`lf-media`), all behind the `lf-io-api` traits.
//!
//! Logging: `lf-wayland` routes `wayland-backend` diagnostics, which can quote
//! compositor messages, to the `log` facade. This daemon installs no `log`
//! logger (it has its own `crate::log`), so those messages are discarded. Keep
//! it that way, or filter the `wayland_backend` target at every level.
//! `WAYLAND_DEBUG` would print the protocol stream (including keys derived
//! from typed text) straight to stderr; `localflowd` clears it at startup.
//! `zbus` (media players, the portal) reports through `tracing`, which
//! likewise has no subscriber here. `reis` (libei) would print every protocol
//! message, keys included, to stderr if `REIS_DEBUG` were set; `localflowd`
//! clears that too.

use std::path::Path;
use std::time::Duration;

use lf_io_api::{AudioCapture, MediaPlayers, TextOutput};
use lf_keyboard::uinput::{UinputConfig, UinputTyper};
use lf_media::{Mpris, MprisConfig};
use lf_pipewire::{CaptureConfig, Overflow, PipeWireCapture};
use lf_portal::{PortalConfig, PortalTyper, Timeouts};
use lf_wayland::{TyperConfig, WaylandTyper};

use crate::config::{Config, Output};
use crate::portal_token::FileTokenStore;
use crate::{info, paths, warn};

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

/// Portal calls that need no user action (each one, and connecting).
const PORTAL_CALL_TIMEOUT: Duration = Duration::from_secs(5);

/// How long the portal's permission dialog may stay unanswered before the
/// request is withdrawn (the next dictation asks again).
const PORTAL_PERMISSION_TIMEOUT: Duration = Duration::from_secs(300);

/// Upper bound for the startup probe of the RemoteDesktop portal.
const PORTAL_PROBE_TIMEOUT: Duration = Duration::from_secs(2);

pub fn portal_config(config: &Config) -> PortalConfig {
    PortalConfig {
        address: None,
        key_delay: Duration::from_millis(config.key_delay_ms),
        timeout: COMPOSITOR_TIMEOUT,
        call_timeout: Some(OUTPUT_CALL_TIMEOUT),
        portal: Timeouts {
            call: PORTAL_CALL_TIMEOUT,
            permission: PORTAL_PERMISSION_TIMEOUT,
        },
        fallback_layout: config.keyboard_layout.clone(),
    }
}

pub fn uinput_config(config: &Config) -> UinputConfig {
    UinputConfig {
        layout: config.keyboard_layout.clone(),
        key_delay: Duration::from_millis(config.key_delay_ms),
        timeout: COMPOSITOR_TIMEOUT,
        call_timeout: Some(OUTPUT_CALL_TIMEOUT),
        ..UinputConfig::default()
    }
}

/// The text output backends.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutputKind {
    Wayland,
    Portal,
    Uinput,
}

impl OutputKind {
    pub fn describe(self) -> &'static str {
        match self {
            OutputKind::Wayland => "Wayland virtual keyboard",
            OutputKind::Portal => "RemoteDesktop portal (libei)",
            OutputKind::Uinput => "uinput keyboard",
        }
    }
}

/// What the startup probe found about the Wayland virtual keyboard.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VirtualKeyboard {
    /// The compositor advertises `zwp_virtual_keyboard_manager_v1`.
    Available,
    /// The compositor answered without it (GNOME, KDE).
    Missing,
    /// A Wayland display is configured but did not answer (it may still be
    /// starting).
    Unreachable,
    /// No Wayland display is configured (X11, or no session).
    NoDisplay,
}

/// The checks behind `output: "auto"`. None of them types, creates a
/// device or session, or shows anything to the user.
pub trait OutputProbe {
    fn virtual_keyboard(&mut self) -> VirtualKeyboard;
    /// Whether a usable RemoteDesktop portal is on the session bus.
    fn remote_desktop_portal(&mut self) -> bool;
    /// Whether `/dev/uinput` can be opened for writing.
    fn uinput_writable(&mut self) -> bool;
}

/// The output to use and why (for the log; no content).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Selection {
    pub kind: OutputKind,
    pub reason: &'static str,
    /// No backend was found usable; this one is a fallback that will report
    /// its own error when typing.
    pub fallback: bool,
}

/// Picks the text output. An explicit choice is taken as is, without
/// probing. `auto` probes in order and stops at the first usable one: the
/// virtual keyboard (also when the compositor is configured but not
/// answering yet, as before `auto` existed), then the RemoteDesktop portal,
/// then uinput. The clipboard is never used.
pub fn select_output(choice: Output, probe: &mut dyn OutputProbe) -> Selection {
    let pick = |kind, reason| Selection {
        kind,
        reason,
        fallback: false,
    };
    match choice {
        Output::Wayland => return pick(OutputKind::Wayland, "configured"),
        Output::Portal => return pick(OutputKind::Portal, "configured"),
        Output::Uinput => return pick(OutputKind::Uinput, "configured"),
        Output::Auto => {}
    }
    match probe.virtual_keyboard() {
        VirtualKeyboard::Available => {
            return pick(
                OutputKind::Wayland,
                "auto: the compositor offers the virtual keyboard protocol",
            );
        }
        VirtualKeyboard::Unreachable => {
            return pick(
                OutputKind::Wayland,
                "auto: the Wayland compositor is not answering yet",
            );
        }
        VirtualKeyboard::Missing | VirtualKeyboard::NoDisplay => {}
    }
    if probe.remote_desktop_portal() {
        return pick(
            OutputKind::Portal,
            "auto: no virtual keyboard protocol; the RemoteDesktop portal is available",
        );
    }
    if probe.uinput_writable() {
        return pick(
            OutputKind::Uinput,
            "auto: no virtual keyboard protocol or RemoteDesktop portal; /dev/uinput is writable",
        );
    }
    Selection {
        kind: OutputKind::Wayland,
        reason: "auto: no virtual keyboard protocol, RemoteDesktop portal or writable /dev/uinput",
        fallback: true,
    }
}

/// The real probes.
struct DesktopProbe<'a> {
    typer: &'a TyperConfig,
}

impl OutputProbe for DesktopProbe<'_> {
    fn virtual_keyboard(&mut self) -> VirtualKeyboard {
        if std::env::var_os("WAYLAND_DISPLAY").is_none()
            && std::env::var_os("WAYLAND_SOCKET").is_none()
        {
            return VirtualKeyboard::NoDisplay;
        }
        match lf_wayland::advertises_virtual_keyboard(self.typer) {
            Ok(true) => VirtualKeyboard::Available,
            Ok(false) => VirtualKeyboard::Missing,
            Err(_) => VirtualKeyboard::Unreachable,
        }
    }

    fn remote_desktop_portal(&mut self) -> bool {
        lf_portal::probe(None, PORTAL_PROBE_TIMEOUT).unwrap_or(false)
    }

    fn uinput_writable(&mut self) -> bool {
        lf_keyboard::uinput::writable(Path::new(lf_keyboard::uinput::DEFAULT_PATH))
    }
}

/// The real desktop backends. Nothing is opened yet: the microphone opens on
/// the first recording. The text output is chosen by `output` (see
/// [`select_output`]) and set up once here so problems show at startup, but
/// a failure is only a warning because each output retries on first use
/// (the compositor may start after the daemon). Fails only if the uinput
/// output's layout cannot be compiled.
pub fn desktop(config: &Config) -> Result<Backends, String> {
    let typer_config = typer_config(config);
    let selection = select_output(
        config.output,
        &mut DesktopProbe {
            typer: &typer_config,
        },
    );
    if selection.fallback {
        warn!(
            "text output: {} ({}); typing will fail until one is available",
            selection.kind.describe(),
            selection.reason
        );
    } else {
        info!(
            "text output: {} ({})",
            selection.kind.describe(),
            selection.reason
        );
    }
    let output: Box<dyn TextOutput> = match selection.kind {
        OutputKind::Wayland => {
            let mut typer = WaylandTyper::new(typer_config);
            if let Err(e) = typer.connect() {
                warn!("text output not available yet ({e}); will retry when typing");
            }
            Box::new(typer)
        }
        OutputKind::Portal => {
            let store = FileTokenStore::new(paths::state_dir()?);
            let mut typer = PortalTyper::new(portal_config(config), Box::new(store));
            // In the background: a first run may show a permission dialog.
            typer.connect();
            Box::new(typer)
        }
        OutputKind::Uinput => {
            let mut typer = UinputTyper::new(uinput_config(config))
                .map_err(|e| format!("keyboard_layout: {e}"))?;
            if let Err(e) = typer.connect() {
                warn!("text output not available yet ({e}); will retry when typing");
            }
            Box::new(typer)
        }
    };
    Ok((
        Box::new(PipeWireCapture::new(capture_config(config))),
        output,
    ))
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

    /// Answers the `auto` probes and counts them.
    struct FakeProbe {
        vk: VirtualKeyboard,
        portal: bool,
        uinput: bool,
        calls: Vec<&'static str>,
    }

    impl FakeProbe {
        fn new(vk: VirtualKeyboard, portal: bool, uinput: bool) -> FakeProbe {
            FakeProbe {
                vk,
                portal,
                uinput,
                calls: Vec::new(),
            }
        }
    }

    impl OutputProbe for FakeProbe {
        fn virtual_keyboard(&mut self) -> VirtualKeyboard {
            self.calls.push("wayland");
            self.vk
        }
        fn remote_desktop_portal(&mut self) -> bool {
            self.calls.push("portal");
            self.portal
        }
        fn uinput_writable(&mut self) -> bool {
            self.calls.push("uinput");
            self.uinput
        }
    }

    #[test]
    fn auto_prefers_the_virtual_keyboard_then_the_portal_then_uinput() {
        use VirtualKeyboard::*;
        // (virtual keyboard, portal, uinput) -> choice, probes made.
        let cases: &[(VirtualKeyboard, bool, bool, OutputKind, &[&str])] = &[
            // Hyprland, sway, river: the portal and uinput are never probed.
            (Available, true, true, OutputKind::Wayland, &["wayland"]),
            // A configured compositor that is still starting: as before.
            (Unreachable, true, true, OutputKind::Wayland, &["wayland"]),
            // GNOME, KDE.
            (
                Missing,
                true,
                true,
                OutputKind::Portal,
                &["wayland", "portal"],
            ),
            (
                Missing,
                false,
                true,
                OutputKind::Uinput,
                &["wayland", "portal", "uinput"],
            ),
            // X11.
            (
                NoDisplay,
                true,
                false,
                OutputKind::Portal,
                &["wayland", "portal"],
            ),
            (
                NoDisplay,
                false,
                true,
                OutputKind::Uinput,
                &["wayland", "portal", "uinput"],
            ),
        ];
        for &(vk, portal, uinput, kind, calls) in cases {
            let mut p = FakeProbe::new(vk, portal, uinput);
            let s = select_output(Output::Auto, &mut p);
            assert_eq!(
                (s.kind, s.fallback),
                (kind, false),
                "{vk:?} {portal} {uinput}"
            );
            assert_eq!(p.calls, calls, "{vk:?} {portal} {uinput}");
        }
        // Nothing usable: the virtual keyboard, flagged as a fallback.
        let mut p = FakeProbe::new(Missing, false, false);
        let s = select_output(Output::Auto, &mut p);
        assert_eq!((s.kind, s.fallback), (OutputKind::Wayland, true));
    }

    #[test]
    fn an_explicit_output_is_used_without_probing() {
        for (choice, kind) in [
            (Output::Wayland, OutputKind::Wayland),
            (Output::Portal, OutputKind::Portal),
            (Output::Uinput, OutputKind::Uinput),
        ] {
            let mut p = FakeProbe::new(VirtualKeyboard::Available, true, true);
            let s = select_output(choice, &mut p);
            assert_eq!((s.kind, s.fallback), (kind, false));
            assert!(p.calls.is_empty());
        }
    }

    #[test]
    fn every_output_shares_the_typing_limits() {
        let mut c = Config::defaults(Path::new("/data/localflow"));
        c.key_delay_ms = 7;
        c.keyboard_layout.layout = "de".into();
        let p = portal_config(&c);
        assert_eq!(p.key_delay, Duration::from_millis(7));
        assert_eq!(p.call_timeout, Some(OUTPUT_CALL_TIMEOUT));
        assert_eq!(p.timeout, COMPOSITOR_TIMEOUT);
        assert_eq!(p.fallback_layout.layout, "de");
        assert_eq!(p.address, None);
        let u = uinput_config(&c);
        assert_eq!(u.key_delay, Duration::from_millis(7));
        assert_eq!(u.call_timeout, Some(OUTPUT_CALL_TIMEOUT));
        assert_eq!(u.layout.layout, "de");
        // Creating the device and letting it settle fits in one call.
        assert!(u.settle * 2 <= OUTPUT_CALL_TIMEOUT);
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

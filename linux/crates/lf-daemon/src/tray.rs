//! `localflowctl tray`: a StatusNotifierItem tray icon showing the daemon's
//! state, from the same watch lines as `watch --waybar`. KDE, Waybar's
//! `tray` module and GNOME's AppIndicator extension show these items.
//!
//! - Served on the D-Bus session bus through `zbus` as
//!   `org.kde.StatusNotifierItem-<pid>-1`, object [`ITEM_PATH`], and
//!   registered with `org.kde.StatusNotifierWatcher`, again whenever a
//!   watcher appears (a tray host that starts later, or restarts).
//! - Icons are standard themed names ([`icon_name`]), so the icon theme
//!   draws them. While recording, `Status` is `NeedsAttention`.
//! - The title is "LocalFlow" and the tooltip says the state ("Recording"):
//!   state names only, never text, words or counts.
//! - Activating it does nothing; it has no menu.
//! - Every method call it makes (registering) waits at most
//!   [`CALL_TIMEOUT`] for the reply. zbus reports through `tracing`, and no
//!   subscriber is installed, so that output is discarded.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use zbus::blocking::Connection;
use zbus::blocking::connection::Builder;
use zbus::object_server::SignalEmitter;

use crate::waybar::Class;

pub const ITEM_PATH: &str = "/StatusNotifierItem";
pub const ITEM_INTERFACE: &str = "org.kde.StatusNotifierItem";
pub const WATCHER: &str = "org.kde.StatusNotifierWatcher";
pub const WATCHER_PATH: &str = "/StatusNotifierWatcher";
pub const TITLE: &str = "LocalFlow";

/// The longest wait for a reply to a call the tray makes.
pub const CALL_TIMEOUT: Duration = Duration::from_secs(5);

/// The themed icon for `class`.
pub fn icon_name(class: Class) -> &'static str {
    match class {
        Class::Idle | Class::Loading => "audio-input-microphone",
        Class::Recording => "media-record",
        Class::Transcribing | Class::Typing => "emblem-synchronizing",
        Class::NoMic => "microphone-sensitivity-muted",
        Class::Offline => "network-offline",
    }
}

/// The tooltip's text for `class`.
pub fn description(class: Class) -> &'static str {
    match class {
        Class::Idle => "Idle",
        Class::Loading => "Loading the model",
        Class::Recording => "Recording",
        Class::Transcribing => "Transcribing",
        Class::Typing => "Typing",
        Class::NoMic => "No microphone",
        Class::Offline => "Not running",
    }
}

/// The item's `Status` for `class`.
pub fn status(class: Class) -> &'static str {
    match class {
        Class::Recording => "NeedsAttention",
        _ => "Active",
    }
}

/// Why the tray cannot run. Never carries a remote error's text.
#[derive(Debug, PartialEq, Eq)]
pub enum TrayError {
    /// No session bus (or not the given address).
    Connect,
    /// The bus refused the item's name or object.
    Serve,
    /// The connection to the bus was lost.
    Lost,
}

impl std::fmt::Display for TrayError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            TrayError::Connect => "cannot connect to the D-Bus session bus",
            TrayError::Serve => "cannot publish the tray item on the session bus",
            TrayError::Lost => "lost the connection to the D-Bus session bus",
        })
    }
}

fn lock(m: &Mutex<Class>) -> MutexGuard<'_, Class> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// The D-Bus object.
struct Item {
    shown: Arc<Mutex<Class>>,
}

impl Item {
    fn class(&self) -> Class {
        *lock(&self.shown)
    }
}

/// The pixmaps of an icon or tooltip: none, the themed name is used.
type Pixmaps = Vec<(i32, i32, Vec<u8>)>;

#[zbus::interface(name = "org.kde.StatusNotifierItem")]
impl Item {
    #[zbus(property)]
    fn category(&self) -> String {
        "ApplicationStatus".into()
    }

    #[zbus(property)]
    fn id(&self) -> String {
        "localflow".into()
    }

    #[zbus(property)]
    fn title(&self) -> String {
        TITLE.into()
    }

    #[zbus(property)]
    fn status(&self) -> String {
        status(self.class()).into()
    }

    #[zbus(property)]
    fn icon_name(&self) -> String {
        icon_name(self.class()).into()
    }

    #[zbus(property)]
    fn icon_pixmap(&self) -> Pixmaps {
        Vec::new()
    }

    #[zbus(property)]
    fn attention_icon_name(&self) -> String {
        icon_name(Class::Recording).into()
    }

    #[zbus(property)]
    fn tool_tip(&self) -> (String, Pixmaps, String, String) {
        let class = self.class();
        (
            icon_name(class).into(),
            Vec::new(),
            TITLE.into(),
            description(class).into(),
        )
    }

    #[zbus(property)]
    fn item_is_menu(&self) -> bool {
        false
    }

    fn activate(&self, _x: i32, _y: i32) {}

    fn secondary_activate(&self, _x: i32, _y: i32) {}

    fn context_menu(&self, _x: i32, _y: i32) {}

    fn scroll(&self, _delta: i32, _orientation: String) {}

    #[zbus(signal)]
    async fn new_icon(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn new_tool_tip(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn new_status(emitter: &SignalEmitter<'_>, status: &str) -> zbus::Result<()>;
}

/// A published tray item.
pub struct Tray {
    conn: Connection,
    name: String,
    shown: Arc<Mutex<Class>>,
    /// Set once the watcher follower sees the connection end.
    lost: Arc<AtomicBool>,
}

impl Tray {
    /// Publishes the item showing `initial` on the bus at `address` (the
    /// session bus when `None`), registers it, and keeps registering it
    /// with every watcher that appears. `on_lost` runs (on another thread)
    /// once the connection to the bus has ended.
    pub fn start(
        address: Option<&str>,
        initial: Class,
        on_lost: impl FnOnce() + Send + 'static,
    ) -> Result<Tray, TrayError> {
        let name = format!("org.kde.StatusNotifierItem-{}-1", std::process::id());
        let shown = Arc::new(Mutex::new(initial));
        let builder = match address {
            Some(a) => Builder::address(a),
            None => Builder::session(),
        }
        .map_err(|_| TrayError::Connect)?;
        let conn = builder
            .method_timeout(CALL_TIMEOUT)
            .serve_at(
                ITEM_PATH,
                Item {
                    shown: shown.clone(),
                },
            )
            .and_then(|b| b.name(name.as_str()))
            .map_err(|_| TrayError::Serve)?
            .build()
            .map_err(|e| match e {
                zbus::Error::NameTaken => TrayError::Serve,
                _ => TrayError::Connect,
            })?;
        // Subscribed before the first registration, so a watcher that
        // appears in between is not missed.
        let changes = zbus::blocking::fdo::DBusProxy::new(&conn)
            .and_then(|p| p.receive_name_owner_changed_with_args(&[(0, WATCHER)]))
            .map_err(|_| TrayError::Connect)?;
        // No watcher yet is fine: one that appears later is followed.
        let _ = register(&conn, &name);
        let lost = Arc::new(AtomicBool::new(false));
        {
            let (conn, name, lost) = (conn.clone(), name.clone(), lost.clone());
            std::thread::spawn(move || {
                for signal in changes {
                    if signal.args().is_ok_and(|a| a.new_owner().is_some()) {
                        let _ = register(&conn, &name);
                    }
                }
                lost.store(true, Ordering::Release);
                on_lost();
            });
        }
        Ok(Tray {
            conn,
            name,
            shown,
            lost,
        })
    }

    /// The item's bus name.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Shows `class`, telling hosts when anything changed.
    pub fn show(&self, class: Class) -> Result<(), TrayError> {
        if self.lost.load(Ordering::Acquire) {
            return Err(TrayError::Lost);
        }
        let old = std::mem::replace(&mut *lock(&self.shown), class);
        if old == class {
            return Ok(());
        }
        let emit = |member: &str| {
            self.conn
                .emit_signal(None::<&str>, ITEM_PATH, ITEM_INTERFACE, member, &())
                .map_err(|_| TrayError::Lost)
        };
        if icon_name(old) != icon_name(class) {
            emit("NewIcon")?;
        }
        emit("NewToolTip")?;
        if status(old) != status(class) {
            self.conn
                .emit_signal(
                    None::<&str>,
                    ITEM_PATH,
                    ITEM_INTERFACE,
                    "NewStatus",
                    &status(class),
                )
                .map_err(|_| TrayError::Lost)?;
        }
        Ok(())
    }

    /// False once the bus connection has ended.
    pub fn connected(&self) -> bool {
        !self.lost.load(Ordering::Acquire)
    }
}

fn register(conn: &Connection, name: &str) -> zbus::Result<()> {
    conn.call_method(
        Some(WATCHER),
        WATCHER_PATH,
        Some(WATCHER),
        "RegisterStatusNotifierItem",
        &name,
    )
    .map(drop)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_class_has_a_themed_icon_and_a_fixed_description() {
        for class in Class::ALL {
            let icon = icon_name(class);
            assert!(!icon.is_empty() && icon.bytes().all(|b| b.is_ascii_lowercase() || b == b'-'));
            assert!(!description(class).is_empty());
            assert_eq!(
                status(class),
                if class == Class::Recording {
                    "NeedsAttention"
                } else {
                    "Active"
                }
            );
        }
        assert_eq!(icon_name(Class::Idle), "audio-input-microphone");
        assert_eq!(icon_name(Class::Recording), "media-record");
        assert_eq!(icon_name(Class::Transcribing), "emblem-synchronizing");
        assert_eq!(icon_name(Class::NoMic), "microphone-sensitivity-muted");
        assert_eq!(icon_name(Class::Offline), "network-offline");
    }
}

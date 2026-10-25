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
//! - Activating it does nothing. Its menu ([`MENU_PATH`], `Menu`) is an
//!   empty `com.canonical.dbusmenu`: GNOME's AppIndicator extension shows
//!   no item without one.
//! - **Bounds.** Connecting (with authentication, the name and the
//!   subscription) must finish within [`CALL_TIMEOUT`]. Signals are sent on
//!   a thread of their own, so a bus that stops reading never holds up the
//!   caller; every method call it makes (registering) waits at most
//!   [`CALL_TIMEOUT`] for the reply.
//! - zbus reports through `tracing`, and no subscriber is installed, so
//!   that output is discarded.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::Duration;

use zbus::blocking::Connection;
use zbus::blocking::connection::Builder;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Str};

use crate::waybar::Class;

pub const ITEM_PATH: &str = "/StatusNotifierItem";
pub const ITEM_INTERFACE: &str = "org.kde.StatusNotifierItem";
pub const MENU_PATH: &str = "/MenuBar";
pub const MENU_INTERFACE: &str = "com.canonical.dbusmenu";
pub const WATCHER: &str = "org.kde.StatusNotifierWatcher";
pub const WATCHER_PATH: &str = "/StatusNotifierWatcher";
pub const TITLE: &str = "LocalFlow";

/// The longest wait for connecting, and for a reply to a call the tray
/// makes.
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
    /// No session bus (or not the given address), or it did not answer in
    /// time.
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

/// What the item shows, shared by the D-Bus object, [`Tray::show`] and the
/// signal thread.
struct State {
    class: Mutex<Shown>,
    changed: Condvar,
}

struct Shown {
    class: Class,
    /// The tray was dropped: the signal thread ends.
    closed: bool,
}

impl State {
    fn lock(&self) -> MutexGuard<'_, Shown> {
        self.class.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// The D-Bus object.
struct Item {
    state: Arc<State>,
}

impl Item {
    fn class(&self) -> Class {
        self.state.lock().class
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

    #[zbus(property)]
    fn menu(&self) -> OwnedObjectPath {
        ObjectPath::from_static_str_unchecked(MENU_PATH).into()
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

/// The item's menu: a root with no entries.
struct Menu;

/// A menu entry: id, properties, children.
type Layout = (i32, HashMap<String, OwnedValue>, Vec<OwnedValue>);

#[zbus::interface(name = "com.canonical.dbusmenu")]
impl Menu {
    #[zbus(property)]
    fn version(&self) -> u32 {
        3
    }

    #[zbus(property)]
    fn text_direction(&self) -> String {
        "ltr".into()
    }

    #[zbus(property)]
    fn status(&self) -> String {
        "normal".into()
    }

    #[zbus(property)]
    fn icon_theme_path(&self) -> Vec<String> {
        Vec::new()
    }

    fn get_layout(
        &self,
        _parent_id: i32,
        _recursion_depth: i32,
        _property_names: Vec<String>,
    ) -> (u32, Layout) {
        let props = HashMap::from([(
            "children-display".to_owned(),
            OwnedValue::from(Str::from_static("submenu")),
        )]);
        (1, (0, props, Vec::new()))
    }

    fn get_group_properties(
        &self,
        _ids: Vec<i32>,
        _property_names: Vec<String>,
    ) -> Vec<(i32, HashMap<String, OwnedValue>)> {
        Vec::new()
    }

    fn get_property(&self, _id: i32, _name: String) -> zbus::fdo::Result<OwnedValue> {
        Err(zbus::fdo::Error::InvalidArgs("no such menu item".into()))
    }

    fn event(&self, _id: i32, _event_id: String, _data: OwnedValue, _timestamp: u32) {}

    fn event_group(&self, _events: Vec<(i32, String, OwnedValue, u32)>) -> Vec<i32> {
        Vec::new()
    }

    fn about_to_show(&self, _id: i32) -> bool {
        false
    }

    fn about_to_show_group(&self, _ids: Vec<i32>) -> (Vec<i32>, Vec<i32>) {
        (Vec::new(), Vec::new())
    }
}

/// Runs `on_lost` once, whichever thread notices first.
type OnLost = Arc<Mutex<Option<Box<dyn FnOnce() + Send>>>>;

/// Marks the connection lost and runs `on_lost` (once).
fn lose(lost: &AtomicBool, on_lost: &OnLost) {
    lost.store(true, Ordering::Release);
    let f = on_lost.lock().unwrap_or_else(|e| e.into_inner()).take();
    if let Some(f) = f {
        f();
    }
}

/// A published tray item.
pub struct Tray {
    name: String,
    state: Arc<State>,
    /// Set once the connection to the bus has ended.
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
        let state = Arc::new(State {
            class: Mutex::new(Shown {
                class: initial,
                closed: false,
            }),
            changed: Condvar::new(),
        });
        let (conn, changes) = connect(address.map(String::from), name.clone(), state.clone())?;
        // No watcher yet is fine: one that appears later is followed.
        let _ = register(&conn, &name);
        let lost = Arc::new(AtomicBool::new(false));
        let on_lost: OnLost = Arc::new(Mutex::new(Some(Box::new(on_lost))));
        {
            let (conn, name, lost, on_lost) =
                (conn.clone(), name.clone(), lost.clone(), on_lost.clone());
            std::thread::spawn(move || {
                for signal in changes {
                    if signal.args().is_ok_and(|a| a.new_owner().is_some()) {
                        let _ = register(&conn, &name);
                    }
                }
                lose(&lost, &on_lost);
            });
        }
        {
            let (state, lost) = (state.clone(), lost.clone());
            std::thread::spawn(move || {
                if emit_changes(&conn, &state, initial).is_err() {
                    lose(&lost, &on_lost);
                }
            });
        }
        Ok(Tray { name, state, lost })
    }

    /// The item's bus name.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Shows `class`. Hosts are told on the signal thread, so this never
    /// waits on the bus.
    pub fn show(&self, class: Class) -> Result<(), TrayError> {
        if self.lost.load(Ordering::Acquire) {
            return Err(TrayError::Lost);
        }
        self.state.lock().class = class;
        self.state.changed.notify_one();
        Ok(())
    }

    /// False once the connection to the bus has ended.
    pub fn connected(&self) -> bool {
        !self.lost.load(Ordering::Acquire)
    }
}

impl Drop for Tray {
    fn drop(&mut self) {
        self.state.lock().closed = true;
        self.state.changed.notify_one();
    }
}

/// Connects, publishes the item and its menu under `name`, and subscribes
/// to watcher changes, all within [`CALL_TIMEOUT`]. A connection attempt
/// that does not finish in time is left to fail on its own thread.
fn connect(
    address: Option<String>,
    name: String,
    state: Arc<State>,
) -> Result<(Connection, zbus::blocking::fdo::NameOwnerChangedIterator), TrayError> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let attempt = || {
            let builder = match address {
                Some(a) => Builder::address(a.as_str()),
                None => Builder::session(),
            }
            .map_err(|_| TrayError::Connect)?;
            let conn = builder
                .method_timeout(CALL_TIMEOUT)
                .serve_at(ITEM_PATH, Item { state })
                .and_then(|b| b.serve_at(MENU_PATH, Menu))
                .and_then(|b| b.name(name))
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
            Ok((conn, changes))
        };
        let _ = tx.send(attempt());
    });
    rx.recv_timeout(CALL_TIMEOUT)
        .map_err(|_| TrayError::Connect)?
}

/// Tells hosts about every change of what the item shows, from `shown`
/// on, until the tray is dropped or a send fails.
fn emit_changes(conn: &Connection, state: &State, mut shown: Class) -> zbus::Result<()> {
    let emit =
        |member: &str| conn.emit_signal(None::<&str>, ITEM_PATH, ITEM_INTERFACE, member, &());
    loop {
        let now = {
            let mut s = state.lock();
            while s.class == shown && !s.closed {
                s = state.changed.wait(s).unwrap_or_else(|e| e.into_inner());
            }
            if s.closed {
                return Ok(());
            }
            s.class
        };
        if icon_name(shown) != icon_name(now) {
            emit("NewIcon")?;
        }
        emit("NewToolTip")?;
        if status(shown) != status(now) {
            conn.emit_signal(
                None::<&str>,
                ITEM_PATH,
                ITEM_INTERFACE,
                "NewStatus",
                &status(now),
            )?;
        }
        shown = now;
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

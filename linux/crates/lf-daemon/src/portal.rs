//! Dictation shortcuts through the xdg-desktop-portal GlobalShortcuts
//! interface (config `trigger: "portal"`), for desktops whose own binds
//! cannot run a command on key release (GNOME, KDE).
//!
//! - A thread of its own connects to the session bus, registers the host
//!   app ID ([`APP_ID`], `org.freedesktop.host.portal.Registry`, where the
//!   portal has it), creates a session and binds two shortcuts:
//!   [`HOLD_ID`] and [`TOGGLE_ID`]. The desktop asks the user for the keys.
//! - `Activated`/`Deactivated` of [`HOLD_ID`] become `press`/`release`, and
//!   `Activated` of [`TOGGLE_ID`] becomes `toggle`. They enter the control
//!   loop as [`Event::Request`]s stamped with `CLOCK_MONOTONIC` on arrival,
//!   exactly like `localflowctl`'s, so hold, toggle, Hold to Prompt
//!   (double-tap and hold) and the minimum length follow the same rules.
//!   The signal's own timestamp has an undefined base and is not used.
//! - Only signals sent by the portal's current owner (its unique name) for
//!   this session count; other clients on the bus cannot press the key.
//! - A `Deactivated` is passed on only after this session's `Activated`,
//!   so it never ends a hold started through `localflowctl`.
//! - **Session loss** (the portal closes the session, the portal exits or
//!   restarts, or the bus connection drops) during a hold counts as the
//!   release. The daemon cannot tell when the key comes up any more, and
//!   `release` is the narrowest existing command that ends the recording:
//!   it stops only a hold, keeps what was said (transcribed and typed, as
//!   if the key came up then), and is ignored while transcribing, typing
//!   or in toggle mode. `cancel` would also abandon a transcription or a
//!   toggle recording the portal never started. A toggle recording keeps
//!   running; it ends with the next toggle from either path.
//! - After a loss (also of a session closed while binding), a failed
//!   `CreateSession`, or while the portal (or its GlobalShortcuts
//!   interface) is missing, the thread tries again with exponential backoff
//!   ([`Setting::retry`] up to [`Setting::max_retry`]), on a fresh
//!   connection. A binding the user cancelled, or that the portal refused,
//!   is not asked for again until the daemon restarts, so a dialog never
//!   reappears by itself.
//! - None of this stops the daemon: `localflowctl` keeps working.
//! - Logs carry shortcut IDs, counts and D-Bus error names, never key names
//!   or other text from the portal.

use std::collections::HashMap;
use std::future::Future;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use futures_lite::{StreamExt, future, stream};
use zbus::connection::Builder;
use zbus::message::Type;
use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};
use zbus::{Connection, MatchRule, Message, MessageStream};

use crate::daemon::Event;
use crate::protocol::{Command, Request, monotonic_ns};

/// The host app ID, registered where the portal supports it. It matches
/// `packaging/com.ajbarryiii.localflow.desktop`, which desktops use for
/// the name shown in their shortcut dialog.
pub const APP_ID: &str = "com.ajbarryiii.localflow";
/// Hold to talk: press starts recording, release stops and types.
pub const HOLD_ID: &str = "hold-to-talk";
/// Each activation starts or stops recording.
pub const TOGGLE_ID: &str = "toggle";

const PORTAL: &str = "org.freedesktop.portal.Desktop";
const DESKTOP_PATH: &str = "/org/freedesktop/portal/desktop";
const SHORTCUTS: &str = "org.freedesktop.portal.GlobalShortcuts";
const REQUEST: &str = "org.freedesktop.portal.Request";
const SESSION: &str = "org.freedesktop.portal.Session";
const REGISTRY: &str = "org.freedesktop.host.portal.Registry";
const PROPERTIES: &str = "org.freedesktop.DBus.Properties";
const BUS: &str = "org.freedesktop.DBus";
const BUS_PATH: &str = "/org/freedesktop/DBus";

/// Signals queued before they are read; a burst beyond it is lost.
const MAX_QUEUED: usize = 64;

#[derive(Clone, Debug)]
pub struct Setting {
    /// A D-Bus address; `None` means the session bus
    /// (`DBUS_SESSION_BUS_ADDRESS`, else `$XDG_RUNTIME_DIR/bus`).
    pub address: Option<String>,
    /// Upper bound for connecting and for each method call (the first may
    /// start the portal through D-Bus activation). Waiting for the user to
    /// answer the binding dialog is not bounded.
    pub call_timeout: Duration,
    /// First delay before trying again; doubled after each failure.
    pub retry: Duration,
    pub max_retry: Duration,
}

impl Default for Setting {
    fn default() -> Setting {
        Setting {
            address: None,
            call_timeout: Duration::from_secs(10),
            retry: Duration::from_secs(1),
            max_retry: Duration::from_secs(60),
        }
    }
}

/// Owns the portal thread. Dropping it stops the thread without waiting.
pub struct Portal {
    /// Never sent on; dropping it wakes the thread, which then ends.
    stop: Option<async_channel::Sender<()>>,
    /// Disconnects when the thread ends (also on a panic).
    done: Receiver<()>,
    thread: Option<JoinHandle<()>>,
}

impl Portal {
    /// Stops the thread and waits up to `timeout` for it. Returns whether it
    /// ended. Closing its connection ends the portal session.
    pub fn stop(mut self, timeout: Duration) -> bool {
        self.stop.take();
        match self.done.recv_timeout(timeout) {
            Err(RecvTimeoutError::Disconnected) | Ok(()) => {
                if let Some(t) = self.thread.take() {
                    let _ = t.join();
                }
                true
            }
            Err(RecvTimeoutError::Timeout) => {
                crate::warn!("global shortcuts: still busy at shutdown; not waiting");
                false
            }
        }
    }
}

/// Starts the portal thread; it sends key events to `events` (the control
/// loop) until stopped.
pub fn spawn(setting: Setting, events: Sender<Event>) -> std::io::Result<Portal> {
    let (stop, stopping) = async_channel::bounded::<()>(1);
    let (done_tx, done) = mpsc::channel::<()>();
    let thread = std::thread::Builder::new()
        .name("lf-portal".into())
        .spawn(move || {
            let _done = done_tx;
            run(&setting, &events, &stopping);
        })?;
    Ok(Portal {
        stop: Some(stop),
        done,
        thread: Some(thread),
    })
}

/// How a session attempt ended.
#[derive(Debug, PartialEq, Eq)]
enum End {
    Stopped,
    /// The portal could not be reached or used; nothing was bound.
    Unavailable(String),
    /// The user cancelled the binding, or the portal refused it.
    Refused(&'static str),
    /// A bound session ended after `bound_for`.
    Lost {
        why: &'static str,
        bound_for: Duration,
    },
}

fn run(setting: &Setting, events: &Sender<Event>, stop: &async_channel::Receiver<()>) {
    let mut delay = setting.retry;
    // Warn about an outage once; repeats go to debug.
    let mut quiet = false;
    loop {
        let mut keys = Keys {
            events,
            held: false,
        };
        // Stopping drops the session wherever it is, its connection with it.
        let end = async_io::block_on(future::or(session(setting, &mut keys), async {
            stopped(stop).await;
            End::Stopped
        }));
        if keys.held && end != End::Stopped {
            // Never leave a recording open after the session is gone.
            keys.held = false;
            keys.forward(Command::Release);
            crate::info!("global shortcuts: released the held dictation key");
        }
        match end {
            End::Stopped => return,
            End::Unavailable(why) => {
                if quiet {
                    crate::debug!("global shortcuts unavailable: {why}");
                } else {
                    crate::warn!(
                        "global shortcuts unavailable: {why}; trying again in the background \
                         (localflowctl commands still work)"
                    );
                    quiet = true;
                }
            }
            End::Refused(why) => {
                crate::warn!(
                    "global shortcuts not bound: {why}; restart localflowd to ask again \
                     (localflowctl commands still work)"
                );
                return;
            }
            End::Lost { why, bound_for } => {
                quiet = false;
                if bound_for >= setting.max_retry {
                    delay = setting.retry;
                }
                crate::info!(
                    "global shortcuts: {why}; binding again in {:.1} s",
                    delay.as_secs_f64()
                );
            }
        }
        if sleep_unless_stopped(delay, stop) {
            return;
        }
        delay = (delay * 2).min(setting.max_retry);
    }
}

/// Key events on their way to the control loop.
struct Keys<'a> {
    events: &'a Sender<Event>,
    /// This session's hold shortcut is down.
    held: bool,
}

impl Keys<'_> {
    /// Hands `command` to the control loop, stamped now like a
    /// `localflowctl` request. The reply is not needed.
    fn forward(&self, command: Command) {
        let (reply, _) = mpsc::channel();
        let request = Request {
            command,
            at: Some(monotonic_ns()),
            args: Default::default(),
        };
        let _ = self.events.send(Event::Request(request, reply.into()));
    }

    fn activated(&mut self, id: &str) {
        match id {
            HOLD_ID => {
                self.held = true;
                self.forward(Command::Press);
            }
            TOGGLE_ID => self.forward(Command::Toggle),
            _ => {}
        }
    }

    fn deactivated(&mut self, id: &str) {
        if id == HOLD_ID && self.held {
            self.held = false;
            self.forward(Command::Release);
        }
    }
}

/// Resolves once [`Portal`] is stopped or dropped.
async fn stopped(stop: &async_channel::Receiver<()>) {
    while stop.recv().await.is_ok() {}
}

/// Returns true if stopped.
fn sleep_unless_stopped(d: Duration, stop: &async_channel::Receiver<()>) -> bool {
    async_io::block_on(future::or(
        async {
            async_io::Timer::after(d).await;
            false
        },
        async {
            stopped(stop).await;
            true
        },
    ))
}

/// `fut`, or `None` after `timeout`.
async fn bounded<T>(timeout: Duration, fut: impl Future<Output = T>) -> Option<T> {
    future::or(async { Some(fut.await) }, async {
        async_io::Timer::after(timeout).await;
        None
    })
    .await
}

/// The D-Bus error name of `e`, never a remote error message.
fn error_name(e: &zbus::Error) -> String {
    match e {
        zbus::Error::MethodError(name, _, _) => name.as_str().to_owned(),
        zbus::Error::InputOutput(_) => "I/O error".into(),
        _ => "D-Bus error".into(),
    }
}

/// Whether the error name from [`call`] means the method does not exist.
fn is_missing_method(e: &str) -> bool {
    matches!(
        e,
        "org.freedesktop.DBus.Error.UnknownMethod"
            | "org.freedesktop.DBus.Error.UnknownInterface"
            | "org.freedesktop.DBus.Error.UnknownObject"
    )
}

/// One call to the portal, bounded.
async fn call<B>(
    conn: &Connection,
    timeout: Duration,
    destination: &str,
    path: &str,
    interface: &str,
    method: &str,
    body: &B,
) -> Result<Message, String>
where
    B: zbus::export::serde::Serialize + zbus::zvariant::DynamicType,
{
    match bounded(
        timeout,
        conn.call_method(Some(destination), path, Some(interface), method, body),
    )
    .await
    {
        Some(Ok(reply)) => Ok(reply),
        Some(Err(e)) => Err(error_name(&e)),
        None => Err(format!("{interface}.{method} timed out")),
    }
}

/// The portal's signals and the bus's `NameOwnerChanged` for it, merged.
type Signals = stream::Or<MessageStream, MessageStream>;

/// The next signal; `None` once the connection closed or the stream failed.
async fn next(signals: &mut Signals, conn: &Connection) -> Option<Message> {
    future::or(async { signals.next().await.and_then(Result::ok) }, async {
        conn.closed().await;
        None
    })
    .await
}

/// Who sent `msg`, as a unique name (or `org.freedesktop.DBus`).
fn sender(msg: &Message) -> Option<String> {
    msg.header().sender().map(|s| s.as_str().to_owned())
}

fn member_is(msg: &Message, interface: &str, member: &str) -> bool {
    let h = msg.header();
    h.message_type() == Type::Signal
        && h.interface().is_some_and(|i| i.as_str() == interface)
        && h.member().is_some_and(|m| m.as_str() == member)
}

fn path(msg: &Message) -> Option<String> {
    msg.header().path().map(|p| p.as_str().to_owned())
}

/// Whether `msg` says the portal's name changed owner (it exited or
/// restarted), for the owner `owner`.
fn portal_gone(msg: &Message, owner: &str) -> bool {
    if !member_is(msg, BUS, "NameOwnerChanged") || sender(msg).as_deref() != Some(BUS) {
        return false;
    }
    match msg.body().deserialize::<(String, String, String)>() {
        Ok((name, _old, new)) => name == PORTAL && new != owner,
        Err(_) => false,
    }
}

/// Whether `msg` is the portal closing `session`.
fn closes(msg: &Message, session: &str) -> bool {
    member_is(msg, SESSION, "Closed") && path(msg).as_deref() == Some(session)
}

/// A Response's code and results, once it arrives on `paths`.
enum Answer {
    Response(u32, HashMap<String, OwnedValue>),
    End(End),
}

/// Waits for the `Request.Response` on one of `paths`, sent by `owner`.
/// Not bounded: it may wait for the user to answer a dialog. Ends early if
/// the portal exits or closes `session` (once there is one).
async fn response(
    signals: &mut Signals,
    conn: &Connection,
    owner: &str,
    session: Option<&str>,
    paths: &[&str],
) -> Answer {
    loop {
        let Some(msg) = next(signals, conn).await else {
            return Answer::End(End::Unavailable("the D-Bus connection closed".into()));
        };
        if portal_gone(&msg, owner) {
            return Answer::End(End::Unavailable("the portal exited".into()));
        }
        if sender(&msg).as_deref() != Some(owner) {
            continue;
        }
        if session.is_some_and(|s| closes(&msg, s)) {
            return Answer::End(End::Unavailable(
                "the portal closed the session while binding".into(),
            ));
        }
        if !member_is(&msg, REQUEST, "Response")
            || !path(&msg).is_some_and(|p| paths.contains(&p.as_str()))
        {
            continue;
        }
        return match msg
            .body()
            .deserialize::<(u32, HashMap<String, OwnedValue>)>()
        {
            Ok((code, results)) => Answer::Response(code, results),
            Err(_) => Answer::End(End::Unavailable(
                "the portal sent an invalid response".into(),
            )),
        };
    }
}

/// `/org/freedesktop/portal/desktop/request/SENDER/TOKEN`, where the
/// portal will answer a request made with `token`.
fn request_path(conn: &Connection, token: &str) -> String {
    let sender = conn
        .unique_name()
        .map(|n| n.as_str().trim_start_matches(':').replace('.', "_"))
        .unwrap_or_default();
    format!("{DESKTOP_PATH}/request/{sender}/{token}")
}

fn string(v: &Value<'_>) -> Option<String> {
    match v {
        Value::Str(s) => Some(s.as_str().to_owned()),
        Value::ObjectPath(p) => Some(p.as_str().to_owned()),
        Value::Value(inner) => string(inner),
        _ => None,
    }
}

/// The IDs in a `shortcuts` result (`a(sa{sv})`).
fn bound_ids(results: &HashMap<String, OwnedValue>) -> Vec<String> {
    let Some(Value::Array(items)) = results.get("shortcuts").map(|v| &**v) else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| match item {
            Value::Structure(s) => s.fields().first().and_then(string),
            _ => None,
        })
        .collect()
}

fn vardict<const N: usize>(entries: [(&str, Value<'static>); N]) -> HashMap<String, OwnedValue> {
    entries
        .into_iter()
        .filter_map(|(k, v)| v.try_into().ok().map(|v| (k.to_owned(), v)))
        .collect()
}

/// One portal session: connect, register, create, bind, then pass key
/// events on until it ends.
async fn session(setting: &Setting, keys: &mut Keys<'_>) -> End {
    let timeout = setting.call_timeout;
    let builder = match &setting.address {
        Some(a) => Builder::address(a.as_str()),
        None => Builder::session(),
    };
    let conn = match builder {
        Ok(b) => match bounded(timeout, b.build()).await {
            Some(Ok(c)) => c,
            Some(Err(_)) | None => {
                return End::Unavailable("cannot connect to the D-Bus session bus".into());
            }
        },
        Err(_) => return End::Unavailable("no D-Bus session bus address".into()),
    };
    // Subscribe before any request, so no answer can be missed.
    let rules = (
        MatchRule::builder()
            .msg_type(Type::Signal)
            .path_namespace(DESKTOP_PATH)
            .map(|b| b.build()),
        MatchRule::builder()
            .msg_type(Type::Signal)
            .interface(BUS)
            .and_then(|b| b.member("NameOwnerChanged"))
            .and_then(|b| b.arg(0, PORTAL))
            .map(|b| b.build()),
    );
    let (Ok(portal_rule), Ok(owner_rule)) = rules else {
        return End::Unavailable("invalid match rule".into());
    };
    let subscribe = async {
        let a = MessageStream::for_match_rule(portal_rule, &conn, Some(MAX_QUEUED)).await?;
        let b = MessageStream::for_match_rule(owner_rule, &conn, Some(MAX_QUEUED)).await?;
        Ok::<_, zbus::Error>(stream::or(a, b))
    };
    let mut signals = match bounded(timeout, subscribe).await {
        Some(Ok(s)) => s,
        Some(Err(e)) => return End::Unavailable(format!("cannot subscribe: {}", error_name(&e))),
        None => return End::Unavailable("subscribing timed out".into()),
    };

    // Register first: it must precede every other portal call. Portals
    // before 1.19 lack it and use an empty app ID.
    let no_options: HashMap<String, OwnedValue> = HashMap::new();
    match call(
        &conn,
        timeout,
        PORTAL,
        DESKTOP_PATH,
        REGISTRY,
        "Register",
        &(APP_ID, &no_options),
    )
    .await
    {
        Ok(_) => {}
        Err(e) if e == "org.freedesktop.DBus.Error.ServiceUnknown" => {
            return End::Unavailable("xdg-desktop-portal is not running".into());
        }
        Err(e) => crate::debug!("global shortcuts: app ID not registered: {e}"),
    }
    let owner = match call(
        &conn,
        timeout,
        BUS,
        BUS_PATH,
        BUS,
        "GetNameOwner",
        &(PORTAL,),
    )
    .await
    {
        Ok(reply) => match reply.body().deserialize::<String>() {
            Ok(o) => o,
            Err(_) => return End::Unavailable("invalid GetNameOwner reply".into()),
        },
        Err(_) => return End::Unavailable("xdg-desktop-portal is not running".into()),
    };
    if let Err(e) = call(
        &conn,
        timeout,
        PORTAL,
        DESKTOP_PATH,
        PROPERTIES,
        "Get",
        &(SHORTCUTS, "version"),
    )
    .await
    {
        return End::Unavailable(format!("the portal has no GlobalShortcuts interface ({e})"));
    }

    // CreateSession.
    let token = "localflow_create";
    let options = vardict([
        ("handle_token", Value::from(token)),
        ("session_handle_token", Value::from("localflow")),
    ]);
    let predicted = request_path(&conn, token);
    let returned = match call(
        &conn,
        timeout,
        PORTAL,
        DESKTOP_PATH,
        SHORTCUTS,
        "CreateSession",
        &(&options,),
    )
    .await
    {
        Ok(reply) => reply
            .body()
            .deserialize::<OwnedObjectPath>()
            .map(|p| p.as_str().to_owned())
            .unwrap_or_default(),
        Err(e) if is_missing_method(&e) => {
            return End::Unavailable("the portal has no GlobalShortcuts interface".into());
        }
        Err(e) => return End::Unavailable(format!("CreateSession failed ({e})")),
    };
    let session = match response(&mut signals, &conn, &owner, None, &[&predicted, &returned]).await
    {
        Answer::End(end) => return end,
        Answer::Response(0, results) => match results.get("session_handle").and_then(|v| string(v))
        {
            Some(s) => s,
            None => return End::Unavailable("the portal returned no session".into()),
        },
        // No dialog is involved, and the portal answers 2 when its backend
        // fails, so this is tried again.
        Answer::Response(code, _) => {
            return End::Unavailable(format!("CreateSession failed (response {code})"));
        }
    };
    let Ok(session_path) = ObjectPath::try_from(session.as_str()) else {
        return End::Unavailable("the portal returned an invalid session".into());
    };

    // BindShortcuts. No preferred keys: the desktop asks which to use. A
    // slice, since zvariant encodes a fixed-size array as a structure.
    let shortcuts: &[(&str, HashMap<String, OwnedValue>)] = &[
        (
            HOLD_ID,
            vardict([("description", Value::from("Hold to dictate"))]),
        ),
        (
            TOGGLE_ID,
            vardict([("description", Value::from("Start or stop dictation"))]),
        ),
    ];
    let token = "localflow_bind";
    let options = vardict([("handle_token", Value::from(token))]);
    let predicted = request_path(&conn, token);
    let returned = match call(
        &conn,
        timeout,
        PORTAL,
        DESKTOP_PATH,
        SHORTCUTS,
        "BindShortcuts",
        &(&session_path, shortcuts, "", &options),
    )
    .await
    {
        Ok(reply) => reply
            .body()
            .deserialize::<OwnedObjectPath>()
            .map(|p| p.as_str().to_owned())
            .unwrap_or_default(),
        Err(e) => return End::Unavailable(format!("BindShortcuts failed ({e})")),
    };
    match response(
        &mut signals,
        &conn,
        &owner,
        Some(&session),
        &[&predicted, &returned],
    )
    .await
    {
        Answer::End(end) => return end,
        Answer::Response(0, results) => {
            let ids = bound_ids(&results);
            let known = |id: &str| ids.iter().any(|i| i == id);
            crate::info!(
                "global shortcuts bound: {} of 2 ({}{}{})",
                usize::from(known(HOLD_ID)) + usize::from(known(TOGGLE_ID)),
                if known(HOLD_ID) { HOLD_ID } else { "" },
                if known(HOLD_ID) && known(TOGGLE_ID) {
                    ", "
                } else {
                    ""
                },
                if known(TOGGLE_ID) { TOGGLE_ID } else { "" },
            );
        }
        Answer::Response(1, _) => return End::Refused("the request was cancelled"),
        Answer::Response(_, _) => return End::Refused("the portal refused the shortcuts"),
    }

    let bound = Instant::now();
    let lost = |why| End::Lost {
        why,
        bound_for: bound.elapsed(),
    };
    loop {
        let Some(msg) = next(&mut signals, &conn).await else {
            return lost("the D-Bus connection closed");
        };
        if portal_gone(&msg, &owner) {
            return lost("the portal exited");
        }
        if sender(&msg).as_deref() != Some(owner.as_str()) {
            continue;
        }
        if closes(&msg, &session) {
            return lost("the portal closed the session");
        }
        let activated = member_is(&msg, SHORTCUTS, "Activated");
        if !activated && !member_is(&msg, SHORTCUTS, "Deactivated") {
            continue;
        }
        let Ok((handle, id, _, _)) =
            msg.body()
                .deserialize::<(OwnedObjectPath, String, u64, HashMap<String, OwnedValue>)>()
        else {
            continue;
        };
        if handle.as_str() != session {
            continue;
        }
        if activated {
            keys.activated(&id);
        } else {
            keys.deactivated(&id);
        }
    }
}

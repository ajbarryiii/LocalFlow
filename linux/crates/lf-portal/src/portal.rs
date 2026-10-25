//! The `org.freedesktop.portal.RemoteDesktop` negotiation, over `zbus`.
//!
//! `CreateSession`, `SelectDevices` (keyboard only, persisted until revoked,
//! with the stored restore token), `Start` (where the desktop may ask the
//! user) and `ConnectToEIS`. Each portal request answers with a `Response`
//! signal on a request object; the signal stream is opened before the first
//! call so no response can be missed, and only signals from the portal's
//! own connection are accepted.
//!
//! Every step is bounded in time (sending included, as in `lf-media`) and
//! can be abandoned through a stop flag. Errors never carry the portal's
//! messages or the restore token.

use std::collections::HashMap;
use std::future::Future;
use std::os::fd::OwnedFd;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use futures_lite::{StreamExt, future};
use lf_io_api::IoError;
use zbus::connection::Builder;
use zbus::message::Type;
use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};
use zbus::{Connection, MatchRule, MessageStream};

pub const DEST: &str = "org.freedesktop.portal.Desktop";
pub const PATH: &str = "/org/freedesktop/portal/desktop";
pub const REMOTE_DESKTOP: &str = "org.freedesktop.portal.RemoteDesktop";
pub const REQUEST: &str = "org.freedesktop.portal.Request";
pub const SESSION: &str = "org.freedesktop.portal.Session";
const PROPERTIES: &str = "org.freedesktop.DBus.Properties";
const BUS: &str = "org.freedesktop.DBus";
const BUS_PATH: &str = "/org/freedesktop/DBus";

/// `AvailableDeviceTypes` / `types` bit for a keyboard.
pub const DEVICE_KEYBOARD: u32 = 1;
/// `persist_mode`: until the user revokes it.
pub const PERSIST_UNTIL_REVOKED: u32 = 2;
/// `ConnectToEIS` and restore tokens need version 2.
pub const MIN_VERSION: u32 = 2;
/// Longest restore token accepted from the portal.
pub const MAX_TOKEN_BYTES: usize = 4096;

/// Upper bounds for the portal calls.
#[derive(Clone, Copy, Debug)]
pub struct Timeouts {
    /// Connecting to the bus, and each step that needs no user action.
    pub call: Duration,
    /// `Start`, which may wait for the user to answer a dialog.
    pub permission: Duration,
}

/// Runs `fut` for at most `timeout`; `None` if it did not finish, in which
/// case it has been dropped (cancelled).
pub fn bounded<T>(timeout: Duration, fut: impl Future<Output = T>) -> Option<T> {
    async_io::block_on(race(timeout, None, fut))
}

/// `fut`, unless `timeout` passes or `stop` turns true first.
async fn race<T>(
    timeout: Duration,
    stop: Option<&AtomicBool>,
    fut: impl Future<Output = T>,
) -> Option<T> {
    let stopped = async {
        loop {
            async_io::Timer::after(Duration::from_millis(50)).await;
            if stop.is_some_and(|s| s.load(Ordering::SeqCst)) {
                return None;
            }
        }
    };
    let timer = async {
        async_io::Timer::after(timeout).await;
        None
    };
    future::or(async { Some(fut.await) }, future::or(timer, stopped)).await
}

/// Connects to `address`, or to the session bus.
pub async fn connect(address: Option<&str>) -> zbus::Result<Connection> {
    match address {
        Some(a) => Builder::address(a)?,
        None => Builder::session()?,
    }
    .build()
    .await
}

fn dbus_error(what: &str, e: &zbus::Error) -> IoError {
    match e {
        // A portal that lacks the interface or method, or refuses the call.
        zbus::Error::MethodError(..) => IoError(format!("the desktop portal refused {what}")),
        zbus::Error::InputOutput(err) => IoError(format!(
            "D-Bus connection failed during {what}: {}",
            err.kind()
        )),
        _ => IoError(format!("D-Bus error during {what}")),
    }
}

async fn property_u32(conn: &Connection, name: &str) -> zbus::Result<u32> {
    let reply = conn
        .call_method(
            Some(DEST),
            PATH,
            Some(PROPERTIES),
            "Get",
            &(REMOTE_DESKTOP, name),
        )
        .await?;
    let value: OwnedValue = reply.body().deserialize()?;
    u32::try_from(value).map_err(|_| zbus::Error::InvalidReply)
}

/// Whether a RemoteDesktop portal of at least [`MIN_VERSION`] that offers
/// keyboards is on the bus. Reads two properties; no session is created
/// and nothing is shown to the user. `Err` means the bus could not be
/// reached.
pub fn probe(address: Option<&str>, timeout: Duration) -> Result<bool, IoError> {
    let result = bounded(timeout, async {
        let conn = connect(address)
            .await
            .map_err(|e| dbus_error("connecting", &e))?;
        let read = async {
            let version = property_u32(&conn, "version").await?;
            let types = property_u32(&conn, "AvailableDeviceTypes").await?;
            zbus::Result::Ok(version >= MIN_VERSION && types & DEVICE_KEYBOARD != 0)
        };
        match read.await {
            Ok(ok) => Ok(ok),
            // No portal, or one without RemoteDesktop.
            Err(zbus::Error::MethodError(..) | zbus::Error::InvalidReply) => Ok(false),
            Err(e) => Err(dbus_error("the portal probe", &e)),
        }
    });
    result.unwrap_or_else(|| {
        Err(IoError(
            "the D-Bus session bus did not answer in time".into(),
        ))
    })
}

/// A negotiated session: the connection that owns it (closing the
/// connection ends it), its handle, and the EIS socket.
pub struct Negotiated {
    pub conn: Connection,
    pub session: OwnedObjectPath,
    pub eis: OwnedFd,
}

/// The sender part of request paths: the unique name without `:`, with
/// `.` as `_`.
pub fn sender_path_element(unique_name: &str) -> String {
    unique_name.trim_start_matches(':').replace('.', "_")
}

/// The object path the portal uses for a request made with `token`.
pub fn request_path(unique_name: &str, token: &str) -> String {
    format!(
        "{PATH}/request/{}/{token}",
        sender_path_element(unique_name)
    )
}

fn next_token() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    format!(
        "localflow_{}_{}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    )
}

type Options<'a> = HashMap<&'a str, Value<'a>>;

/// Options for `SelectDevices`.
pub fn select_devices_options<'a>(
    handle_token: &'a str,
    restore_token: Option<&'a str>,
) -> Options<'a> {
    let mut o = Options::new();
    o.insert("handle_token", Value::from(handle_token));
    o.insert("types", Value::from(DEVICE_KEYBOARD));
    o.insert("persist_mode", Value::from(PERSIST_UNTIL_REVOKED));
    if let Some(t) = restore_token {
        o.insert("restore_token", Value::from(t));
    }
    o
}

struct Requests<'c> {
    conn: &'c Connection,
    stream: MessageStream,
    /// Unique name of the portal; signals from anyone else are ignored.
    owner: String,
    stop: &'c AtomicBool,
}

impl Requests<'_> {
    /// Calls `method` with `args` (whose last element is the options, with
    /// a fresh `handle_token`), then waits for its
    /// `Response`. Returns the results of a successful response.
    async fn request<B>(
        &mut self,
        method: &str,
        args: &B,
        timeout: Duration,
    ) -> Result<HashMap<String, OwnedValue>, IoError>
    where
        B: zbus::export::serde::ser::Serialize + zbus::zvariant::DynamicType,
    {
        let stop = self.stop;
        let wait = async {
            let reply = self
                .conn
                .call_method(Some(DEST), PATH, Some(REMOTE_DESKTOP), method, args)
                .await
                .map_err(|e| dbus_error(method, &e))?;
            let handle: OwnedObjectPath = reply
                .body()
                .deserialize()
                .map_err(|_| IoError(format!("the desktop portal answered {method} oddly")))?;
            // The stream covers every request path of this connection, so a
            // portal that uses another path than the predicted one works too.
            self.response(&handle).await
        };
        let (code, results) = race(timeout, Some(stop), wait).await.unwrap_or_else(|| {
            Err(IoError(if stop.load(Ordering::SeqCst) {
                "the portal negotiation was abandoned".into()
            } else {
                format!("the desktop portal did not answer {method} in time")
            }))
        })?;
        match code {
            0 => Ok(results),
            1 => Err(IoError(format!(
                "the desktop portal request ({method}) was cancelled"
            ))),
            _ => Err(IoError(format!(
                "the desktop portal refused the request ({method})"
            ))),
        }
    }

    async fn response(
        &mut self,
        handle: &ObjectPath<'_>,
    ) -> Result<(u32, HashMap<String, OwnedValue>), IoError> {
        while let Some(msg) = self.stream.next().await {
            let Ok(msg) = msg else { continue };
            let header = msg.header();
            if header.path() != Some(handle)
                || header.sender().map(|s| s.as_str()) != Some(self.owner.as_str())
            {
                continue;
            }
            return msg
                .body()
                .deserialize::<(u32, HashMap<String, OwnedValue>)>()
                .map_err(|_| IoError("the desktop portal sent an invalid response".into()));
        }
        Err(IoError("the D-Bus connection closed".into()))
    }
}

fn string_result(results: &HashMap<String, OwnedValue>, key: &str) -> Option<String> {
    let value = results.get(key)?;
    match &**value {
        Value::Str(s) => Some(s.as_str().to_owned()),
        Value::ObjectPath(p) => Some(p.as_str().to_owned()),
        _ => None,
    }
}

/// Negotiates a keyboard session on `address` (or the session bus), using
/// `restore_token` if given. A new restore token goes to `save_token` as soon
/// as `Start` grants access (it replaces the one used, even if a later step
/// fails). `stop` abandons the negotiation at the next check.
pub async fn negotiate(
    address: Option<&str>,
    restore_token: Option<String>,
    save_token: &mut dyn FnMut(&str),
    timeouts: Timeouts,
    stop: &AtomicBool,
) -> Result<Negotiated, IoError> {
    let conn = race(timeouts.call, Some(stop), connect(address))
        .await
        .ok_or_else(|| IoError("the D-Bus session bus did not answer in time".into()))?
        .map_err(|e| dbus_error("connecting", &e))?;
    let unique = conn
        .unique_name()
        .ok_or_else(|| IoError("the D-Bus connection has no name".into()))?
        .as_str()
        .to_owned();
    let setup = async {
        // Asking the portal itself first starts it if it is installed but
        // not running yet (D-Bus activation), and checks its version.
        match property_u32(&conn, "version").await {
            Ok(v) if v >= MIN_VERSION => {}
            Ok(_) => {
                return Err(IoError(
                    "the desktop portal's RemoteDesktop is too old (version 2 needed)".into(),
                ));
            }
            Err(zbus::Error::MethodError(..) | zbus::Error::InvalidReply) => {
                return Err(IoError(
                    "no RemoteDesktop portal on the D-Bus session bus".into(),
                ));
            }
            Err(e) => return Err(dbus_error("the portal version check", &e)),
        }
        let owner_reply = conn
            .call_method(Some(BUS), BUS_PATH, Some(BUS), "GetNameOwner", &DEST)
            .await
            .map_err(|_| IoError("no desktop portal on the D-Bus session bus".into()))?;
        let owner: String = owner_reply
            .body()
            .deserialize()
            .map_err(|_| IoError("D-Bus answered GetNameOwner oddly".into()))?;
        let rule = MatchRule::builder()
            .msg_type(Type::Signal)
            .interface(REQUEST)
            .and_then(|r| r.member("Response"))
            .and_then(|r| {
                r.path_namespace(format!("{PATH}/request/{}", sender_path_element(&unique)))
            })
            .map_err(|_| IoError("invalid D-Bus match rule".into()))?
            .build();
        let stream = MessageStream::for_match_rule(rule, &conn, Some(16))
            .await
            .map_err(|e| dbus_error("subscribing", &e))?;
        Ok::<_, IoError>((owner, stream))
    };
    let (owner, stream) = race(timeouts.call, Some(stop), setup)
        .await
        .unwrap_or_else(|| {
            Err(IoError(
                "the D-Bus session bus did not answer in time".into(),
            ))
        })?;
    let mut requests = Requests {
        conn: &conn,
        stream,
        owner,
        stop,
    };

    let token = next_token();
    let session_token = next_token();
    let mut options = Options::new();
    options.insert("handle_token", Value::from(token.as_str()));
    options.insert("session_handle_token", Value::from(session_token.as_str()));
    let results = requests
        .request("CreateSession", &(options,), timeouts.call)
        .await?;
    let session = string_result(&results, "session_handle")
        .and_then(|s| OwnedObjectPath::try_from(s).ok())
        .ok_or_else(|| IoError("the desktop portal returned no session".into()))?;

    let token = next_token();
    let options = select_devices_options(&token, restore_token.as_deref());
    let selected = requests
        .request("SelectDevices", &(&session, options), timeouts.call)
        .await;
    let result = async {
        selected?;
        let token = next_token();
        let mut options = Options::new();
        options.insert("handle_token", Value::from(token.as_str()));
        let results = requests
            .request("Start", &(&session, "", options), timeouts.permission)
            .await?;
        let devices = results
            .get("devices")
            .and_then(|v| u32::try_from(v).ok())
            .unwrap_or(0);
        if devices & DEVICE_KEYBOARD == 0 {
            return Err(IoError("the desktop did not grant keyboard access".into()));
        }
        if let Some(token) = string_result(&results, "restore_token").filter(|t| {
            !t.is_empty() && t.len() <= MAX_TOKEN_BYTES && !t.chars().any(char::is_control)
        }) {
            save_token(&token);
        }
        let options = Options::new();
        let connect_eis = async {
            let reply = conn
                .call_method(
                    Some(DEST),
                    PATH,
                    Some(REMOTE_DESKTOP),
                    "ConnectToEIS",
                    &(&session, options),
                )
                .await
                .map_err(|e| dbus_error("ConnectToEIS", &e))?;
            let fd: zbus::zvariant::OwnedFd = reply
                .body()
                .deserialize()
                .map_err(|_| IoError("the desktop portal answered ConnectToEIS oddly".into()))?;
            Ok::<_, IoError>(OwnedFd::from(fd))
        };
        let eis = race(timeouts.call, Some(stop), connect_eis)
            .await
            .unwrap_or_else(|| {
                Err(IoError(
                    "the desktop portal did not answer ConnectToEIS in time".into(),
                ))
            })?;
        Ok(eis)
    }
    .await;
    match result {
        Ok(eis) => Ok(Negotiated { conn, session, eis }),
        Err(e) => {
            // Ends a pending permission dialog too.
            close(&conn, &session, timeouts.call).await;
            Err(e)
        }
    }
}

/// Closes `session`, waiting at most `timeout`.
pub async fn close(conn: &Connection, session: &ObjectPath<'_>, timeout: Duration) {
    let call = conn.call_method(Some(DEST), session, Some(SESSION), "Close", &());
    let _ = race(timeout, None, call).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_paths_follow_the_portal_spec() {
        assert_eq!(sender_path_element(":1.42"), "1_42");
        assert_eq!(
            request_path(":1.42", "localflow_7_0"),
            "/org/freedesktop/portal/desktop/request/1_42/localflow_7_0"
        );
        let t = next_token();
        assert!(
            t.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'),
            "{t}"
        );
        assert_ne!(t, next_token());
    }

    #[test]
    fn select_devices_asks_for_a_persistent_keyboard() {
        let o = select_devices_options("h", None);
        assert_eq!(o["types"], Value::from(1u32));
        assert_eq!(o["persist_mode"], Value::from(2u32));
        assert!(!o.contains_key("restore_token"));
        let o = select_devices_options("h", Some("synthetic-token"));
        assert_eq!(o["restore_token"], Value::from("synthetic-token"));
    }
}

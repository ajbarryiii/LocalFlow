//! MPRIS over the D-Bus session bus, through `zbus`.
//!
//! - Players are the bus names `org.mpris.MediaPlayer2.*`. Each is resolved
//!   to its owner's unique name (`:1.42`), which the bus never reuses while
//!   it runs, and calls go to that unique name. A player that quits and
//!   restarts under the same well-known name is therefore a new player.
//! - `org.mpris.MediaPlayer2.playerctld` is skipped: it forwards calls to
//!   whichever player was active last, so a `Play` through it could start a
//!   player LocalFlow never paused.
//! - Only `PlaybackStatus` is read, with `org.freedesktop.DBus.Properties.Get`.
//!   No proxy is built, so nothing calls `GetAll` (which would fetch track
//!   metadata) or subscribes to signals.
//! - **Bounds.** Every call, sending included, is bounded by
//!   [`MprisConfig::call_timeout`], and connecting (with authentication) by
//!   [`MprisConfig::connect_timeout`]. zbus's blocking API (and its
//!   `method_timeout`) only times the wait for the reply, not the send, which
//!   can block on a bus that stops reading; so each call is zbus's async
//!   call raced against a timer on the calling thread
//!   (`async_io::block_on`), and a call or connection attempt that loses
//!   the race is dropped, cancelling it.
//! - After a timeout or a connection error the connection is discarded (a
//!   cancelled send may have left half a message on it) and the next call
//!   reconnects. Players found on a different bus instance (another server
//!   GUID) get a new [`PlayerId::session`], so names from the old bus are
//!   never called; on the same bus, unique names stay valid.
//! - Errors are [`MediaError`] kinds; D-Bus error messages from players are
//!   never passed on.
//!
//! `zbus` reports through `tracing`; the daemon installs no subscriber, so
//! that output is discarded.

use std::future::Future;
use std::time::Duration;

use futures_lite::future;
use lf_io_api::{MediaError, MediaPlayers, PlaybackStatus, PlayerId};
use zbus::connection::Builder;
use zbus::zvariant::Value;
use zbus::{Connection, Message};

const PREFIX: &str = "org.mpris.MediaPlayer2.";
const PLAYERCTLD: &str = "org.mpris.MediaPlayer2.playerctld";
const PATH: &str = "/org/mpris/MediaPlayer2";
const PLAYER: &str = "org.mpris.MediaPlayer2.Player";
const PROPERTIES: &str = "org.freedesktop.DBus.Properties";
const BUS: &str = "org.freedesktop.DBus";
const BUS_PATH: &str = "/org/freedesktop/DBus";

/// At most this many MPRIS names are looked at, bounding the work per pass.
pub const MAX_PLAYERS: usize = 16;

#[derive(Clone, Debug)]
pub struct MprisConfig {
    /// A D-Bus address; `None` means the session bus
    /// (`DBUS_SESSION_BUS_ADDRESS`, else `$XDG_RUNTIME_DIR/bus`).
    pub address: Option<String>,
    /// Upper bound for each method call, to the bus or to a player.
    pub call_timeout: Duration,
    /// Upper bound for connecting and authenticating.
    pub connect_timeout: Duration,
}

impl Default for MprisConfig {
    fn default() -> MprisConfig {
        MprisConfig {
            address: None,
            call_timeout: Duration::from_millis(250),
            connect_timeout: Duration::from_secs(1),
        }
    }
}

pub struct Mpris {
    config: MprisConfig,
    conn: Option<Connection>,
    /// GUID of the bus `session` refers to.
    guid: Option<String>,
    session: u64,
}

/// Runs `fut` on this thread for at most `timeout`; `None` if it did not
/// finish, in which case it has been dropped (cancelled).
fn bounded<T>(timeout: Duration, fut: impl Future<Output = T>) -> Option<T> {
    async_io::block_on(future::or(async { Some(fut.await) }, async {
        async_io::Timer::after(timeout).await;
        None
    }))
}

/// The kind of `e`; never the text of a remote error.
fn classify(e: &zbus::Error) -> MediaError {
    match e {
        zbus::Error::InputOutput(err) if err.kind() == std::io::ErrorKind::TimedOut => {
            MediaError::TimedOut
        }
        zbus::Error::InputOutput(_) => MediaError::Unavailable,
        zbus::Error::MethodError(name, _, _) => match name.as_str() {
            "org.freedesktop.DBus.Error.ServiceUnknown"
            | "org.freedesktop.DBus.Error.NameHasNoOwner"
            | "org.freedesktop.DBus.Error.UnknownObject" => MediaError::Gone,
            "org.freedesktop.DBus.Error.NoReply"
            | "org.freedesktop.DBus.Error.Timeout"
            | "org.freedesktop.DBus.Error.TimedOut" => MediaError::TimedOut,
            "org.freedesktop.DBus.Error.Disconnected" => MediaError::Unavailable,
            // UnknownMethod, UnknownInterface, AccessDenied, NotSupported,
            // a player's own errors...: the call had no effect.
            _ => MediaError::Rejected,
        },
        _ => MediaError::Rejected,
    }
}

impl Mpris {
    /// Nothing is opened yet; the first call connects.
    pub fn new(config: MprisConfig) -> Mpris {
        Mpris {
            config,
            conn: None,
            guid: None,
            session: 0,
        }
    }

    /// Connects unless connected, within `connect_timeout`.
    pub fn connect(&mut self) -> Result<(), MediaError> {
        if self.conn.as_ref().is_some_and(|c| !c.is_closed()) {
            return Ok(());
        }
        self.conn = None;
        let builder = match &self.config.address {
            Some(a) => Builder::address(a.as_str()),
            None => Builder::session(),
        }
        .map_err(|_| MediaError::Unavailable)?;
        let conn = match bounded(self.config.connect_timeout, builder.build()) {
            Some(Ok(conn)) => conn,
            Some(Err(_)) | None => return Err(MediaError::Unavailable),
        };
        let guid = conn.server_guid().as_str().to_owned();
        if self.guid.as_deref() != Some(guid.as_str()) {
            self.session += 1;
            self.guid = Some(guid);
        }
        self.conn = Some(conn);
        Ok(())
    }

    /// The connection, if `player` belongs to the bus it is connected to.
    fn conn_for(&mut self, player: &PlayerId) -> Result<Connection, MediaError> {
        if player.session != self.session {
            return Err(MediaError::Gone);
        }
        self.connect()?;
        if player.session != self.session {
            return Err(MediaError::Gone);
        }
        self.conn.clone().ok_or(MediaError::Unavailable)
    }

    /// Finishes a call started on the current connection, within
    /// `call_timeout`. A timeout or connection error discards the
    /// connection.
    fn finish(
        &mut self,
        call: impl Future<Output = zbus::Result<Message>>,
    ) -> Result<Message, MediaError> {
        let result = match bounded(self.config.call_timeout, call) {
            Some(Ok(reply)) => return Ok(reply),
            Some(Err(e)) => classify(&e),
            None => MediaError::TimedOut,
        };
        if matches!(result, MediaError::TimedOut | MediaError::Unavailable) {
            self.conn = None;
        }
        Err(result)
    }

    fn call_player(&mut self, player: &PlayerId, method: &str) -> Result<(), MediaError> {
        let conn = self.conn_for(player)?;
        let call = conn.call_method(Some(player.name.as_str()), PATH, Some(PLAYER), method, &());
        self.finish(call).map(|_| ())
    }
}

impl MediaPlayers for Mpris {
    fn players(&mut self) -> Result<Vec<PlayerId>, MediaError> {
        self.connect()?;
        let session = self.session;
        let conn = self.conn.clone().ok_or(MediaError::Unavailable)?;
        let reply =
            self.finish(conn.call_method(Some(BUS), BUS_PATH, Some(BUS), "ListNames", &()))?;
        let mut names: Vec<String> = reply
            .body()
            .deserialize::<Vec<String>>()
            .map_err(|_| MediaError::Rejected)?
            .into_iter()
            .filter(|n| n.starts_with(PREFIX) && n.len() > PREFIX.len() && n != PLAYERCTLD)
            .collect();
        names.sort_unstable();
        names.truncate(MAX_PLAYERS);
        let mut players: Vec<PlayerId> = Vec::new();
        for name in names {
            let Some(conn) = self.conn.clone() else {
                return Err(MediaError::Unavailable);
            };
            let call = conn.call_method(Some(BUS), BUS_PATH, Some(BUS), "GetNameOwner", &name);
            let owner = match self.finish(call) {
                Ok(reply) => reply.body().deserialize::<String>().ok(),
                // The player quit since the listing.
                Err(MediaError::Gone | MediaError::Rejected) => None,
                // The connection was discarded: give up on this pass.
                Err(e) => return Err(e),
            };
            let Some(owner) = owner else { continue };
            let id = PlayerId {
                session,
                name: owner,
            };
            // One player may own several MPRIS names.
            if !players.contains(&id) {
                players.push(id);
            }
        }
        Ok(players)
    }

    fn status(&mut self, player: &PlayerId) -> Result<PlaybackStatus, MediaError> {
        let conn = self.conn_for(player)?;
        let call = conn.call_method(
            Some(player.name.as_str()),
            PATH,
            Some(PROPERTIES),
            "Get",
            &(PLAYER, "PlaybackStatus"),
        );
        let reply = self.finish(call)?;
        let body = reply.body();
        let value: Value<'_> = body.deserialize().map_err(|_| MediaError::Rejected)?;
        match value {
            Value::Str(s) => match s.as_str() {
                "Playing" => Ok(PlaybackStatus::Playing),
                "Paused" => Ok(PlaybackStatus::Paused),
                "Stopped" => Ok(PlaybackStatus::Stopped),
                _ => Err(MediaError::Rejected),
            },
            _ => Err(MediaError::Rejected),
        }
    }

    fn pause(&mut self, player: &PlayerId) -> Result<(), MediaError> {
        self.call_player(player, "Pause")
    }

    fn play(&mut self, player: &PlayerId) -> Result<(), MediaError> {
        self.call_player(player, "Play")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    fn scratch(tag: &str) -> std::path::PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.subsec_nanos());
        let dir =
            std::env::temp_dir().join(format!("lf-media-{tag}-{}-{nanos}", std::process::id()));
        std::fs::create_dir(&dir).unwrap();
        dir
    }

    #[test]
    fn a_missing_bus_fails_fast() {
        let dir = scratch("no-bus");
        let mut m = Mpris::new(MprisConfig {
            address: Some(format!("unix:path={}/no-such-socket", dir.display())),
            ..MprisConfig::default()
        });
        let t = Instant::now();
        assert_eq!(m.players(), Err(MediaError::Unavailable));
        assert!(t.elapsed() < Duration::from_secs(1));
        // Players from no session at all are never called.
        let ghost = PlayerId {
            session: 7,
            name: ":1.1".into(),
        };
        assert_eq!(m.play(&ghost), Err(MediaError::Gone));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_bad_address_is_an_error() {
        let mut m = Mpris::new(MprisConfig {
            address: Some("not-an-address".into()),
            ..MprisConfig::default()
        });
        assert_eq!(m.players(), Err(MediaError::Unavailable));
    }

    #[test]
    fn a_silent_bus_is_bounded_by_the_connect_timeout() {
        use std::os::unix::net::UnixListener;
        let dir = scratch("silent-bus");
        let path = dir.join("bus");
        // Accepts connections (the backlog does) but never answers.
        let _listener = UnixListener::bind(&path).unwrap();
        let mut m = Mpris::new(MprisConfig {
            address: Some(format!("unix:path={}", path.display())),
            connect_timeout: Duration::from_millis(200),
            ..MprisConfig::default()
        });
        for _ in 0..3 {
            let t = Instant::now();
            assert_eq!(m.players(), Err(MediaError::Unavailable));
            let took = t.elapsed();
            assert!(took >= Duration::from_millis(200), "{took:?}");
            assert!(took < Duration::from_millis(800), "{took:?}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn remote_errors_are_classified_without_their_text() {
        use zbus::names::OwnedErrorName;
        let method_error = |name: &str| {
            let msg = Message::method_call("/", "Synthetic")
                .unwrap()
                .build(&())
                .unwrap();
            zbus::Error::MethodError(
                OwnedErrorName::try_from(name).unwrap(),
                Some("synthetic detail".into()),
                msg,
            )
        };
        for (name, kind) in [
            (
                "org.freedesktop.DBus.Error.ServiceUnknown",
                MediaError::Gone,
            ),
            (
                "org.freedesktop.DBus.Error.NameHasNoOwner",
                MediaError::Gone,
            ),
            ("org.freedesktop.DBus.Error.UnknownObject", MediaError::Gone),
            ("org.freedesktop.DBus.Error.NoReply", MediaError::TimedOut),
            ("org.freedesktop.DBus.Error.Timeout", MediaError::TimedOut),
            ("org.freedesktop.DBus.Error.TimedOut", MediaError::TimedOut),
            (
                "org.freedesktop.DBus.Error.Disconnected",
                MediaError::Unavailable,
            ),
            (
                "org.freedesktop.DBus.Error.AccessDenied",
                MediaError::Rejected,
            ),
            (
                "org.freedesktop.DBus.Error.UnknownMethod",
                MediaError::Rejected,
            ),
            (
                "org.mpris.MediaPlayer2.Synthetic.Error",
                MediaError::Rejected,
            ),
        ] {
            assert_eq!(classify(&method_error(name)), kind, "{name}");
        }
        let timeout =
            zbus::Error::InputOutput(std::io::Error::from(std::io::ErrorKind::TimedOut).into());
        assert_eq!(classify(&timeout), MediaError::TimedOut);
        let broken =
            zbus::Error::InputOutput(std::io::Error::from(std::io::ErrorKind::BrokenPipe).into());
        assert_eq!(classify(&broken), MediaError::Unavailable);
    }
}

//! `zbus` plumbing shared by the D-Bus clients (`lf-media`, `lf-portal` and
//! `lf-daemon`): connecting to an address or the session bus, time bounds
//! for whole operations, and error kinds without remote error text.
//!
//! zbus's blocking API (and its `method_timeout`) only times the wait for a
//! reply, not the send, which can block on a bus that stops reading. So an
//! operation (a connection attempt, a call) is zbus's async future raced
//! against a timer, and one that loses the race is dropped, cancelling it.

use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use futures_lite::future;
use zbus::Connection;

/// How often [`race`] checks its stop flag.
const STOP_POLL: Duration = Duration::from_millis(50);

/// A connection builder for `address`, or for the session bus
/// (`DBUS_SESSION_BUS_ADDRESS`, else `$XDG_RUNTIME_DIR/bus`) if `None`.
/// Fails if the address is invalid or there is no session bus address.
pub fn builder<'a>(address: Option<&str>) -> zbus::Result<zbus::connection::Builder<'a>> {
    match address {
        Some(a) => zbus::connection::Builder::address(a),
        None => zbus::connection::Builder::session(),
    }
}

/// [`builder`] for zbus's blocking API.
pub fn blocking_builder<'a>(
    address: Option<&str>,
) -> zbus::Result<zbus::blocking::connection::Builder<'a>> {
    match address {
        Some(a) => zbus::blocking::connection::Builder::address(a),
        None => zbus::blocking::connection::Builder::session(),
    }
}

/// Connects to `address`, or to the session bus, and authenticates.
pub async fn connect(address: Option<&str>) -> zbus::Result<Connection> {
    builder(address)?.build().await
}

/// `fut`, or `None` once `timeout` passes first; `fut` has then been
/// dropped (cancelled).
pub async fn within<T>(timeout: Duration, fut: impl Future<Output = T>) -> Option<T> {
    future::or(async { Some(fut.await) }, async {
        async_io::Timer::after(timeout).await;
        None
    })
    .await
}

/// Runs `fut` on this thread for at most `timeout`; `None` if it did not
/// finish, in which case it has been dropped (cancelled).
pub fn bounded<T>(timeout: Duration, fut: impl Future<Output = T>) -> Option<T> {
    async_io::block_on(within(timeout, fut))
}

/// `fut`, unless `timeout` passes or `stop` turns true first (checked every
/// 50 ms); `None` then, and `fut` has been dropped (cancelled).
pub async fn race<T>(
    timeout: Duration,
    stop: &AtomicBool,
    fut: impl Future<Output = T>,
) -> Option<T> {
    let stopped = async {
        loop {
            async_io::Timer::after(STOP_POLL).await;
            if stop.load(Ordering::SeqCst) {
                return None;
            }
        }
    };
    future::or(within(timeout, fut), stopped).await
}

/// What kind of failure a zbus error is. Never carries the text of a remote
/// error, which may come from any client on the bus.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DbusErrorKind<'a> {
    /// The other side answered with an error: its D-Bus error name.
    Method(&'a str),
    /// The connection failed.
    Io(std::io::ErrorKind),
    /// Anything else, such as a reply of the wrong type.
    Other,
}

/// The kind of `e`.
pub fn error_kind(e: &zbus::Error) -> DbusErrorKind<'_> {
    match e {
        zbus::Error::MethodError(name, _, _) => DbusErrorKind::Method(name.as_str()),
        zbus::Error::InputOutput(err) => DbusErrorKind::Io(err.kind()),
        _ => DbusErrorKind::Other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::time::Instant;

    /// Sets its flag when dropped.
    struct DropFlag(Arc<AtomicBool>);

    impl Drop for DropFlag {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }

    /// A future that never finishes and records being dropped.
    fn forever(dropped: &Arc<AtomicBool>) -> impl Future<Output = ()> + use<> {
        let flag = DropFlag(dropped.clone());
        async move {
            let _flag = flag;
            future::pending::<()>().await
        }
    }

    #[test]
    fn bounded_returns_what_finishes_in_time() {
        assert_eq!(bounded(Duration::from_secs(5), async { 7 }), Some(7));
        assert_eq!(
            async_io::block_on(within(Duration::from_secs(5), async { 8 })),
            Some(8)
        );
    }

    #[test]
    fn bounded_cancels_what_does_not() {
        let dropped = Arc::new(AtomicBool::new(false));
        let t = Instant::now();
        assert_eq!(bounded(Duration::from_millis(60), forever(&dropped)), None);
        let took = t.elapsed();
        assert!(took >= Duration::from_millis(60), "{took:?}");
        assert!(took < Duration::from_secs(1), "{took:?}");
        assert!(dropped.load(Ordering::SeqCst));
    }

    #[test]
    fn race_ends_at_the_timeout_or_the_stop_flag() {
        let stop = AtomicBool::new(false);
        assert_eq!(
            async_io::block_on(race(Duration::from_secs(5), &stop, async { 9 })),
            Some(9)
        );

        let dropped = Arc::new(AtomicBool::new(false));
        let t = Instant::now();
        let r = async_io::block_on(race(Duration::from_millis(60), &stop, forever(&dropped)));
        assert_eq!(r, None);
        assert!(t.elapsed() < Duration::from_secs(1));
        assert!(dropped.load(Ordering::SeqCst));

        // Stopping ends a wait far shorter than its timeout.
        let dropped = Arc::new(AtomicBool::new(false));
        let stop = AtomicBool::new(false);
        let t = Instant::now();
        let r = async_io::block_on(future::or(
            race(Duration::from_secs(30), &stop, forever(&dropped)),
            async {
                async_io::Timer::after(Duration::from_millis(20)).await;
                stop.store(true, Ordering::SeqCst);
                future::pending().await
            },
        ));
        assert_eq!(r, None);
        assert!(t.elapsed() < Duration::from_secs(1), "{:?}", t.elapsed());
        assert!(dropped.load(Ordering::SeqCst));
    }

    #[test]
    fn errors_are_classified_without_their_text() {
        use zbus::names::OwnedErrorName;
        let msg = zbus::Message::method_call("/", "Synthetic")
            .unwrap()
            .build(&())
            .unwrap();
        let method = zbus::Error::MethodError(
            OwnedErrorName::try_from("org.example.Synthetic.Error").unwrap(),
            Some("synthetic detail".into()),
            msg,
        );
        assert_eq!(
            error_kind(&method),
            DbusErrorKind::Method("org.example.Synthetic.Error")
        );
        let io =
            zbus::Error::InputOutput(std::io::Error::from(std::io::ErrorKind::TimedOut).into());
        assert_eq!(
            error_kind(&io),
            DbusErrorKind::Io(std::io::ErrorKind::TimedOut)
        );
        assert_eq!(error_kind(&zbus::Error::InvalidReply), DbusErrorKind::Other);
    }

    #[test]
    fn connecting_to_a_bad_or_missing_address_fails() {
        assert!(builder(Some("not-an-address")).is_err());
        assert!(blocking_builder(Some("not-an-address")).is_err());
        let missing = format!(
            "unix:path={}/lf-dbus-no-such-socket-{}",
            std::env::temp_dir().display(),
            std::process::id()
        );
        assert!(builder(Some(&missing)).is_ok());
        let r = bounded(Duration::from_secs(5), connect(Some(&missing)));
        assert!(matches!(r, Some(Err(_))));
    }
}

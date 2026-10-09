//! Text insertion through the Wayland virtual keyboard protocol
//! (`zwp_virtual_keyboard_v1`), the way `wtype` does it.
//!
//! [`WaylandTyper`] creates a virtual keyboard on the first seat and types
//! text by uploading its own XKB keymap in which every needed character is a
//! Unicode keysym on its own keycode (see [`keymap`]). The result does not
//! depend on the user's layout, and text with more distinct characters than
//! one keymap holds is typed in batches, each with a fresh keymap.
//!
//! Privacy: the text is never logged, persisted or included in errors, and
//! errors never echo free-form compositor messages. Keymaps live in sealed
//! memfds that are closed after upload; they do, necessarily, reveal the set
//! of characters to the compositor and to the focused client, exactly as the
//! key events themselves do. `wayland-backend` is built with its `log`
//! feature, so its diagnostics go to the `log` facade (silent unless the
//! application installs a logger) instead of stderr. An application that
//! installs a logger must filter out the `wayland_backend` target at every
//! level: at error level it logs the compositor's full protocol error
//! message, and at debug level every request, including keycodes. Setting
//! `WAYLAND_DEBUG=1` likewise prints the protocol stream, as in any Wayland
//! client.
//!
//! Requirements: a compositor with `zwp_virtual_keyboard_manager_v1`
//! (wlroots-based compositors such as Hyprland and sway; not GNOME or
//! KDE). Keys go to whichever surface has keyboard focus.

pub mod keymap;
mod memfd;

use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use lf_io_api::{IoError, TextOutput};
use wayland_client::backend::WaylandError;
use wayland_client::protocol::{wl_callback, wl_keyboard, wl_registry, wl_seat};
use wayland_client::{Connection, Dispatch, EventQueue, QueueHandle};
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::{
    zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1,
    zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1,
};

use keymap::{Keymap, Sym};

/// Which Wayland compositor to connect to.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum Display {
    /// `WAYLAND_SOCKET`, or `WAYLAND_DISPLAY` (absolute, or relative to
    /// `XDG_RUNTIME_DIR`), as every Wayland client does.
    #[default]
    Env,
    /// An explicit socket path.
    Socket(PathBuf),
}

/// Typing configuration.
#[derive(Debug, Clone)]
pub struct TyperConfig {
    pub display: Display,
    /// Pause after each key (press and release). Some applications drop
    /// keys that arrive too quickly; 0 types as fast as the compositor
    /// accepts.
    pub key_delay: Duration,
    /// Upper bound for any single wait on the compositor (a flush or a
    /// round trip). A compositor that stops responding fails the call
    /// instead of hanging it.
    pub timeout: Duration,
    /// Upper bound for one whole `type_text`/`press_enter` call: every wait
    /// in it (liveness check, reconnect, setup, flushes, syncs and key
    /// delays) draws on this one budget, and the call fails once it is used
    /// up. `None` (the default) bounds only each single wait.
    pub call_timeout: Option<Duration>,
}

impl Default for TyperConfig {
    fn default() -> Self {
        Self {
            display: Display::Env,
            key_delay: Duration::from_millis(1),
            timeout: Duration::from_secs(5),
            call_timeout: None,
        }
    }
}

/// How long the next wait may take: `timeout`, cut to what is left before
/// `deadline`. Fails once the deadline has passed.
fn wait_budget(
    timeout: Duration,
    deadline: Option<Instant>,
    now: Instant,
) -> Result<Duration, IoError> {
    match deadline {
        None => Ok(timeout),
        Some(d) => {
            let left = d.saturating_duration_since(now);
            if left.is_zero() {
                Err(IoError(
                    "typing did not finish within its time limit".into(),
                ))
            } else {
                Ok(timeout.min(left))
            }
        }
    }
}

/// Keys sent between round trips with the compositor, so a fast sender
/// cannot run far ahead of it.
const KEYS_PER_SYNC: usize = 32;

/// `TextOutput` backed by `zwp_virtual_keyboard_v1`.
///
/// Connects lazily on first use and keeps one virtual keyboard. After any
/// error the connection is dropped and the next call reconnects. A live
/// connection is checked with a round trip before each call, so a restarted
/// compositor costs no lost text.
pub struct WaylandTyper {
    config: TyperConfig,
    pool: Vec<u32>,
    session: Option<Session>,
}

impl WaylandTyper {
    /// Creates a typer; no connection is made until [`Self::connect`] or the
    /// first `TextOutput` call.
    pub fn new(config: TyperConfig) -> Self {
        Self {
            config,
            pool: keymap::char_pool(),
            session: None,
        }
    }

    /// Connects now and creates the virtual keyboard, so that setup errors
    /// (no compositor, protocol missing) surface early. Idempotent.
    pub fn connect(&mut self) -> Result<(), IoError> {
        self.session_mut(None).map(|_| ())
    }

    /// Drops the connection and the virtual keyboard.
    pub fn disconnect(&mut self) {
        if let Some(mut s) = self.session.take() {
            s.close();
        }
    }

    /// A live session whose waits are bounded by `call_deadline` (if any)
    /// until the next call sets its own.
    fn session_mut(&mut self, call_deadline: Option<Instant>) -> Result<&mut Session, IoError> {
        if let Some(s) = self.session.as_mut() {
            s.call_deadline = call_deadline;
            if s.sync().is_err() {
                self.disconnect();
            }
        }
        if self.session.is_none() {
            self.session = Some(Session::open(&self.config, call_deadline)?);
        }
        Ok(self.session.as_mut().expect("session just set"))
    }

    fn type_syms(&mut self, syms: &[Sym]) -> Result<(), IoError> {
        if syms.is_empty() {
            return Ok(());
        }
        let deadline = self.config.call_timeout.map(|t| Instant::now() + t);
        let batches = keymap::plan(syms, &self.pool);
        let delay = self.config.key_delay;
        let result = self
            .session_mut(deadline)
            .and_then(|session| Self::send(session, syms, &batches, delay, deadline));
        if result.is_err() {
            self.disconnect();
        }
        result
    }

    fn send(
        session: &mut Session,
        syms: &[Sym],
        batches: &[keymap::Batch],
        delay: Duration,
        deadline: Option<Instant>,
    ) -> Result<(), IoError> {
        for batch in batches {
            let range = &syms[batch.start..batch.end];
            if !session.keymap.covers(range) {
                session.upload(&batch.keymap)?;
            }
            for (i, &sym) in range.iter().enumerate() {
                let code = session
                    .keymap
                    .code(sym)
                    .expect("planned keymap covers its batch");
                session.tap(code)?;
                if !delay.is_zero() {
                    // Never sleep past the call's deadline; the next flush or
                    // sync then fails the call.
                    let left =
                        deadline.map_or(delay, |d| d.saturating_duration_since(Instant::now()));
                    std::thread::sleep(delay.min(left));
                }
                if (i + 1) % KEYS_PER_SYNC == 0 {
                    session.sync()?;
                }
            }
        }
        session.sync()
    }
}

impl Drop for WaylandTyper {
    fn drop(&mut self) {
        self.disconnect();
    }
}

/// The error for a character `tokenize` rejects; names the position only.
fn unsupported(e: keymap::UnsupportedChar) -> IoError {
    IoError(format!(
        "cannot type control character at position {} (only \\n, \\r and \\t are supported)",
        e.index
    ))
}

impl TextOutput for WaylandTyper {
    fn check(&self, text: &str) -> Result<(), IoError> {
        keymap::tokenize(text).map(|_| ()).map_err(unsupported)
    }

    fn type_text(&mut self, text: &str) -> Result<(), IoError> {
        let syms = keymap::tokenize(text).map_err(unsupported)?;
        self.type_syms(&syms)
    }

    fn press_enter(&mut self) -> Result<(), IoError> {
        self.type_syms(&[Sym::Return])
    }
}

/// A live connection with a virtual keyboard.
struct Session {
    conn: Connection,
    queue: EventQueue<State>,
    state: State,
    keyboard: ZwpVirtualKeyboardV1,
    _manager: ZwpVirtualKeyboardManagerV1,
    _seat: wl_seat::WlSeat,
    syncs_sent: u64,
    /// The keymap the compositor currently has for this keyboard.
    keymap: Keymap,
    timeout: Duration,
    /// Deadline of the call in progress (see `TyperConfig::call_timeout`).
    call_deadline: Option<Instant>,
}

#[derive(Default)]
struct State {
    globals: Vec<(u32, String, u32)>,
    syncs_done: u64,
}

impl Session {
    /// Connects and creates the keyboard. With `call_deadline`, every wait
    /// here is also cut to the time left in the call.
    fn open(config: &TyperConfig, call_deadline: Option<Instant>) -> Result<Self, IoError> {
        let now = Instant::now();
        let deadline = now + wait_budget(config.timeout, call_deadline, now)?;
        let path = match &config.display {
            // `connect_to_env` reads WAYLAND_SOCKET with `env::var`; a value
            // that is not UTF-8 would make it fall through to a blocking
            // connect, so reject that here.
            Display::Env if std::env::var("WAYLAND_SOCKET").is_ok() => None,
            Display::Env if std::env::var_os("WAYLAND_SOCKET").is_some() => {
                return Err(IoError("WAYLAND_SOCKET is not valid UTF-8".into()));
            }
            Display::Env => Some(env_socket_path()?),
            Display::Socket(path) => Some(path.clone()),
        };
        let conn = match path {
            // An inherited, already connected socket: nothing can block.
            None => Connection::connect_to_env()
                .map_err(|e| IoError(format!("cannot use WAYLAND_SOCKET: {e}")))?,
            Some(path) => {
                let stream = connect_unix(&path, deadline).map_err(|e| {
                    IoError(format!("cannot connect to the Wayland compositor: {e}"))
                })?;
                Connection::from_socket(stream)
                    .map_err(|e| IoError(format!("cannot use the Wayland socket: {e}")))?
            }
        };
        let mut queue = conn.new_event_queue::<State>();
        let qh = queue.handle();
        let registry = conn.display().get_registry(&qh, ());
        let mut state = State::default();
        let mut syncs_sent = 0;
        sync(
            &conn,
            &mut queue,
            &mut state,
            &mut syncs_sent,
            wait_budget(config.timeout, call_deadline, Instant::now())?,
        )?;

        let find = |name: &str| {
            state
                .globals
                .iter()
                .find(|(_, iface, _)| iface == name)
                .map(|&(id, _, version)| (id, version))
        };
        let (manager_name, _) = find("zwp_virtual_keyboard_manager_v1").ok_or_else(|| {
            IoError(
                "the Wayland compositor does not support the virtual keyboard protocol \
                 (zwp_virtual_keyboard_manager_v1)"
                    .into(),
            )
        })?;
        let (seat_name, seat_version) =
            find("wl_seat").ok_or_else(|| IoError("the Wayland compositor has no seat".into()))?;
        let manager: ZwpVirtualKeyboardManagerV1 = registry.bind(manager_name, 1, &qh, ());
        let seat: wl_seat::WlSeat = registry.bind(seat_name, seat_version.min(1), &qh, ());
        let keyboard = manager.create_virtual_keyboard(&seat, &qh, ());

        let mut session = Session {
            conn,
            queue,
            state,
            keyboard,
            _manager: manager,
            _seat: seat,
            syncs_sent,
            keymap: Keymap::base(),
            timeout: config.timeout,
            call_deadline,
        };
        // A keymap must be set before any key event; the base keymap has
        // Return and Tab.
        session.upload(&Keymap::base())?;
        session.sync()?;
        Ok(session)
    }

    fn upload(&mut self, keymap: &Keymap) -> Result<(), IoError> {
        let text = keymap.to_xkb();
        let (fd, size) = memfd::sealed_keymap(&text)
            .map_err(|e| IoError(format!("cannot create keymap memfd: {e}")))?;
        // The request duplicates the fd into the outgoing queue, so `fd`
        // can close when this function returns.
        self.keyboard
            .keymap(wl_keyboard::KeymapFormat::XkbV1.into(), fd.as_fd(), size);
        self.keymap = keymap.clone();
        // A new keymap starts with no modifiers; say so explicitly.
        self.keyboard.modifiers(0, 0, 0, 0);
        self.flush()
    }

    /// Presses and releases one key.
    fn tap(&mut self, code: u32) -> Result<(), IoError> {
        let t = now_ms();
        self.keyboard
            .key(t, code, wl_keyboard::KeyState::Pressed.into());
        self.keyboard
            .key(t, code, wl_keyboard::KeyState::Released.into());
        self.flush()
    }

    fn budget(&self) -> Result<Duration, IoError> {
        wait_budget(self.timeout, self.call_deadline, Instant::now())
    }

    fn flush(&mut self) -> Result<(), IoError> {
        let t = self.budget()?;
        flush(&self.conn, t)
    }

    fn sync(&mut self) -> Result<(), IoError> {
        let t = self.budget()?;
        sync(
            &self.conn,
            &mut self.queue,
            &mut self.state,
            &mut self.syncs_sent,
            t,
        )
    }

    fn close(&mut self) {
        self.keyboard.destroy();
        let _ = self.conn.flush();
    }
}

/// Milliseconds of CLOCK_MONOTONIC, the clock compositors use for input
/// timestamps. Wraps after 49 days, as the protocol expects.
fn now_ms() -> u32 {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: valid pointer to a timespec; CLOCK_MONOTONIC always exists.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    (ts.tv_sec as u64)
        .wrapping_mul(1000)
        .wrapping_add(ts.tv_nsec as u64 / 1_000_000) as u32
}

/// Maps a backend error to a fixed description. The compositor's free-form
/// message is deliberately dropped; only the interface and numeric code
/// (protocol metadata) are kept.
fn wayland_error(e: WaylandError) -> IoError {
    match e {
        WaylandError::Protocol(p) => {
            let what = match (p.object_interface.as_str(), p.code) {
                ("zwp_virtual_keyboard_manager_v1", 0) => {
                    " (the compositor refused to create a virtual keyboard)"
                }
                ("zwp_virtual_keyboard_v1", 0) => " (key sent before a keymap)",
                _ => "",
            };
            IoError(format!(
                "Wayland protocol error on {} (code {}){what}",
                p.object_interface, p.code
            ))
        }
        WaylandError::Io(e) => IoError(format!("Wayland connection error: {}", e.kind())),
    }
}

/// The socket `WAYLAND_DISPLAY` names, resolved like `wayland-client`
/// does: absolute, or relative to `XDG_RUNTIME_DIR`.
fn env_socket_path() -> Result<PathBuf, IoError> {
    let name = std::env::var_os("WAYLAND_DISPLAY")
        .map(PathBuf::from)
        .ok_or_else(|| IoError("WAYLAND_DISPLAY is not set".into()))?;
    if name.is_absolute() {
        return Ok(name);
    }
    let dir = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|d| d.is_absolute())
        .ok_or_else(|| IoError("XDG_RUNTIME_DIR is not set".into()))?;
    Ok(dir.join(name))
}

/// Connects a Unix stream socket without blocking past `deadline`. A
/// compositor whose listen backlog is full makes a blocking `connect` wait
/// forever; non-blocking it returns `EAGAIN`, and we retry until the
/// deadline.
fn connect_unix(path: &Path, deadline: Instant) -> std::io::Result<UnixStream> {
    use std::io::{Error, ErrorKind};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;

    let bytes = path.as_os_str().as_bytes();
    // SAFETY: an all-zero sockaddr_un is valid.
    let mut addr: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.is_empty() || bytes.len() >= addr.sun_path.len() || bytes.contains(&0) {
        return Err(Error::new(ErrorKind::InvalidInput, "bad socket path"));
    }
    addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (dst, &src) in addr.sun_path.iter_mut().zip(bytes) {
        *dst = src as libc::c_char;
    }
    let len = (std::mem::size_of::<libc::sa_family_t>() + bytes.len() + 1) as libc::socklen_t;
    loop {
        // SAFETY: plain socket(2).
        let raw = unsafe {
            libc::socket(
                libc::AF_UNIX,
                libc::SOCK_STREAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
                0,
            )
        };
        if raw < 0 {
            return Err(Error::last_os_error());
        }
        // SAFETY: fresh fd owned by nobody else.
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        // SAFETY: addr is a valid sockaddr_un of `len` bytes.
        let r = unsafe {
            libc::connect(
                fd.as_raw_fd(),
                (&addr as *const libc::sockaddr_un).cast(),
                len,
            )
        };
        let err = if r == 0 {
            None
        } else {
            Some(Error::last_os_error())
        };
        match err.as_ref().and_then(Error::raw_os_error) {
            None => {}
            Some(libc::EINTR) => continue,
            Some(libc::EAGAIN) => {
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    return Err(Error::new(
                        ErrorKind::TimedOut,
                        "the compositor is not accepting connections",
                    ));
                }
                std::thread::sleep(left.min(Duration::from_millis(5)));
                continue;
            }
            Some(libc::EINPROGRESS) => {
                use std::os::fd::AsFd;
                wait_fd(fd.as_fd(), libc::POLLOUT, deadline)
                    .map_err(|_| Error::new(ErrorKind::TimedOut, "connect timed out"))?;
                let mut so_error: libc::c_int = 0;
                let mut optlen = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
                // SAFETY: valid out-pointers of the right size.
                let r = unsafe {
                    libc::getsockopt(
                        fd.as_raw_fd(),
                        libc::SOL_SOCKET,
                        libc::SO_ERROR,
                        (&mut so_error as *mut libc::c_int).cast(),
                        &mut optlen,
                    )
                };
                if r < 0 {
                    return Err(Error::last_os_error());
                }
                if so_error != 0 {
                    return Err(Error::from_raw_os_error(so_error));
                }
            }
            Some(_) => return Err(err.expect("error present")),
        }
        let stream = UnixStream::from(fd);
        stream.set_nonblocking(false)?;
        return Ok(stream);
    }
}

fn would_block(e: &WaylandError) -> bool {
    matches!(e, WaylandError::Io(io) if io.kind() == std::io::ErrorKind::WouldBlock)
}

/// Waits until `fd` is ready for `events` or the deadline passes.
fn wait_fd(fd: std::os::fd::BorrowedFd<'_>, events: i16, deadline: Instant) -> Result<(), IoError> {
    use std::os::fd::AsRawFd;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(IoError(
                "timed out waiting for the Wayland compositor".into(),
            ));
        }
        let mut pfd = libc::pollfd {
            fd: fd.as_raw_fd(),
            events,
            revents: 0,
        };
        let ms = left.as_millis().clamp(1, i32::MAX as u128) as i32;
        // SAFETY: one valid pollfd.
        let n = unsafe { libc::poll(&mut pfd, 1, ms) };
        if n < 0 {
            let err = std::io::Error::last_os_error();
            if err.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(IoError(format!("poll on the Wayland socket failed: {err}")));
        }
        if n > 0 {
            // Readiness, hang-up or error: let the caller's next I/O
            // operation report what happened.
            return Ok(());
        }
    }
}

/// Writes all queued requests, waiting for socket space as needed.
fn flush(conn: &Connection, timeout: Duration) -> Result<(), IoError> {
    let deadline = Instant::now() + timeout;
    loop {
        match conn.flush() {
            Ok(()) => return Ok(()),
            Err(e) if would_block(&e) => {
                let backend = conn.backend();
                wait_fd(backend.poll_fd(), libc::POLLOUT, deadline)?;
            }
            Err(e) => return Err(wayland_error(e)),
        }
    }
}

/// Round trip with a deadline: returns once the compositor has processed
/// every request sent so far. Surfaces protocol errors (such as an
/// unauthorized virtual keyboard) as `Err`.
fn sync(
    conn: &Connection,
    queue: &mut EventQueue<State>,
    state: &mut State,
    syncs_sent: &mut u64,
    timeout: Duration,
) -> Result<(), IoError> {
    let deadline = Instant::now() + timeout;
    *syncs_sent += 1;
    let target = *syncs_sent;
    conn.display().sync(&queue.handle(), target);
    loop {
        queue
            .dispatch_pending(state)
            .map_err(|e| IoError(format!("Wayland dispatch failed: {e}")))?;
        if state.syncs_done >= target {
            return Ok(());
        }
        flush(conn, deadline.saturating_duration_since(Instant::now()))?;
        if let Some(guard) = queue.prepare_read() {
            wait_fd(guard.connection_fd(), libc::POLLIN, deadline)?;
            match guard.read() {
                Ok(_) => {}
                Err(e) if would_block(&e) => {}
                Err(e) => return Err(wayland_error(e)),
            }
        }
    }
}

impl Dispatch<wl_registry::WlRegistry, ()> for State {
    fn event(
        state: &mut Self,
        _: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            wl_registry::Event::Global {
                name,
                interface,
                version,
            } => state.globals.push((name, interface, version)),
            wl_registry::Event::GlobalRemove { name } => {
                state.globals.retain(|&(n, _, _)| n != name)
            }
            _ => {}
        }
    }
}

impl Dispatch<wl_callback::WlCallback, u64> for State {
    fn event(
        state: &mut Self,
        _: &wl_callback::WlCallback,
        event: wl_callback::Event,
        target: &u64,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_callback::Event::Done { .. } = event {
            state.syncs_done = state.syncs_done.max(*target);
        }
    }
}

wayland_client::delegate_noop!(State: ignore wl_seat::WlSeat);
wayland_client::delegate_noop!(State: ZwpVirtualKeyboardManagerV1);
wayland_client::delegate_noop!(State: ZwpVirtualKeyboardV1);

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::fs::DirBuilderExt;

    #[test]
    fn call_deadline_cuts_every_wait() {
        let now = Instant::now();
        let t = Duration::from_secs(1);
        // No call deadline: the per-wait timeout.
        assert_eq!(wait_budget(t, None, now).unwrap(), t);
        // A nearer deadline shortens the wait.
        let d = now + Duration::from_millis(300);
        assert_eq!(
            wait_budget(t, Some(d), now).unwrap(),
            Duration::from_millis(300)
        );
        // A farther one does not lengthen it.
        assert_eq!(
            wait_budget(t, Some(now + Duration::from_secs(9)), now).unwrap(),
            t
        );
        // Once it has passed, the call fails.
        assert!(wait_budget(t, Some(now), now).is_err());
        assert!(wait_budget(t, Some(now), now + Duration::from_millis(1)).is_err());
    }

    /// A private listening socket with a backlog of 0 that never accepts.
    fn stuck_listener(dir: &Path) -> (OwnedFd, PathBuf) {
        let path = dir.join("stuck");
        // SAFETY: plain socket/bind/listen on a fresh fd and a valid address.
        unsafe {
            let fd = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0);
            assert!(fd >= 0);
            let fd = OwnedFd::from_raw_fd(fd);
            let mut addr: libc::sockaddr_un = std::mem::zeroed();
            addr.sun_family = libc::AF_UNIX as libc::sa_family_t;
            for (d, &s) in addr
                .sun_path
                .iter_mut()
                .zip(path.as_os_str().as_encoded_bytes())
            {
                *d = s as libc::c_char;
            }
            let len = std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t;
            assert_eq!(
                libc::bind(
                    fd.as_raw_fd(),
                    (&addr as *const libc::sockaddr_un).cast(),
                    len
                ),
                0
            );
            assert_eq!(libc::listen(fd.as_raw_fd(), 0), 0);
            (fd, path)
        }
    }

    #[test]
    fn connect_times_out_when_the_compositor_never_accepts() {
        let dir = std::env::temp_dir().join(format!("lf-wayland-unit-{}", std::process::id()));
        std::fs::DirBuilder::new().mode(0o700).create(&dir).unwrap();
        let (_listener, path) = stuck_listener(&dir);
        // Fill the backlog (0 admits one pending connection).
        let _filler = UnixStream::connect(&path).unwrap();
        let mut typer = WaylandTyper::new(TyperConfig {
            display: Display::Socket(path.clone()),
            timeout: Duration::from_millis(300),
            ..TyperConfig::default()
        });
        let t0 = Instant::now();
        let err = typer.connect().expect_err("must time out");
        let took = t0.elapsed();
        let _ = std::fs::remove_dir_all(&dir);
        assert!(took < Duration::from_secs(2), "took {took:?}");
        assert!(err.0.contains("not accepting"), "{err}");
    }

    #[test]
    fn handshake_times_out_when_the_compositor_is_silent() {
        let dir = std::env::temp_dir().join(format!("lf-wayland-unit2-{}", std::process::id()));
        std::fs::DirBuilder::new().mode(0o700).create(&dir).unwrap();
        let path = dir.join("silent");
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let mut typer = WaylandTyper::new(TyperConfig {
            display: Display::Socket(path.clone()),
            timeout: Duration::from_millis(300),
            ..TyperConfig::default()
        });
        let t0 = Instant::now();
        let err = typer.connect().expect_err("must time out");
        let took = t0.elapsed();
        drop(listener);
        let _ = std::fs::remove_dir_all(&dir);
        assert!(took < Duration::from_secs(2), "took {took:?}");
        assert!(err.0.contains("timed out"), "{err}");
    }

    #[test]
    fn missing_socket_fails_cleanly() {
        let mut typer = WaylandTyper::new(TyperConfig {
            display: Display::Socket(std::env::temp_dir().join("lf-wayland-no-such-socket")),
            ..TyperConfig::default()
        });
        assert!(typer.connect().is_err());
        assert!(typer.type_text("x").is_err());
    }
}

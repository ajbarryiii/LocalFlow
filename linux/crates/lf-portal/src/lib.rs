//! Text output through the xdg-desktop-portal RemoteDesktop interface and
//! libei: the cross-desktop route for compositors without the wlroots
//! virtual keyboard (GNOME 45+, KDE Plasma 6).
//!
//! [`PortalTyper`] negotiates a keyboard-only RemoteDesktop session on a
//! background thread ([`portal`]), asking for a restore token so the desktop
//! asks the user once and then remembers the grant. The portal hands back
//! an EIS socket, on which [`ei`] types: characters are mapped through the
//! keymap the desktop sends (see `lf-keyboard`), so text the desktop's
//! layout cannot produce is refused, never typed differently.
//!
//! The first `Start` may show a permission dialog. It runs on the
//! negotiation thread with its own long timeout; typing calls never wait
//! for it beyond their own deadline, and fail with "waiting for permission"
//! until it is granted.
//!
//! Privacy: text is never logged or included in errors. The restore token
//! is a credential for the grant: it goes only to [`TokenStore`], never to
//! errors. The portal's own error messages are not passed on.

pub mod ei;
pub mod portal;

use std::cell::RefCell;
use std::os::fd::OwnedFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use lf_io_api::{IoError, TextOutput};
use lf_keyboard::{Pace, Rmlvo, Token, type_strokes, wait_budget};

pub use portal::{Timeouts, probe};

/// Where the restore token is kept between runs.
pub trait TokenStore: Send {
    /// The stored token, if any.
    fn load(&mut self) -> Option<String>;
    /// Replaces the stored token (the portal issues a new one each time).
    fn save(&mut self, token: &str);
}

/// A store that forgets everything: the desktop asks again every run.
#[derive(Default)]
pub struct NoTokenStore;

impl TokenStore for NoTokenStore {
    fn load(&mut self) -> Option<String> {
        None
    }
    fn save(&mut self, _token: &str) {}
}

/// Typing configuration.
#[derive(Clone, Debug)]
pub struct PortalConfig {
    /// A D-Bus address; `None` means the session bus.
    pub address: Option<String>,
    /// Pause after each character.
    pub key_delay: Duration,
    /// Upper bound for any single wait on the desktop.
    pub timeout: Duration,
    /// Upper bound for one whole `check`/`type_text`/`press_enter` call,
    /// waiting for the session included.
    pub call_timeout: Option<Duration>,
    /// Portal call bounds (on the negotiation thread).
    pub portal: Timeouts,
    /// The layout to use if the desktop sends no keymap.
    pub fallback_layout: Rmlvo,
}

impl Default for PortalConfig {
    fn default() -> Self {
        Self {
            address: None,
            key_delay: Duration::from_millis(1),
            timeout: Duration::from_secs(1),
            call_timeout: None,
            portal: Timeouts {
                call: Duration::from_secs(5),
                permission: Duration::from_secs(300),
            },
            fallback_layout: Rmlvo::default(),
        }
    }
}

enum Phase {
    Pending,
    /// The EIS socket, until the typer takes it.
    Ready(Option<OwnedFd>),
    Failed(IoError),
}

/// One negotiation on its own thread, which keeps the session open until
/// told to stop.
struct Negotiation {
    phase: Mutex<Phase>,
    changed: Condvar,
    stop: AtomicBool,
}

impl Negotiation {
    fn lock(&self) -> MutexGuard<'_, Phase> {
        self.phase.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn set(&self, phase: Phase) {
        *self.lock() = phase;
        self.changed.notify_all();
    }

    fn start(config: &PortalConfig, store: Arc<Mutex<Box<dyn TokenStore>>>) -> Arc<Negotiation> {
        let n = Arc::new(Negotiation {
            phase: Mutex::new(Phase::Pending),
            changed: Condvar::new(),
            stop: AtomicBool::new(false),
        });
        let (thread_n, address, timeouts) = (n.clone(), config.address.clone(), config.portal);
        let spawned = std::thread::Builder::new()
            .name("lf-portal".into())
            .spawn(move || run(&thread_n, address, timeouts, &store));
        if spawned.is_err() {
            n.set(Phase::Failed(IoError(
                "cannot start the portal thread".into(),
            )));
        }
        n
    }

    /// Asks the thread to close the session and exit.
    fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
        let _guard = self.lock();
        self.changed.notify_all();
    }

    /// Waits until the negotiation is no longer pending, or `deadline`.
    fn wait(&self, deadline: Instant) -> MutexGuard<'_, Phase> {
        let mut guard = self.lock();
        loop {
            if !matches!(*guard, Phase::Pending) {
                return guard;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return guard;
            }
            guard = self
                .changed
                .wait_timeout(guard, left)
                .unwrap_or_else(|e| e.into_inner())
                .0;
        }
    }
}

fn lock_store(store: &Mutex<Box<dyn TokenStore>>) -> MutexGuard<'_, Box<dyn TokenStore>> {
    store.lock().unwrap_or_else(|e| e.into_inner())
}

fn run(
    n: &Negotiation,
    address: Option<String>,
    timeouts: Timeouts,
    store: &Mutex<Box<dyn TokenStore>>,
) {
    let restore = lock_store(store).load();
    let result = async_io::block_on(portal::negotiate(
        address.as_deref(),
        restore,
        timeouts,
        &n.stop,
    ));
    let negotiated = match result {
        Ok(negotiated) => negotiated,
        Err(e) => return n.set(Phase::Failed(e)),
    };
    if let Some(token) = &negotiated.restore_token {
        lock_store(store).save(token);
    }
    n.set(Phase::Ready(Some(negotiated.eis)));
    // Hold the connection (and so the session) until told to stop. zbus
    // reads the connection on its own thread meanwhile.
    let mut guard = n.lock();
    while !n.stop.load(Ordering::SeqCst) {
        guard = n.changed.wait(guard).unwrap_or_else(|e| e.into_inner());
    }
    drop(guard);
    portal::bounded(
        timeouts.call,
        portal::close(&negotiated.conn, &negotiated.session, timeouts.call),
    );
}

struct Inner {
    config: PortalConfig,
    store: Arc<Mutex<Box<dyn TokenStore>>>,
    negotiation: Option<Arc<Negotiation>>,
    session: Option<ei::EiSession>,
}

impl Inner {
    fn restart(&mut self) -> Arc<Negotiation> {
        self.session = None;
        if let Some(old) = self.negotiation.take() {
            old.stop();
        }
        let n = Negotiation::start(&self.config, self.store.clone());
        self.negotiation = Some(n.clone());
        n
    }

    /// A live EIS session with a usable keyboard, within `deadline`.
    fn session(&mut self, deadline: Instant) -> Result<&mut ei::EiSession, IoError> {
        let alive = match self.session.as_mut() {
            // Something may have ended it since the last call.
            Some(s) => {
                let budget = wait_budget(self.config.timeout, Some(deadline), Instant::now())?;
                s.roundtrip(Instant::now() + budget).is_ok()
            }
            None => false,
        };
        if alive {
            return Ok(self.session.as_mut().expect("alive session"));
        }
        self.session = None;
        let mut restarted = false;
        loop {
            let n = match &self.negotiation {
                Some(n) => n.clone(),
                None => {
                    restarted = true;
                    self.restart()
                }
            };
            let fd = {
                let mut phase = n.wait(deadline);
                match &mut *phase {
                    Phase::Pending => {
                        return Err(IoError(
                            "waiting for the desktop to allow LocalFlow to type (remote desktop permission)"
                                .into(),
                        ));
                    }
                    Phase::Failed(e) => {
                        let e = e.clone();
                        drop(phase);
                        // The next call starts over.
                        self.negotiation = None;
                        return Err(e);
                    }
                    Phase::Ready(fd) => fd.take(),
                }
            };
            match fd {
                Some(fd) => {
                    let session =
                        ei::EiSession::open(fd, self.config.fallback_layout.clone(), deadline);
                    match session {
                        Ok(s) => return Ok(self.session.insert(s)),
                        Err(e) => {
                            // A session whose EIS connection failed is no use.
                            if let Some(n) = self.negotiation.take() {
                                n.stop();
                            }
                            return Err(e);
                        }
                    }
                }
                // The socket was used by an earlier session that has
                // ended: negotiate again (with the restore token, so
                // without asking), once per call.
                None if !restarted => {
                    restarted = true;
                    self.restart();
                }
                None => {
                    return Err(IoError("the desktop ended the input session".into()));
                }
            }
        }
    }

    fn deadline(&self) -> Instant {
        Instant::now() + self.config.call_timeout.unwrap_or(self.config.timeout)
    }

    fn type_tokens(&mut self, text: Option<&str>) -> Result<(), IoError> {
        if text == Some("") {
            return Ok(());
        }
        let deadline = self.deadline();
        let result = self.type_within(text, deadline);
        if result.is_err() {
            // Drop the connection: that releases any key still held.
            self.session = None;
        }
        result
    }

    fn type_within(&mut self, text: Option<&str>, deadline: Instant) -> Result<(), IoError> {
        let pace = Pace {
            key_delay: self.config.key_delay,
            timeout: self.config.timeout,
            deadline: Some(deadline),
        };
        let session = self.session(deadline)?;
        let strokes = match text {
            Some(text) => session.layout()?.strokes(text)?,
            None => vec![
                session
                    .layout()?
                    .stroke(Token::Return)
                    .ok_or_else(|| IoError("the desktop's keymap has no Return key".into()))?
                    .clone(),
            ],
        };
        if strokes.is_empty() {
            return Ok(());
        }
        type_strokes(session, &strokes, pace)?;
        session.stop_emulating(deadline)
    }
}

impl Drop for Inner {
    fn drop(&mut self) {
        self.session = None;
        if let Some(n) = self.negotiation.take() {
            n.stop();
        }
    }
}

/// `TextOutput` backed by the RemoteDesktop portal and libei.
///
/// Thread-safe to move, not to share: `check` takes `&self` but may need to
/// set up the session, so the state sits in a `RefCell`.
pub struct PortalTyper {
    inner: RefCell<Inner>,
}

impl PortalTyper {
    /// Opens nothing yet.
    pub fn new(config: PortalConfig, store: Box<dyn TokenStore>) -> Self {
        Self {
            inner: RefCell::new(Inner {
                config,
                store: Arc::new(Mutex::new(store)),
                negotiation: None,
                session: None,
            }),
        }
    }

    /// Starts negotiating now, in the background, so a first-time
    /// permission dialog appears at startup rather than at the first
    /// dictation. Returns at once.
    pub fn connect(&mut self) {
        let inner = self.inner.get_mut();
        if inner.negotiation.is_none() {
            inner.restart();
        }
    }
}

impl TextOutput for PortalTyper {
    fn check(&self, text: &str) -> Result<(), IoError> {
        let mut inner = self.inner.borrow_mut();
        let deadline = inner.deadline();
        inner
            .session(deadline)
            .and_then(|s| s.layout()?.strokes(text).map(|_| ()))
    }

    fn type_text(&mut self, text: &str) -> Result<(), IoError> {
        self.inner.get_mut().type_tokens(Some(text))
    }

    fn press_enter(&mut self) -> Result<(), IoError> {
        self.inner.get_mut().type_tokens(None)
    }
}

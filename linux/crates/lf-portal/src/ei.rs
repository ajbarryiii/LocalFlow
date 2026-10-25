//! A libei sender client over the socket the portal hands out, with the
//! pure-Rust `reis` protocol bindings.
//!
//! The client completes the handshake, binds the keyboard capability of the
//! first seat that offers one, and waits for a keyboard device that the
//! server has resumed. Characters are mapped through the keymap the server
//! sends for that device (with its current group and locked modifiers);
//! without one, through the fallback layout. Each key event is framed on its
//! own, inside one `start_emulating`/`stop_emulating` per call.
//!
//! The socket stays non-blocking; every wait is a `poll` bounded by the
//! caller's deadline. Nothing here logs; server messages (disconnect
//! explanations) are dropped.

use std::os::fd::{AsFd, AsRawFd, BorrowedFd, OwnedFd};
use std::os::unix::fs::FileExt;
use std::os::unix::net::UnixStream;
use std::time::Instant;

use lf_io_api::IoError;
use lf_keyboard::{KeySink, Layout, Rmlvo};
use reis::ei;
use reis::handshake::EiHandshaker;
use reis::{Interface as _, PendingRequestResult};

/// Name the client gives the server (desktops may show it).
pub const CLIENT_NAME: &str = "localflowd";
/// Largest keymap accepted from the server.
const MAX_KEYMAP_BYTES: u32 = 4 << 20;

struct Seat {
    seat: ei::Seat,
    keyboard_mask: Option<u64>,
}

struct Device {
    device: ei::Device,
    keyboard: Option<ei::Keyboard>,
    keymap: Option<String>,
    group: u32,
    locked: u32,
    done: bool,
    resumed: bool,
    layout: Option<Layout>,
}

/// A connected libei client with (eventually) a usable keyboard.
pub struct EiSession {
    ctx: ei::Context,
    connection: ei::Connection,
    last_serial: u32,
    sequence: u32,
    seats: Vec<Seat>,
    devices: Vec<Device>,
    /// The device being emulated on, between `start_emulating` and
    /// `stop_emulating`.
    emulating: Option<ei::Device>,
    /// Outstanding `ei_connection.sync` callback, and whether it is done.
    sync: Option<(ei::Callback, bool)>,
    fallback: Rmlvo,
    /// Goes up whenever a layout may have changed (new keymap, group or
    /// locked modifiers, a pause): strokes mapped before are stale.
    generation: u64,
}

fn io(what: &str, e: std::io::Error) -> IoError {
    if e.kind() == std::io::ErrorKind::UnexpectedEof {
        IoError("the desktop closed the input connection".into())
    } else {
        IoError(format!("input connection {what} failed: {}", e.kind()))
    }
}

/// Waits until `fd` is ready for `events` or `deadline` passes.
fn wait_fd(fd: BorrowedFd<'_>, events: i16, deadline: Instant) -> Result<(), IoError> {
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(IoError("timed out waiting for the desktop".into()));
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
            return Err(io("poll", err));
        }
        if n > 0 {
            return Ok(());
        }
    }
}

/// Microseconds of CLOCK_MONOTONIC, the clock libei timestamps use.
fn now_us() -> u64 {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: valid pointer to a timespec; CLOCK_MONOTONIC always exists.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    (ts.tv_sec as u64)
        .wrapping_mul(1_000_000)
        .wrapping_add(ts.tv_nsec as u64 / 1000)
}

/// Reads a keymap the server shared as a file descriptor.
fn read_keymap(fd: OwnedFd, size: u32) -> Result<String, IoError> {
    if size == 0 || size > MAX_KEYMAP_BYTES {
        return Err(IoError("the desktop sent a keymap of unusable size".into()));
    }
    let file = std::fs::File::from(fd);
    let mut buf = vec![0u8; size as usize];
    file.read_exact_at(&mut buf, 0)
        .map_err(|e| io("keymap read", e))?;
    while buf.last() == Some(&0) {
        buf.pop();
    }
    String::from_utf8(buf).map_err(|_| IoError("the desktop sent a keymap that is not text".into()))
}

impl EiSession {
    /// Handshakes over `fd` and waits for a resumed keyboard, until
    /// `deadline`.
    pub fn open(fd: OwnedFd, fallback: Rmlvo, deadline: Instant) -> Result<EiSession, IoError> {
        let ctx = ei::Context::new(UnixStream::from(fd)).map_err(|e| io("setup", e))?;
        let mut handshaker = EiHandshaker::new(CLIENT_NAME, ei::handshake::ContextType::Sender);
        let resp = 'handshake: loop {
            while let Some(result) = ctx.pending_event() {
                let event = match result {
                    PendingRequestResult::Request(event) => event,
                    _ => return Err(IoError("the desktop broke the input protocol".into())),
                };
                match handshaker.handle_event(event) {
                    Ok(Some(resp)) => break 'handshake resp,
                    Ok(None) => {}
                    Err(_) => return Err(IoError("the input protocol handshake failed".into())),
                }
            }
            flush(&ctx, deadline)?;
            wait_fd(ctx.as_fd(), libc::POLLIN, deadline)?;
            ctx.read().map_err(|e| io("read", e))?;
        };
        let mut session = EiSession {
            ctx,
            connection: resp.connection,
            last_serial: resp.serial,
            sequence: 0,
            seats: Vec::new(),
            devices: Vec::new(),
            emulating: None,
            sync: None,
            fallback,
            generation: 0,
        };
        session
            .pump(deadline, |s| s.usable().is_some())
            .map_err(|e| {
                if e.0.starts_with("timed out") {
                    IoError("the desktop offered no keyboard in time".into())
                } else {
                    e
                }
            })?;
        // Events the server sent along with the resume (its current
        // modifiers, say) are handled before the first key.
        session.roundtrip(deadline)?;
        Ok(session)
    }

    /// Index of the first keyboard device that is set up and resumed.
    fn usable(&self) -> Option<usize> {
        self.devices
            .iter()
            .position(|d| d.keyboard.is_some() && d.done && d.resumed)
    }

    /// See [`Guard`].
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// The layout of the usable keyboard.
    pub fn layout(&mut self) -> Result<&Layout, IoError> {
        let i = self
            .usable()
            .ok_or_else(|| IoError("the desktop paused LocalFlow's keyboard".into()))?;
        let fallback = &self.fallback;
        let d = &mut self.devices[i];
        if d.layout.is_none() {
            d.layout = Some(match &d.keymap {
                Some(text) => Layout::from_keymap_text(text, d.group, d.locked)?,
                None => Layout::from_names(fallback)?,
            });
        }
        Ok(d.layout.as_ref().expect("layout just set"))
    }

    /// Handles every event already read.
    fn dispatch(&mut self) -> Result<(), IoError> {
        while let Some(result) = self.ctx.pending_event() {
            match result {
                PendingRequestResult::Request(event) => self.handle(event)?,
                // An event for an object already released: nothing to do.
                PendingRequestResult::InvalidObject(_) => {}
                PendingRequestResult::ParseError(_) => {
                    return Err(IoError("the desktop broke the input protocol".into()));
                }
            }
        }
        Ok(())
    }

    fn device_mut(&mut self, device: &ei::Device) -> Option<&mut Device> {
        self.devices.iter_mut().find(|d| &d.device == device)
    }

    fn handle(&mut self, event: ei::Event) -> Result<(), IoError> {
        match event {
            ei::Event::Handshake(..) => {
                return Err(IoError("the desktop broke the input protocol".into()));
            }
            ei::Event::Connection(_, e) => match e {
                ei::connection::Event::Seat { seat } => self.seats.push(Seat {
                    seat,
                    keyboard_mask: None,
                }),
                ei::connection::Event::Ping { ping } => ping.done(0),
                ei::connection::Event::Disconnected { .. } => {
                    return Err(IoError("the desktop ended the input session".into()));
                }
                ei::connection::Event::InvalidObject { last_serial, .. } => {
                    self.last_serial = last_serial;
                }
                _ => {}
            },
            ei::Event::Callback(callback, ei::callback::Event::Done { .. }) => {
                if let Some((c, done)) = &mut self.sync
                    && *c == callback
                {
                    *done = true;
                }
            }
            ei::Event::Seat(seat, e) => match e {
                ei::seat::Event::Capability { mask, interface } => {
                    if interface == ei::Keyboard::NAME
                        && let Some(s) = self.seats.iter_mut().find(|s| s.seat == seat)
                    {
                        s.keyboard_mask = Some(mask);
                    }
                }
                ei::seat::Event::Done => {
                    // Bind only the keyboard; ask for nothing else.
                    if let Some(s) = self.seats.iter().find(|s| s.seat == seat)
                        && let Some(mask) = s.keyboard_mask
                    {
                        seat.bind(mask);
                    }
                }
                ei::seat::Event::Device { device } => self.devices.push(Device {
                    device,
                    keyboard: None,
                    keymap: None,
                    group: 0,
                    locked: 0,
                    done: false,
                    resumed: false,
                    layout: None,
                }),
                ei::seat::Event::Destroyed { serial } => {
                    self.last_serial = serial;
                    self.seats.retain(|s| s.seat != seat);
                }
                _ => {}
            },
            ei::Event::Device(device, e) => match e {
                ei::device::Event::Interface { object } => {
                    if let Some(kb) = object.downcast::<ei::Keyboard>()
                        && let Some(d) = self.device_mut(&device)
                    {
                        d.keyboard = Some(kb);
                    }
                }
                ei::device::Event::Done => {
                    if let Some(d) = self.device_mut(&device) {
                        d.done = true;
                    }
                }
                ei::device::Event::Resumed { serial } => {
                    self.last_serial = serial;
                    if let Some(d) = self.device_mut(&device) {
                        d.resumed = true;
                    }
                }
                ei::device::Event::Paused { serial } => {
                    self.last_serial = serial;
                    if let Some(d) = self.device_mut(&device) {
                        d.resumed = false;
                        // A paused device's modifiers count as released; a
                        // resume announces only a non-zero state.
                        d.locked = 0;
                        d.group = 0;
                        d.layout = None;
                    }
                    self.generation += 1;
                    if self.emulating.as_ref() == Some(&device) {
                        self.emulating = None;
                    }
                }
                ei::device::Event::Destroyed { serial } => {
                    self.last_serial = serial;
                    self.devices.retain(|d| d.device != device);
                    if self.emulating.as_ref() == Some(&device) {
                        self.emulating = None;
                    }
                }
                ei::device::Event::StartEmulating { serial, .. }
                | ei::device::Event::StopEmulating { serial }
                | ei::device::Event::Frame { serial, .. } => self.last_serial = serial,
                _ => {}
            },
            ei::Event::Keyboard(keyboard, e) => {
                let Some(d) = self
                    .devices
                    .iter_mut()
                    .find(|d| d.keyboard.as_ref() == Some(&keyboard))
                else {
                    return Ok(());
                };
                match e {
                    ei::keyboard::Event::Keymap {
                        keymap_type,
                        size,
                        keymap,
                    } => {
                        d.keymap = match keymap_type {
                            ei::keyboard::KeymapType::Xkb => Some(read_keymap(keymap, size)?),
                        };
                        d.layout = None;
                        self.generation += 1;
                    }
                    ei::keyboard::Event::Modifiers {
                        serial,
                        locked,
                        group,
                        ..
                    } => {
                        self.last_serial = serial;
                        if (d.locked, d.group) != (locked, group) {
                            d.locked = locked;
                            d.group = group;
                            d.layout = None;
                            self.generation += 1;
                        }
                    }
                    ei::keyboard::Event::Destroyed { serial } => {
                        self.last_serial = serial;
                        d.keyboard = None;
                    }
                    _ => {}
                }
            }
            _ => {}
        }
        Ok(())
    }

    /// Reads and handles events until `until` holds or `deadline` passes
    /// (which fails).
    fn pump(&mut self, deadline: Instant, until: impl Fn(&Self) -> bool) -> Result<(), IoError> {
        loop {
            self.dispatch()?;
            flush(&self.ctx, deadline)?;
            if until(self) {
                return Ok(());
            }
            wait_fd(self.ctx.as_fd(), libc::POLLIN, deadline)?;
            self.ctx.read().map_err(|e| io("read", e))?;
        }
    }

    /// Handles whatever arrived without waiting (pings, pauses, a
    /// disconnect).
    fn poll_events(&mut self) -> Result<(), IoError> {
        match self.ctx.read() {
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(e) => return Err(io("read", e)),
        }
        self.dispatch()
    }

    /// A round trip: returns once the server has handled everything sent.
    pub fn roundtrip(&mut self, deadline: Instant) -> Result<(), IoError> {
        let callback = self.connection.sync(1);
        self.sync = Some((callback, false));
        let result = self.pump(deadline, |s| matches!(s.sync, Some((_, true))));
        self.sync = None;
        result
    }

    /// Ends the emulation sequence started by the last key, if any.
    pub fn stop_emulating(&mut self, deadline: Instant) -> Result<(), IoError> {
        if let Some(device) = self.emulating.take() {
            device.stop_emulating(self.last_serial);
        }
        flush(&self.ctx, deadline)
    }
}

impl KeySink for EiSession {
    fn key(&mut self, code: u32, pressed: bool) -> Result<(), IoError> {
        let i = self
            .usable()
            .ok_or_else(|| IoError("the desktop paused LocalFlow's keyboard".into()))?;
        let d = &self.devices[i];
        let keyboard = d.keyboard.clone().expect("usable device has a keyboard");
        if self.emulating.as_ref() != Some(&d.device) {
            if let Some(old) = self.emulating.take() {
                old.stop_emulating(self.last_serial);
            }
            d.device.start_emulating(self.last_serial, self.sequence);
            self.sequence = self.sequence.wrapping_add(1);
            self.emulating = Some(d.device.clone());
        }
        let state = if pressed {
            ei::keyboard::KeyState::Press
        } else {
            ei::keyboard::KeyState::Released
        };
        keyboard.key(code, state);
        d.device.frame(self.last_serial, now_us());
        Ok(())
    }

    fn flush(&mut self, deadline: Instant) -> Result<(), IoError> {
        flush(&self.ctx, deadline)?;
        self.poll_events()?;
        if self.usable().is_none() {
            return Err(IoError("the desktop paused LocalFlow's keyboard".into()));
        }
        Ok(())
    }

    fn sync(&mut self, deadline: Instant) -> Result<(), IoError> {
        self.roundtrip(deadline)
    }
}

/// Writes everything queued, waiting for socket space until `deadline`.
fn flush(ctx: &ei::Context, deadline: Instant) -> Result<(), IoError> {
    loop {
        match ctx.flush() {
            Ok(()) => return Ok(()),
            Err(e) if e.raw_os_error() == libc::EAGAIN => {
                wait_fd(ctx.as_fd(), libc::POLLOUT, deadline)?
            }
            Err(e) if e.raw_os_error() == libc::EINTR => {}
            Err(e) => {
                return Err(io(
                    "write",
                    std::io::Error::from_raw_os_error(e.raw_os_error()),
                ));
            }
        }
    }
}

/// Key events for strokes mapped at layout generation `generation`: fails
/// as soon as the desktop changes the layout (switches group, locks Caps
/// Lock, sends a new keymap, pauses the keyboard), so the rest of the text
/// is never typed with stale keys.
pub struct Guard<'a> {
    session: &'a mut EiSession,
    generation: u64,
}

impl<'a> Guard<'a> {
    pub fn new(session: &'a mut EiSession, generation: u64) -> Self {
        Self {
            session,
            generation,
        }
    }

    fn current(&self) -> Result<(), IoError> {
        if self.session.generation == self.generation {
            Ok(())
        } else {
            Err(IoError(
                "the desktop's keyboard layout changed while typing".into(),
            ))
        }
    }
}

impl KeySink for Guard<'_> {
    fn key(&mut self, code: u32, pressed: bool) -> Result<(), IoError> {
        // Whatever the desktop sent meanwhile (during the key delay, say)
        // counts before the next key goes out. A change still in flight
        // is caught at the next flush.
        self.session.poll_events()?;
        self.current()?;
        self.session.key(code, pressed)
    }

    fn flush(&mut self, deadline: Instant) -> Result<(), IoError> {
        self.session.flush(deadline)?;
        self.current()
    }

    fn sync(&mut self, deadline: Instant) -> Result<(), IoError> {
        self.session.sync(deadline)?;
        self.current()
    }
}

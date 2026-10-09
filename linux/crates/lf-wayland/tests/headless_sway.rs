//! End-to-end typing test against a private, headless sway.
//!
//! The harness starts its own sway (`WLR_BACKENDS=headless`, no input
//! devices, no XWayland) in a fresh private `XDG_RUNTIME_DIR`, points
//! `WAYLAND_DISPLAY` at that sway's socket and refuses to run unless the
//! environment resolves to exactly that socket. A small client maps a window,
//! receives `wl_keyboard` events and decodes them with libxkbcommon. The test
//! asserts that typed text round-trips exactly.
//!
//! It never connects to the user's session. It needs `sway` on `PATH` (the
//! `linux/flake.nix` dev shell provides it); set
//! `LF_SKIP_COMPOSITOR_TESTS=1` to skip it elsewhere.
//!
//! This is a `harness = false` test so it can set the process environment
//! before any thread exists.

use std::collections::HashSet;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd};
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use lf_io_api::TextOutput;
use lf_wayland::{Display, TyperConfig, WaylandTyper};
use wayland_client::protocol::{
    wl_buffer, wl_compositor, wl_keyboard, wl_registry, wl_seat, wl_shm, wl_shm_pool, wl_surface,
};
use wayland_client::{Connection, Dispatch, EventQueue, QueueHandle, WEnum};
use wayland_protocols::xdg::shell::client::{xdg_surface, xdg_toplevel, xdg_wm_base};
use xkbcommon::xkb;

const WAIT: Duration = Duration::from_secs(15);

// ---------------------------------------------------------------- compositor

struct PrivateSway {
    dir: PathBuf,
    socket: PathBuf,
    child: Child,
}

impl PrivateSway {
    fn start() -> PrivateSway {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .subsec_nanos();
        let dir = std::env::temp_dir().join(format!(
            "lf-wayland-test-{}-{nanos:08x}",
            std::process::id()
        ));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&dir)
            .expect("create private runtime dir");
        let dir = dir.canonicalize().unwrap();
        let config = dir.join("sway.conf");
        std::fs::write(&config, "xwayland disable\nswaybg_command -\n").unwrap();
        let log = std::fs::File::create(dir.join("sway.log")).unwrap();
        let path = std::env::var_os("PATH").unwrap_or_default();
        let mut cmd = Command::new("sway");
        cmd.arg("-c")
            .arg(&config)
            .env_clear()
            .env("PATH", path)
            .env("HOME", &dir)
            .env("XDG_RUNTIME_DIR", &dir)
            .env("XDG_CONFIG_HOME", &dir)
            .env("WLR_BACKENDS", "headless")
            .env("WLR_LIBINPUT_NO_DEVICES", "1")
            .env("WLR_RENDERER", "pixman")
            // A bus address that leads nowhere: the nixpkgs wrapper then
            // execs sway directly (no dbus-run-session), and sway can never
            // reach the user's session bus.
            .env(
                "DBUS_SESSION_BUS_ADDRESS",
                format!("unix:path={}", dir.join("no-bus").display()),
            )
            .process_group(0)
            .stdin(Stdio::null())
            .stdout(log.try_clone().unwrap())
            .stderr(log);
        // SAFETY: prctl is async-signal-safe; sway dies with this process.
        unsafe {
            cmd.pre_exec(|| {
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
                Ok(())
            });
        }
        let child = cmd.spawn().expect("spawn sway");
        let mut sway = PrivateSway {
            dir: dir.clone(),
            socket: PathBuf::new(),
            child,
        };
        let deadline = Instant::now() + WAIT;
        loop {
            if let Some(status) = sway.child.try_wait().unwrap() {
                let log = std::fs::read_to_string(dir.join("sway.log")).unwrap_or_default();
                panic!("sway exited early ({status}):\n{log}");
            }
            let socket = std::fs::read_dir(&dir).unwrap().find_map(|e| {
                let name = e.ok()?.file_name().into_string().ok()?;
                (name.starts_with("wayland-") && !name.ends_with(".lock")).then(|| dir.join(name))
            });
            if let Some(socket) = socket
                && UnixStream::connect(&socket).is_ok()
            {
                sway.socket = socket;
                return sway;
            }
            assert!(Instant::now() < deadline, "sway socket did not appear");
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for PrivateSway {
    fn drop(&mut self) {
        // sway leads its own process group; signal the whole group.
        let pgid = self.child.id() as i32;
        // SAFETY: plain kill(2) on our own child's process group.
        unsafe { libc::kill(-pgid, libc::SIGTERM) };
        let deadline = Instant::now() + Duration::from_secs(5);
        while self.child.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        // SAFETY: as above.
        unsafe { libc::kill(-pgid, libc::SIGKILL) };
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// Where a Wayland client following the environment would connect, the
/// same way `wayland-client` resolves it.
fn env_socket() -> Option<PathBuf> {
    if std::env::var_os("WAYLAND_SOCKET").is_some() {
        return None;
    }
    let name = PathBuf::from(std::env::var_os("WAYLAND_DISPLAY")?);
    let path = if name.is_absolute() {
        name
    } else {
        PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR")?).join(name)
    };
    path.canonicalize().ok()
}

/// Refuses to continue unless the environment points at the private sway.
fn guard(sway: &PrivateSway) {
    let resolved = env_socket();
    let ok = resolved.as_deref() == Some(sway.socket.as_path())
        && sway.socket.starts_with(&sway.dir)
        && sway
            .dir
            .starts_with(std::env::temp_dir().canonicalize().unwrap());
    assert!(
        ok,
        "refusing to run: WAYLAND_DISPLAY does not resolve to the private test socket"
    );
}

// ---------------------------------------------------------------- client

#[derive(Default)]
struct Received {
    text: String,
    focused: bool,
    enters: usize,
    keymaps: usize,
    errors: Vec<String>,
    /// When the receiver decoded its latest key press.
    last_key: Option<Instant>,
}

struct Client {
    shared: Arc<Mutex<Received>>,
    compositor: Option<wl_compositor::WlCompositor>,
    shm: Option<wl_shm::WlShm>,
    wm_base: Option<xdg_wm_base::XdgWmBase>,
    surface: Option<wl_surface::WlSurface>,
    buffer: Option<wl_buffer::WlBuffer>,
    keyboard: Option<wl_keyboard::WlKeyboard>,
    xkb_ctx: xkb::Context,
    xkb_state: Option<xkb::State>,
    pressed: HashSet<u32>,
    last_time: u32,
}

impl Client {
    fn error(&self, msg: String) {
        self.shared.lock().unwrap().errors.push(msg);
    }
}

fn shm_buffer(client: &Client, qh: &QueueHandle<Client>) -> wl_buffer::WlBuffer {
    let (w, h) = (64i32, 64i32);
    let size = (w * h * 4) as usize;
    // SAFETY: valid name and flags.
    let raw = unsafe { libc::memfd_create(c"lf-test-buffer".as_ptr(), libc::MFD_CLOEXEC) };
    assert!(raw >= 0);
    // SAFETY: new fd owned by nobody else.
    let fd = unsafe { <std::os::fd::OwnedFd as std::os::fd::FromRawFd>::from_raw_fd(raw) };
    let file = std::fs::File::from(fd);
    file.set_len(size as u64).unwrap();
    let pool = client
        .shm
        .as_ref()
        .unwrap()
        .create_pool(file.as_fd(), size as i32, qh, ());
    let buffer = pool.create_buffer(0, w, h, w * 4, wl_shm::Format::Argb8888, qh, ());
    pool.destroy();
    buffer
}

impl Dispatch<wl_registry::WlRegistry, ()> for Client {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global {
            name,
            interface,
            version,
        } = event
        {
            match interface.as_str() {
                "wl_compositor" => {
                    state.compositor = Some(registry.bind(name, version.min(4), qh, ()))
                }
                "wl_shm" => state.shm = Some(registry.bind(name, 1, qh, ())),
                "xdg_wm_base" => state.wm_base = Some(registry.bind(name, 1, qh, ())),
                "wl_seat" => {
                    let _: wl_seat::WlSeat = registry.bind(name, version.min(5), qh, ());
                }
                _ => {}
            }
        }
    }
}

impl Dispatch<xdg_wm_base::XdgWmBase, ()> for Client {
    fn event(
        _: &mut Self,
        base: &xdg_wm_base::XdgWmBase,
        event: xdg_wm_base::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let xdg_wm_base::Event::Ping { serial } = event {
            base.pong(serial);
        }
    }
}

impl Dispatch<xdg_surface::XdgSurface, ()> for Client {
    fn event(
        state: &mut Self,
        xs: &xdg_surface::XdgSurface,
        event: xdg_surface::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let xdg_surface::Event::Configure { serial } = event {
            xs.ack_configure(serial);
            if state.buffer.is_none() {
                state.buffer = Some(shm_buffer(state, qh));
            }
            let surface = state.surface.as_ref().unwrap();
            surface.attach(state.buffer.as_ref(), 0, 0);
            surface.damage(0, 0, 64, 64);
            surface.commit();
        }
    }
}

impl Dispatch<wl_seat::WlSeat, ()> for Client {
    fn event(
        state: &mut Self,
        seat: &wl_seat::WlSeat,
        event: wl_seat::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_seat::Event::Capabilities {
            capabilities: WEnum::Value(caps),
        } = event
        {
            let has = caps.contains(wl_seat::Capability::Keyboard);
            if has && state.keyboard.is_none() {
                state.keyboard = Some(seat.get_keyboard(qh, ()));
            } else if !has && let Some(kb) = state.keyboard.take() {
                // The last keyboard (our virtual one) went away.
                kb.release();
                state.xkb_state = None;
                state.pressed.clear();
                state.shared.lock().unwrap().focused = false;
            }
        }
    }
}

impl Dispatch<wl_keyboard::WlKeyboard, ()> for Client {
    fn event(
        state: &mut Self,
        _: &wl_keyboard::WlKeyboard,
        event: wl_keyboard::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            wl_keyboard::Event::Keymap { format, fd, size } => {
                if format != WEnum::Value(wl_keyboard::KeymapFormat::XkbV1) {
                    state.error("unexpected keymap format".into());
                    return;
                }
                if !state.pressed.is_empty() {
                    state.error("keymap changed while a key was down".into());
                }
                // SAFETY: the compositor sent a keymap fd of `size` bytes.
                let keymap = unsafe {
                    xkb::Keymap::new_from_fd(
                        &state.xkb_ctx,
                        fd,
                        size as usize,
                        xkb::KEYMAP_FORMAT_TEXT_V1,
                        xkb::COMPILE_NO_FLAGS,
                    )
                };
                match keymap {
                    Ok(Some(km)) => {
                        state.xkb_state = Some(xkb::State::new(&km));
                        state.shared.lock().unwrap().keymaps += 1;
                    }
                    _ => state.error("keymap did not compile".into()),
                }
            }
            wl_keyboard::Event::Enter { keys, .. } => {
                if !keys.is_empty() {
                    state.error("keys already down on enter".into());
                }
                let mut r = state.shared.lock().unwrap();
                r.focused = true;
                r.enters += 1;
            }
            wl_keyboard::Event::Leave { .. } => {
                state.shared.lock().unwrap().focused = false;
            }
            wl_keyboard::Event::Modifiers {
                mods_depressed,
                mods_latched,
                mods_locked,
                group,
                ..
            } => {
                if mods_depressed | mods_latched | mods_locked != 0 {
                    state.error(format!(
                        "non-zero modifiers {mods_depressed:#x}/{mods_latched:#x}/{mods_locked:#x}"
                    ));
                }
                if let Some(s) = state.xkb_state.as_mut() {
                    s.update_mask(mods_depressed, mods_latched, mods_locked, 0, 0, group);
                }
            }
            wl_keyboard::Event::Key {
                time,
                key,
                state: key_state,
                ..
            } => {
                if time < state.last_time {
                    state.error(format!(
                        "time went backwards: {} -> {time}",
                        state.last_time
                    ));
                }
                state.last_time = time;
                match key_state {
                    WEnum::Value(wl_keyboard::KeyState::Pressed) => {
                        if !state.pressed.insert(key) {
                            state.error(format!("key {key} pressed twice"));
                        }
                        // Only ordinary printable keys plus Tab, Return and
                        // Space may appear on the wire.
                        let fixed = [
                            lf_wayland::keymap::KEY_TAB,
                            lf_wayland::keymap::KEY_ENTER,
                            lf_wayland::keymap::KEY_SPACE,
                        ];
                        if !fixed.contains(&key) && !lf_wayland::keymap::char_pool().contains(&key)
                        {
                            state.error(format!("key {key} is outside the allowlist"));
                        }
                        let Some(xs) = state.xkb_state.as_ref() else {
                            state.error("key before keymap".into());
                            return;
                        };
                        let code = xkb::Keycode::new(key + 8);
                        let sym = xs.key_get_one_sym(code).raw();
                        let text = if sym == xkb::keysyms::KEY_Return {
                            "\n".to_owned()
                        } else if sym == xkb::keysyms::KEY_Tab {
                            "\t".to_owned()
                        } else {
                            xs.key_get_utf8(code)
                        };
                        if text.is_empty() {
                            state.error(format!("key {key} (keysym {sym:#x}) has no text"));
                        }
                        let mut r = state.shared.lock().unwrap();
                        r.text.push_str(&text);
                        r.last_key = Some(Instant::now());
                    }
                    WEnum::Value(wl_keyboard::KeyState::Released) => {
                        if !state.pressed.remove(&key) {
                            state.error(format!("key {key} released while up"));
                        }
                    }
                    _ => state.error("unknown key state".into()),
                }
            }
            _ => {}
        }
    }
}

wayland_client::delegate_noop!(Client: ignore wl_compositor::WlCompositor);
wayland_client::delegate_noop!(Client: ignore wl_shm::WlShm);
wayland_client::delegate_noop!(Client: ignore wl_shm_pool::WlShmPool);
wayland_client::delegate_noop!(Client: ignore wl_buffer::WlBuffer);
wayland_client::delegate_noop!(Client: ignore wl_surface::WlSurface);
wayland_client::delegate_noop!(Client: ignore xdg_toplevel::XdgToplevel);

fn poll_in(fd: BorrowedFd<'_>, timeout: Duration) {
    let mut pfd = libc::pollfd {
        fd: fd.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: one valid pollfd.
    unsafe { libc::poll(&mut pfd, 1, timeout.as_millis() as i32) };
}

fn run_client(socket: PathBuf, shared: Arc<Mutex<Received>>, stop: Arc<AtomicBool>) {
    let conn = Connection::from_socket(UnixStream::connect(&socket).unwrap()).unwrap();
    let mut queue: EventQueue<Client> = conn.new_event_queue();
    let qh = queue.handle();
    let _registry = conn.display().get_registry(&qh, ());
    let mut client = Client {
        shared,
        compositor: None,
        shm: None,
        wm_base: None,
        surface: None,
        buffer: None,
        keyboard: None,
        xkb_ctx: xkb::Context::new(xkb::CONTEXT_NO_FLAGS),
        xkb_state: None,
        pressed: HashSet::new(),
        last_time: 0,
    };
    queue.roundtrip(&mut client).unwrap();
    let surface = client.compositor.as_ref().unwrap().create_surface(&qh, ());
    let xs = client
        .wm_base
        .as_ref()
        .unwrap()
        .get_xdg_surface(&surface, &qh, ());
    let toplevel = xs.get_toplevel(&qh, ());
    toplevel.set_title("lf-wayland test".into());
    surface.commit();
    client.surface = Some(surface);

    while !stop.load(Ordering::Relaxed) {
        queue.dispatch_pending(&mut client).unwrap();
        conn.flush().unwrap();
        if let Some(guard) = queue.prepare_read() {
            poll_in(guard.connection_fd(), Duration::from_millis(20));
            match guard.read() {
                Ok(_) => {}
                Err(wayland_client::backend::WaylandError::Io(e))
                    if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(e) => panic!("client connection failed: {e}"),
            }
        }
    }
    if !client.pressed.is_empty() {
        client.error(format!("keys still down at exit: {:?}", client.pressed));
    }
}

// ---------------------------------------------------------------- test

fn wait_until(what: &str, mut f: impl FnMut() -> bool) {
    let deadline = Instant::now() + WAIT;
    while !f() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

struct Harness {
    shared: Arc<Mutex<Received>>,
}

impl Harness {
    fn take(&self) -> String {
        std::mem::take(&mut self.shared.lock().unwrap().text)
    }

    /// Runs `op` and waits until the client has received `expected`.
    fn expect(
        &self,
        name: &str,
        expected: &str,
        op: impl FnOnce() -> Result<(), lf_io_api::IoError>,
    ) {
        assert!(
            self.take().is_empty(),
            "{name}: stray input before the case"
        );
        let t0 = Instant::now();
        op().unwrap_or_else(|e| panic!("{name}: {e}"));
        let elapsed = t0.elapsed();
        let deadline = Instant::now() + WAIT;
        let received = loop {
            let (got, last_key) = {
                let r = self.shared.lock().unwrap();
                (r.text.clone(), r.last_key)
            };
            if got == expected {
                // Timestamped by the receiver when it decoded the last key.
                break last_key.map_or(Duration::ZERO, |t| t.saturating_duration_since(t0));
            }
            if got.len() >= expected.len() || Instant::now() > deadline {
                panic!("{name}: text mismatch\n  expected {expected:?}\n  got      {got:?}");
            }
            std::thread::sleep(Duration::from_micros(200));
        };
        let errors = std::mem::take(&mut self.shared.lock().unwrap().errors);
        assert!(
            errors.is_empty(),
            "{name}: client saw protocol issues: {errors:?}"
        );
        self.take();
        println!(
            "ok   {name}: {} chars in {:.1} ms",
            expected.chars().count(),
            elapsed.as_secs_f64() * 1e3
        );
        println!(
            "     (sender returned after {:.1} ms; the receiver decoded the last key at {:.1} ms)",
            elapsed.as_secs_f64() * 1e3,
            received.as_secs_f64() * 1e3
        );
    }
}

fn main() {
    if std::env::var_os("LF_SKIP_COMPOSITOR_TESTS").is_some() {
        println!("skipped: LF_SKIP_COMPOSITOR_TESTS is set");
        return;
    }
    if Command::new("sway").arg("--version").output().is_err() {
        panic!(
            "sway not found on PATH; run inside `nix develop ./linux` or set LF_SKIP_COMPOSITOR_TESTS=1"
        );
    }

    let sway = PrivateSway::start();
    // Still single-threaded: point the environment at the private socket.
    // SAFETY: no other threads exist yet.
    unsafe {
        std::env::remove_var("WAYLAND_SOCKET");
        std::env::set_var("XDG_RUNTIME_DIR", &sway.dir);
        std::env::set_var("WAYLAND_DISPLAY", sway.socket.file_name().unwrap());
    }
    guard(&sway);

    let shared = Arc::new(Mutex::new(Received::default()));
    let stop = Arc::new(AtomicBool::new(false));
    let client = {
        let (socket, shared, stop) = (sway.socket.clone(), shared.clone(), stop.clone());
        std::thread::spawn(move || run_client(socket, shared, stop))
    };

    // Typer through the environment, exactly as the daemon will connect.
    guard(&sway);
    let mut typer = WaylandTyper::new(TyperConfig::default());
    typer.connect().expect("connect to private sway");
    wait_until("keyboard focus on the test window", || {
        let r = shared.lock().unwrap();
        r.focused && r.keymaps > 0
    });

    let h = Harness {
        shared: shared.clone(),
    };

    let ascii: String = (0x20u8..0x7f).map(char::from).collect();
    h.expect("printable ASCII", &ascii, || typer.type_text(&ascii));
    h.expect("repeats", "aaaa  llll!!", || {
        typer.type_text("aaaa  llll!!")
    });
    let accents = "Grüße, naïve café — “quotes” ‘x’ … € £ ß Ω π Ж 日本語 한국어 עברית";
    h.expect("non-ASCII", accents, || typer.type_text(accents));
    let astral = "👍🏽 🎉 𝔘𝔫𝔦𝔠𝔬𝔡𝔢 👨\u{200D}👩\u{200D}👧 e\u{301}";
    h.expect("non-BMP and combining", astral, || typer.type_text(astral));
    h.expect("newlines and tabs", "one\ntwo\tthree\nfour\nfive", || {
        typer.type_text("one\ntwo\tthree\r\nfour\rfive")
    });
    h.expect("press_enter", "\n", || typer.press_enter());
    h.expect("empty", "", || typer.type_text(""));

    // Far more distinct characters than one keymap holds: several uploads.
    let many: String = (0..700u32)
        .map(|i| char::from_u32(0x4E00 + i * 3).unwrap())
        .chain("abc\n".chars())
        .cycle()
        .take(1500)
        .collect();
    let keymaps_before = shared.lock().unwrap().keymaps;
    h.expect("many distinct characters", &many, || typer.type_text(&many));
    let uploads = shared.lock().unwrap().keymaps - keymaps_before;
    let pool = lf_wayland::keymap::char_pool().len();
    assert!(
        uploads >= 704 / pool,
        "expected several keymap uploads, saw {uploads}"
    );
    println!("     ({uploads} keymaps for 704 distinct characters, {pool} per keymap)");

    // Control characters fail before anything is typed.
    let err = typer
        .type_text("ab\u{7}cd")
        .expect_err("BEL must be rejected");
    assert!(!err.0.contains("ab"), "error must not echo the text");
    std::thread::sleep(Duration::from_millis(200));
    assert!(h.take().is_empty(), "nothing may be typed on rejection");
    println!("ok   control character rejected, nothing typed");

    // Reconnecting after a disconnect works. Destroying the only keyboard
    // removes the seat's keyboard capability, so wait for focus to return.
    let enters = shared.lock().unwrap().enters;
    typer.disconnect();
    typer.connect().expect("reconnect");
    wait_until("focus after reconnect", || {
        let r = shared.lock().unwrap();
        r.focused && r.enters > enters
    });
    h.expect("after reconnect", "back again", || {
        typer.type_text("back again")
    });

    // Fast path with no per-key delay.
    let fast_cfg = TyperConfig {
        display: Display::Socket(sway.socket.clone()),
        key_delay: Duration::ZERO,
        ..TyperConfig::default()
    };
    let mut fast = WaylandTyper::new(fast_cfg);
    let long: String = "The quick brown fox jumps over the lazy dog. ".repeat(20);
    h.expect("900 chars, no delay", &long, || fast.type_text(&long));
    drop(fast);
    h.expect("900 chars, default delay", &long[..900], || {
        typer.type_text(&long[..900])
    });

    drop(typer);
    stop.store(true, Ordering::Relaxed);
    client.join().expect("client thread");
    let errors = std::mem::take(&mut shared.lock().unwrap().errors);
    assert!(errors.is_empty(), "client saw protocol issues: {errors:?}");
    drop(sway);
    println!("headless sway typing test: all cases passed");
}

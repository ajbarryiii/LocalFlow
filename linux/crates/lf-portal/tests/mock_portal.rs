//! Contract tests for the RemoteDesktop portal backend, against a mock
//! portal on a private D-Bus bus and a fake EIS server.
//!
//! Each test starts its own `dbus-daemon` (configuration, socket and
//! environment in a fresh private directory, no service activation) and
//! serves a mock `org.freedesktop.portal.Desktop` on it from this process.
//! The typer is pointed at that bus by explicit address, so nothing ever
//! reaches the user's session bus or real portal. The mock's
//! `ConnectToEIS` hands out one end of a socket pair whose other end is a
//! fake EIS server (built on `reis`'s server side) that records the key
//! events it receives. All keymaps and text are synthetic.
//!
//! Needs `dbus-daemon` on `PATH` (the `linux/flake.nix` dev shell provides
//! it); set `LF_SKIP_DBUS_TESTS=1` to skip these tests elsewhere.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use lf_io_api::TextOutput;
use lf_portal::{PortalConfig, PortalTyper, Timeouts, TokenStore};
use reis::PendingRequestResult;
use reis::eis;
use reis::handshake::EisHandshaker;
use zbus::message::Header;
use zbus::object_server::ObjectServer;
use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};

const DEST: &str = "org.freedesktop.portal.Desktop";
const PATH: &str = "/org/freedesktop/portal/desktop";
const REQUEST: &str = "org.freedesktop.portal.Request";

fn skip() -> bool {
    if std::env::var_os("LF_SKIP_DBUS_TESTS").is_some() {
        println!("skipped: LF_SKIP_DBUS_TESTS is set");
        return true;
    }
    false
}

// ------------------------------------------------------------ private bus

struct PrivateBus {
    dir: PathBuf,
    address: String,
    child: Child,
}

impl PrivateBus {
    fn start() -> PrivateBus {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .subsec_nanos();
        let dir =
            std::env::temp_dir().join(format!("lf-portal-test-{}-{nanos:08x}", std::process::id()));
        std::fs::DirBuilder::new().mode(0o700).create(&dir).unwrap();
        let dir = dir.canonicalize().unwrap();
        let socket = dir.join("bus");
        let conf = dir.join("bus.conf");
        std::fs::write(
            &conf,
            format!(
                r#"<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path={}</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
"#,
                socket.display()
            ),
        )
        .unwrap();
        let mut cmd = Command::new("dbus-daemon");
        cmd.arg(format!("--config-file={}", conf.display()))
            .args(["--nofork", "--nopidfile", "--nosyslog", "--print-address=1"])
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", &dir)
            .env("XDG_RUNTIME_DIR", &dir)
            .process_group(0)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        // SAFETY: prctl is async-signal-safe.
        unsafe {
            cmd.pre_exec(|| {
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
                Ok(())
            });
        }
        let child = cmd
            .spawn()
            .expect("spawn dbus-daemon (from the linux/flake.nix shell)");
        let mut bus = PrivateBus {
            dir,
            address: String::new(),
            child,
        };
        let mut stdout = bus.child.stdout.take().unwrap();
        let fd = stdout.as_raw_fd();
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut out = Vec::new();
        while !out.contains(&b'\n') {
            let left = deadline.saturating_duration_since(Instant::now());
            assert!(!left.is_zero(), "dbus-daemon printed no address");
            let mut pfd = libc::pollfd {
                fd,
                events: libc::POLLIN,
                revents: 0,
            };
            // SAFETY: one valid pollfd.
            unsafe { libc::poll(&mut pfd, 1, left.as_millis().max(1) as i32) };
            let mut chunk = [0u8; 256];
            match stdout.read(&mut chunk) {
                Ok(0) => panic!("dbus-daemon exited without an address"),
                Ok(n) => out.extend_from_slice(&chunk[..n]),
                Err(e) => panic!("reading the dbus-daemon address: {e}"),
            }
        }
        let line = String::from_utf8(out).unwrap();
        bus.address = line.lines().next().unwrap().trim().to_owned();
        // Never the user's bus: the address names our private socket.
        assert!(
            bus.address
                .starts_with(&format!("unix:path={}", bus.dir.display())),
            "unexpected bus address"
        );
        bus
    }
}

impl Drop for PrivateBus {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

// ------------------------------------------------------------ fake EIS

/// A self-contained synthetic keymap: a/A (Caps-aware), 1/!/¹/¡, q/Q/@,
/// space, Tab, Return, Shift and AltGr.
const SYNTHETIC: &str = r#"xkb_keymap {
xkb_keycodes "synthetic" {
    minimum = 8;
    maximum = 255;
    <AE01> = 10;
    <AD01> = 24;
    <AC01> = 38;
    <SPCE> = 65;
    <TAB> = 23;
    <RTRN> = 36;
    <LFSH> = 50;
    <RALT> = 108;
};
xkb_types "synthetic" {
    virtual_modifiers LevelThree;
    type "ONE_LEVEL" { modifiers = none; map[none] = Level1; level_name[Level1] = "Any"; };
    type "ALPHABETIC" {
        modifiers = Shift + Lock;
        map[Shift] = Level2;
        map[Lock] = Level2;
        level_name[Level1] = "Base";
        level_name[Level2] = "Caps";
    };
    type "FOUR_LEVEL" {
        modifiers = Shift + LevelThree;
        map[Shift] = Level2;
        map[LevelThree] = Level3;
        map[Shift + LevelThree] = Level4;
        level_name[Level1] = "1";
        level_name[Level2] = "2";
        level_name[Level3] = "3";
        level_name[Level4] = "4";
    };
};
xkb_compatibility "synthetic" {
    virtual_modifiers LevelThree;
    interpret Shift_L { action = SetMods(modifiers = Shift); };
    interpret ISO_Level3_Shift {
        useModMapMods = level1;
        virtualModifier = LevelThree;
        action = SetMods(modifiers = LevelThree);
    };
};
xkb_symbols "synthetic" {
    key <AE01> { type = "FOUR_LEVEL", [ 1, exclam, onesuperior, exclamdown ] };
    key <AD01> { type = "FOUR_LEVEL", [ q, Q, at, Greek_OMEGA ] };
    key <AC01> { type = "ALPHABETIC", [ a, A ] };
    key <SPCE> { [ space ] };
    key <TAB> { [ Tab ] };
    key <RTRN> { [ Return ] };
    key <LFSH> { [ Shift_L ] };
    key <RALT> { [ ISO_Level3_Shift ] };
    modifier_map Shift { <LFSH> };
    modifier_map Mod5 { <RALT> };
};
};
"#;

const KA: u32 = 30;
const K1: u32 = 2;
const KQ: u32 = 16;
const SHIFT: u32 = 42;
const ALTGR: u32 = 100;
const SPACE: u32 = 57;
const ENTER: u32 = 28;

const KEYBOARD_MASK: u64 = 0x4;
const POINTER_MASK: u64 = 0x1;

#[derive(Default)]
struct EisLog {
    connections: usize,
    name: Option<String>,
    bound: Vec<u64>,
    keys: Vec<(u32, bool)>,
    frames: usize,
    starts: usize,
    stops: usize,
}

#[derive(Clone, Copy, Default)]
struct EisOptions {
    caps_locked: bool,
}

fn keymap_fd(text: &str) -> (OwnedFd, u32) {
    // SAFETY: memfd_create with a valid NUL-terminated name.
    let raw = unsafe { libc::memfd_create(c"lf-test-keymap".as_ptr(), libc::MFD_CLOEXEC) };
    assert!(raw >= 0);
    // SAFETY: a fresh fd owned by nobody else.
    let mut file = unsafe { std::fs::File::from_raw_fd(raw) };
    file.write_all(text.as_bytes()).unwrap();
    file.write_all(&[0]).unwrap();
    (file.into(), text.len() as u32 + 1)
}

/// Serves one EIS client until it disconnects or `kill` is set (which
/// closes the socket).
fn serve_eis(stream: UnixStream, log: Arc<Mutex<EisLog>>, opts: EisOptions, kill: Arc<AtomicBool>) {
    let ctx = eis::Context::new(stream).unwrap();
    let mut handshaker = Some(EisHandshaker::new(&ctx, 1));
    let mut serial = 10u32;
    log.lock().unwrap().connections += 1;
    loop {
        if kill.load(Ordering::SeqCst) {
            return;
        }
        let mut pfd = libc::pollfd {
            fd: ctx.as_fd().as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: one valid pollfd.
        unsafe { libc::poll(&mut pfd, 1, 50) };
        match ctx.read() {
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => continue,
            Err(_) => return,
        }
        while let Some(result) = ctx.pending_request() {
            let PendingRequestResult::Request(request) = result else {
                panic!("the client broke the protocol");
            };
            if let Some(h) = handshaker.as_mut() {
                if let Some(resp) = h.handle_request(request).expect("handshake") {
                    handshaker = None;
                    log.lock().unwrap().name = resp.name.clone();
                    let seat = resp.connection.seat(1);
                    seat.name("synthetic seat");
                    seat.capability(POINTER_MASK, "ei_pointer");
                    seat.capability(KEYBOARD_MASK, "ei_keyboard");
                    seat.done();
                }
                continue;
            }
            match request {
                eis::Request::Seat(seat, eis::seat::Request::Bind { capabilities }) => {
                    log.lock().unwrap().bound.push(capabilities);
                    if capabilities & KEYBOARD_MASK != 0 {
                        let device = seat.device(1);
                        device.name("synthetic keyboard");
                        device.device_type(eis::device::DeviceType::Virtual);
                        let kb: eis::Keyboard = device.interface(1);
                        let (fd, size) = keymap_fd(SYNTHETIC);
                        kb.keymap(eis::keyboard::KeymapType::Xkb, size, fd.as_fd());
                        device.done();
                        serial += 1;
                        device.resumed(serial);
                        if opts.caps_locked {
                            serial += 1;
                            kb.modifiers(serial, 0, 1 << 1, 0, 0);
                        }
                    }
                }
                eis::Request::Device(_, eis::device::Request::StartEmulating { .. }) => {
                    log.lock().unwrap().starts += 1;
                }
                eis::Request::Device(_, eis::device::Request::StopEmulating { .. }) => {
                    log.lock().unwrap().stops += 1;
                }
                eis::Request::Device(_, eis::device::Request::Frame { .. }) => {
                    log.lock().unwrap().frames += 1;
                }
                eis::Request::Keyboard(_, eis::keyboard::Request::Key { key, state }) => {
                    let pressed = state == eis::keyboard::KeyState::Press;
                    log.lock().unwrap().keys.push((key, pressed));
                }
                eis::Request::Connection(_, eis::connection::Request::Sync { callback }) => {
                    callback.done(0);
                }
                eis::Request::Connection(_, eis::connection::Request::Disconnect) => return,
                _ => {}
            }
        }
        let _ = ctx.flush();
    }
}

// ------------------------------------------------------------ mock portal

#[derive(Default)]
struct MockState {
    calls: Vec<String>,
    select_options: Vec<HashMap<String, OwnedValue>>,
    /// Response code of `Start` (0 granted, 1 cancelled, 2 refused).
    start_code: u32,
    /// How long `Start` takes to answer (a permission dialog).
    start_delay: Duration,
    tokens_issued: u32,
    closed: Vec<String>,
    eis: EisOptions,
    eis_log: Arc<Mutex<EisLog>>,
    /// Setting this closes every EIS connection served so far.
    eis_kill: Vec<Arc<AtomicBool>>,
}

#[derive(Clone)]
struct MockPortal {
    state: Arc<Mutex<MockState>>,
}

struct MockSession {
    state: Arc<Mutex<MockState>>,
    path: String,
}

fn string_option(options: &HashMap<String, OwnedValue>, key: &str) -> String {
    match options.get(key).map(|v| &**v) {
        Some(Value::Str(s)) => s.as_str().to_owned(),
        _ => panic!("option {key} missing"),
    }
}

fn request_path(header: &Header<'_>, options: &HashMap<String, OwnedValue>) -> (String, String) {
    let sender = header.sender().unwrap().as_str().to_owned();
    let element = sender.trim_start_matches(':').replace('.', "_");
    let token = string_option(options, "handle_token");
    (sender, format!("{PATH}/request/{element}/{token}"))
}

async fn respond(
    conn: &zbus::Connection,
    sender: &str,
    path: &str,
    code: u32,
    results: HashMap<&str, Value<'_>>,
) {
    conn.emit_signal(Some(sender), path, REQUEST, "Response", &(code, results))
        .await
        .unwrap();
}

#[zbus::interface(name = "org.freedesktop.portal.RemoteDesktop")]
impl MockPortal {
    #[zbus(property, name = "version")]
    fn version(&self) -> u32 {
        2
    }

    #[zbus(property, name = "AvailableDeviceTypes")]
    fn available_device_types(&self) -> u32 {
        7
    }

    async fn create_session(
        &self,
        options: HashMap<String, OwnedValue>,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] conn: &zbus::Connection,
        #[zbus(object_server)] server: &ObjectServer,
    ) -> OwnedObjectPath {
        self.state
            .lock()
            .unwrap()
            .calls
            .push("CreateSession".into());
        let (sender, request) = request_path(&header, &options);
        let element = sender.trim_start_matches(':').replace('.', "_");
        let session = format!(
            "{PATH}/session/{element}/{}",
            string_option(&options, "session_handle_token")
        );
        server
            .at(
                session.as_str(),
                MockSession {
                    state: self.state.clone(),
                    path: session.clone(),
                },
            )
            .await
            .unwrap();
        // Sent before the reply: a client must already be listening.
        let mut results = HashMap::new();
        results.insert("session_handle", Value::from(session.as_str()));
        respond(conn, &sender, &request, 0, results).await;
        OwnedObjectPath::try_from(request).unwrap()
    }

    async fn select_devices(
        &self,
        _session: ObjectPath<'_>,
        options: HashMap<String, OwnedValue>,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] conn: &zbus::Connection,
    ) -> OwnedObjectPath {
        let (sender, request) = request_path(&header, &options);
        {
            let mut s = self.state.lock().unwrap();
            s.calls.push("SelectDevices".into());
            s.select_options.push(options);
        }
        respond(conn, &sender, &request, 0, HashMap::new()).await;
        OwnedObjectPath::try_from(request).unwrap()
    }

    async fn start(
        &self,
        _session: ObjectPath<'_>,
        _parent_window: &str,
        options: HashMap<String, OwnedValue>,
        #[zbus(header)] header: Header<'_>,
        #[zbus(connection)] conn: &zbus::Connection,
    ) -> OwnedObjectPath {
        let (sender, request) = request_path(&header, &options);
        let (code, delay, token) = {
            let mut s = self.state.lock().unwrap();
            s.calls.push("Start".into());
            s.tokens_issued += 1;
            (
                s.start_code,
                s.start_delay,
                format!("synthetic-token-{}", s.tokens_issued),
            )
        };
        let conn = conn.clone();
        let reply_path = request.clone();
        // Answers later, as a dialog would.
        std::thread::spawn(move || {
            std::thread::sleep(delay);
            let mut results = HashMap::new();
            if code == 0 {
                results.insert("devices", Value::from(1u32));
                results.insert("restore_token", Value::from(token.as_str()));
            }
            async_io::block_on(respond(&conn, &sender, &reply_path, code, results));
        });
        OwnedObjectPath::try_from(request).unwrap()
    }

    #[zbus(name = "ConnectToEIS")]
    async fn connect_to_eis(
        &self,
        _session: ObjectPath<'_>,
        _options: HashMap<String, OwnedValue>,
    ) -> zbus::zvariant::OwnedFd {
        let (client, server) = UnixStream::pair().unwrap();
        let (log, opts, kill) = {
            let mut s = self.state.lock().unwrap();
            s.calls.push("ConnectToEIS".into());
            let kill = Arc::new(AtomicBool::new(false));
            s.eis_kill.push(kill.clone());
            (s.eis_log.clone(), s.eis, kill)
        };
        std::thread::spawn(move || serve_eis(server, log, opts, kill));
        zbus::zvariant::OwnedFd::from(OwnedFd::from(client))
    }
}

#[zbus::interface(name = "org.freedesktop.portal.Session")]
impl MockSession {
    async fn close(&self) {
        self.state.lock().unwrap().closed.push(self.path.clone());
    }
}

struct Rig {
    bus: PrivateBus,
    state: Arc<Mutex<MockState>>,
    _service: zbus::Connection,
}

impl Rig {
    fn start(configure: impl FnOnce(&mut MockState)) -> Rig {
        let bus = PrivateBus::start();
        let mut state = MockState::default();
        configure(&mut state);
        let state = Arc::new(Mutex::new(state));
        let service = async_io::block_on(async {
            zbus::connection::Builder::address(bus.address.as_str())?
                .name(DEST)?
                .serve_at(
                    PATH,
                    MockPortal {
                        state: state.clone(),
                    },
                )?
                .build()
                .await
        })
        .unwrap();
        Rig {
            bus,
            state,
            _service: service,
        }
    }

    fn config(&self) -> PortalConfig {
        PortalConfig {
            address: Some(self.bus.address.clone()),
            key_delay: Duration::ZERO,
            timeout: Duration::from_secs(1),
            call_timeout: Some(Duration::from_secs(2)),
            portal: Timeouts {
                call: Duration::from_secs(2),
                permission: Duration::from_secs(10),
            },
            ..PortalConfig::default()
        }
    }

    fn log(&self) -> Arc<Mutex<EisLog>> {
        self.state.lock().unwrap().eis_log.clone()
    }

    fn keys(&self) -> Vec<(u32, bool)> {
        self.log().lock().unwrap().keys.clone()
    }

    fn calls(&self, name: &str) -> usize {
        self.state
            .lock()
            .unwrap()
            .calls
            .iter()
            .filter(|c| *c == name)
            .count()
    }

    fn wait_until(&self, what: &str, cond: impl Fn(&Rig) -> bool) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !cond(self) {
            assert!(Instant::now() < deadline, "timed out waiting for {what}");
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

#[derive(Clone, Default)]
struct MemStore {
    saved: Arc<Mutex<Vec<String>>>,
}

impl TokenStore for MemStore {
    fn load(&mut self) -> Option<String> {
        self.saved.lock().unwrap().last().cloned()
    }
    fn save(&mut self, token: &str) {
        self.saved.lock().unwrap().push(token.to_owned());
    }
}

fn tap(code: u32) -> Vec<(u32, bool)> {
    vec![(code, true), (code, false)]
}

fn with(mods: &[u32], code: u32) -> Vec<(u32, bool)> {
    let mut v: Vec<(u32, bool)> = mods.iter().map(|&m| (m, true)).collect();
    v.extend(tap(code));
    v.extend(mods.iter().rev().map(|&m| (m, false)));
    v
}

// ------------------------------------------------------------ tests

#[test]
fn probe_finds_the_portal_and_its_absence() {
    if skip() {
        return;
    }
    let rig = Rig::start(|_| {});
    assert_eq!(
        lf_portal::probe(Some(&rig.bus.address), Duration::from_secs(2)),
        Ok(true)
    );
    // A bus without a portal.
    let empty = PrivateBus::start();
    assert_eq!(
        lf_portal::probe(Some(&empty.address), Duration::from_secs(2)),
        Ok(false)
    );
    // No bus at all.
    let missing = format!("unix:path={}/no-such-bus", empty.dir.display());
    assert!(lf_portal::probe(Some(&missing), Duration::from_secs(2)).is_err());
    // Probing created no session.
    assert_eq!(rig.calls("CreateSession"), 0);
}

#[test]
fn types_through_a_negotiated_session_and_keeps_the_restore_token() {
    if skip() {
        return;
    }
    let rig = Rig::start(|_| {});
    let store = MemStore::default();
    let mut typer = PortalTyper::new(rig.config(), Box::new(store.clone()));
    typer.connect();
    typer.check("aA 1!@").unwrap();
    typer.type_text("aA 1!@").unwrap();
    let mut expected = tap(KA);
    expected.extend(with(&[SHIFT], KA));
    expected.extend(tap(SPACE));
    expected.extend(tap(K1));
    expected.extend(with(&[SHIFT], K1));
    expected.extend(with(&[ALTGR], KQ));
    assert_eq!(rig.keys(), expected);
    typer.press_enter().unwrap();
    expected.extend(tap(ENTER));
    assert_eq!(rig.keys(), expected);
    // The last stop_emulating is flushed, not round-tripped.
    rig.wait_until("stop_emulating", |r| r.log().lock().unwrap().stops == 2);
    {
        let log = rig.log();
        let log = log.lock().unwrap();
        assert_eq!(log.connections, 1);
        assert_eq!(log.name.as_deref(), Some("localflowd"));
        // Only the keyboard is bound, never the pointer.
        assert_eq!(log.bound, vec![KEYBOARD_MASK]);
        // One emulation sequence per call, one frame per key event.
        assert_eq!((log.starts, log.stops), (2, 2));
        assert_eq!(log.frames, expected.len());
    }
    {
        let s = rig.state.lock().unwrap();
        let o = &s.select_options[0];
        assert_eq!(u32::try_from(&o["types"]).unwrap(), 1);
        assert_eq!(u32::try_from(&o["persist_mode"]).unwrap(), 2);
        assert!(!o.contains_key("restore_token"));
    }
    assert_eq!(*store.saved.lock().unwrap(), vec!["synthetic-token-1"]);

    // Dropping the typer closes the session.
    drop(typer);
    rig.wait_until("Session.Close", |r| {
        r.state.lock().unwrap().closed.len() == 1
    });

    // The next run restores the grant with the stored token.
    let mut typer = PortalTyper::new(rig.config(), Box::new(store.clone()));
    typer.type_text("q").unwrap();
    {
        let s = rig.state.lock().unwrap();
        let o = &s.select_options[1];
        assert_eq!(
            o.get("restore_token").map(|v| &**v),
            Some(&Value::from("synthetic-token-1"))
        );
    }
    assert_eq!(
        *store.saved.lock().unwrap(),
        vec!["synthetic-token-1", "synthetic-token-2"]
    );
    assert_eq!(rig.keys()[expected.len()..], tap(KQ));
}

#[test]
fn text_the_keymap_cannot_produce_is_refused_whole() {
    if skip() {
        return;
    }
    let rig = Rig::start(|_| {});
    let mut typer = PortalTyper::new(rig.config(), Box::new(MemStore::default()));
    let err = typer.check("aé").unwrap_err();
    assert!(err.0.contains("position 1"), "{err}");
    assert!(!err.0.contains('é'), "{err}");
    assert!(typer.type_text("aé").is_err());
    assert!(typer.type_text("a\u{7}").is_err());
    assert!(rig.keys().is_empty());
    // The session is still usable.
    typer.type_text("a").unwrap();
    assert_eq!(rig.keys(), tap(KA));
}

#[test]
fn a_pending_permission_fails_fast_then_types_once_granted() {
    if skip() {
        return;
    }
    let rig = Rig::start(|s| s.start_delay = Duration::from_millis(1500));
    let mut config = rig.config();
    config.call_timeout = Some(Duration::from_millis(300));
    let mut typer = PortalTyper::new(config, Box::new(MemStore::default()));
    typer.connect();
    let t0 = Instant::now();
    let err = typer.type_text("a").unwrap_err();
    assert!(
        t0.elapsed() < Duration::from_millis(900),
        "{:?}",
        t0.elapsed()
    );
    assert!(err.0.contains("waiting"), "{err}");
    rig.wait_until("ConnectToEIS", |r| r.calls("ConnectToEIS") == 1);
    typer.type_text("a").unwrap();
    assert_eq!(rig.keys(), tap(KA));
    // Still the one negotiation.
    assert_eq!(rig.calls("CreateSession"), 1);
}

#[test]
fn a_cancelled_request_types_nothing_and_closes_the_session() {
    if skip() {
        return;
    }
    let rig = Rig::start(|s| s.start_code = 1);
    let store = MemStore::default();
    let mut typer = PortalTyper::new(rig.config(), Box::new(store.clone()));
    let err = typer.type_text("a").unwrap_err();
    assert!(err.0.contains("cancelled"), "{err}");
    assert_eq!(rig.calls("ConnectToEIS"), 0);
    rig.wait_until("Session.Close", |r| {
        r.state.lock().unwrap().closed.len() == 1
    });
    assert!(store.saved.lock().unwrap().is_empty());
    // The next call asks again.
    assert!(typer.type_text("a").is_err());
    assert_eq!(rig.calls("Start"), 2);
    assert!(rig.keys().is_empty());
}

#[test]
fn renegotiates_after_the_desktop_ends_the_input_session() {
    if skip() {
        return;
    }
    let rig = Rig::start(|_| {});
    let mut typer = PortalTyper::new(rig.config(), Box::new(MemStore::default()));
    typer.type_text("a").unwrap();
    for kill in &rig.state.lock().unwrap().eis_kill {
        kill.store(true, Ordering::SeqCst);
    }
    std::thread::sleep(Duration::from_millis(150));
    typer.type_text("1").unwrap();
    let mut expected = tap(KA);
    expected.extend(tap(K1));
    assert_eq!(rig.keys(), expected);
    assert_eq!(rig.calls("CreateSession"), 2);
    let s = rig.state.lock().unwrap();
    assert_eq!(
        s.select_options[1].get("restore_token").map(|v| &**v),
        Some(&Value::from("synthetic-token-1"))
    );
    // The old session was closed.
    drop(s);
    rig.wait_until("Session.Close", |r| {
        r.state.lock().unwrap().closed.len() == 1
    });
}

#[test]
fn modifiers_locked_on_the_desktop_are_accounted_for() {
    if skip() {
        return;
    }
    let rig = Rig::start(|s| s.eis.caps_locked = true);
    let mut typer = PortalTyper::new(rig.config(), Box::new(MemStore::default()));
    typer.type_text("aA").unwrap();
    let mut expected = with(&[SHIFT], KA);
    expected.extend(tap(KA));
    assert_eq!(rig.keys(), expected);
}

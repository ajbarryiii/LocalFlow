//! End-to-end media pausing and global shortcuts against a private D-Bus
//! session bus.
//!
//! The harness starts its own `dbus-daemon` with its own configuration and a
//! socket in a fresh private directory: no service activation, no syslog,
//! a cleared environment. Fake MPRIS players (served by `zbus` in this
//! process) join that bus, and the daemon (fake microphone, recognizer and
//! keyboard; the real MPRIS backend) pauses and resumes them.
//!
//! A fake xdg-desktop-portal (`org.freedesktop.portal.Desktop` with only
//! GlobalShortcuts and the host registry, served the same way) checks the
//! `"trigger": "portal"` thread: registration and binding, key signals as
//! press, release and toggle, and session loss. The user's own portal is
//! never reached, so no binding dialog can open.
//!
//! The test refuses to run unless `DBUS_SESSION_BUS_ADDRESS` names its
//! private socket with the GUID that `dbus-daemon` printed, so it can never
//! reach the user's session bus or players. Every fake player connects by
//! that explicit address too.
//!
//! Needs `dbus-daemon` on `PATH` (the `linux/flake.nix` dev shell provides
//! it); set `LF_SKIP_DBUS_TESTS=1` to skip it elsewhere. `harness = false`
//! so the environment is set before any thread exists.

mod common;

use std::collections::HashMap;
use std::io::Read;
use std::os::fd::AsRawFd;
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use common::{Rig, factory, settings};
use lf_daemon::backends;
use lf_daemon::testing::{FakeCapture, FakeRecognizer};
use lf_daemon::tray::{self, Tray, TrayError};
use lf_daemon::waybar::Class;
use lf_io_api::MediaPlayers;
use lf_media::{Mpris, MprisConfig};
use zbus::zvariant::OwnedValue;

const PREFIX: &str = "org.mpris.MediaPlayer2.";

// ------------------------------------------------------------ private bus

struct PrivateBus {
    dir: PathBuf,
    /// As printed by dbus-daemon, with its GUID.
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
            std::env::temp_dir().join(format!("lf-dbus-test-{}-{nanos:08x}", std::process::id()));
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
        let log = std::fs::File::create(dir.join("dbus.log")).unwrap();
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
            .stderr(log);
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
        // From here on, `Drop` stops the daemon and removes the directory.
        let mut bus = PrivateBus {
            dir,
            address: String::new(),
            child,
        };
        let mut stdout = bus.child.stdout.take().unwrap();
        // Read the address line under one deadline, without a thread (none
        // may exist before the environment is set): non-blocking reads
        // between polls.
        let fd = stdout.as_raw_fd();
        // SAFETY: fcntl on a descriptor we own.
        unsafe {
            let flags = libc::fcntl(fd, libc::F_GETFL);
            libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
        }
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut out = Vec::new();
        while !out.contains(&b'\n') {
            let left = deadline.saturating_duration_since(Instant::now());
            assert!(
                !left.is_zero(),
                "dbus-daemon printed no address within 10 s"
            );
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
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(e) => panic!("reading the dbus-daemon address: {e}"),
            }
        }
        bus.address = String::from_utf8(out).unwrap().trim().to_owned();
        assert!(
            bus.address
                .starts_with(&format!("unix:path={},guid=", socket.display())),
            "unexpected bus address {:?}",
            bus.address
        );
        bus
    }

    fn guid(&self) -> &str {
        self.address.rsplit_once("guid=").unwrap().1
    }
}

impl Drop for PrivateBus {
    fn drop(&mut self) {
        let pgid = self.child.id() as i32;
        // SAFETY: signals our own child's process group.
        unsafe { libc::kill(-pgid, libc::SIGTERM) };
        let deadline = Instant::now() + Duration::from_secs(5);
        while self.child.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        // SAFETY: as above.
        unsafe { libc::kill(-pgid, libc::SIGKILL) };
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// Panics unless the session bus address can only lead to `bus`, and the
/// bus there is the one `dbus-daemon` started (same GUID).
fn assert_private(bus: &PrivateBus) {
    let env = std::env::var("DBUS_SESSION_BUS_ADDRESS").unwrap_or_default();
    assert_eq!(
        env, bus.address,
        "DBUS_SESSION_BUS_ADDRESS is not the private bus"
    );
    assert!(
        bus.dir
            .starts_with(std::env::temp_dir().canonicalize().unwrap())
    );
    // Connect through the session-bus lookup itself, on a thread so a
    // stalled bus fails the test instead of hanging it.
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let guid = zbus::blocking::connection::Builder::session()
            .and_then(|b| b.build())
            .map(|c| c.server_guid().to_owned());
        let _ = tx.send(guid);
    });
    let guid = rx
        .recv_timeout(Duration::from_secs(10))
        .expect("the private bus did not answer")
        .expect("cannot connect to the private bus");
    assert_eq!(guid, bus.guid(), "connected to another bus");
}

// ------------------------------------------------------------ fake player

#[derive(Debug)]
struct PlayerState {
    status: &'static str,
    pauses: usize,
    plays: usize,
    status_reads: usize,
    metadata_reads: usize,
    /// `PlaybackStatus` reads block this long (a hung player).
    stall: Duration,
}

#[derive(Clone)]
struct Player(Arc<Mutex<PlayerState>>);

impl Player {
    fn state(&self) -> MutexGuard<'_, PlayerState> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[zbus::interface(name = "org.mpris.MediaPlayer2.Player")]
impl Player {
    fn play(&self) {
        let mut s = self.state();
        s.plays += 1;
        s.status = "Playing";
    }

    fn pause(&self) {
        let mut s = self.state();
        s.pauses += 1;
        s.status = "Paused";
    }

    fn stop(&self) {
        self.state().status = "Stopped";
    }

    #[zbus(property)]
    fn playback_status(&self) -> String {
        let stall = self.state().stall;
        if !stall.is_zero() {
            std::thread::sleep(stall);
        }
        let mut s = self.state();
        s.status_reads += 1;
        s.status.to_owned()
    }

    /// Must never be read: it would carry titles and URLs.
    #[zbus(property)]
    fn metadata(&self) -> HashMap<String, OwnedValue> {
        self.state().metadata_reads += 1;
        HashMap::new()
    }
}

/// A fake player process: its own connection to the private bus.
struct FakeMpris {
    player: Player,
    conn: Option<zbus::blocking::Connection>,
}

impl FakeMpris {
    fn start(bus: &PrivateBus, names: &[&str], status: &'static str) -> FakeMpris {
        let player = Player(Arc::new(Mutex::new(PlayerState {
            status,
            pauses: 0,
            plays: 0,
            status_reads: 0,
            metadata_reads: 0,
            stall: Duration::ZERO,
        })));
        let mut builder = zbus::blocking::connection::Builder::address(bus.address.as_str())
            .unwrap()
            .serve_at("/org/mpris/MediaPlayer2", player.clone())
            .unwrap();
        for name in names {
            builder = builder.name(format!("{PREFIX}{name}")).unwrap();
        }
        // Bounded, so a stalled private bus fails the test instead of
        // hanging it.
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(builder.build());
        });
        let conn = rx
            .recv_timeout(Duration::from_secs(10))
            .expect("fake player could not join the private bus in 10 s")
            .unwrap();
        FakeMpris {
            player,
            conn: Some(conn),
        }
    }

    fn state(&self) -> MutexGuard<'_, PlayerState> {
        self.player.state()
    }

    fn status(&self) -> &'static str {
        self.state().status
    }

    /// The player quits.
    fn quit(&mut self) {
        if let Some(c) = self.conn.take() {
            let _ = c.close();
        }
    }
}

impl Drop for FakeMpris {
    fn drop(&mut self) {
        if !std::thread::panicking() {
            assert_eq!(self.state().metadata_reads, 0, "track metadata was read");
        }
    }
}

// ------------------------------------------------------------ helpers

fn wait_until(what: &str, f: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !f() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn daemon(tag: &str, media: Box<dyn MediaPlayers>) -> Rig {
    Rig::start_with_media(
        tag,
        FakeCapture::with_samples(vec![0.1; 16_000]),
        factory(FakeRecognizer::returning("Synthetic.")),
        settings(),
        false,
        Some(media),
    )
}

/// The daemon's own backend: the session bus from the environment.
fn session_daemon(bus: &PrivateBus, tag: &str) -> Rig {
    assert_private(bus);
    daemon(tag, backends::media())
}

// ------------------------------------------------------------ tests

type Case = fn(&PrivateBus);

fn pauses_playing_players_and_resumes_them(bus: &PrivateBus) {
    let a = FakeMpris::start(bus, &["lftest_a"], "Playing");
    let b = FakeMpris::start(bus, &["lftest_b"], "Paused");
    let c = FakeMpris::start(bus, &["lftest_c"], "Stopped");
    // One player owning two names is paused once.
    let d = FakeMpris::start(bus, &["lftest_d", "lftest_d.instance2"], "Playing");
    // A proxy for "the last active player" is never used.
    let ctld = FakeMpris::start(bus, &["playerctld"], "Playing");
    let rig = session_daemon(bus, "dbus-basic");

    assert_eq!(rig.cmd("press"), "state=recording mode=hold model=ready");
    wait_until("pause", || a.status() == "Paused" && d.status() == "Paused");
    assert_eq!(rig.cmd("release"), "state=transcribing model=ready");
    wait_until("resume", || {
        a.status() == "Playing" && d.status() == "Playing"
    });
    rig.wait_for("state=idle");
    assert_eq!(rig.output.text(), "Synthetic. ");
    for p in [&a, &d] {
        let s = p.state();
        assert_eq!((s.pauses, s.plays), (1, 1));
    }
    for p in [&b, &c, &ctld] {
        let s = p.state();
        assert_eq!((s.pauses, s.plays), (0, 0));
    }
    assert_eq!(ctld.state().status_reads, 0);
    assert_eq!(b.status(), "Paused");
    assert_eq!(c.status(), "Stopped");

    // Cancel resumes too.
    rig.cmd("toggle");
    wait_until("pause", || a.status() == "Paused");
    assert_eq!(rig.cmd("cancel"), "state=idle model=ready note=cancelled");
    wait_until("resume", || a.status() == "Playing");
}

fn leaves_players_the_user_changed_alone(bus: &PrivateBus) {
    let a = FakeMpris::start(bus, &["lftest_a"], "Playing");
    let b = FakeMpris::start(bus, &["lftest_b"], "Playing");
    let rig = session_daemon(bus, "dbus-user");
    rig.cmd("toggle");
    wait_until("pause", || a.status() == "Paused" && b.status() == "Paused");
    // While recording, the user resumes one player and stops the other.
    a.state().status = "Playing";
    b.state().status = "Stopped";
    let reads = (a.state().status_reads, b.state().status_reads);
    rig.cmd("toggle");
    // The resume pass read both statuses and played neither.
    wait_until("resume pass", || {
        a.state().status_reads > reads.0 && b.state().status_reads > reads.1
    });
    rig.wait_for("state=idle");
    assert_eq!(a.state().plays, 0);
    assert_eq!(b.state().plays, 0);
    assert_eq!(b.status(), "Stopped");
}

fn a_restarted_player_is_not_resumed(bus: &PrivateBus) {
    let mut a = FakeMpris::start(bus, &["lftest_a"], "Playing");
    let z = FakeMpris::start(bus, &["lftest_z"], "Playing");
    let rig = session_daemon(bus, "dbus-restart");
    rig.cmd("toggle");
    wait_until("pause", || a.status() == "Paused" && z.status() == "Paused");
    // The player quits and starts again under the same name, paused.
    a.quit();
    let a2 = FakeMpris::start(bus, &["lftest_a"], "Paused");
    rig.cmd("toggle");
    // `z` is resumed after the old `a` in the same pass.
    wait_until("resume", || z.status() == "Playing");
    assert_eq!(a2.state().plays, 0);
    assert_eq!(a2.status(), "Paused");
    drop(a);
}

fn a_hung_player_delays_nothing(bus: &PrivateBus) {
    // Sorted first, so the pass meets it before the healthy player.
    let hung = FakeMpris::start(bus, &["lftest_0hung"], "Playing");
    hung.state().stall = Duration::from_millis(3000);
    let a = FakeMpris::start(bus, &["lftest_a"], "Playing");
    let mut rig = session_daemon(bus, "dbus-hung");
    let t = Instant::now();
    assert_eq!(rig.cmd("toggle"), "state=recording mode=toggle model=ready");
    assert!(
        t.elapsed() < Duration::from_millis(1000),
        "{:?}",
        t.elapsed()
    );
    // The hung player's status read times out after 250 ms (well before
    // its 3 s stall ends), then the healthy player is paused.
    wait_until("pause", || a.status() == "Paused");
    let paused_after = t.elapsed();
    assert!(
        paused_after >= Duration::from_millis(250) && paused_after < Duration::from_millis(2500),
        "{paused_after:?}"
    );
    // The stalled read did reach the player; no pause followed it.
    wait_until("stalled read", || hung.state().status_reads >= 1);
    assert_eq!(hung.state().pauses, 0);
    let t = Instant::now();
    assert_eq!(rig.cmd("toggle"), "state=transcribing model=ready");
    assert!(
        t.elapsed() < Duration::from_millis(1000),
        "{:?}",
        t.elapsed()
    );
    wait_until("resume", || a.status() == "Playing");
    rig.wait_for("state=idle");
    // Shutdown is bounded too.
    let t = Instant::now();
    rig.stop().unwrap();
    assert!(t.elapsed() < Duration::from_secs(4), "{:?}", t.elapsed());
    hung.state().stall = Duration::ZERO;
}

fn shutdown_while_recording_resumes(bus: &PrivateBus) {
    let a = FakeMpris::start(bus, &["lftest_a"], "Playing");
    let mut rig = session_daemon(bus, "dbus-shutdown");
    rig.cmd("press");
    wait_until("pause", || a.status() == "Paused");
    rig.stop().unwrap();
    // Resumed before the daemon finished stopping.
    assert_eq!(a.status(), "Playing");
    assert_eq!(a.state().plays, 1);
}

fn no_bus_is_not_fatal(bus: &PrivateBus) {
    let a = FakeMpris::start(bus, &["lftest_a"], "Playing");
    let missing = Mpris::new(MprisConfig {
        address: Some(format!("unix:path={}/no-such-bus", bus.dir.display())),
        ..MprisConfig::default()
    });
    let rig = daemon("dbus-missing", Box::new(missing));
    rig.cmd("toggle");
    rig.cmd("toggle");
    rig.wait_for("state=idle");
    assert_eq!(rig.output.text(), "Synthetic. ");
    assert_eq!(a.state().pauses, 0);
}

// ------------------------------------------------------------ tray

/// A fake tray host's watcher: records every item registered.
#[derive(Clone, Default)]
struct FakeWatcher(Arc<Mutex<Vec<String>>>);

#[zbus::interface(name = "org.kde.StatusNotifierWatcher")]
impl FakeWatcher {
    fn register_status_notifier_item(&self, service: String) {
        self.0.lock().unwrap().push(service);
    }
}

impl FakeWatcher {
    /// Joins `bus` as `org.kde.StatusNotifierWatcher`.
    fn start(bus: &PrivateBus) -> (FakeWatcher, zbus::blocking::Connection) {
        let w = FakeWatcher::default();
        let builder = zbus::blocking::connection::Builder::address(bus.address.as_str())
            .unwrap()
            .serve_at(tray::WATCHER_PATH, w.clone())
            .unwrap()
            .name(tray::WATCHER)
            .unwrap();
        (
            w,
            bounded("the fake watcher", move || builder.build()).unwrap(),
        )
    }

    fn registered(&self) -> Vec<String> {
        self.0.lock().unwrap().clone()
    }

    fn wait_for(&self, name: &str, times: usize) {
        wait_until("registration", || {
            self.registered().iter().filter(|n| *n == name).count() >= times
        });
    }
}

/// Runs `f` on a thread for at most 10 s, so a stalled private bus fails
/// the test instead of hanging it.
fn bounded<T: Send + 'static>(what: &str, f: impl FnOnce() -> T + Send + 'static) -> T {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(f());
    });
    rx.recv_timeout(Duration::from_secs(10))
        .unwrap_or_else(|_| panic!("{what} did not finish in 10 s"))
}

/// Reads the tray item's properties as a host does.
struct Host(zbus::blocking::Connection);

type ToolTip = (String, Vec<(i32, i32, Vec<u8>)>, String, String);

impl Host {
    fn new(bus: &PrivateBus) -> Host {
        let addr = bus.address.clone();
        Host(bounded("a host connection", move || {
            zbus::blocking::connection::Builder::address(addr.as_str())
                .unwrap()
                .build()
                .unwrap()
        }))
    }

    fn get(&self, item: &str, property: &str) -> OwnedValue {
        let reply = self
            .0
            .call_method(
                Some(item),
                tray::ITEM_PATH,
                Some("org.freedesktop.DBus.Properties"),
                "Get",
                &(tray::ITEM_INTERFACE, property),
            )
            .unwrap();
        reply.body().deserialize::<OwnedValue>().unwrap()
    }

    fn string(&self, item: &str, property: &str) -> String {
        String::try_from(self.get(item, property)).unwrap()
    }

    fn tool_tip(&self, item: &str) -> ToolTip {
        ToolTip::try_from(self.get(item, "ToolTip")).unwrap()
    }

    /// Every signal from the tray interface, as (member, body string).
    fn signals(&self) -> std::sync::mpsc::Receiver<(String, String)> {
        let rule = zbus::MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .interface(tray::ITEM_INTERFACE)
            .unwrap()
            .build();
        let it = zbus::blocking::MessageIterator::for_match_rule(rule, &self.0, None).unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for msg in it {
                let Ok(msg) = msg else { break };
                let member = msg.header().member().map(|m| m.to_string());
                let body = msg.body().deserialize::<String>().unwrap_or_default();
                if tx.send((member.unwrap_or_default(), body)).is_err() {
                    break;
                }
            }
        });
        rx
    }
}

/// The signals that arrive within `wait`.
fn drain(
    rx: &std::sync::mpsc::Receiver<(String, String)>,
    wait: Duration,
) -> Vec<(String, String)> {
    let mut got = Vec::new();
    while let Ok(s) = rx.recv_timeout(wait) {
        got.push(s);
    }
    got
}

fn signal(member: &str, body: &str) -> (String, String) {
    (member.into(), body.into())
}

fn tray_publishes_states_and_follows_watchers(bus: &PrivateBus) {
    let host = Host::new(bus);
    // Published before any watcher exists: registered once one appears.
    let item = bounded("tray start", || {
        Tray::start(None, Class::Offline, || {}).map_err(|e| e.to_string())
    })
    .unwrap();
    let name = item.name().to_owned();
    assert_eq!(
        name,
        format!("org.kde.StatusNotifierItem-{}-1", std::process::id())
    );
    for (property, want) in [
        ("Category", "ApplicationStatus"),
        ("Id", "localflow"),
        ("Title", "LocalFlow"),
        ("Status", "Active"),
        ("IconName", "network-offline"),
        ("AttentionIconName", "media-record"),
    ] {
        assert_eq!(host.string(&name, property), want, "{property}");
    }
    assert!(!bool::try_from(host.get(&name, "ItemIsMenu")).unwrap());
    // GNOME's AppIndicator extension shows an item only with a menu: an
    // empty dbusmenu.
    let menu = zbus::zvariant::OwnedObjectPath::try_from(host.get(&name, "Menu")).unwrap();
    assert_eq!(menu.as_str(), tray::MENU_PATH);
    let reply = host
        .0
        .call_method(
            Some(name.as_str()),
            tray::MENU_PATH,
            Some(tray::MENU_INTERFACE),
            "GetLayout",
            &(0i32, -1i32, Vec::<String>::new()),
        )
        .unwrap();
    type Layout = (i32, HashMap<String, OwnedValue>, Vec<OwnedValue>);
    let (_revision, (id, props, children)): (u32, Layout) = reply.body().deserialize().unwrap();
    assert_eq!((id, children.len()), (0, 0));
    assert_eq!(
        String::try_from(props["children-display"].try_clone().unwrap()).unwrap(),
        "submenu"
    );
    let reply = host
        .0
        .call_method(
            Some(name.as_str()),
            tray::MENU_PATH,
            Some(tray::MENU_INTERFACE),
            "AboutToShow",
            &0i32,
        )
        .unwrap();
    assert!(!reply.body().deserialize::<bool>().unwrap());
    assert_eq!(
        host.tool_tip(&name),
        (
            "network-offline".into(),
            vec![],
            "LocalFlow".into(),
            "Not running".into()
        )
    );
    let (watcher, conn) = FakeWatcher::start(bus);
    watcher.wait_for(&name, 1);

    // Changes are signalled: the icon and status only when they change.
    let rx = host.signals();
    item.show(Class::Recording).unwrap();
    let got = drain(&rx, Duration::from_millis(500));
    assert_eq!(
        got,
        [
            signal("NewIcon", ""),
            signal("NewToolTip", ""),
            signal("NewStatus", "NeedsAttention")
        ]
    );
    assert_eq!(host.string(&name, "IconName"), "media-record");
    assert_eq!(host.string(&name, "Status"), "NeedsAttention");
    item.show(Class::Recording).unwrap();
    assert_eq!(drain(&rx, Duration::from_millis(300)), []);
    item.show(Class::Transcribing).unwrap();
    assert_eq!(
        drain(&rx, Duration::from_millis(500)),
        [
            signal("NewIcon", ""),
            signal("NewToolTip", ""),
            signal("NewStatus", "Active"),
        ]
    );
    item.show(Class::Typing).unwrap();
    assert_eq!(
        drain(&rx, Duration::from_millis(500)),
        [signal("NewToolTip", "")]
    );
    for (class, icon, text) in [
        (Class::Idle, "audio-input-microphone", "Idle"),
        (
            Class::Loading,
            "audio-input-microphone",
            "Loading the model",
        ),
        (
            Class::NoMic,
            "microphone-sensitivity-muted",
            "No microphone",
        ),
        (Class::Typing, "emblem-synchronizing", "Typing"),
    ] {
        item.show(class).unwrap();
        assert_eq!(host.string(&name, "IconName"), icon);
        assert_eq!(
            host.tool_tip(&name),
            (icon.into(), vec![], "LocalFlow".into(), text.into())
        );
    }

    // The tray host restarts: registered again with the new watcher.
    drop(conn);
    let (watcher2, _conn2) = FakeWatcher::start(bus);
    watcher2.wait_for(&name, 1);
    assert_eq!(watcher.registered(), std::slice::from_ref(&name));
    assert!(item.connected());
}

fn localflowctl_tray_follows_the_daemon(bus: &PrivateBus) {
    let host = Host::new(bus);
    let (watcher, _conn) = FakeWatcher::start(bus);
    let mut rig = Rig::start(
        "dbus-tray",
        FakeCapture::with_samples(vec![0.1; 16_000]),
        factory(FakeRecognizer::returning("Synthetic.")),
        settings(),
        false,
    );
    let mut child = Command::new(env!("CARGO_BIN_EXE_localflowctl"))
        .arg("tray")
        .env("XDG_RUNTIME_DIR", common::runtime_dir(&rig.dir))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    // Nothing reads its output: unlike `watch`, the tray keeps running.
    drop(child.stdout.take());
    let name = format!("org.kde.StatusNotifierItem-{}-1", child.id());
    watcher.wait_for(&name, 1);
    let icon_becomes = |want: &str| wait_until(want, || host.string(&name, "IconName") == want);
    icon_becomes("audio-input-microphone");
    rig.cmd("toggle");
    icon_becomes("media-record");
    assert_eq!(host.string(&name, "Status"), "NeedsAttention");
    rig.cmd("toggle");
    rig.wait_for("state=idle");
    icon_becomes("audio-input-microphone");
    assert_eq!(rig.output.text(), "Synthetic. ");
    rig.stop().unwrap();
    icon_becomes("network-offline");
    assert_eq!(host.tool_tip(&name).3, "Not running");
    assert!(child.try_wait().unwrap().is_none(), "the tray exited");
    child.kill().unwrap();
    child.wait().unwrap();
    let mut err = String::new();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut err)
        .unwrap();
    assert!(!err.contains("ynthetic"), "{err}");
}

/// Its own bus, stopped under it: the tray reports the loss.
fn tray_reports_a_lost_bus(shared: &PrivateBus) {
    let bus = PrivateBus::start();
    let (tx, rx) = std::sync::mpsc::channel();
    let addr = bus.address.clone();
    let item = bounded("tray start", move || {
        Tray::start(Some(&addr), Class::Idle, move || {
            let _ = tx.send(());
        })
        .map_err(|e| e.to_string())
    })
    .unwrap();
    assert!(item.connected());
    drop(bus);
    rx.recv_timeout(Duration::from_secs(10))
        .expect("the lost bus was not reported");
    assert!(!item.connected());
    assert_eq!(item.show(Class::Recording), Err(TrayError::Lost));
    // An unreachable bus is refused at once.
    let missing = Tray::start(
        Some("unix:path=/nonexistent/lf-test-bus"),
        Class::Idle,
        || {},
    );
    assert_eq!(missing.err(), Some(TrayError::Connect));
    // A bus that accepts the connection and then says nothing: given up
    // after the deadline.
    let dir = shared.dir.join("silent");
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("bus");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    let held = std::thread::spawn(move || listener.accept().map(|(s, _)| s));
    let t = Instant::now();
    let silent = Tray::start(
        Some(&format!("unix:path={}", socket.display())),
        Class::Idle,
        || {},
    );
    assert_eq!(silent.err(), Some(TrayError::Connect));
    assert!(
        t.elapsed() >= tray::CALL_TIMEOUT && t.elapsed() < tray::CALL_TIMEOUT * 2,
        "{:?}",
        t.elapsed()
    );
    drop(held.join());
    let _ = std::fs::remove_dir_all(&dir);
}

// ------------------------------------------------------------ fake portal

const PORTAL_NAME: &str = "org.freedesktop.portal.Desktop";
const DESKTOP_PATH: &str = "/org/freedesktop/portal/desktop";
const SHORTCUTS: &str = "org.freedesktop.portal.GlobalShortcuts";
const HOLD: &str = "hold-to-talk";
const TOGGLE: &str = "toggle";
/// Real audio-length samples (one second at 16 kHz), synthetic values.
const SECOND: usize = 16_000;

type Vardict = HashMap<String, OwnedValue>;

#[derive(Debug, Default)]
struct PortalState {
    /// `Registry.Register` app IDs.
    registered: Vec<String>,
    created: usize,
    /// Shortcut IDs and descriptions of each `BindShortcuts`.
    binds: Vec<Vec<(String, String)>>,
    /// The `BindShortcuts` response code: 0 bound, 1 cancelled.
    bind_response: u32,
    /// This many `CreateSession`s answer 2 (the backend failed).
    create_failures: usize,
    /// This many `BindShortcuts` close the session instead of answering.
    bind_closes: usize,
    /// The client's unique name and its current session handle.
    client: Option<String>,
    session: Option<String>,
}

#[derive(Clone)]
struct PortalCalls(Arc<Mutex<PortalState>>);

impl PortalCalls {
    fn state(&self) -> MutexGuard<'_, PortalState> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// `/org/freedesktop/portal/desktop/request/SENDER/TOKEN`, as the portal
/// builds it.
fn handle_path(kind: &str, sender: &str, options: &Vardict, key: &str) -> String {
    let token: String = options
        .get(key)
        .and_then(|v| String::try_from(v.try_clone().unwrap()).ok())
        .expect("a token");
    let sender = sender.trim_start_matches(':').replace('.', "_");
    format!("{DESKTOP_PATH}/{kind}/{sender}/{token}")
}

fn value(v: impl Into<zbus::zvariant::Value<'static>>) -> OwnedValue {
    v.into().try_into().unwrap()
}

struct ShortcutsIface(PortalCalls);

#[zbus::interface(name = "org.freedesktop.portal.GlobalShortcuts")]
impl ShortcutsIface {
    /// Answers through `Request.Response` before the method returns, which
    /// a client must handle (it subscribes first).
    async fn create_session(
        &self,
        options: Vardict,
        #[zbus(header)] header: zbus::message::Header<'_>,
        #[zbus(connection)] conn: &zbus::Connection,
    ) -> zbus::zvariant::OwnedObjectPath {
        let sender = header.sender().unwrap().to_string();
        let request = handle_path("request", &sender, &options, "handle_token");
        let session = handle_path("session", &sender, &options, "session_handle_token");
        let fail = {
            let mut s = self.0.state();
            s.created += 1;
            s.client = Some(sender.clone());
            s.session = Some(session.clone());
            let fail = s.create_failures > 0;
            s.create_failures = s.create_failures.saturating_sub(1);
            fail
        };
        // `session_handle` is a string (`s`), as the portal sends it.
        let (code, results): (u32, Vardict) = if fail {
            (2, Vardict::new())
        } else {
            (0, [("session_handle".to_owned(), value(session))].into())
        };
        conn.emit_signal(
            Some(sender.as_str()),
            request.as_str(),
            "org.freedesktop.portal.Request",
            "Response",
            &(code, results),
        )
        .await
        .unwrap();
        request.try_into().unwrap()
    }

    async fn bind_shortcuts(
        &self,
        session_handle: zbus::zvariant::ObjectPath<'_>,
        shortcuts: Vec<(String, Vardict)>,
        _parent_window: String,
        options: Vardict,
        #[zbus(header)] header: zbus::message::Header<'_>,
        #[zbus(connection)] conn: &zbus::Connection,
    ) -> zbus::zvariant::OwnedObjectPath {
        let sender = header.sender().unwrap().to_string();
        let request = handle_path("request", &sender, &options, "handle_token");
        let bound: Vec<(String, String)> = shortcuts
            .iter()
            .map(|(id, opts)| {
                let description = opts
                    .get("description")
                    .and_then(|v| String::try_from(v.try_clone().unwrap()).ok())
                    .unwrap_or_default();
                (id.clone(), description)
            })
            .collect();
        let (code, close) = {
            let mut s = self.0.state();
            assert_eq!(s.session.as_deref(), Some(session_handle.as_str()));
            s.binds.push(bound.clone());
            let close = s.bind_closes > 0;
            s.bind_closes = s.bind_closes.saturating_sub(1);
            (s.bind_response, close)
        };
        if close {
            // The session ends while the user would be answering the dialog.
            conn.emit_signal(
                Some(sender.as_str()),
                session_handle.as_str(),
                "org.freedesktop.portal.Session",
                "Closed",
                &(Vardict::new(),),
            )
            .await
            .unwrap();
            return request.try_into().unwrap();
        }
        let reply: Vec<(String, Vardict)> = bound
            .into_iter()
            .map(|(id, description)| {
                let d: Vardict = [
                    ("description".to_owned(), value(description)),
                    ("trigger_description".to_owned(), value("Synthetic key")),
                ]
                .into();
                (id, d)
            })
            .collect();
        let results: Vardict = if code == 0 {
            [("shortcuts".to_owned(), value(reply))].into()
        } else {
            Vardict::new()
        };
        conn.emit_signal(
            Some(sender.as_str()),
            request.as_str(),
            "org.freedesktop.portal.Request",
            "Response",
            &(code, results),
        )
        .await
        .unwrap();
        request.try_into().unwrap()
    }

    /// Lower case, as the portal names it.
    #[zbus(property, name = "version")]
    fn version(&self) -> u32 {
        2
    }
}

struct RegistryIface(PortalCalls);

#[zbus::interface(name = "org.freedesktop.host.portal.Registry")]
impl RegistryIface {
    fn register(&self, app_id: String, _options: Vardict) {
        self.0.state().registered.push(app_id);
    }
}

/// A fake xdg-desktop-portal with only GlobalShortcuts (and the host
/// registry), owning `org.freedesktop.portal.Desktop` on the private bus.
struct FakePortal {
    calls: PortalCalls,
    conn: Option<zbus::blocking::Connection>,
}

impl FakePortal {
    fn start(bus: &PrivateBus, bind_response: u32) -> FakePortal {
        let calls = PortalCalls(Arc::new(Mutex::new(PortalState {
            bind_response,
            ..PortalState::default()
        })));
        let builder = zbus::blocking::connection::Builder::address(bus.address.as_str())
            .unwrap()
            .serve_at(DESKTOP_PATH, ShortcutsIface(calls.clone()))
            .unwrap()
            .serve_at(DESKTOP_PATH, RegistryIface(calls.clone()))
            .unwrap()
            .name(PORTAL_NAME)
            .unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(builder.build());
        });
        let conn = rx
            .recv_timeout(Duration::from_secs(10))
            .expect("fake portal could not join the private bus in 10 s")
            .unwrap();
        FakePortal {
            calls,
            conn: Some(conn),
        }
    }

    fn state(&self) -> MutexGuard<'_, PortalState> {
        self.calls.state()
    }

    fn binds(&self) -> usize {
        self.state().binds.len()
    }

    /// Waits until the daemon has bound its shortcuts `n` times in all.
    fn wait_bound(&self, n: usize) {
        wait_until("the shortcuts to be bound", || self.binds() >= n);
    }

    fn conn(&self) -> &zbus::blocking::Connection {
        self.conn.as_ref().expect("running")
    }

    /// Sends `Activated` or `Deactivated` for `id` to the client.
    fn signal(&self, member: &str, id: &str) {
        let (client, session) = {
            let s = self.state();
            (s.client.clone().unwrap(), s.session.clone().unwrap())
        };
        let session = zbus::zvariant::ObjectPath::try_from(session).unwrap();
        self.conn()
            .emit_signal(
                Some(client.as_str()),
                DESKTOP_PATH,
                SHORTCUTS,
                member,
                &(session, id, 12_345u64, Vardict::new()),
            )
            .unwrap();
    }

    fn activate(&self, id: &str) {
        self.signal("Activated", id);
    }

    fn deactivate(&self, id: &str) {
        self.signal("Deactivated", id);
    }

    /// The portal closes the session (`Session.Closed`).
    fn close_session(&self) {
        let (client, session) = {
            let s = self.state();
            (s.client.clone().unwrap(), s.session.clone().unwrap())
        };
        self.conn()
            .emit_signal(
                Some(client.as_str()),
                session.as_str(),
                "org.freedesktop.portal.Session",
                "Closed",
                &(Vardict::new(),),
            )
            .unwrap();
    }

    /// The portal process exits.
    fn quit(&mut self) {
        if let Some(c) = self.conn.take() {
            let _ = c.close();
        }
    }
}

/// The daemon with the portal trigger, on the private session bus.
struct PortalRig {
    rig: Rig,
    capture: FakeCapture,
    portal: Option<lf_daemon::portal::Portal>,
}

impl PortalRig {
    fn start(bus: &PrivateBus, tag: &str) -> PortalRig {
        assert_private(bus);
        let capture = FakeCapture::with_samples(vec![0.1; SECOND]);
        let rig = Rig::start_full(
            tag,
            capture.clone(),
            factory(FakeRecognizer::returning("Synthetic.")),
            settings(),
            false,
            None,
            WINDOW,
        );
        let setting = lf_daemon::portal::Setting {
            // The session bus from the environment: the private bus.
            address: None,
            call_timeout: Duration::from_secs(5),
            retry: Duration::from_millis(50),
            max_retry: Duration::from_millis(200),
        };
        let events = rig.handle.as_ref().unwrap().events();
        let portal = lf_daemon::portal::spawn(setting, events).unwrap();
        PortalRig {
            rig,
            capture,
            portal: Some(portal),
        }
    }

    fn typed(&self) -> String {
        self.rig.output.text()
    }

    /// Stamped now, like `localflowctl`.
    fn send(&self, cmd: &str) -> String {
        let at = lf_daemon::protocol::monotonic_ns();
        self.rig.cmd(&format!("{cmd} at={at}"))
    }

    fn status(&self) -> String {
        self.rig.cmd("status")
    }
}

impl Drop for PortalRig {
    fn drop(&mut self) {
        if let Some(p) = self.portal.take() {
            assert!(p.stop(Duration::from_secs(5)), "the portal thread hung");
        }
    }
}

/// The double-tap window: the widest allowed, so scheduling rarely matters.
const WINDOW: Duration = Duration::from_millis(1000);

/// No change follows for this long (signals are asynchronous).
fn settle() {
    std::thread::sleep(Duration::from_millis(300));
}

fn portal_maps_shortcuts_to_hold_toggle_and_prompt(bus: &PrivateBus) {
    let portal = FakePortal::start(bus, 0);
    let r = PortalRig::start(bus, "portal-basic");
    portal.wait_bound(1);
    {
        let s = portal.state();
        assert_eq!(s.registered, ["com.ajbarryiii.localflow"]);
        assert_eq!(s.created, 1);
        let ids: Vec<&str> = s.binds[0].iter().map(|(id, _)| id.as_str()).collect();
        assert_eq!(ids, [HOLD, TOGGLE]);
        assert!(s.binds[0].iter().all(|(_, d)| !d.is_empty()));
    }

    // Hold to talk: Activated is press, Deactivated is release.
    portal.activate(HOLD);
    r.rig.wait_for("state=recording mode=hold");
    portal.deactivate(HOLD);
    r.rig.wait_for("state=idle");
    assert_eq!(r.typed(), "Synthetic. ");

    // Toggle: each activation is a full tap; Deactivated changes nothing.
    portal.activate(TOGGLE);
    r.rig.wait_for("state=recording mode=toggle");
    portal.deactivate(TOGGLE);
    settle();
    assert!(r.status().contains("state=recording mode=toggle"));
    portal.activate(TOGGLE);
    r.rig.wait_for("state=idle");
    assert_eq!(r.typed(), "Synthetic. Synthetic. ");

    // A too-short hold is discarded, as from the socket.
    r.capture.state().samples = vec![0.1; SECOND / 10];
    portal.activate(HOLD);
    r.rig.wait_for("state=recording");
    portal.deactivate(HOLD);
    r.rig.wait_for("state=idle");
    settle();
    assert_eq!(r.typed(), "Synthetic. Synthetic. ");

    // A Deactivated without its Activated does not stop a socket hold.
    r.capture.state().samples = vec![0.1; SECOND];
    std::thread::sleep(WINDOW);
    assert_eq!(r.send("press"), "state=recording mode=hold model=ready");
    portal.deactivate(HOLD);
    settle();
    assert!(r.status().contains("state=recording mode=hold"));
    assert_eq!(r.send("release"), "state=transcribing model=ready");
    r.rig.wait_for("state=idle");
    r.rig.output.state().typed.clear();

    // Hold to Prompt: a tap, then press again at once and hold. Timing uses
    // real clocks (see `hold_to_prompt_by_double_tap_and_hold` in
    // tests/daemon.rs), so an overrun window is detected and retried.
    std::thread::sleep(WINDOW);
    let mut attempts = 0;
    loop {
        attempts += 1;
        r.capture.state().samples = vec![0.1; SECOND / 10];
        portal.activate(HOLD);
        r.rig.wait_for("state=recording");
        let t = Instant::now();
        portal.deactivate(HOLD);
        r.rig.wait_for("state=idle");
        r.capture.state().samples = vec![0.1; SECOND];
        portal.activate(HOLD);
        let status = r.rig.wait_for("state=recording");
        let took = t.elapsed();
        if status.contains("tag=prompt") {
            break;
        }
        assert!(
            took > WINDOW,
            "no prompt although the second press came {took:?} after the tap: {status}"
        );
        assert!(attempts < 20, "the window was overrun 20 times");
        portal.deactivate(HOLD);
        r.rig.wait_for("state=idle");
        r.rig.output.state().typed.clear();
        std::thread::sleep(WINDOW);
    }
    portal.deactivate(HOLD);
    r.rig.wait_for("state=idle");
    assert_eq!(r.typed(), "[dictated] Synthetic. ");
}

fn portal_session_loss_releases_and_binds_again(bus: &PrivateBus) {
    let mut portal = FakePortal::start(bus, 0);
    let r = PortalRig::start(bus, "portal-loss");
    portal.wait_bound(1);

    // The portal closes the session during a hold: treated as the release
    // (the recording is transcribed, never left open), then a new session
    // is bound.
    portal.activate(HOLD);
    r.rig.wait_for("state=recording mode=hold");
    portal.close_session();
    r.rig.wait_for("state=idle");
    assert_eq!(r.typed(), "Synthetic. ");
    portal.wait_bound(2);
    assert_eq!(portal.state().created, 2);
    portal.activate(HOLD);
    r.rig.wait_for("state=recording mode=hold");
    portal.deactivate(HOLD);
    r.rig.wait_for("state=idle");
    assert_eq!(r.typed(), "Synthetic. Synthetic. ");

    // The portal exits during a hold: released too.
    portal.activate(HOLD);
    r.rig.wait_for("state=recording mode=hold");
    portal.quit();
    r.rig.wait_for("state=idle");
    assert_eq!(r.typed(), "Synthetic. Synthetic. Synthetic. ");

    // It starts again: the daemon registers and binds afresh.
    let portal = FakePortal::start(bus, 0);
    portal.wait_bound(1);
    assert_eq!(portal.state().registered, ["com.ajbarryiii.localflow"]);
    portal.activate(HOLD);
    r.rig.wait_for("state=recording mode=hold");
    portal.deactivate(HOLD);
    r.rig.wait_for("state=idle");

    // A toggle recording is not the portal's hold: losing the session
    // leaves it running.
    portal.activate(TOGGLE);
    r.rig.wait_for("state=recording mode=toggle");
    portal.close_session();
    portal.wait_bound(2);
    assert!(r.status().contains("state=recording mode=toggle"));
    assert_eq!(r.send("cancel"), "state=idle model=ready note=cancelled");
}

fn portal_missing_is_not_fatal(bus: &PrivateBus) {
    let r = PortalRig::start(bus, "portal-missing");
    // Socket commands work without a portal.
    settle();
    assert_eq!(r.send("press"), "state=recording mode=hold model=ready");
    assert_eq!(r.send("release"), "state=transcribing model=ready");
    r.rig.wait_for("state=idle");
    assert_eq!(r.typed(), "Synthetic. ");
    // A portal that starts later is used.
    let portal = FakePortal::start(bus, 0);
    portal.wait_bound(1);
    portal.activate(HOLD);
    r.rig.wait_for("state=recording mode=hold");
    portal.deactivate(HOLD);
    r.rig.wait_for("state=idle");
    assert_eq!(r.typed(), "Synthetic. Synthetic. ");
}

fn portal_ignores_signals_from_others(bus: &PrivateBus) {
    let portal = FakePortal::start(bus, 0);
    let r = PortalRig::start(bus, "portal-spoof");
    portal.wait_bound(1);
    let (client, session) = {
        let s = portal.state();
        (s.client.clone().unwrap(), s.session.clone().unwrap())
    };
    // Another client on the bus, not the portal.
    let other = {
        let address = bus.address.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(
                zbus::blocking::connection::Builder::address(address.as_str())
                    .unwrap()
                    .build(),
            );
        });
        rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap()
    };
    let path = zbus::zvariant::ObjectPath::try_from(session.as_str()).unwrap();
    other
        .emit_signal(
            Some(client.as_str()),
            DESKTOP_PATH,
            SHORTCUTS,
            "Activated",
            &(path, HOLD, 1u64, Vardict::new()),
        )
        .unwrap();
    other
        .emit_signal(
            Some(client.as_str()),
            session.as_str(),
            "org.freedesktop.portal.Session",
            "Closed",
            &(Vardict::new(),),
        )
        .unwrap();
    settle();
    assert!(r.status().starts_with("state=idle"), "{}", r.status());
    assert_eq!(portal.binds(), 1);
    // Signals for another session are ignored too.
    let other_session =
        zbus::zvariant::ObjectPath::try_from(format!("{DESKTOP_PATH}/session/x/other")).unwrap();
    portal
        .conn()
        .emit_signal(
            Some(client.as_str()),
            DESKTOP_PATH,
            SHORTCUTS,
            "Activated",
            &(other_session, HOLD, 1u64, Vardict::new()),
        )
        .unwrap();
    settle();
    assert!(r.status().starts_with("state=idle"), "{}", r.status());
    // The real portal's signals still work.
    portal.activate(HOLD);
    r.rig.wait_for("state=recording mode=hold");
    portal.deactivate(HOLD);
    r.rig.wait_for("state=idle");
}

fn portal_cancelled_binding_is_not_asked_again(bus: &PrivateBus) {
    let portal = FakePortal::start(bus, 1);
    let r = PortalRig::start(bus, "portal-cancelled");
    portal.wait_bound(1);
    // Well past several retry intervals: no second dialog.
    std::thread::sleep(Duration::from_millis(1000));
    assert_eq!(portal.binds(), 1);
    assert_eq!(portal.state().created, 1);
    assert_eq!(r.send("toggle"), "state=recording mode=toggle model=ready");
    assert_eq!(r.send("toggle"), "state=transcribing model=ready");
    r.rig.wait_for("state=idle");
}

fn portal_retries_a_failed_session_and_a_session_closed_while_binding(bus: &PrivateBus) {
    let portal = FakePortal::start(bus, 0);
    {
        let mut s = portal.state();
        s.create_failures = 1;
        s.bind_closes = 1;
    }
    let r = PortalRig::start(bus, "portal-retry");
    // A failed CreateSession and a session closed during BindShortcuts are
    // both tried again; the third session is bound.
    portal.wait_bound(2);
    wait_until("the third session", || portal.state().created == 3);
    portal.activate(HOLD);
    r.rig.wait_for("state=recording mode=hold");
    portal.deactivate(HOLD);
    r.rig.wait_for("state=idle");
    assert_eq!(r.typed(), "Synthetic. ");
}

fn portal_stops_with_the_daemon(bus: &PrivateBus) {
    let portal = FakePortal::start(bus, 0);
    let mut r = PortalRig::start(bus, "portal-stop");
    portal.wait_bound(1);
    portal.activate(HOLD);
    r.rig.wait_for("state=recording mode=hold");
    let t = Instant::now();
    r.rig.stop().unwrap();
    assert!(r.portal.take().unwrap().stop(Duration::from_secs(5)));
    assert!(t.elapsed() < Duration::from_secs(4), "{:?}", t.elapsed());
    assert_eq!(r.capture.state().cancels, 1);
}

fn main() {
    if std::env::var_os("LF_SKIP_DBUS_TESTS").is_some() {
        println!("private_dbus: skipped (LF_SKIP_DBUS_TESTS)");
        return;
    }
    let bus = PrivateBus::start();
    // SAFETY: `harness = false` and nothing has started a thread yet (the
    // dbus-daemon child is a separate process), so nothing reads the
    // environment concurrently.
    unsafe {
        std::env::set_var("DBUS_SESSION_BUS_ADDRESS", &bus.address);
        std::env::set_var("XDG_RUNTIME_DIR", &bus.dir);
        std::env::remove_var("DBUS_SYSTEM_BUS_ADDRESS");
    }
    assert_private(&bus);
    let tests: [(&str, Case); 16] = [
        (
            "pauses_playing_players_and_resumes_them",
            pauses_playing_players_and_resumes_them,
        ),
        (
            "leaves_players_the_user_changed_alone",
            leaves_players_the_user_changed_alone,
        ),
        (
            "a_restarted_player_is_not_resumed",
            a_restarted_player_is_not_resumed,
        ),
        ("a_hung_player_delays_nothing", a_hung_player_delays_nothing),
        (
            "shutdown_while_recording_resumes",
            shutdown_while_recording_resumes,
        ),
        ("no_bus_is_not_fatal", no_bus_is_not_fatal),
        (
            "tray_publishes_states_and_follows_watchers",
            tray_publishes_states_and_follows_watchers,
        ),
        (
            "localflowctl_tray_follows_the_daemon",
            localflowctl_tray_follows_the_daemon,
        ),
        ("tray_reports_a_lost_bus", tray_reports_a_lost_bus),
        (
            "portal_maps_shortcuts_to_hold_toggle_and_prompt",
            portal_maps_shortcuts_to_hold_toggle_and_prompt,
        ),
        (
            "portal_session_loss_releases_and_binds_again",
            portal_session_loss_releases_and_binds_again,
        ),
        ("portal_missing_is_not_fatal", portal_missing_is_not_fatal),
        (
            "portal_ignores_signals_from_others",
            portal_ignores_signals_from_others,
        ),
        (
            "portal_cancelled_binding_is_not_asked_again",
            portal_cancelled_binding_is_not_asked_again,
        ),
        (
            "portal_retries_a_failed_session_and_a_session_closed_while_binding",
            portal_retries_a_failed_session_and_a_session_closed_while_binding,
        ),
        ("portal_stops_with_the_daemon", portal_stops_with_the_daemon),
    ];
    for (name, test) in tests {
        assert_private(&bus);
        let t = Instant::now();
        test(&bus);
        println!("test {name} ... ok ({:.0?})", t.elapsed());
    }
    println!("private_dbus: {} tests passed", tests.len());
}

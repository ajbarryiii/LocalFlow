//! End-to-end media pausing against a private D-Bus session bus.
//!
//! The harness starts its own `dbus-daemon` with its own configuration and a
//! socket in a fresh private directory: no service activation, no syslog,
//! a cleared environment. Fake MPRIS players (served by `zbus` in this
//! process) join that bus, and the daemon (fake microphone, recognizer and
//! keyboard; the real MPRIS backend) pauses and resumes them.
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
    assert_eq!(rig.output.text(), "Synthetic.");
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
    assert_eq!(rig.output.text(), "Synthetic.");
    assert_eq!(a.state().pauses, 0);
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
    let tests: [(&str, Case); 6] = [
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
    ];
    for (name, test) in tests {
        assert_private(&bus);
        let t = Instant::now();
        test(&bus);
        println!("test {name} ... ok ({:.0?})", t.elapsed());
    }
    println!("private_dbus: {} tests passed", tests.len());
}

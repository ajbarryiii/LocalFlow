//! End-to-end capture test against a private PipeWire daemon.
//!
//! The harness starts its own `pipewire` with a minimal configuration in a
//! fresh private runtime directory: no ALSA, no udev, no Bluetooth, no
//! session manager, no D-Bus, and a socket named `lf-test-pipewire` that the
//! user's graph never has. A synthetic 440 Hz tone (a playback stream in
//! this process) is linked into the capture stream with `pw-link`. The test
//! refuses to run unless the PipeWire remote resolves into its private
//! directory, so it can never join the user's live graph.
//! The microphone presence monitor is checked against a null audio source
//! created on the same private daemon.
//!
//! Needs `pipewire` and `pw-link` on `PATH` (the `linux/flake.nix` dev shell
//! provides them); set `LF_SKIP_PIPEWIRE_TESTS=1` to skip it elsewhere.
//! `harness = false` so the environment is set before any thread exists.

use std::cell::Cell;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use lf_io_api::{AudioCapture, SAMPLE_RATE};
use lf_pipewire::{CaptureConfig, Overflow, PipeWireCapture, PresenceMonitor, Recording};
use pipewire as pw;
use pw::spa;

const SOCKET: &str = "lf-test-pipewire";
const TONE_HZ: f64 = 440.0;
const TONE_AMP: f64 = 0.5;

const CONFIG: &str = r#"
context.properties = {
    core.daemon = true
    core.name = lf-test-pipewire
    support.dbus = false
    default.clock.rate = 48000
    default.clock.allowed-rates = [ 48000 ]
}
context.spa-libs = {
    audio.convert.* = audioconvert/libspa-audioconvert
    audio.adapt = audioconvert/libspa-audioconvert
    support.* = support/libspa-support
}
context.modules = [
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-access args = { } }
    { name = libpipewire-module-metadata }
    { name = libpipewire-module-spa-node-factory }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-adapter }
    { name = libpipewire-module-link-factory }
]
context.objects = [
    { factory = spa-node-factory
      args = { factory.name = support.node.driver node.name = Dummy-Driver priority.driver = 20000 } }
]
"#;

/// The stock client.conf minus module-rt (which talks to RTKit over D-Bus)
/// and the session-manager/client-device modules nobody here needs.
const CLIENT_CONFIG: &str = r#"
context.properties = { log.level = 0 }
context.spa-libs = {
    audio.convert.* = audioconvert/libspa-audioconvert
    support.* = support/libspa-support
}
context.modules = [
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-adapter }
    { name = libpipewire-module-metadata }
]
"#;

/// Without a session manager nobody configures stream ports; ask the
/// adapter to expose one DSP port per channel itself.
const PORT_CONFIG: &str = "{ mode = dsp monitor = false control = false position = preserve }";

// ---------------------------------------------------------------- daemon

struct PrivatePipeWire {
    dir: PathBuf,
    socket: PathBuf,
    child: Child,
}

impl PrivatePipeWire {
    fn start() -> Self {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .subsec_nanos();
        let dir = std::env::temp_dir().join(format!(
            "lf-pipewire-test-{}-{nanos:08x}",
            std::process::id()
        ));
        std::fs::DirBuilder::new().mode(0o700).create(&dir).unwrap();
        let dir = dir.canonicalize().unwrap();
        let conf = dir.join("lf-test-pipewire.conf");
        std::fs::write(&conf, CONFIG).unwrap();
        // Client configuration for every client of the private daemon (this
        // process and pw-link), so the user's client.conf drop-ins (which
        // could name another remote) and module-rt (D-Bus) are not used.
        std::fs::create_dir(dir.join("client-conf")).unwrap();
        std::fs::write(dir.join("client-conf/client.conf"), CLIENT_CONFIG).unwrap();
        let log = std::fs::File::create(dir.join("pipewire.log")).unwrap();
        let mut cmd = Command::new("pipewire");
        cmd.arg("-c")
            .arg(&conf)
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", &dir)
            .env("XDG_RUNTIME_DIR", &dir)
            .env("PIPEWIRE_RUNTIME_DIR", &dir)
            .env("XDG_CONFIG_HOME", &dir)
            .env(
                "DBUS_SESSION_BUS_ADDRESS",
                format!("unix:path={}", dir.join("no-bus").display()),
            )
            .env(
                "DBUS_SYSTEM_BUS_ADDRESS",
                format!("unix:path={}", dir.join("no-bus").display()),
            )
            .process_group(0)
            .stdin(Stdio::null())
            .stdout(log.try_clone().unwrap())
            .stderr(log);
        // SAFETY: prctl is async-signal-safe.
        unsafe {
            cmd.pre_exec(|| {
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
                Ok(())
            });
        }
        let child = cmd.spawn().expect("spawn pipewire");
        let mut pw = Self {
            socket: dir.join(SOCKET),
            dir,
            child,
        };
        let deadline = Instant::now() + Duration::from_secs(10);
        while !pw.socket.exists() {
            if let Some(status) = pw.child.try_wait().unwrap() {
                let log = std::fs::read_to_string(pw.dir.join("pipewire.log")).unwrap_or_default();
                panic!("pipewire exited early ({status}):\n{log}");
            }
            assert!(Instant::now() < deadline, "pipewire socket did not appear");
            std::thread::sleep(Duration::from_millis(10));
        }
        pw
    }

    fn remote(&self) -> String {
        self.socket.to_str().unwrap().to_owned()
    }

    fn command(&self, program: &str) -> Command {
        let mut cmd = Command::new(program);
        cmd.env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", &self.dir)
            .env("XDG_RUNTIME_DIR", &self.dir)
            .env("PIPEWIRE_RUNTIME_DIR", &self.dir)
            .env("PIPEWIRE_REMOTE", &self.socket)
            .env("PIPEWIRE_CONFIG_DIR", self.dir.join("client-conf"))
            .env("XDG_CONFIG_HOME", &self.dir)
            .process_group(0)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        cmd
    }
}

impl Drop for PrivatePipeWire {
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

/// Refuses to continue unless `remote` can only lead into the private
/// directory.
///
/// PipeWire resolves the remote as: `PIPEWIRE_REMOTE` if set, else the
/// `remote.name` property; an absolute name is used as is, a relative one
/// is tried in the runtime directory and then in `/run/pipewire`. So: the
/// variable must be unset, every remote used must be absolute and inside
/// the private directory, and the client configuration must come from the
/// private directory too.
fn guard(pw: &PrivatePipeWire, remote: &str) {
    let tmp = std::env::temp_dir().canonicalize().unwrap();
    let env_path = |k: &str| std::env::var_os(k).map(PathBuf::from);
    let remote = Path::new(remote);
    // The only PipeWire variables present are the private ones set in main.
    let allowed = [
        "PIPEWIRE_CONFIG_DIR",
        "PIPEWIRE_CONFIG_NAME",
        "PIPEWIRE_RUNTIME_DIR",
        "PIPEWIRE_STATE_DIR",
    ];
    let only_private_vars = std::env::vars_os().all(|(k, _)| {
        let k = k.to_string_lossy();
        !(k.starts_with("PIPEWIRE_") || k.starts_with("SPA_") || k.starts_with("PW_"))
            || allowed.contains(&k.as_ref())
    });
    let ok = only_private_vars
        && std::env::var_os("PIPEWIRE_CONFIG_NAME").as_deref() == Some("client.conf".as_ref())
        && env_path("PIPEWIRE_STATE_DIR").as_deref() == Some(pw.dir.as_path())
        && remote.is_absolute()
        && remote.starts_with(&pw.dir)
        && !remote
            .components()
            .any(|c| c == std::path::Component::ParentDir)
        && pw.dir.starts_with(&tmp)
        && env_path("PIPEWIRE_CONFIG_DIR").as_deref() == Some(pw.dir.join("client-conf").as_path())
        && env_path("PIPEWIRE_RUNTIME_DIR").as_deref() == Some(pw.dir.as_path())
        && env_path("XDG_RUNTIME_DIR").as_deref() == Some(pw.dir.as_path());
    assert!(
        ok,
        "refusing to run: the PipeWire remote does not resolve to the private test daemon"
    );
}

// ---------------------------------------------------------------- tone

/// A playback stream in this process producing a 48 kHz stereo sine.
struct Tone {
    stop: Arc<EventFd>,
    thread: Option<JoinHandle<()>>,
}

struct EventFd(OwnedFd);

impl EventFd {
    fn new() -> Self {
        // SAFETY: valid flags.
        let fd = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) };
        assert!(fd >= 0);
        // SAFETY: fresh fd.
        Self(unsafe { OwnedFd::from_raw_fd(fd) })
    }
}

struct Fd(Arc<EventFd>);

impl AsRawFd for Fd {
    fn as_raw_fd(&self) -> RawFd {
        self.0.0.as_raw_fd()
    }
}

impl Tone {
    fn start(remote: String) -> Self {
        let stop = Arc::new(EventFd::new());
        let stop2 = stop.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        let thread = std::thread::spawn(move || {
            let mainloop = pw::main_loop::MainLoopRc::new(None).unwrap();
            let context = pw::context::ContextRc::new(&mainloop, None).unwrap();
            let mut cprops = pw::properties::PropertiesBox::new();
            cprops.insert("remote.name", remote.as_str());
            let core = context.connect_rc(Some(cprops)).expect("tone: connect");
            let mut props = pw::properties::PropertiesBox::new();
            props.insert("media.type", "Audio");
            props.insert("media.category", "Playback");
            props.insert("node.name", "lf-test-tone");
            props.insert("node.autoconnect", "false");
            props.insert("adapter.auto-port-config", PORT_CONFIG);
            let stream = pw::stream::StreamRc::new(core.clone(), "lf-test-tone", props).unwrap();
            let phase = Rc::new(Cell::new(0u64));
            let _listener = stream
                .add_local_listener_with_user_data(())
                .process(move |stream, _| {
                    let Some(mut buffer) = stream.dequeue_buffer() else {
                        return;
                    };
                    let requested = buffer.requested() as usize;
                    let datas = buffer.datas_mut();
                    let data = &mut datas[0];
                    let Some(bytes) = data.data() else {
                        return;
                    };
                    let max = bytes.len() / 8;
                    let frames = if requested > 0 {
                        requested.min(max)
                    } else {
                        max.min(1024)
                    };
                    for f in 0..frames {
                        let n = phase.get() + f as u64;
                        let v = (TONE_AMP
                            * (2.0 * std::f64::consts::PI * TONE_HZ * n as f64 / 48_000.0).sin())
                            as f32;
                        bytes[f * 8..f * 8 + 4].copy_from_slice(&v.to_le_bytes());
                        bytes[f * 8 + 4..f * 8 + 8].copy_from_slice(&v.to_le_bytes());
                    }
                    phase.set(phase.get() + frames as u64);
                    let chunk = data.chunk_mut();
                    *chunk.offset_mut() = 0;
                    *chunk.stride_mut() = 8;
                    *chunk.size_mut() = (frames * 8) as u32;
                })
                .register()
                .unwrap();
            let mut info = spa::param::audio::AudioInfoRaw::new();
            info.set_format(spa::param::audio::AudioFormat::F32LE);
            info.set_rate(48_000);
            info.set_channels(2);
            let mut pos = [0u32; spa::sys::SPA_AUDIO_MAX_CHANNELS as usize];
            pos[0] = spa::sys::SPA_AUDIO_CHANNEL_FL;
            pos[1] = spa::sys::SPA_AUDIO_CHANNEL_FR;
            info.set_position(pos);
            let bytes = spa::pod::serialize::PodSerializer::serialize(
                std::io::Cursor::new(Vec::new()),
                &spa::pod::Value::Object(spa::pod::Object {
                    type_: spa::utils::SpaTypes::ObjectParamFormat.as_raw(),
                    id: spa::param::ParamType::EnumFormat.as_raw(),
                    properties: info.into(),
                }),
            )
            .unwrap()
            .0
            .into_inner();
            let mut params = [spa::pod::Pod::from_bytes(&bytes).unwrap()];
            stream
                .connect(
                    spa::utils::Direction::Output,
                    None,
                    pw::stream::StreamFlags::MAP_BUFFERS,
                    &mut params,
                )
                .unwrap();
            let weak = mainloop.downgrade();
            let _src =
                mainloop
                    .loop_()
                    .add_io(Fd(stop2), spa::support::system::IoFlags::IN, move |_| {
                        if let Some(l) = weak.upgrade() {
                            l.quit();
                        }
                    });
            tx.send(()).unwrap();
            mainloop.run();
            let _ = stream.disconnect();
        });
        rx.recv_timeout(Duration::from_secs(10))
            .expect("tone stream");
        Self {
            stop,
            thread: Some(thread),
        }
    }
}

impl Drop for Tone {
    fn drop(&mut self) {
        let one = 1u64;
        // SAFETY: 8-byte write to our eventfd.
        unsafe { libc::write(self.stop.0.as_raw_fd(), (&one as *const u64).cast(), 8) };
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

// -{64} source

/// A null audio source node on the private daemon, alive while this exists.
struct NullSource {
    stop: Arc<EventFd>,
    thread: Option<JoinHandle<()>>,
}

impl NullSource {
    fn start(remote: String, name: &'static str) -> Self {
        let stop = Arc::new(EventFd::new());
        let stop2 = stop.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        let thread = std::thread::spawn(move || {
            let mainloop = pw::main_loop::MainLoopRc::new(None).unwrap();
            let context = pw::context::ContextRc::new(&mainloop, None).unwrap();
            let mut cprops = pw::properties::PropertiesBox::new();
            cprops.insert("remote.name", remote.as_str());
            let core = context.connect_rc(Some(cprops)).expect("source: connect");
            let mut props = pw::properties::PropertiesBox::new();
            props.insert("factory.name", "support.null-audio-sink");
            props.insert("media.class", "Audio/Source");
            props.insert("node.name", name);
            props.insert("audio.channels", "1");
            // The node lives as long as this proxy.
            let _node: pw::node::Node = core
                .create_object("adapter", &props)
                .expect("source: create");
            let weak = mainloop.downgrade();
            let _src =
                mainloop
                    .loop_()
                    .add_io(Fd(stop2), spa::support::system::IoFlags::IN, move |_| {
                        if let Some(l) = weak.upgrade() {
                            l.quit();
                        }
                    });
            tx.send(()).unwrap();
            mainloop.run();
        });
        rx.recv_timeout(Duration::from_secs(10))
            .expect("null source");
        Self {
            stop,
            thread: Some(thread),
        }
    }
}

impl Drop for NullSource {
    fn drop(&mut self) {
        let one = 1u64;
        // SAFETY: 8-byte write to our eventfd.
        unsafe { libc::write(self.stop.0.as_raw_fd(), (&one as *const u64).cast(), 8) };
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

// ---------------------------------------------------------------- linker

/// Links the tone's left channel into the capture stream as soon as both
/// ports exist (a session manager would normally do this).
struct Linker {
    done: Arc<AtomicBool>,
    thread: Option<JoinHandle<bool>>,
}

impl Linker {
    fn start(pw: &PrivatePipeWire) -> Self {
        let done = Arc::new(AtomicBool::new(false));
        let done2 = done.clone();
        let mut cmd = pw.command("pw-link");
        cmd.arg("lf-test-tone:output_FL")
            .arg("localflow-capture:input_MONO");
        let thread = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(10);
            let stop = || done2.load(Ordering::Relaxed) || Instant::now() >= deadline;
            while !stop() {
                // Every pw-link run is bounded: killed and reaped if it does
                // not finish within a second or the linker is cancelled.
                let Ok(mut child) = cmd.spawn() else {
                    return false;
                };
                let run_deadline = Instant::now() + Duration::from_secs(1);
                let status = loop {
                    match child.try_wait() {
                        Ok(Some(s)) => break Some(s),
                        Ok(None) if !stop() && Instant::now() < run_deadline => {
                            std::thread::sleep(Duration::from_millis(1));
                        }
                        _ => {
                            let _ = child.kill();
                            let _ = child.wait();
                            break None;
                        }
                    }
                };
                if status.is_some_and(|s| s.success()) {
                    return true;
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            false
        });
        Self {
            done,
            thread: Some(thread),
        }
    }

    fn finish(mut self) -> bool {
        self.done.store(true, Ordering::Relaxed);
        self.thread.take().unwrap().join().unwrap()
    }
}

impl Drop for Linker {
    fn drop(&mut self) {
        self.done.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

// ---------------------------------------------------------------- checks

fn rms(x: &[f32]) -> f64 {
    (x.iter().map(|&v| f64::from(v) * f64::from(v)).sum::<f64>() / x.len().max(1) as f64).sqrt()
}

/// Power of `freq` in `x` (16 kHz) relative to total power, via Goertzel.
fn tone_fraction(x: &[f32], freq: f64) -> f64 {
    let w = 2.0 * std::f64::consts::PI * freq / f64::from(SAMPLE_RATE);
    let coeff = 2.0 * w.cos();
    let (mut s1, mut s2) = (0.0f64, 0.0f64);
    for &v in x {
        let s0 = f64::from(v) + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    let power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
    // A pure sine of amplitude A over N samples gives power ~ (A N / 2)^2;
    // total energy is A^2 N / 2.
    let energy: f64 = x.iter().map(|&v| f64::from(v) * f64::from(v)).sum();
    2.0 * power / (x.len() as f64 * energy.max(1e-30))
}

fn check_tone(name: &str, rec: &Recording, recorded_for: Duration) {
    let n = rec.samples.len();
    assert_eq!(rec.negotiated, Some((SAMPLE_RATE, 1)), "{name}: format");
    assert!(!rec.truncated, "{name}: unexpected truncation");
    let latency = rec.start_latency.expect("first buffer time");
    let expected = (recorded_for.saturating_sub(latency)).as_secs_f64() * f64::from(SAMPLE_RATE);
    assert!(
        (n as f64) > expected * 0.85 && (n as f64) < expected * 1.15 + 2048.0,
        "{name}: {n} samples, expected about {expected:.0}"
    );
    // Skip the converter's start-up transient.
    let body = &rec.samples[n.min(1600)..];
    let r = rms(body);
    let want = TONE_AMP / 2f64.sqrt();
    assert!(
        (r - want).abs() < want * 0.05,
        "{name}: RMS {r:.4}, want {want:.4}"
    );
    let frac = tone_fraction(body, TONE_HZ);
    assert!(
        frac > 0.95,
        "{name}: only {frac:.3} of the power at {TONE_HZ} Hz"
    );
    assert!(rec.samples.iter().all(|v| (-1.0..=1.0).contains(v)));
    println!(
        "ok   {name}: {n} samples ({:.3} s), RMS {r:.4}, {:.1}% at 440 Hz, first buffer after {:.1} ms",
        n as f64 / f64::from(SAMPLE_RATE),
        frac * 100.0,
        latency.as_secs_f64() * 1e3
    );
}

/// Starts a capture while the linker connects the tone; returns the time
/// `start` took.
fn linked_start(pw: &PrivatePipeWire, cap: &mut PipeWireCapture) -> Duration {
    let linker = Linker::start(pw);
    let t0 = Instant::now();
    let r = cap.start();
    let took = t0.elapsed();
    let linked = linker.finish();
    r.expect("start");
    assert!(linked, "pw-link never succeeded");
    took
}

/// Polls `get` until it returns `want`.
fn wait_presence(what: &str, want: Option<bool>, get: impl Fn() -> Option<bool>) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while get() != want {
        assert!(
            Instant::now() < deadline,
            "{what}: presence {:?}, want {want:?}",
            get()
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn counter() -> (Arc<AtomicUsize>, Box<dyn Fn() + Send + Sync>) {
    let count = Arc::new(AtomicUsize::new(0));
    let c = count.clone();
    (
        count,
        Box::new(move || {
            c.fetch_add(1, Ordering::AcqRel);
        }),
    )
}

/// Polls until `count` reaches `want`; fails if it passes it.
fn wait_count(what: &str, count: &AtomicUsize, want: usize) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let n = count.load(Ordering::Acquire);
        assert!(n <= want, "{what}: {n} calls, want {want}");
        if n == want {
            return;
        }
        assert!(Instant::now() < deadline, "{what}: {n} calls, want {want}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// Microphone presence through the registry monitor.
fn presence(daemon: &PrivatePipeWire, config: &CaptureConfig) {
    let remote = || Some(daemon.remote());
    let (changes, notify) = counter();
    let any = PresenceMonitor::spawn(remote(), None, notify).unwrap();
    wait_presence("no source yet", Some(false), || any.get());

    // LocalFlow's own capture stream is not a source.
    let mut cap = PipeWireCapture::new(config.clone());
    linked_start(daemon, &mut cap);
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(any.get(), Some(false), "the capture stream counted");
    cap.cancel();

    let source = NullSource::start(daemon.remote(), "lf-test-source");
    wait_presence("source added", Some(true), || any.get());
    let named =
        PresenceMonitor::spawn(remote(), Some("lf-test-source".into()), counter().1).unwrap();
    let other =
        PresenceMonitor::spawn(remote(), Some("lf-test-missing".into()), counter().1).unwrap();
    wait_presence("target present", Some(true), || named.get());
    wait_presence("other target", Some(false), || other.get());

    // Through the AudioCapture trait, as the daemon uses it.
    let mut cap = PipeWireCapture::new(config.clone());
    assert_eq!(cap.input_available(), None);
    let (trait_changes, notify) = counter();
    cap.watch_input(notify);
    wait_presence("trait", Some(true), || cap.input_available());

    drop(source);
    wait_presence("source removed", Some(false), || any.get());
    wait_presence("target removed", Some(false), || named.get());
    wait_presence("trait removed", Some(false), || cap.input_available());
    // unknown -> absent -> present -> absent. The monitor publishes the
    // value before it calls `notify`, so wait for the calls themselves, then
    // check no extra ones follow.
    wait_count("monitor notifications", &changes, 3);
    wait_count("trait notifications", &trait_changes, 2);
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(changes.load(Ordering::Acquire), 3);
    assert_eq!(trait_changes.load(Ordering::Acquire), 2);
    drop(cap);

    // An unreachable server is unknown, not absent.
    let missing = daemon
        .dir
        .join("no-such-socket")
        .to_str()
        .unwrap()
        .to_owned();
    guard(daemon, &missing);
    let (missing_changes, notify) = counter();
    let m = PresenceMonitor::spawn(Some(missing), None, notify).unwrap();
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(m.get(), None);
    assert_eq!(missing_changes.load(Ordering::Relaxed), 0);
    let t = Instant::now();
    drop(m);
    drop(any);
    assert!(t.elapsed() < Duration::from_secs(1), "{:?}", t.elapsed());
    println!("ok   microphone presence");
}

fn main() {
    if std::env::var_os("LF_SKIP_PIPEWIRE_TESTS").is_some() {
        println!("skipped: LF_SKIP_PIPEWIRE_TESTS is set");
        return;
    }
    for tool in ["pipewire", "pw-link"] {
        if Command::new(tool).arg("--version").output().is_err() {
            panic!(
                "{tool} not found on PATH; run inside `nix develop ./linux` or set LF_SKIP_PIPEWIRE_TESTS=1"
            );
        }
    }

    let daemon = PrivatePipeWire::start();
    // SAFETY: still single-threaded.
    unsafe {
        // Drop every inherited PipeWire/SPA selector (PIPEWIRE_REMOTE,
        // PIPEWIRE_CONFIG_NAME, PIPEWIRE_CONFIG_PREFIX, PIPEWIRE_PROPS, ...);
        // the ones needed are set below to private values.
        let inherited: Vec<_> = std::env::vars_os()
            .map(|(k, _)| k)
            .filter(|k| {
                let k = k.to_string_lossy();
                k.starts_with("PIPEWIRE_") || k.starts_with("SPA_") || k.starts_with("PW_")
            })
            .collect();
        for k in inherited {
            std::env::remove_var(k);
        }
        std::env::set_var("PIPEWIRE_CONFIG_NAME", "client.conf");
        std::env::set_var("PIPEWIRE_STATE_DIR", &daemon.dir);
        std::env::set_var("PIPEWIRE_RUNTIME_DIR", &daemon.dir);
        std::env::set_var("XDG_RUNTIME_DIR", &daemon.dir);
        let nobus = format!("unix:path={}", daemon.dir.join("no-bus").display());
        std::env::set_var("DBUS_SESSION_BUS_ADDRESS", &nobus);
        std::env::set_var("DBUS_SYSTEM_BUS_ADDRESS", &nobus);
        std::env::set_var("PIPEWIRE_CONFIG_DIR", daemon.dir.join("client-conf"));
        std::env::set_var("HOME", &daemon.dir);
        std::env::set_var("XDG_CONFIG_HOME", &daemon.dir);
        std::env::set_var("XDG_STATE_HOME", &daemon.dir);
    }
    guard(&daemon, &daemon.remote());

    let config = CaptureConfig {
        remote: Some(daemon.remote()),
        start_timeout: Duration::from_secs(10),
        extra_properties: vec![("adapter.auto-port-config".into(), PORT_CONFIG.into())],
        ..CaptureConfig::default()
    };

    // Nothing to link to: start must fail cleanly after its timeout.
    {
        let mut cap = PipeWireCapture::new(CaptureConfig {
            start_timeout: Duration::from_millis(500),
            ..config.clone()
        });
        let t0 = Instant::now();
        let err = cap.start().expect_err("unlinked stream must not start");
        assert!(t0.elapsed() < Duration::from_secs(3));
        assert!(!cap.is_recording());
        assert_eq!(cap.level(), 0.0);
        println!(
            "ok   no source linked: start failed after {:.0} ms ({err})",
            t0.elapsed().as_secs_f64() * 1e3
        );
    }

    // An unreachable (absolute, private) remote fails fast.
    {
        let remote = daemon
            .dir
            .join("no-such-socket")
            .to_str()
            .unwrap()
            .to_owned();
        guard(&daemon, &remote);
        let mut cap = PipeWireCapture::new(CaptureConfig {
            remote: Some(remote),
            ..config.clone()
        });
        let t0 = Instant::now();
        let err = cap.start().expect_err("missing socket must fail");
        assert!(
            t0.elapsed() < Duration::from_secs(2),
            "took {:?}",
            t0.elapsed()
        );
        assert!(!cap.is_recording());
        println!("ok   missing remote: {err}");
    }

    let _tone = Tone::start(daemon.remote());

    let mut cap = PipeWireCapture::new(config.clone());
    let mut start_calls = Vec::new();
    let mut first_buffers = Vec::new();
    for cycle in 1..=3 {
        let t0 = Instant::now();
        start_calls.push(linked_start(&daemon, &mut cap));
        assert!(cap.is_recording());
        assert!(cap.start().is_err(), "second start must fail");
        let mut max_level = 0f32;
        while t0.elapsed() < Duration::from_millis(1000) {
            std::thread::sleep(Duration::from_millis(20));
            max_level = max_level.max(cap.level());
        }
        let rec = cap.stop_recording().expect("stop");
        let elapsed = t0.elapsed();
        assert!(
            (0.25..=0.5).contains(&max_level),
            "level {max_level} for a 0.354 RMS tone"
        );
        assert_eq!(cap.level(), 0.0, "level resets when idle");
        check_tone(&format!("cycle {cycle}"), &rec, elapsed);
        first_buffers.push(rec.start_latency.unwrap());
    }
    assert!(cap.stop().is_err(), "stop when idle must fail");

    // Cancel discards and is idempotent.
    linked_start(&daemon, &mut cap);
    std::thread::sleep(Duration::from_millis(200));
    cap.cancel();
    assert!(!cap.is_recording());
    assert_eq!(cap.level(), 0.0);
    cap.cancel();
    assert!(cap.stop().is_err());
    println!("ok   cancel");

    // Plain AudioCapture::stop after a short recording.
    linked_start(&daemon, &mut cap);
    std::thread::sleep(Duration::from_millis(300));
    let samples = cap.stop().expect("stop");
    assert!(samples.len() > 1000);
    println!("ok   AudioCapture::stop: {} samples", samples.len());

    // Truncation at max_duration.
    let mut short = PipeWireCapture::new(CaptureConfig {
        max_duration: Duration::from_millis(250),
        ..config.clone()
    });
    linked_start(&daemon, &mut short);
    std::thread::sleep(Duration::from_millis(700));
    let rec = short.stop_recording().expect("truncating stop");
    assert!(rec.truncated);
    assert_eq!(rec.samples.len(), 4000);
    println!(
        "ok   truncate at 0.25 s: {} samples, truncated",
        rec.samples.len()
    );

    // Overflow as an error.
    let mut strict = PipeWireCapture::new(CaptureConfig {
        max_duration: Duration::from_millis(250),
        overflow: Overflow::Error,
        ..config.clone()
    });
    linked_start(&daemon, &mut strict);
    std::thread::sleep(Duration::from_millis(700));
    let err = strict.stop_recording().expect_err("overflow must fail");
    println!("ok   overflow error: {err}");
    // Still usable afterwards.
    linked_start(&daemon, &mut strict);
    std::thread::sleep(Duration::from_millis(100));
    assert!(strict.stop_recording().is_ok());

    // Dropping while recording cleans up.
    linked_start(&daemon, &mut cap);
    drop(cap);
    println!("ok   drop while recording");

    presence(&daemon, &config);

    let ms = |d: &Duration| format!("{:.1}", d.as_secs_f64() * 1e3);
    println!(
        "start() call: {} ms; first buffer: {} ms (private graph, linking by polling pw-link)",
        start_calls.iter().map(ms).collect::<Vec<_>>().join(", "),
        first_buffers.iter().map(ms).collect::<Vec<_>>().join(", ")
    );
    drop(_tone);
    drop(daemon);
    println!("private PipeWire capture test: all cases passed");
}

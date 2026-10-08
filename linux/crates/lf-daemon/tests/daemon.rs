//! The daemon end to end over its socket, with fake capture, recognizer and
//! output. All text is synthetic.

mod common;

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use common::{Rig, ctl, factory, private_dir, runtime_dir, settings};
use lf_daemon::controller::Limits;
use lf_daemon::daemon::{self, Parts};
use lf_daemon::history::History;
use lf_daemon::testing::{FakeCapture, FakeOutput, FakeRecognizer, TempDir, Typed};
use lf_daemon::worker::Settings;
use lf_dictation::VoiceMacro;
use lf_io_api::PlaybackStatus::{Paused, Playing};
use lf_media::fake::{Call as MediaCall, FakePlayers};

const SECOND: usize = 16_000;

fn speech() -> FakeCapture {
    FakeCapture::with_samples(vec![0.1; SECOND])
}

#[test]
fn hold_dictation_types_text_presses_enter_and_records_history() {
    let rec = FakeRecognizer::returning("Synthetic words, quote hi end quote, press enter.");
    let rig = Rig::start("hold", speech(), factory(rec.clone()), settings(), true);
    rig.wait_for("model=ready");
    assert_eq!(rig.cmd("press"), "state=recording mode=hold model=ready");
    assert_eq!(rig.cmd("release"), "state=transcribing model=ready");
    rig.wait_for("state=idle");
    assert_eq!(rig.output.text(), "Synthetic words, \"hi\"\n");
    assert_eq!(rig.output.state().typed.last(), Some(&Typed::Enter));
    assert_eq!(rec.state().lengths, [SECOND]);

    let history = History::open(&common::data_dir(&rig.dir)).unwrap();
    let entries: Vec<_> = history.entries().collect();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].text, "Synthetic words, \"hi\"");
    assert_eq!(entries[0].raw, "Synthetic words, quote hi end quote");

    // Paste Again types the text again, without Return or a history entry.
    assert_eq!(rig.cmd("again"), "state=typing model=ready");
    rig.wait_for("state=idle");
    assert_eq!(
        rig.output.text(),
        "Synthetic words, \"hi\"\nSynthetic words, \"hi\""
    );
    let history = History::open(&common::data_dir(&rig.dir)).unwrap();
    assert_eq!(history.entries().count(), 1);
}

#[test]
fn voice_macros_and_disabled_history() {
    let rec = FakeRecognizer::returning("Sign off.");
    let s = Settings {
        options: lf_dictation::Options::default(),
        macros: vec![VoiceMacro {
            command: "sign off".into(),
            payload: "Synthetic regards.".into(),
        }],
        type_chunk_chars: lf_daemon::worker::TYPE_CHUNK_CHARS,
        prompt_tag: "[dictated]".into(),
    };
    let rig = Rig::start("macro", speech(), factory(rec), s, false);
    rig.cmd("toggle");
    rig.cmd("toggle");
    rig.wait_for("state=idle");
    assert_eq!(rig.output.text(), "Synthetic regards.");
    assert!(!common::data_dir(&rig.dir).exists());
}

#[test]
fn cancel_during_transcription_types_nothing() {
    let rec = FakeRecognizer::returning("Synthetic never typed.");
    rec.state().delay = Duration::from_millis(300);
    let rig = Rig::start(
        "cancel-tr",
        speech(),
        factory(rec.clone()),
        settings(),
        true,
    );
    rig.wait_for("model=ready");
    rig.cmd("toggle");
    assert_eq!(rig.cmd("toggle"), "state=transcribing model=ready");
    // The control loop stays responsive while the worker is busy.
    let t = Instant::now();
    assert_eq!(
        rig.cmd("press"),
        "state=transcribing model=ready note=ignored"
    );
    assert!(t.elapsed() < Duration::from_millis(200));
    assert_eq!(rig.cmd("cancel"), "state=idle model=ready note=cancelled");
    std::thread::sleep(Duration::from_millis(500));
    assert_eq!(rec.state().calls, 1);
    assert_eq!(rig.output.text(), "");
    assert_eq!(
        History::open(&common::data_dir(&rig.dir))
            .unwrap()
            .entries()
            .count(),
        0
    );
}

#[test]
fn cancel_during_typing_stops_part_way() {
    let long = "Synthetic ".repeat(40);
    let rec = FakeRecognizer::returning(&format!("{long}press enter"));
    let rig = Rig::start("cancel-typing", speech(), factory(rec), settings(), true);
    rig.output.state().delay = Duration::from_millis(30);
    rig.wait_for("model=ready");
    rig.cmd("press");
    rig.cmd("release");
    rig.wait_for("state=typing");
    while rig.output.text().is_empty() {
        std::thread::sleep(Duration::from_millis(1));
    }
    assert_eq!(rig.cmd("cancel"), "state=idle model=ready note=cancelled");
    std::thread::sleep(Duration::from_millis(200));
    let typed = rig.output.text();
    assert!(
        !typed.is_empty() && typed.len() < long.trim().len(),
        "{}",
        typed.len()
    );
    assert!(long.starts_with(&typed));
    assert!(!rig.output.state().typed.contains(&Typed::Enter));
}

#[test]
fn nothing_is_typed_after_the_cancel_reply() {
    // Regression: Return could be pressed after cancel had replied.
    let rec = FakeRecognizer::returning("Synthetic short, press enter");
    let rig = Rig::start("cancel-enter", speech(), factory(rec), settings(), true);
    rig.output.state().delay = Duration::from_millis(150);
    rig.cmd("press");
    rig.cmd("release");
    rig.wait_for("state=typing");
    // The only text piece is being typed; cancel waits for it, then Return
    // must not follow.
    assert_eq!(rig.cmd("cancel"), "state=idle model=ready note=cancelled");
    let typed_at_reply = rig.output.state().typed.clone();
    std::thread::sleep(Duration::from_millis(400));
    assert_eq!(rig.output.state().typed, typed_at_reply);
    assert!(!typed_at_reply.contains(&Typed::Enter));
}

#[test]
fn short_recordings_capture_errors_and_failures() {
    let cap = FakeCapture::with_samples(vec![0.1; SECOND / 10]);
    let rec = FakeRecognizer::default(); // fails
    let rig = Rig::start(
        "errors",
        cap.clone(),
        factory(rec.clone()),
        settings(),
        true,
    );
    rig.cmd("press");
    assert_eq!(rig.cmd("release"), "state=idle model=ready note=too-short");
    assert_eq!(rec.state().calls, 0);

    cap.state().fail_start = true;
    assert_eq!(
        rig.raw(b"localflow/1 press\n"),
        "localflow/1 error capture\n"
    );
    let out = rig.ctl(&["toggle"]);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(
        String::from_utf8_lossy(&out.stderr),
        "localflowctl: daemon error: capture\n"
    );
    cap.state().fail_start = false;

    // Recognition failure returns to idle and types nothing.
    cap.state().samples = vec![0.1; SECOND];
    rig.cmd("press");
    rig.cmd("release");
    rig.wait_for("state=idle");
    assert_eq!(rec.state().calls, 1);
    assert_eq!(rig.output.text(), "");

    // Output failure too.
    rec.state().text = Some("Synthetic.".into());
    rig.output.state().fail = true;
    rig.cmd("press");
    rig.cmd("release");
    rig.wait_for("state=idle");
    assert_eq!(rig.output.text(), "");
    rig.output.state().fail = false;
    rig.cmd("press");
    rig.cmd("release");
    rig.wait_for("state=idle");
    assert_eq!(rig.output.text(), "Synthetic.");
}

#[test]
fn records_while_the_model_loads() {
    let dir = TempDir::new("loading");
    private_dir(&runtime_dir(&dir));
    let (go_tx, go_rx) = std::sync::mpsc::channel::<()>();
    let rec = FakeRecognizer::returning("Synthetic late.");
    let rec2 = rec.clone();
    let output = FakeOutput::default();
    let handle = daemon::start(
        Parts {
            capture: Box::new(speech()),
            output: Box::new(output.clone()),
            recognizer: Box::new(move || {
                go_rx.recv().unwrap();
                Ok(Box::new(rec2) as _)
            }),
            settings: settings(),
            limits: Limits {
                min_recording: Duration::ZERO,
                max_recording: Duration::from_secs(60),
                double_tap: Duration::ZERO,
            },
            history: lf_daemon::history::Setting {
                dir: dir.path().join("data"),
                enabled: false,
            },
            media: None,
        },
        &runtime_dir(&dir),
    )
    .unwrap();
    let rd = runtime_dir(&dir);
    let mut watcher = {
        let mut s = UnixStream::connect(handle.socket_path()).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        s.write_all(b"localflow/1 watch\n").unwrap();
        common::Watcher(BufReader::new(s))
    };
    assert_eq!(
        watcher.line(),
        "localflow/1 ok state=idle model=loading mic=unknown"
    );
    let status = |cmd: &str| String::from_utf8(ctl(&rd, &[cmd]).stdout).unwrap();
    assert_eq!(status("status"), "state=idle model=loading\n");
    assert_eq!(status("press"), "state=recording mode=hold model=loading\n");
    assert_eq!(status("release"), "state=transcribing model=loading\n");
    go_tx.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while status("status") != "state=idle model=ready\n" {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(output.text(), "Synthetic late.");
    // The watcher saw the model become ready while the dictation waited.
    let lines = watcher.until("state=idle model=ready");
    assert!(
        lines
            .iter()
            .any(|l| l == "localflow/1 ok state=transcribing model=loading mic=unknown")
    );
    assert!(
        lines
            .iter()
            .any(|l| l == "localflow/1 ok state=transcribing model=ready mic=unknown")
    );
    handle.shutdown();
    handle.join().unwrap();
}

#[test]
fn model_failure_stops_the_daemon() {
    let dir = TempDir::new("model-fail");
    private_dir(&runtime_dir(&dir));
    let handle = daemon::start(
        Parts {
            capture: Box::new(speech()),
            output: Box::new(FakeOutput::default()),
            recognizer: Box::new(|| Err("synthetic load failure".into())),
            settings: settings(),
            limits: Limits {
                min_recording: Duration::ZERO,
                max_recording: Duration::from_secs(60),
                double_tap: Duration::ZERO,
            },
            history: lf_daemon::history::Setting {
                dir: dir.path().join("data"),
                enabled: false,
            },
            media: None,
        },
        &runtime_dir(&dir),
    )
    .unwrap();
    let socket = handle.socket_path().to_owned();
    let err = handle.join().unwrap_err();
    assert!(err.contains("synthetic load failure"), "{err}");
    assert!(!socket.exists());
}

#[test]
fn socket_permissions_and_single_instance() {
    let mut rig = Rig::start(
        "perms",
        speech(),
        factory(FakeRecognizer::default()),
        settings(),
        false,
    );
    let socket = rig.socket();
    let meta = std::fs::symlink_metadata(&socket).unwrap();
    assert_eq!(meta.mode() & 0o777, 0o600);
    let dir_meta = std::fs::metadata(socket.parent().unwrap()).unwrap();
    assert_eq!(dir_meta.mode() & 0o777, 0o700);

    let second = lf_daemon::server::Server::bind(&runtime_dir(&rig.dir));
    assert!(second.err().unwrap().contains("already running"));

    rig.stop().unwrap();
    assert!(!socket.exists());
    // After a clean stop the lock is free again; a stale socket file is replaced.
    std::os::unix::net::UnixListener::bind(&socket).unwrap();
    let server = bind_after_stop(&runtime_dir(&rig.dir)).unwrap();
    drop(server);
    // Something other than a socket at the path is refused.
    std::fs::remove_file(&socket).ok();
    std::fs::write(&socket, b"").unwrap();
    let err = bind_after_stop(&runtime_dir(&rig.dir)).err().unwrap();
    assert!(err.contains("not a socket"), "{err}");
}

#[test]
fn insecure_runtime_directories_are_refused() {
    let dir = TempDir::new("insecure");
    let rd = runtime_dir(&dir);
    private_dir(&rd);
    std::fs::set_permissions(&rd, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(lf_daemon::server::Server::bind(&rd).is_err());
    std::fs::set_permissions(&rd, std::fs::Permissions::from_mode(0o700)).unwrap();

    let app = rd.join("localflow");
    private_dir(&app);
    std::fs::set_permissions(&app, std::fs::Permissions::from_mode(0o711)).unwrap();
    let err = lf_daemon::server::Server::bind(&rd).err().unwrap();
    assert!(err.contains("accessible to other users"), "{err}");

    assert!(lf_daemon::server::Server::bind(&dir.path().join("missing")).is_err());
}

#[test]
fn malformed_requests_are_rejected() {
    let rig = Rig::start(
        "proto",
        speech(),
        factory(FakeRecognizer::default()),
        settings(),
        false,
    );
    let cases: &[(&[u8], &str)] = &[
        (b"localflow/1 explode\n", "unknown-command"),
        (b"localflow/2 status\n", "version"),
        (b"status\n", "malformed"),
        (b"localflow/1 status\r\n", "malformed"),
        (b"localflow/1 status\nlocalflow/1 press\n", "malformed"),
        (b"localflow/1 st\xffatus\n", "malformed"),
        (b"localflow/1 status", "malformed"), // closed without newline (see below)
    ];
    for (req, code) in cases {
        let mut s = UnixStream::connect(rig.socket()).unwrap();
        s.write_all(req).unwrap();
        s.shutdown(std::net::Shutdown::Write).unwrap();
        let mut reply = String::new();
        s.read_to_string(&mut reply).unwrap();
        assert_eq!(reply, format!("localflow/1 error {code}\n"), "{req:?}");
    }
    let long = vec![b'a'; 300];
    assert_eq!(rig.raw(&long), "localflow/1 error too-long\n");

    // A client that sends nothing is cut off after the request deadline.
    let mut s = UnixStream::connect(rig.socket()).unwrap();
    let t = Instant::now();
    let mut reply = String::new();
    s.read_to_string(&mut reply).unwrap();
    assert_eq!(reply, "localflow/1 error timeout\n");
    assert!(t.elapsed() >= Duration::from_millis(200));
    // The daemon still works and the state is untouched.
    assert_eq!(rig.cmd("status"), "state=idle model=ready");
}

#[test]
fn localflowd_writes_its_fatal_error_before_exiting() {
    // Logging goes through a background thread; the exit path flushes it.
    let dir = TempDir::new("fatal-log");
    let config = dir.path().join("config.json");
    std::fs::write(&config, b"{ not json").unwrap();
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_localflowd"))
        .arg("--config")
        .arg(&config)
        .env("XDG_DATA_HOME", dir.path().join("data"))
        .env("XDG_CONFIG_HOME", dir.path().join("config"))
        .env("XDG_RUNTIME_DIR", runtime_dir(&dir))
        .env_remove("JOURNAL_STREAM")
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.starts_with("localflowd error: config ") && err.ends_with('\n'),
        "{err:?}"
    );
}

#[test]
fn localflowctl_exit_codes() {
    let dir = TempDir::new("ctl");
    let rd = runtime_dir(&dir);
    private_dir(&rd);
    // Not running.
    let out = ctl(&rd, &["status"]);
    assert_eq!(out.status.code(), Some(3));
    // Usage.
    assert_eq!(ctl(&rd, &[]).status.code(), Some(2));
    assert_eq!(ctl(&rd, &["explode"]).status.code(), Some(2));
    assert_eq!(ctl(&rd, &["status", "press"]).status.code(), Some(2));
    assert_eq!(
        ctl(&rd, &["--timeout-ms", "0", "status"]).status.code(),
        Some(2)
    );
    // No runtime directory.
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_localflowctl"))
        .arg("status")
        .env_remove("XDG_RUNTIME_DIR")
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(3));

    // A server that never answers: timeout.
    let app = rd.join("localflow");
    private_dir(&app);
    let listener = std::os::unix::net::UnixListener::bind(app.join("ctl.sock")).unwrap();
    let t = Instant::now();
    let out = ctl(&rd, &["--timeout-ms", "300", "status"]);
    assert_eq!(out.status.code(), Some(4));
    assert!(t.elapsed() < Duration::from_secs(3));
    // A server that answers garbage: protocol error.
    let server = std::thread::spawn(move || {
        drop(listener.accept().unwrap()); // the timed-out client
        let (mut s, _) = listener.accept().unwrap();
        let mut buf = [0u8; 64];
        let _ = s.read(&mut buf);
        s.write_all(b"HTTP/1.1 200 OK\n").unwrap();
    });
    let out = ctl(&rd, &["status"]);
    assert_eq!(out.status.code(), Some(5));
    server.join().unwrap();
}

#[test]
fn localflowctl_stamps_requests_so_an_overtaken_press_is_ignored() {
    let rig = Rig::start(
        "stamps",
        speech(),
        factory(FakeRecognizer::default()),
        settings(),
        false,
    );
    // The release of a tap, sent by the real client (stamped now)...
    let out = rig.ctl(&["release"]);
    assert_eq!(
        String::from_utf8_lossy(&out.stdout),
        "state=idle model=ready note=ignored\n"
    );
    // ...then its press, started earlier but delivered later.
    assert_eq!(
        rig.raw(b"localflow/1 press at=1\n"),
        "localflow/1 ok state=idle model=ready note=ignored\n"
    );
    assert_eq!(rig.capture.state().starts, 0);
    // A press started now is a new hold.
    let out = rig.ctl(&["press"]);
    assert_eq!(
        String::from_utf8_lossy(&out.stdout),
        "state=recording mode=hold model=ready\n"
    );
}

#[test]
fn stop_waits_for_the_worker_before_releasing_the_lock() {
    let rec = FakeRecognizer::returning("Synthetic.");
    rec.state().delay = Duration::from_millis(300);
    let mut rig = Rig::start(
        "stop-worker",
        speech(),
        factory(rec.clone()),
        settings(),
        false,
    );
    rig.cmd("press");
    rig.cmd("release");
    // Let the worker pick the job up.
    std::thread::sleep(Duration::from_millis(50));
    rig.stop().unwrap();
    // The job finished (cancelled) before stop returned; nothing was typed.
    assert_eq!(rec.state().calls, 1);
    assert_eq!(rig.output.text(), "");
    let server = bind_after_stop(&runtime_dir(&rig.dir));
    assert!(server.is_ok());
}

#[test]
fn shutdown_while_recording_discards_audio() {
    let cap = speech();
    let rec = FakeRecognizer::returning("Synthetic.");
    let mut rig = Rig::start(
        "shutdown",
        cap.clone(),
        factory(rec.clone()),
        settings(),
        false,
    );
    rig.cmd("press");
    assert!(cap.state().recording);
    rig.stop().unwrap();
    assert!(!cap.state().recording);
    assert_eq!(cap.state().cancels, 1);
    assert_eq!(rec.state().calls, 0);
}

const PLAYER: &str = "org.mpris.MediaPlayer2.synthetic";
const OTHER: &str = "org.mpris.MediaPlayer2.synthetic_other";

fn media_rig(tag: &str, players: &FakePlayers, rec: FakeRecognizer) -> Rig {
    Rig::start_with_media(
        tag,
        speech(),
        factory(rec),
        settings(),
        false,
        Some(Box::new(players.clone())),
    )
}

fn wait_until(what: &str, f: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !f() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(2));
    }
}

#[test]
fn media_pauses_while_recording_and_resumes_after() {
    let players = FakePlayers::default();
    players.add(PLAYER, Playing);
    players.add(OTHER, Paused);
    let rig = media_rig("media", &players, FakeRecognizer::returning("Synthetic."));
    assert_eq!(rig.cmd("press"), "state=recording mode=hold model=ready");
    wait_until("pause", || players.status_of(PLAYER) == Some(Paused));
    assert_eq!(rig.cmd("release"), "state=transcribing model=ready");
    wait_until("resume", || players.status_of(PLAYER) == Some(Playing));
    rig.wait_for("state=idle");
    assert_eq!(rig.output.text(), "Synthetic.");
    // The player the user had paused was never touched.
    assert_eq!(players.calls(MediaCall::Pause, OTHER), 0);
    assert_eq!(players.calls(MediaCall::Play, OTHER), 0);

    // Cancel resumes too.
    rig.cmd("toggle");
    wait_until("pause", || players.status_of(PLAYER) == Some(Paused));
    assert_eq!(rig.cmd("cancel"), "state=idle model=ready note=cancelled");
    wait_until("resume", || players.status_of(PLAYER) == Some(Playing));
    assert_eq!(players.calls(MediaCall::Play, PLAYER), 2);
}

#[test]
fn shutdown_while_recording_resumes_media_before_returning() {
    let players = FakePlayers::default();
    players.add(PLAYER, Playing);
    let mut rig = media_rig(
        "media-stop",
        &players,
        FakeRecognizer::returning("Synthetic."),
    );
    rig.cmd("toggle");
    wait_until("pause", || players.status_of(PLAYER) == Some(Paused));
    rig.stop().unwrap();
    assert_eq!(players.status_of(PLAYER), Some(Playing));
}

#[test]
fn slow_or_missing_media_players_do_not_delay_recording() {
    // Every D-Bus call takes 1.5 s.
    let players = FakePlayers::default();
    players.add(PLAYER, Playing);
    players.state().delay = Duration::from_millis(1500);
    let rig = media_rig(
        "media-slow",
        &players,
        FakeRecognizer::returning("Synthetic."),
    );
    let t = Instant::now();
    assert_eq!(rig.cmd("toggle"), "state=recording mode=toggle model=ready");
    assert!(
        t.elapsed() < Duration::from_millis(1000),
        "{:?}",
        t.elapsed()
    );
    assert_eq!(rig.cmd("toggle"), "state=transcribing model=ready");
    rig.wait_for("state=idle");
    assert_eq!(rig.output.text(), "Synthetic.");

    // No session bus: dictation works.
    let players = FakePlayers::default();
    players.state().fail_list = Some(lf_io_api::MediaError::Unavailable);
    let rig = media_rig(
        "media-none",
        &players,
        FakeRecognizer::returning("Synthetic."),
    );
    rig.cmd("toggle");
    rig.cmd("toggle");
    rig.wait_for("state=idle");
    assert_eq!(rig.output.text(), "Synthetic.");
}

/// `Server::bind` right after a daemon stopped. Other tests fork
/// `localflowctl` processes concurrently, and a child holds a copy of the
/// lock descriptor between fork and exec, so the lock can stay held for a
/// moment after the server drops it.
fn bind_after_stop(dir: &std::path::Path) -> Result<lf_daemon::server::Server, String> {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        match lf_daemon::server::Server::bind(dir) {
            Err(e) if e.contains("already running") && Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(5));
            }
            other => return other,
        }
    }
}

// ---------------------------------------------------------------- watch

#[test]
fn a_watcher_follows_a_dictation() {
    let cap = speech();
    let rec = FakeRecognizer::returning("Synthetic watched words.");
    let rig = Rig::start("watch", cap.clone(), factory(rec), settings(), false);
    let mut w = rig.watch();
    assert_eq!(
        w.line(),
        "localflow/1 ok state=idle model=ready mic=unknown"
    );

    cap.state().level = 0.42;
    // Started before the press, so no level line can predate it.
    let t = Instant::now();
    assert_eq!(rig.cmd("press"), "state=recording mode=hold model=ready");
    let recording = "localflow/1 ok state=recording mode=hold model=ready mic=unknown level=42";
    assert_eq!(w.line(), recording);
    // Level lines keep coming while recording, even with the level unchanged,
    // but no faster than the interval: the third repeat is due at the
    // earliest three intervals after the press. (No upper bound: a slow
    // machine only makes this slower; the reads time out after 10 s.)
    for _ in 0..3 {
        assert_eq!(w.line(), recording);
    }
    assert!(
        t.elapsed() >= 3 * lf_daemon::watch::LEVEL_INTERVAL,
        "{:?}",
        t.elapsed()
    );

    assert_eq!(rig.cmd("release"), "state=transcribing model=ready");
    let lines = w.until("state=idle");
    let after: Vec<_> = common::states(&lines)
        .into_iter()
        .filter(|s| s != "recording")
        .collect();
    assert_eq!(after, ["transcribing", "typing", "idle"]);
    assert_eq!(
        lines.last().unwrap(),
        "localflow/1 ok state=idle model=ready mic=unknown"
    );
    // Watch lines carry no text; command replies are unchanged.
    assert!(lines.iter().all(|l| !l.contains("Synthetic")));
    assert_eq!(rig.output.text(), "Synthetic watched words.");
    assert_eq!(rig.cmd("status"), "state=idle model=ready");
}

#[test]
fn a_watcher_sees_the_microphone_come_and_go() {
    let cap = speech();
    cap.state().input = Some(false);
    let rig = Rig::start(
        "watch-mic",
        cap.clone(),
        factory(FakeRecognizer::default()),
        settings(),
        false,
    );
    let mut w = rig.watch();
    assert_eq!(w.line(), "localflow/1 ok state=idle model=ready mic=absent");
    cap.set_input(Some(true));
    assert_eq!(
        w.line(),
        "localflow/1 ok state=idle model=ready mic=present"
    );
    cap.set_input(None);
    assert_eq!(
        w.line(),
        "localflow/1 ok state=idle model=ready mic=unknown"
    );
    cap.set_input(Some(false));
    assert_eq!(w.line(), "localflow/1 ok state=idle model=ready mic=absent");
}

/// True once the daemon has closed its end of `s` (unread data aside).
fn hung_up(s: &UnixStream) -> bool {
    use std::os::fd::AsRawFd;
    let mut p = libc::pollfd {
        fd: s.as_raw_fd(),
        events: 0,
        revents: 0,
    };
    // SAFETY: polls one valid pollfd without waiting.
    unsafe { libc::poll(&mut p, 1, 0) };
    p.revents & libc::POLLHUP != 0
}

#[test]
fn a_watcher_that_never_reads_is_dropped_and_keys_stay_fast() {
    // Recordings too short to transcribe: every press/release pair goes
    // recording -> idle.
    let cap = FakeCapture::with_samples(vec![0.1; SECOND / 10]);
    let rig = Rig::start(
        "watch-stuck",
        cap,
        factory(FakeRecognizer::default()),
        settings(),
        false,
    );
    // Subscribes, then never reads.
    let mut stuck = UnixStream::connect(rig.socket()).unwrap();
    stuck.write_all(b"localflow/1 watch\n").unwrap();
    // A watcher that keeps up, reading on its own thread. Production waits
    // for it after every cycle (below), so it is never more than one cycle
    // behind and cannot be dropped however the threads are scheduled.
    let mut good = rig.watch();
    let received = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counter = std::sync::Arc::clone(&received);
    let reader = std::thread::spawn(move || {
        let mut buf = String::new();
        while good.0.read_line(&mut buf).is_ok_and(|n| n > 0) {
            counter.fetch_add(1, std::sync::atomic::Ordering::AcqRel);
            buf.clear();
        }
        counter.load(std::sync::atomic::Ordering::Acquire)
    });
    let wait_received = |want: usize| {
        let deadline = Instant::now() + Duration::from_secs(10);
        while received.load(std::sync::atomic::Ordering::Acquire) < want {
            assert!(Instant::now() < deadline, "the reading watcher fell silent");
            std::thread::sleep(Duration::from_millis(1));
        }
    };
    wait_received(1);

    // Each command must succeed: a send that blocked on the stuck watcher
    // would stall the control loop until that watcher read, i.e. forever,
    // and the command would fail with `error unavailable` after the reply
    // deadline (`rig.cmd` panics on any error). No wall-clock bound is
    // needed.
    let mut cycles = 0;
    while !hung_up(&stuck) {
        cycles += 1;
        assert!(cycles < 5000, "the stuck watcher was never dropped");
        assert_eq!(rig.cmd("press"), "state=recording mode=hold model=ready");
        assert_eq!(rig.cmd("release"), "state=idle model=ready note=too-short");
        // The initial line, then at least recording and idle per cycle
        // (level lines may come in between).
        wait_received(1 + 2 * cycles);
    }
    // The daemon still takes new watchers and serves them.
    let mut late = rig.watch();
    assert_eq!(
        late.line(),
        "localflow/1 ok state=idle model=ready mic=unknown"
    );
    rig.cmd("press");
    assert!(late.line().contains("state=recording"));
    rig.cmd("release");
    drop(rig);
    // The reading watcher stayed subscribed throughout: at least two lines
    // per cycle.
    let got = reader.join().unwrap();
    assert!(got > 2 * cycles, "{got} lines for {cycles} cycles");
    // The stuck watcher received whole lines, then the close.
    let mut rest = String::new();
    stuck
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    stuck.read_to_string(&mut rest).unwrap();
    assert!(rest.starts_with("localflow/1 ok state=idle"));
    assert!(rest.ends_with('\n'));
}

#[test]
fn the_number_of_watchers_is_capped_and_closed_ones_are_removed() {
    let rig = Rig::start(
        "watch-cap",
        speech(),
        factory(FakeRecognizer::default()),
        settings(),
        false,
    );
    let mut watchers: Vec<_> = (0..lf_daemon::watch::MAX_WATCHERS)
        .map(|_| {
            let mut w = rig.watch();
            assert!(w.line().starts_with("localflow/1 ok state=idle"));
            w
        })
        .collect();
    // One too many: told so and closed.
    let mut extra = rig.watch();
    assert_eq!(extra.line(), "localflow/1 error busy");
    let mut rest = String::new();
    extra.0.read_to_string(&mut rest).unwrap();
    assert_eq!(rest, "");
    // Commands are unaffected.
    assert_eq!(rig.cmd("status"), "state=idle model=ready");

    // Closing one makes room for the next arrival, with nothing published
    // in between. (Other tests fork concurrently, and a forked child holds a
    // copy of the closed socket until it execs, so the daemon may briefly
    // still see it open: retry like a real client.)
    drop(watchers.pop());
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut next = loop {
        let mut w = rig.watch();
        let line = w.line();
        if line != "localflow/1 error busy" {
            assert_eq!(line, "localflow/1 ok state=idle model=ready mic=unknown");
            break w;
        }
        assert!(
            Instant::now() < deadline,
            "the closed watcher was never reclaimed"
        );
        std::thread::sleep(Duration::from_millis(10));
    };
    let out = rig.ctl(&["--timeout-ms", "2000", "watch"]);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(
        String::from_utf8_lossy(&out.stderr),
        "localflowctl: daemon error: busy\n"
    );
    // Every remaining watcher still gets updates.
    rig.cmd("toggle");
    for w in watchers.iter_mut().chain([&mut next]) {
        assert!(w.line().contains("state=recording mode=toggle"));
    }
}

#[test]
fn a_flood_of_watch_connections_is_refused_on_the_spot() {
    let rig = Rig::start(
        "watch-flood",
        speech(),
        factory(FakeRecognizer::default()),
        settings(),
        false,
    );
    let mut watchers: Vec<_> = (0..lf_daemon::watch::MAX_WATCHERS)
        .map(|_| {
            let mut w = rig.watch();
            w.line();
            w
        })
        .collect();
    // Many more, all kept open: each is answered `busy` and closed; none is
    // left queued holding a descriptor.
    let mut flood: Vec<_> = (0..200).map(|_| rig.watch()).collect();
    for f in &mut flood {
        assert_eq!(f.line(), "localflow/1 error busy");
        let mut rest = String::new();
        f.0.read_to_string(&mut rest).unwrap();
        assert_eq!(rest, "");
    }
    // Keys and the existing watchers are unaffected.
    assert_eq!(rig.cmd("press"), "state=recording mode=hold model=ready");
    for w in &mut watchers {
        assert!(w.line().contains("state=recording"));
    }
}

#[test]
fn a_watcher_that_stops_reading_while_idle_is_reclaimed() {
    let rig = Rig::start(
        "watch-deaf",
        speech(),
        factory(FakeRecognizer::default()),
        settings(),
        false,
    );
    let mut watchers: Vec<_> = (0..lf_daemon::watch::MAX_WATCHERS)
        .map(|_| {
            let mut w = rig.watch();
            w.line();
            w
        })
        .collect();
    // Shut down reading but keep the socket open (no hang-up for the
    // daemon to see), with nothing published afterwards.
    watchers[0]
        .0
        .get_ref()
        .shutdown(std::net::Shutdown::Read)
        .unwrap();
    // Shut down writing only: still a valid watcher.
    watchers[1]
        .0
        .get_ref()
        .shutdown(std::net::Shutdown::Write)
        .unwrap();
    let mut next = rig.watch();
    assert_eq!(
        next.line(),
        "localflow/1 ok state=idle model=ready mic=unknown"
    );
    // The cap holds again, and the half-closed-for-writing one is served.
    assert_eq!(rig.watch().line(), "localflow/1 error busy");
    rig.cmd("toggle");
    assert!(watchers[1].line().contains("state=recording"));
    assert!(next.line().contains("state=recording"));
}

type Lines = std::sync::mpsc::Receiver<String>;

/// Starts `localflowctl` with its stdout lines delivered on a channel.
fn spawn_ctl(rd: &std::path::Path, args: &[&str]) -> (std::process::Child, Lines) {
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_localflowctl"))
        .args(args)
        .env("XDG_RUNTIME_DIR", rd)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let stdout = BufReader::new(child.stdout.take().unwrap());
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for line in stdout.lines() {
            let Ok(line) = line else { break };
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    (child, rx)
}

fn child_line(lines: &Lines) -> String {
    lines
        .recv_timeout(Duration::from_secs(10))
        .expect("a line from localflowctl")
}

fn wait_exit(child: &mut std::process::Child) -> Option<i32> {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status.code();
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            panic!("localflowctl did not exit");
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn localflowctl_watch_streams_lines_and_exits_when_the_daemon_stops() {
    let cap = speech();
    let mut rig = Rig::start(
        "watch-ctl",
        cap.clone(),
        factory(FakeRecognizer::default()),
        settings(),
        false,
    );
    let rd = runtime_dir(&rig.dir);
    let (mut child, lines) = spawn_ctl(&rd, &["watch"]);
    assert_eq!(child_line(&lines), "state=idle model=ready mic=unknown");
    cap.set_input(Some(true));
    assert_eq!(child_line(&lines), "state=idle model=ready mic=present");
    rig.stop().unwrap();
    assert_eq!(wait_exit(&mut child), Some(3));

    // Not running at all.
    assert_eq!(ctl(&rd, &["watch"]).status.code(), Some(3));
    // --waybar only goes with watch.
    assert_eq!(ctl(&rd, &["status", "--waybar"]).status.code(), Some(2));
}

#[test]
fn localflowctl_watch_exits_quietly_when_its_reader_goes_away() {
    let rig = Rig::start(
        "watch-epipe",
        speech(),
        factory(FakeRecognizer::default()),
        settings(),
        false,
    );
    for args in [&["watch"][..], &["watch", "--waybar"]] {
        let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_localflowctl"))
            .args(args)
            .env("XDG_RUNTIME_DIR", runtime_dir(&rig.dir))
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let mut stdout = BufReader::new(child.stdout.take().unwrap());
        let mut first = String::new();
        stdout.read_line(&mut first).unwrap();
        assert!(!first.is_empty());
        drop(stdout);
        // The next line hits the closed pipe. Other tests fork concurrently,
        // and a forked child holds a copy of the read end until it execs, so
        // one write can still succeed: keep producing lines until it exits.
        let deadline = Instant::now() + Duration::from_secs(10);
        let code = loop {
            rig.cmd("toggle");
            rig.cmd("cancel");
            if let Some(status) = child.try_wait().unwrap() {
                break status.code();
            }
            assert!(Instant::now() < deadline, "{args:?}: did not exit");
            std::thread::sleep(Duration::from_millis(20));
        };
        assert_eq!(code, Some(0), "{args:?}");
        let mut err = String::new();
        child
            .stderr
            .take()
            .unwrap()
            .read_to_string(&mut err)
            .unwrap();
        assert_eq!(err, "", "{args:?}");
    }
}

/// Runs `localflowctl args`, reads its first line, closes the reader and
/// expects a quiet exit 0 without anything else happening.
fn exits_once_its_reader_closes(rd: &std::path::Path, args: &[&str], first: &str) {
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_localflowctl"))
        .args(args)
        .env("XDG_RUNTIME_DIR", rd)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let mut line = String::new();
    stdout.read_line(&mut line).unwrap();
    assert!(line.contains(first), "{args:?}: {line}");
    drop(stdout);
    assert_eq!(wait_exit(&mut child), Some(0), "{args:?}");
    let mut err = String::new();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut err)
        .unwrap();
    assert_eq!(err, "", "{args:?}");
}

#[test]
fn localflowctl_watch_exits_when_its_reader_closes_while_nothing_changes() {
    // Daemon idle: no line is ever written after the first.
    let rig = Rig::start(
        "watch-idle-close",
        speech(),
        factory(FakeRecognizer::default()),
        settings(),
        false,
    );
    let rd = runtime_dir(&rig.dir);
    exits_once_its_reader_closes(&rd, &["watch"], "state=idle");
    exits_once_its_reader_closes(&rd, &["watch", "--waybar"], "\"idle\"");
    // Their subscriptions are reclaimed: a full set of watchers fits again
    // (one at a time, so each is answered before the next arrives).
    let _watchers: Vec<_> = (0..lf_daemon::watch::MAX_WATCHERS)
        .map(|_| {
            let mut w = rig.watch();
            assert!(w.line().starts_with("localflow/1 ok state=idle"));
            w
        })
        .collect();

    // No daemon: the waybar client shows offline once and retries; it must
    // still notice the reader going away.
    let dir = TempDir::new("waybar-absent-close");
    let rd = runtime_dir(&dir);
    private_dir(&rd);
    exits_once_its_reader_closes(&rd, &["watch", "--waybar"], "\"offline\"");
}

/// The double-tap window of [`hold_to_prompt_by_double_tap_and_hold`]: the
/// widest the configuration allows, so scheduling delays rarely matter.
const WINDOW: Duration = Duration::from_millis(1000);

#[test]
fn hold_to_prompt_by_double_tap_and_hold() {
    let cap = speech();
    let rec = FakeRecognizer::returning("Synthetic prompt words, press enter.");
    let rig = Rig::start_full(
        "prompt",
        cap.clone(),
        factory(rec),
        settings(),
        false,
        None,
        WINDOW,
    );
    let rd = runtime_dir(&rig.dir);
    let mut w = rig.watch();
    w.line();
    let (mut bar, bar_lines) = spawn_ctl(&rd, &["watch", "--waybar"]);
    child_line(&bar_lines);
    // Requests stamped now, as `localflowctl` stamps them (the daemon
    // distrusts stamps ahead of its clock).
    let send = |cmd: &str| -> String {
        let at = lf_daemon::protocol::monotonic_ns();
        let reply = rig.raw(format!("localflow/1 {cmd} at={at}\n").as_bytes());
        reply
            .strip_prefix("localflow/1 ok ")
            .and_then(|r| r.strip_suffix('\n'))
            .unwrap_or_else(|| panic!("{cmd}: {reply:?}"))
            .to_owned()
    };

    // A tap too short to dictate, then press again at once and hold: a
    // prompt dictation, tagged and still pressing Return.
    //
    // This cannot be fully deterministic: it drives the real daemon over
    // its socket, whose double-tap timing rightly uses real clocks (the
    // daemon's own receive times and the requests' stamps), which a test
    // cannot pause. If this thread is descheduled for longer than the
    // window between the tap and the second press, the tap rightly
    // expires; that is detected (the elapsed time is measured) and the
    // gesture retried, and only a missing tag within the window fails.
    // The exact timing rules are covered deterministically, with injected
    // times, by the controller's unit tests.
    let mut attempts = 0;
    loop {
        attempts += 1;
        cap.state().samples = vec![0.1; SECOND / 10];
        let t = Instant::now();
        send("press");
        assert_eq!(send("release"), "state=idle model=ready note=too-short");
        cap.state().samples = vec![0.1; SECOND];
        let reply = send("press");
        let took = t.elapsed();
        if reply == "state=recording mode=hold tag=prompt model=ready" {
            break;
        }
        assert!(
            took > WINDOW,
            "no prompt although the second press came {took:?} after the tap: {reply}"
        );
        assert!(attempts < 20, "the window was overrun 20 times");
        assert_eq!(send("cancel"), "state=idle model=ready note=cancelled");
    }
    assert_eq!(send("release"), "state=transcribing tag=prompt model=ready");
    rig.wait_for("state=idle");
    assert_eq!(rig.output.text(), "[dictated] Synthetic prompt words\n");
    // Past the tap's own recording and idle lines, to the prompt.
    let mut lines = w.until("tag=prompt");
    lines.extend(w.until("state=idle"));
    assert!(
        lines
            .contains(&"localflow/1 ok state=typing tag=prompt model=ready mic=unknown".to_owned())
    );
    // The bar shows the prompt class while it lasts.
    let mut prompt_classes = Vec::new();
    loop {
        let v: serde_json::Value = serde_json::from_str(&child_line(&bar_lines)).unwrap();
        if v["class"] == "idle" && !prompt_classes.is_empty() {
            break;
        }
        if v["class"].is_array() {
            assert_eq!(v["class"][1], "prompt");
            assert_eq!(v["alt"], v["class"][0]);
            prompt_classes.push(v["class"][0].as_str().unwrap().to_owned());
        }
    }
    assert!(
        prompt_classes.contains(&"recording".to_owned()),
        "{prompt_classes:?}"
    );
    assert!(
        prompt_classes.contains(&"typing".to_owned()),
        "{prompt_classes:?}"
    );

    // A single long hold is an ordinary dictation.
    rig.output.state().typed.clear();
    assert_eq!(send("press"), "state=recording mode=hold model=ready");
    assert_eq!(send("release"), "state=transcribing model=ready");
    rig.wait_for("state=idle");
    assert_eq!(rig.output.text(), "Synthetic prompt words\n");
    // So is a press too long after a tap.
    rig.output.state().typed.clear();
    cap.state().samples = vec![0.1; SECOND / 10];
    send("press");
    send("release");
    std::thread::sleep(WINDOW + Duration::from_millis(200));
    cap.state().samples = vec![0.1; SECOND];
    assert_eq!(send("press"), "state=recording mode=hold model=ready");
    send("release");
    rig.wait_for("state=idle");
    assert_eq!(rig.output.text(), "Synthetic prompt words\n");
    let _ = bar.kill();
    let _ = bar.wait();
}

#[test]
fn localflowctl_waybar_shows_states_and_survives_daemon_restarts() {
    let dir = TempDir::new("waybar");
    let rd = runtime_dir(&dir);
    private_dir(&rd);
    let (mut child, lines) = spawn_ctl(&rd, &["watch", "--waybar"]);
    let object = |lines: &Lines| -> serde_json::Value {
        let v: serde_json::Value = serde_json::from_str(&child_line(lines)).unwrap();
        assert_eq!(v["alt"], v["class"]);
        v
    };
    let class = |lines: &Lines| object(lines)["class"].as_str().unwrap().to_owned();
    // No daemon yet.
    assert_eq!(class(&lines), "offline");

    let start = |cap: FakeCapture| {
        daemon::start(
            Parts {
                capture: Box::new(cap),
                output: Box::new(FakeOutput::default()),
                recognizer: factory(FakeRecognizer::returning("Synthetic.")),
                settings: settings(),
                limits: Limits {
                    min_recording: Duration::ZERO,
                    max_recording: Duration::from_secs(60),
                    double_tap: Duration::ZERO,
                },
                history: lf_daemon::history::Setting {
                    dir: dir.path().join("data"),
                    enabled: false,
                },
                media: None,
            },
            &rd,
        )
        .unwrap()
    };
    // Idle, model loading or ready.
    let idle = |lines: &Lines| {
        let mut c = class(lines);
        if c == "loading" {
            c = class(lines);
        }
        assert_eq!(c, "idle");
    };

    let cap = speech();
    cap.state().input = Some(false);
    let handle = start(cap.clone());
    // Picked up within the retry interval.
    assert_eq!(class(&lines), "nomic");
    cap.set_input(Some(true));
    idle(&lines);

    cap.state().level = 0.5;
    assert!(ctl(&rd, &["toggle"]).status.success());
    let v = object(&lines);
    assert_eq!(v["class"], "recording");
    let graph = v["text"].as_str().unwrap();
    assert_eq!(graph.chars().count(), 8);
    assert!(graph.ends_with('▆'), "{graph}");
    assert!(ctl(&rd, &["cancel"]).status.success());
    // Skip level lines still queued.
    while class(&lines) != "idle" {}

    // The daemon stops: offline, then back when it returns.
    handle.shutdown();
    handle.join().unwrap();
    assert_eq!(class(&lines), "offline");
    let handle = start(speech());
    idle(&lines);
    assert!(child.try_wait().unwrap().is_none(), "still running");
    let _ = child.kill();
    let _ = child.wait();
    handle.shutdown();
    handle.join().unwrap();
}

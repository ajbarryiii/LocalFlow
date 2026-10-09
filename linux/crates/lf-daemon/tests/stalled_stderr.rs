//! The daemon keeps working while its stderr is a pipe nobody reads.
//!
//! This process's stderr is replaced by a pipe that is filled to capacity
//! before anything logs, so every write the logger attempts blocks until the
//! pipe is drained. Debug logging is on, and the socket thread (rejected
//! requests) and the control loop (every press and release) log on each
//! command. Checked while stalled:
//! - press/release keep working, and their log lines are dropped;
//! - with the daemon's panic hook, a panicking thread does not block, and a
//!   daemon whose recognition thread panics still stops (the default hook
//!   would block both on the pipe).
//!
//! Then the pipe is drained: the drop note appears, and a later panic is
//! logged with thread name and location but without any payload.
//!
//! `harness = false`: stderr is swapped for the whole process, so failures
//! are collected and reported only after it is restored. Panics on the main
//! thread are recorded for the report instead of being printed.

mod common;

use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::process::ExitCode;
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::{Rig, factory, private_dir, runtime_dir, settings};
use lf_daemon::controller::Limits;
use lf_daemon::daemon::{self, Parts};
use lf_daemon::log::{self, Level};
use lf_daemon::testing::{FakeCapture, FakeOutput, FakeRecognizer, TempDir};

const SECRET: &str = "synthetic secret dictation";

/// Short recordings: every press/release pair goes recording -> idle.
fn rig() -> Rig {
    Rig::start(
        "stalled-stderr",
        FakeCapture::with_samples(vec![0.1; 1600]),
        factory(FakeRecognizer::default()),
        settings(),
        false,
    )
}

/// One press/release pair plus a rejected request; returns a failure, if
/// any. Uses `raw` so a daemon error is reported rather than panicking.
fn cycle(rig: &Rig) -> Result<(), String> {
    for (req, want) in [
        (
            &b"localflow/1 press\n"[..],
            "localflow/1 ok state=recording mode=hold model=ready\n",
        ),
        (
            b"localflow/1 release\n",
            "localflow/1 ok state=idle model=ready note=too-short\n",
        ),
        (
            b"localflow/1 explode\n",
            "localflow/1 error unknown-command\n",
        ),
    ] {
        let got = rig.raw(req);
        if got != want {
            return Err(format!("{:?}: got {got:?}", String::from_utf8_lossy(req)));
        }
    }
    Ok(())
}

/// Runs `f` on its own thread; fails if it does not finish within 20 s
/// (the thread is then left behind).
fn finishes<T: Send + 'static>(
    what: &str,
    f: impl FnOnce() -> T + Send + 'static,
) -> Result<std::thread::Result<T>, String> {
    let t = std::thread::Builder::new()
        .name(format!("lf-test-{what}"))
        .spawn(f)
        .map_err(|e| e.to_string())?;
    let deadline = Instant::now() + Duration::from_secs(20);
    while !t.is_finished() {
        if Instant::now() >= deadline {
            return Err(format!("{what}: blocked"));
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    Ok(t.join())
}

/// A daemon whose recognition thread panics while loading the model, with a
/// payload that must never be logged.
fn panicking_daemon_stops(dir: &TempDir) -> Result<(), String> {
    let rd = runtime_dir(dir);
    private_dir(&rd);
    let handle = daemon::start(
        Parts {
            capture: Box::new(FakeCapture::default()),
            output: Box::new(FakeOutput::default()),
            recognizer: Box::new(|| panic!("{SECRET}")),
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
    )?;
    match finishes("panicking-daemon", move || handle.join())? {
        Ok(Err(e)) if e.contains("panicked") => Ok(()),
        other => Err(format!("daemon with a panicking worker: {other:?}")),
    }
}

/// Collects what the drained pipe delivers.
struct Drain {
    rx: Receiver<Vec<u8>>,
    seen: Vec<u8>,
}

impl Drain {
    fn start(read_end: OwnedFd) -> Drain {
        let mut pipe = std::fs::File::from(read_end);
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut buf = [0u8; 65536];
            while let Ok(n) = pipe.read(&mut buf) {
                if n == 0 || tx.send(buf[..n].to_vec()).is_err() {
                    break;
                }
            }
        });
        Drain {
            rx,
            seen: Vec::new(),
        }
    }

    fn text(&self) -> String {
        String::from_utf8_lossy(&self.seen).into_owned()
    }

    fn until(&mut self, want: &str) -> Result<(), String> {
        let deadline = Instant::now() + Duration::from_secs(20);
        while !self.text().contains(want) {
            if Instant::now() >= deadline {
                return Err(format!("{want:?} never reached stderr"));
            }
            if let Ok(chunk) = self.rx.recv_timeout(Duration::from_millis(50)) {
                self.seen.extend_from_slice(&chunk);
            }
        }
        Ok(())
    }
}

fn body(rig: &Rig, read_end: OwnedFd) -> Result<String, String> {
    // Every logger write blocks, so the logger holds one line and its queue
    // fills: lines are dropped after at most QUEUE_LINES + 1 lines.
    let mut cycles = 0;
    while log::dropped() == 0 {
        cycles += 1;
        if cycles > log::QUEUE_LINES {
            return Err("the logger never dropped a line".into());
        }
        cycle(rig)?;
    }
    // Stalled: keys still work, and every command still logs (dropped).
    let before = log::dropped();
    for _ in 0..200 {
        cycle(rig)?;
    }
    if log::dropped() < before + 200 * 3 {
        return Err(format!(
            "expected at least 600 more dropped lines, got {}",
            log::dropped() - before
        ));
    }

    // Panics while stalled do not block.
    match finishes("plain-panic", || panic!("{SECRET}"))? {
        Err(_) => {}
        Ok(()) => return Err("the thread did not panic".into()),
    }
    panicking_daemon_stops(&TempDir::new("stalled-panic"))?;
    // Keys still work after all that.
    cycle(rig)?;

    // Drain the pipe: the logger catches up and reports the drops.
    let mut drain = Drain::start(read_end);
    drain.until("log lines dropped (output stalled)")?;
    // Once output moves, a panic is logged without its payload,
    let _ = finishes("logged-panic", || panic!("{SECRET}"))?;
    drain.until("thread 'lf-test-logged-panic' panicked at ")?;
    // including a `&'static str` one, which runtime text can become.
    let _ = finishes("static-panic", || {
        let leaked: &'static str = Box::leak(String::from(SECRET).into_boxed_str());
        std::panic::panic_any(leaked)
    })?;
    drain.until("thread 'lf-test-static-panic' panicked at ")?;
    if drain.text().contains(SECRET) {
        return Err("a panic payload reached the log".into());
    }
    Ok(format!(
        "stalled after {cycles} cycles; 200 more cycles, 2 panics and a panicking worker \
         did not block; {} lines dropped",
        log::dropped()
    ))
}

/// Fills the pipe behind `fd` completely, without blocking.
fn fill_pipe(fd: &OwnedFd) {
    let fd = fd.as_raw_fd();
    // SAFETY: fcntl on a valid descriptor.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    // SAFETY: as above.
    assert!(unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } >= 0);
    let chunk = [b'.'; 4096];
    for size in [chunk.len(), 1] {
        // SAFETY: writes from a valid buffer of at least `size` bytes.
        while unsafe { libc::write(fd, chunk.as_ptr().cast(), size) } > 0 {}
    }
    // Blocking again, so the logger's writes wait for room.
    // SAFETY: as above.
    assert!(unsafe { libc::fcntl(fd, libc::F_SETFL, flags) } >= 0);
}

fn main() -> ExitCode {
    log::set_level(Level::Debug);
    let mut fds = [0; 2];
    // SAFETY: `fds` has room for the two descriptors.
    assert_eq!(unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) }, 0);
    // SAFETY: fresh descriptors owned by nothing else.
    let (read_end, write_end) =
        unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    fill_pipe(&write_end);
    // SAFETY: duplicates our own stderr.
    let saved = unsafe { libc::dup(libc::STDERR_FILENO) };
    assert!(saved >= 0);
    // SAFETY: replaces fd 2 with the pipe's write end; both are valid.
    assert!(unsafe { libc::dup2(write_end.as_raw_fd(), libc::STDERR_FILENO) } >= 0);
    drop(write_end);

    // Other threads panic through the daemon's hook, as in `localflowd`; a
    // panic on the main thread (a failed check) is kept for the report.
    let message = Arc::new(Mutex::new(String::new()));
    let hook_message = Arc::clone(&message);
    std::panic::set_hook(Box::new(move |info| {
        if std::thread::current().name() == Some("main") {
            *hook_message.lock().unwrap_or_else(|e| e.into_inner()) = info.to_string();
        } else {
            log::panic_hook(info);
        }
    }));
    let result = std::panic::catch_unwind(move || {
        let rig = rig();
        body(&rig, read_end)
    })
    .unwrap_or_else(|_| {
        Err(format!(
            "panicked: {}",
            message.lock().unwrap_or_else(|e| e.into_inner())
        ))
    });

    // SAFETY: restores the saved stderr; both descriptors are valid.
    unsafe {
        libc::dup2(saved, libc::STDERR_FILENO);
        libc::close(saved);
    }
    let _ = std::panic::take_hook();
    match result {
        Ok(summary) => {
            println!("ok   stalled stderr: {summary}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("FAILED: {e}");
            ExitCode::FAILURE
        }
    }
}

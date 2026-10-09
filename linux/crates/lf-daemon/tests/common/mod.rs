#![allow(dead_code)]

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Output;
use std::time::{Duration, Instant};

use lf_daemon::controller::Limits;
use lf_daemon::daemon::{self, Handle, Parts};
use lf_daemon::history;
use lf_daemon::recognizer::{Recognizer, RecognizerFactory};
use lf_daemon::testing::{FakeCapture, FakeOutput, TempDir};
use lf_daemon::worker::Settings;
use lf_io_api::MediaPlayers;

pub struct Rig {
    pub dir: TempDir,
    pub capture: FakeCapture,
    pub output: FakeOutput,
    pub handle: Option<Handle>,
}

pub fn runtime_dir(dir: &TempDir) -> PathBuf {
    dir.path().join("run")
}

pub fn data_dir(dir: &TempDir) -> PathBuf {
    dir.path().join("data/localflow")
}

pub fn factory(r: impl Recognizer + Send + 'static) -> RecognizerFactory {
    Box::new(move || Ok(Box::new(r) as Box<dyn Recognizer>))
}

pub fn private_dir(path: &Path) {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .unwrap();
}

impl Rig {
    pub fn start(
        tag: &str,
        capture: FakeCapture,
        recognizer: RecognizerFactory,
        settings: Settings,
        history: bool,
    ) -> Rig {
        Rig::start_with_media(tag, capture, recognizer, settings, history, None)
    }

    pub fn start_with_media(
        tag: &str,
        capture: FakeCapture,
        recognizer: RecognizerFactory,
        settings: Settings,
        history: bool,
        media: Option<Box<dyn MediaPlayers>>,
    ) -> Rig {
        Rig::start_full(
            tag,
            capture,
            recognizer,
            settings,
            history,
            media,
            Duration::ZERO,
        )
    }

    /// Like [`Rig::start_with_media`], with a double-tap window (zero
    /// disables Hold to Prompt, as in the other constructors).
    pub fn start_full(
        tag: &str,
        capture: FakeCapture,
        recognizer: RecognizerFactory,
        settings: Settings,
        history: bool,
        media: Option<Box<dyn MediaPlayers>>,
        double_tap: Duration,
    ) -> Rig {
        let dir = TempDir::new(tag);
        private_dir(&runtime_dir(&dir));
        let output = FakeOutput::default();
        let history = history::Setting {
            dir: data_dir(&dir),
            enabled: history,
        };
        let handle = daemon::start(
            Parts {
                capture: Box::new(capture.clone()),
                output: Box::new(output.clone()),
                recognizer,
                settings,
                limits: Limits {
                    min_recording: Duration::from_millis(300),
                    max_recording: Duration::from_secs(60),
                    double_tap,
                },
                history,
                media,
            },
            &runtime_dir(&dir),
        )
        .unwrap();
        let rig = Rig {
            dir,
            capture,
            output,
            handle: Some(handle),
        };
        rig.wait_for("model=ready");
        rig
    }

    pub fn socket(&self) -> PathBuf {
        runtime_dir(&self.dir).join("localflow/ctl.sock")
    }

    /// Sends raw bytes and returns the raw reply.
    pub fn raw(&self, request: &[u8]) -> String {
        let mut s = UnixStream::connect(self.socket()).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        s.write_all(request).unwrap();
        let mut reply = String::new();
        s.read_to_string(&mut reply).unwrap();
        reply
    }

    /// Sends a command and returns the reply fields after `ok`, or panics.
    pub fn cmd(&self, command: &str) -> String {
        let reply = self.raw(format!("localflow/1 {command}\n").as_bytes());
        reply
            .strip_prefix("localflow/1 ok ")
            .and_then(|r| r.strip_suffix('\n'))
            .unwrap_or_else(|| panic!("{command}: {reply:?}"))
            .to_owned()
    }

    /// Subscribes with `watch`.
    pub fn watch(&self) -> Watcher {
        let mut s = UnixStream::connect(self.socket()).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        s.write_all(b"localflow/1 watch\n").unwrap();
        Watcher(BufReader::new(s))
    }

    /// Runs the real `localflowctl` binary against this daemon.
    pub fn ctl(&self, args: &[&str]) -> Output {
        ctl(&runtime_dir(&self.dir), args)
    }

    /// Polls `status` until it contains `want`.
    pub fn wait_for(&self, want: &str) -> String {
        let deadline = Instant::now() + Duration::from_secs(60);
        loop {
            let s = self.cmd("status");
            if s.contains(want) {
                return s;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for {want}: {s}"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    pub fn stop(&mut self) -> Result<(), String> {
        let h = self.handle.take().expect("running");
        h.shutdown();
        h.join()
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        if let Some(h) = self.handle.take() {
            h.shutdown();
            let _ = h.join();
        }
    }
}

/// A `watch` subscription.
pub struct Watcher(pub BufReader<UnixStream>);

impl Watcher {
    /// The next line without its newline; panics on end of stream.
    pub fn line(&mut self) -> String {
        let mut line = String::new();
        let n = self.0.read_line(&mut line).unwrap();
        assert!(n > 0, "watch connection closed");
        line.strip_suffix('\n').unwrap().to_owned()
    }

    /// Reads lines up to and including the first that contains `want`.
    pub fn until(&mut self, want: &str) -> Vec<String> {
        let mut lines = Vec::new();
        loop {
            let line = self.line();
            let done = line.contains(want);
            lines.push(line);
            if done {
                return lines;
            }
        }
    }
}

/// The `state=` field of each line, with repeats (level lines) collapsed.
pub fn states(lines: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for l in lines {
        let s = l
            .split(' ')
            .find_map(|f| f.strip_prefix("state="))
            .unwrap_or("?")
            .to_owned();
        if out.last() != Some(&s) {
            out.push(s);
        }
    }
    out
}

pub fn ctl(runtime_dir: &Path, args: &[&str]) -> Output {
    std::process::Command::new(env!("CARGO_BIN_EXE_localflowctl"))
        .args(args)
        .env("XDG_RUNTIME_DIR", runtime_dir)
        .output()
        .unwrap()
}

pub fn settings() -> Settings {
    Settings {
        options: lf_dictation::Options::default(),
        macros: Vec::new(),
        type_chunk_chars: lf_daemon::worker::TYPE_CHUNK_CHARS,
        prompt_tag: "[dictated]".into(),
    }
}

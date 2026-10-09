//! Fakes for tests and for `localflowd --fake-io`, and a temporary directory.
//! None of them touch a microphone or the desktop.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use lf_io_api::{AudioCapture, IoError, SAMPLE_RATE, TextOutput};

use crate::recognizer::Recognizer;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Shared, inspectable state of a [`FakeCapture`].
#[derive(Debug, Default)]
pub struct CaptureState {
    pub recording: bool,
    pub starts: usize,
    pub stops: usize,
    pub cancels: usize,
    /// Returned by the next `stop`.
    pub samples: Vec<f32>,
    pub fail_start: bool,
    pub fail_stop: bool,
    /// How long `start` blocks, like a device waking up.
    pub start_delay: Duration,
    /// Reported by `input_available`; change it with
    /// [`FakeCapture::set_input`].
    pub input: Option<bool>,
    /// Reported by `level` while recording.
    pub level: f32,
    notify: Notify,
}

/// The `watch_input` callback.
#[derive(Default)]
struct Notify(Option<Arc<dyn Fn() + Send + Sync>>);

impl std::fmt::Debug for Notify {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(if self.0.is_some() {
            "Notify(set)"
        } else {
            "Notify(none)"
        })
    }
}

/// Returns preset samples. Clones share state.
#[derive(Clone, Default)]
pub struct FakeCapture(pub Arc<Mutex<CaptureState>>);

impl FakeCapture {
    pub fn with_samples(samples: Vec<f32>) -> FakeCapture {
        let c = FakeCapture::default();
        c.state().samples = samples;
        c
    }

    pub fn state(&self) -> MutexGuard<'_, CaptureState> {
        lock(&self.0)
    }

    /// Changes the reported microphone presence and notifies the watcher
    /// registered with `watch_input`, like a device being plugged in or out.
    pub fn set_input(&self, input: Option<bool>) {
        let notify = {
            let mut s = self.state();
            s.input = input;
            s.notify.0.clone()
        };
        if let Some(n) = notify {
            n();
        }
    }
}

impl AudioCapture for FakeCapture {
    fn level(&self) -> f32 {
        let s = self.state();
        if s.recording { s.level } else { 0.0 }
    }

    fn input_available(&self) -> Option<bool> {
        self.state().input
    }

    fn watch_input(&mut self, notify: Box<dyn Fn() + Send + Sync>) {
        self.state().notify = Notify(Some(Arc::from(notify)));
    }

    fn start(&mut self) -> Result<(), IoError> {
        let delay = self.state().start_delay;
        if !delay.is_zero() {
            std::thread::sleep(delay);
        }
        let mut s = self.state();
        if s.recording {
            return Err(IoError("already recording".into()));
        }
        s.recording = true;
        s.starts += 1;
        if s.fail_start {
            // A failure that leaves the stream half-open: the caller must cancel.
            return Err(IoError("synthetic start failure".into()));
        }
        Ok(())
    }

    fn stop(&mut self) -> Result<Vec<f32>, IoError> {
        let mut s = self.state();
        if !s.recording {
            return Err(IoError("not recording".into()));
        }
        s.stops += 1;
        if s.fail_stop {
            // Likewise left running.
            return Err(IoError("synthetic stop failure".into()));
        }
        s.recording = false;
        Ok(s.samples.clone())
    }

    fn cancel(&mut self) {
        let mut s = self.state();
        if s.recording {
            s.cancels += 1;
        }
        s.recording = false;
    }
}

/// Returns silence as long as the recording lasted (for `--fake-io`).
#[derive(Default)]
pub struct SilenceCapture {
    started: Option<Instant>,
}

impl AudioCapture for SilenceCapture {
    fn start(&mut self) -> Result<(), IoError> {
        if self.started.is_some() {
            return Err(IoError("already recording".into()));
        }
        self.started = Some(Instant::now());
        Ok(())
    }

    fn stop(&mut self) -> Result<Vec<f32>, IoError> {
        let started = self.started.take().ok_or(IoError("not recording".into()))?;
        let seconds = started
            .elapsed()
            .as_secs_f64()
            .min(crate::config::MAX_RECORDING_SECONDS);
        Ok(vec![0.0; (seconds * f64::from(SAMPLE_RATE)) as usize])
    }

    fn cancel(&mut self) {
        self.started = None;
    }
}

/// What a [`FakeOutput`] received.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Typed {
    Text(String),
    Enter,
}

#[derive(Debug, Default)]
pub struct OutputState {
    pub typed: Vec<Typed>,
    pub fail: bool,
    /// Delay per call, to exercise cancel during typing.
    pub delay: Duration,
}

/// Records typed text. Clones share state.
#[derive(Clone, Default)]
pub struct FakeOutput(pub Arc<Mutex<OutputState>>);

impl FakeOutput {
    pub fn state(&self) -> MutexGuard<'_, OutputState> {
        lock(&self.0)
    }

    /// All typed text concatenated, with Return as `\n`.
    pub fn text(&self) -> String {
        self.state()
            .typed
            .iter()
            .map(|t| match t {
                Typed::Text(s) => s.as_str(),
                Typed::Enter => "\n",
            })
            .collect()
    }
}

/// The real typer's rule: control characters other than `\n`, `\r` and `\t`
/// cannot be typed.
fn fake_check(text: &str) -> Result<(), IoError> {
    match text
        .chars()
        .position(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t'))
    {
        Some(i) => Err(IoError(format!(
            "cannot type control character at position {i}"
        ))),
        None => Ok(()),
    }
}

impl TextOutput for FakeOutput {
    fn check(&self, text: &str) -> Result<(), IoError> {
        fake_check(text)
    }

    fn type_text(&mut self, text: &str) -> Result<(), IoError> {
        fake_check(text)?;
        let delay = self.state().delay;
        std::thread::sleep(delay);
        let mut s = self.state();
        if s.fail {
            return Err(IoError("synthetic output failure".into()));
        }
        s.typed.push(Typed::Text(text.to_owned()));
        Ok(())
    }

    fn press_enter(&mut self) -> Result<(), IoError> {
        let mut s = self.state();
        if s.fail {
            return Err(IoError("synthetic output failure".into()));
        }
        s.typed.push(Typed::Enter);
        Ok(())
    }
}

/// Discards text (for `--fake-io`).
pub struct DiscardOutput;

impl TextOutput for DiscardOutput {
    fn type_text(&mut self, _text: &str) -> Result<(), IoError> {
        Ok(())
    }

    fn press_enter(&mut self) -> Result<(), IoError> {
        Ok(())
    }
}

#[derive(Debug, Default)]
pub struct RecognizerState {
    /// Returned for every call; `None` fails.
    pub text: Option<String>,
    pub calls: usize,
    /// Number of samples in each call.
    pub lengths: Vec<usize>,
    pub delay: Duration,
}

/// Returns preset text. Clones share state.
#[derive(Clone, Default)]
pub struct FakeRecognizer(pub Arc<Mutex<RecognizerState>>);

impl FakeRecognizer {
    pub fn returning(text: &str) -> FakeRecognizer {
        let r = FakeRecognizer::default();
        r.state().text = Some(text.to_owned());
        r
    }

    pub fn state(&self) -> MutexGuard<'_, RecognizerState> {
        lock(&self.0)
    }
}

impl Recognizer for FakeRecognizer {
    fn transcribe(&mut self, samples: &[f32]) -> Result<String, String> {
        let delay = self.state().delay;
        std::thread::sleep(delay);
        let mut s = self.state();
        s.calls += 1;
        s.lengths.push(samples.len());
        s.text
            .clone()
            .ok_or_else(|| "synthetic recognition failure".into())
    }
}

/// A private temporary directory (mode 0700), removed on drop.
pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new(tag: &str) -> TempDir {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.subsec_nanos());
        let path = std::env::temp_dir().join(format!(
            "lf-daemon-{tag}-{}-{}-{nanos}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .expect("create temporary directory");
        TempDir(path)
    }

    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

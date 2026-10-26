//! Fakes for tests and for `localflowd --fake-io`, and a temporary directory.
//! None of them touch a microphone or the desktop.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use lf_asr::Projection;
use lf_asr::dictionary::DictionaryEntry;
use lf_asr::tokenizer::Tokenizer;
use lf_chunk::{Chunk, Word};
use lf_io_api::{AudioCapture, AudioSink, IoError, SAMPLE_RATE, TextOutput};

use crate::dictionary::Snapshot;
use crate::recognizer::{ChunkResult, Recognizer};

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
    /// Delivered to the sink by the next `stop` (in blocks of `block`
    /// samples; 0 delivers them in one).
    pub samples: Vec<f32>,
    pub block: usize,
    /// Samples delivered to the current recording's sink so far.
    pub delivered: usize,
    sink: Sink,
    pub fail_start: bool,
    pub fail_stop: bool,
    /// How long `start` blocks, like a device waking up.
    pub start_delay: Duration,
    /// Holds `start` (before it does anything) until the gate opens; see
    /// [`FakeCapture::gate_start`].
    pub start_gate: Option<Gate>,
    /// Likewise for `stop`.
    pub stop_gate: Option<Gate>,
    /// Likewise for `cancel`.
    pub cancel_gate: Option<Gate>,
    /// Reported by `input_available`; change it with
    /// [`FakeCapture::set_input`].
    pub input: Option<bool>,
    /// Reported by `level` while recording.
    pub level: f32,
    notify: Notify,
}

/// The current recording's sink.
#[derive(Default)]
struct Sink(Option<Box<dyn AudioSink>>);

impl std::fmt::Debug for Sink {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(if self.0.is_some() {
            "Sink(set)"
        } else {
            "Sink(none)"
        })
    }
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

/// Holds [`FakeCapture`] calls until opened, so a test can act while one
/// runs, like a device that takes its time. Clones share state.
#[derive(Clone, Default)]
pub struct Gate(Arc<(Mutex<GateState>, Condvar)>);

#[derive(Default)]
struct GateState {
    entered: usize,
    open: bool,
}

impl std::fmt::Debug for Gate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = lock(&self.0.0);
        write!(f, "Gate(entered {}, open {})", s.entered, s.open)
    }
}

impl Gate {
    /// A held call gives up waiting after this long, so a failed test
    /// cannot leave a thread blocked for ever.
    const LIMIT: Duration = Duration::from_secs(30);

    /// Waits until `calls` calls have reached the gate. Panics after 10 s.
    pub fn wait_entered(&self, calls: usize) {
        let (m, cv) = &*self.0;
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut s = lock(m);
        while s.entered < calls {
            let left = deadline.saturating_duration_since(Instant::now());
            assert!(!left.is_zero(), "{calls} calls never reached the gate");
            s = cv
                .wait_timeout(s, left)
                .unwrap_or_else(|e| e.into_inner())
                .0;
        }
    }

    /// Lets the held calls, and every later one, go on.
    pub fn open(&self) {
        let (m, cv) = &*self.0;
        lock(m).open = true;
        cv.notify_all();
    }

    fn pass(&self) {
        let (m, cv) = &*self.0;
        let deadline = Instant::now() + Self::LIMIT;
        let mut s = lock(m);
        s.entered += 1;
        cv.notify_all();
        while !s.open {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return;
            }
            s = cv
                .wait_timeout(s, left)
                .unwrap_or_else(|e| e.into_inner())
                .0;
        }
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

    /// Holds every later `start` until the returned gate opens.
    pub fn gate_start(&self) -> Gate {
        let gate = Gate::default();
        self.state().start_gate = Some(gate.clone());
        gate
    }

    /// Holds every later `stop` until the returned gate opens.
    pub fn gate_stop(&self) -> Gate {
        let gate = Gate::default();
        self.state().stop_gate = Some(gate.clone());
        gate
    }

    /// Holds every later `cancel` until the returned gate opens.
    pub fn gate_cancel(&self) -> Gate {
        let gate = Gate::default();
        self.state().cancel_gate = Some(gate.clone());
        gate
    }

    /// Delivers `samples` to the current recording's sink now, as audio
    /// arriving while it runs. Nothing happens when not recording.
    pub fn push(&self, samples: &[f32]) {
        let sink = self.state().sink.0.take();
        if let Some(mut sink) = sink {
            sink.audio(samples);
            let mut s = self.state();
            s.delivered += samples.len();
            s.sink.0 = Some(sink);
        }
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

    fn start(&mut self, sink: Box<dyn AudioSink>) -> Result<(), IoError> {
        let (delay, gate) = {
            let s = self.state();
            (s.start_delay, s.start_gate.clone())
        };
        if let Some(gate) = gate {
            gate.pass();
        }
        if !delay.is_zero() {
            std::thread::sleep(delay);
        }
        let mut s = self.state();
        if s.recording {
            return Err(IoError("already recording".into()));
        }
        s.recording = true;
        s.starts += 1;
        s.delivered = 0;
        s.sink.0 = Some(sink);
        if s.fail_start {
            // A failure that leaves the stream half-open: the caller must cancel.
            return Err(IoError("synthetic start failure".into()));
        }
        Ok(())
    }

    fn stop(&mut self) -> Result<usize, IoError> {
        let gate = self.state().stop_gate.clone();
        if let Some(gate) = gate {
            gate.pass();
        }
        let (samples, block, sink) = {
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
            (s.samples.clone(), s.block, s.sink.0.take())
        };
        // Outside the lock: the sink may take its time.
        if let Some(mut sink) = sink {
            let size = if block == 0 {
                samples.len().max(1)
            } else {
                block
            };
            for piece in samples.chunks(size) {
                sink.audio(piece);
            }
        }
        let mut s = self.state();
        s.delivered += samples.len();
        Ok(s.delivered)
    }

    fn cancel(&mut self) {
        let gate = self.state().cancel_gate.clone();
        if let Some(gate) = gate {
            gate.pass();
        }
        let mut s = self.state();
        if s.recording {
            s.cancels += 1;
        }
        s.recording = false;
        s.sink.0 = None;
    }
}

/// Delivers silence as long as the recording lasted, at `stop` (for
/// `--fake-io`).
#[derive(Default)]
pub struct SilenceCapture {
    started: Option<(Instant, Box<dyn AudioSink>)>,
}

impl AudioCapture for SilenceCapture {
    fn start(&mut self, sink: Box<dyn AudioSink>) -> Result<(), IoError> {
        if self.started.is_some() {
            return Err(IoError("already recording".into()));
        }
        self.started = Some((Instant::now(), sink));
        Ok(())
    }

    fn stop(&mut self) -> Result<usize, IoError> {
        let (started, mut sink) = self.started.take().ok_or(IoError("not recording".into()))?;
        let seconds = started
            .elapsed()
            .as_secs_f64()
            .min(crate::config::MAX_RECORDING_SECONDS);
        let n = (seconds * f64::from(SAMPLE_RATE)) as usize;
        let block = [0.0f32; SAMPLE_RATE as usize];
        let mut left = n;
        while left > 0 {
            let k = left.min(block.len());
            sink.audio(&block[..k]);
            left -= k;
        }
        Ok(n)
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
    /// Transcriptions begun (counted before `delay`).
    pub started: usize,
    pub calls: usize,
    /// Number of samples in each chunk transcribed.
    pub lengths: Vec<usize>,
    /// Where each chunk starts in the compacted recording.
    pub starts: Vec<usize>,
    pub delay: Duration,
    /// The dictionary each transcription saw: revision and entry count.
    pub dictionaries: Vec<(u64, usize)>,
    /// What a re-decode returns when its extra entry has this strength (in
    /// thousandths); otherwise `text`.
    pub redecoded: Vec<(u32, String)>,
    /// Re-decodes run so far.
    pub redecodes: usize,
    /// How long each re-decode takes.
    pub redecode_delay: Duration,
    /// Floats in each retained projection (0 means 4).
    pub projection_floats: usize,
}

/// Returns preset text: its whitespace-separated words, all at the chunk's
/// start, for every chunk. Clones share state.
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
    fn transcribe_chunk(
        &mut self,
        chunk: &Chunk,
        dictionary: &Snapshot,
        retain: bool,
    ) -> Result<ChunkResult, String> {
        let delay = {
            let mut s = self.state();
            s.started += 1;
            s.delay
        };
        std::thread::sleep(delay);
        let mut s = self.state();
        s.calls += 1;
        s.lengths.push(chunk.samples.len());
        s.starts.push(chunk.start);
        s.dictionaries
            .push((dictionary.revision, dictionary.dictionary.entries.len()));
        let text = s
            .text
            .clone()
            .ok_or_else(|| "synthetic recognition failure".to_string())?;
        Ok(ChunkResult {
            words: fake_words(&text, chunk.start),
            projection: retain.then(|| Projection {
                data: vec![
                    0.5;
                    if s.projection_floats == 0 {
                        4
                    } else {
                        s.projection_floats
                    }
                ],
                frames: 1,
            }),
        })
    }

    fn redecode_chunk(
        &mut self,
        _projection: &Projection,
        start: usize,
        _dictionary: &Snapshot,
        extra: &DictionaryEntry,
    ) -> Result<Vec<Word>, String> {
        let delay = self.state().redecode_delay;
        std::thread::sleep(delay);
        let mut s = self.state();
        s.redecodes += 1;
        let milli = (extra.strength * 1000.0).round() as u32;
        let text = match s.redecoded.iter().find(|(m, _)| *m == milli) {
            Some((_, t)) => t.clone(),
            None => s
                .text
                .clone()
                .ok_or_else(|| "synthetic recognition failure".to_string())?,
        };
        Ok(fake_words(&text, start))
    }
}

/// The words of `text`, all starting at `start`.
fn fake_words(text: &str, start: usize) -> Vec<Word> {
    text.split_whitespace()
        .map(|w| Word {
            text: w.to_owned(),
            start,
        })
        .collect()
}

/// A small invented vocabulary for tests and `--fake-io`-style rigs:
/// `<unk>`, `▁`, ASCII letters and digits and common punctuation, so
/// ordinary ASCII words encode and accented letters such as `é` do not.
pub fn synthetic_tokenizer() -> Tokenizer {
    let mut pieces = vec!["<unk>".to_string(), "\u{2581}".to_string()];
    pieces.extend(('a'..='z').map(String::from));
    pieces.extend(('A'..='Z').map(String::from));
    pieces.extend(('0'..='9').map(String::from));
    pieces.extend(
        ["#", ".", ",", "'", "-", "?", "!", "_", "\"", "+", "&"]
            .iter()
            .map(|s| s.to_string()),
    );
    Tokenizer::from_pieces(pieces).expect("synthetic vocabulary")
}

/// A Unix socket path must fit `sockaddr_un::sun_path`: 108 bytes on Linux,
/// with the terminating NUL.
const SUN_PATH_MAX: usize = 107;

/// The longest socket path a rig binds below its [`TempDir`]: the daemon's
/// control socket under a runtime directory named `run`
/// (`/run/localflow/ctl.sock`).
const SOCKET_ROOM: usize =
    "/run/".len() + crate::paths::APP_DIR.len() + 1 + crate::paths::SOCKET_NAME.len();

/// Where a temporary directory named `name` is created: `temp` (the
/// process's temporary directory), unless the control socket below the new
/// directory would not fit `sun_path`; then `/tmp`. CI runners and `nix
/// develop` nest long temporary directories.
fn temp_parent(temp: PathBuf, name: &str) -> PathBuf {
    if temp.as_os_str().len() + 1 + name.len() + SOCKET_ROOM <= SUN_PATH_MAX {
        temp
    } else {
        PathBuf::from("/tmp")
    }
}

/// A private temporary directory (mode 0700), removed on drop, with room
/// below it for the daemon's control socket (see [`temp_parent`]).
pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new(tag: &str) -> TempDir {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.subsec_nanos());
        let name = format!(
            "lf-daemon-{tag}-{}-{}-{nanos}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        );
        let path = temp_parent(std::env::temp_dir(), &name).join(name);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn temporary_directories_leave_room_for_the_control_socket() {
        // The longest name that still fits stays where TMPDIR says; one byte
        // more moves the directory to /tmp.
        let room = SUN_PATH_MAX - SOCKET_ROOM - "/n".len();
        let fits = PathBuf::from(format!("/{}", "d".repeat(room - 1)));
        assert_eq!(temp_parent(fits.clone(), "n"), fits);
        let long = PathBuf::from(format!("/{}", "d".repeat(room)));
        assert_eq!(temp_parent(long, "n"), PathBuf::from("/tmp"));

        // Whatever TMPDIR is, a rig's socket path fits.
        let t = TempDir::new("room");
        assert!(t.path().as_os_str().len() + SOCKET_ROOM <= SUN_PATH_MAX);
        assert!(t.path().is_dir());
    }
}

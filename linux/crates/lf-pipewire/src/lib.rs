//! Microphone capture through an in-process PipeWire stream.
//!
//! [`PipeWireCapture`] implements [`AudioCapture`]. Each recording runs a
//! PipeWire main loop on its own thread with one capture stream that asks
//! for 16 kHz mono f32. PipeWire's adapter does the sample-rate conversion
//! and downmix; [`convert`] is a fallback used only if the server negotiates
//! another rate or channel count.
//!
//! Privacy: samples stay in memory, are returned once by `stop` (or dropped
//! by `cancel`), and are never written to disk or logged. Errors carry no
//! audio. The level meter exposes only an RMS value.
//!
//! [`AudioCapture::watch_input`] starts a [`PresenceMonitor`] that tracks
//! whether the configured input exists (see the `presence` module).

pub mod convert;
mod presence;
mod wipe;

pub use presence::{PresenceMonitor, SOURCE_CLASSES, SourceSet};

use std::cell::RefCell;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use lf_io_api::{AudioCapture, IoError, SAMPLE_RATE};
use pipewire as pw;
use pw::spa;
use spa::param::audio::{AudioFormat, AudioInfoRaw};
use spa::param::format::{MediaSubtype, MediaType};
use spa::param::format_utils;
use spa::pod::Pod;

use convert::Converter;

/// `node.name` of the capture stream; the presence monitor never counts it.
pub const CAPTURE_NODE_NAME: &str = "localflow-capture";

/// What happens when a recording reaches [`CaptureConfig::max_duration`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Overflow {
    /// Keep the first `max_duration` of audio, drop the rest and report
    /// [`Recording::truncated`].
    #[default]
    Truncate,
    /// Fail `stop` with an error (the audio is discarded).
    Error,
}

/// Capture configuration.
#[derive(Debug, Clone)]
pub struct CaptureConfig {
    /// Input to record from: a PipeWire `node.name` (or object serial),
    /// passed as `target.object`. `None` follows the default source. With a
    /// target set, the stream also gets `node.dont-fallback` and
    /// `node.dont-move`: the session manager neither falls back to another
    /// device (a missing device fails `start`) nor lets stored routing
    /// metadata move it.
    pub target: Option<String>,
    /// Longest recording kept; see [`Overflow`].
    pub max_duration: Duration,
    pub overflow: Overflow,
    /// How long `start` waits for the stream to be linked and running.
    pub start_timeout: Duration,
    /// PipeWire remote (socket name in the runtime directory, or an
    /// absolute path). `None` uses the normal default, `pipewire-0`. As
    /// everywhere in PipeWire, a set `PIPEWIRE_REMOTE` environment variable
    /// takes precedence over this.
    pub remote: Option<String>,
    /// Extra stream properties, for tests and unusual setups.
    pub extra_properties: Vec<(String, String)>,
}

impl Default for CaptureConfig {
    fn default() -> Self {
        Self {
            target: None,
            // Matches lf-asr's MAX_SECONDS.
            max_duration: Duration::from_secs(600),
            overflow: Overflow::Truncate,
            start_timeout: Duration::from_secs(3),
            remote: None,
            extra_properties: Vec::new(),
        }
    }
}

/// A finished recording with its metadata. The samples are wiped when the
/// recording is dropped; take them with `std::mem::take` to keep them.
/// `Debug` prints only the sample count.
#[derive(Default)]
pub struct Recording {
    /// 16 kHz mono samples in [-1, 1].
    pub samples: Vec<f32>,
    /// True if audio beyond `max_duration` was dropped.
    pub truncated: bool,
    /// Time from `start` being called to the first buffer holding at least
    /// one whole audio frame. Includes thread start, connecting, stream
    /// creation, linking by the session manager and device wake-up.
    pub start_latency: Option<Duration>,
    /// Rate and channel count PipeWire delivered (16000, 1 unless the
    /// fallback converter was needed).
    pub negotiated: Option<(u32, u32)>,
}

impl Drop for Recording {
    fn drop(&mut self) {
        wipe::wipe(&mut self.samples);
    }
}

impl std::fmt::Debug for Recording {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Recording")
            .field("samples", &format_args!("[{} samples]", self.samples.len()))
            .field("truncated", &self.truncated)
            .field("start_latency", &self.start_latency)
            .field("negotiated", &self.negotiated)
            .finish()
    }
}

/// `AudioCapture` over PipeWire. See the crate docs.
pub struct PipeWireCapture {
    config: CaptureConfig,
    /// The current recording's level meter; replaced on every `start`.
    level: Arc<AtomicU32>,
    active: Option<Active>,
    /// Started by `watch_input`.
    presence: Option<PresenceMonitor>,
}

struct Active {
    wake: Arc<EventFd>,
    thread: JoinHandle<Result<Recording, String>>,
}

impl PipeWireCapture {
    pub fn new(config: CaptureConfig) -> Self {
        Self {
            config,
            level: Arc::new(AtomicU32::new(0)),
            active: None,
            presence: None,
        }
    }

    pub fn config(&self) -> &CaptureConfig {
        &self.config
    }

    /// True between a successful `start` and `stop`/`cancel`.
    pub fn is_recording(&self) -> bool {
        self.active.is_some()
    }

    /// Like `stop`, with truncation, latency and format details.
    pub fn stop_recording(&mut self) -> Result<Recording, IoError> {
        let active = self
            .active
            .take()
            .ok_or_else(|| IoError("not recording".into()))?;
        let result = finish(active);
        self.level.store(0, Ordering::Relaxed);
        result.map_err(IoError)
    }

    fn validate(&self) -> Result<(), IoError> {
        let c = &self.config;
        let bad = |s: &str| s.contains('\0');
        if c.target.as_deref().is_some_and(bad)
            || c.remote.as_deref().is_some_and(bad)
            || c.extra_properties.iter().any(|(k, v)| bad(k) || bad(v))
        {
            return Err(IoError("capture configuration contains a NUL byte".into()));
        }
        if c.max_duration.is_zero() {
            return Err(IoError("max_duration must be positive".into()));
        }
        Ok(())
    }
}

impl Drop for PipeWireCapture {
    fn drop(&mut self) {
        self.cancel();
    }
}

impl AudioCapture for PipeWireCapture {
    fn start(&mut self) -> Result<(), IoError> {
        if self.active.is_some() {
            return Err(IoError("a recording is already running".into()));
        }
        self.validate()?;
        // A fresh meter per recording: a previous capture thread that was
        // detached on a timeout may still write to its own (old) meter, but
        // can never touch this recording's reading.
        self.level = Arc::new(AtomicU32::new(0));
        let wake = Arc::new(EventFd::new().map_err(|e| IoError(format!("eventfd: {e}")))?);
        let (ready_tx, ready_rx) = mpsc::channel();
        let started = Instant::now();
        let config = self.config.clone();
        let level = self.level.clone();
        let thread_wake = wake.clone();
        let thread = std::thread::Builder::new()
            .name("lf-pipewire".into())
            .spawn(move || run(config, thread_wake, ready_tx, level, started))
            .map_err(|e| IoError(format!("cannot spawn capture thread: {e}")))?;
        let active = Active { wake, thread };
        match ready_rx.recv_timeout(self.config.start_timeout) {
            Ok(Ok(())) => {
                self.active = Some(active);
                Ok(())
            }
            Ok(Err(msg)) => {
                let _ = finish(active);
                self.level.store(0, Ordering::Relaxed);
                Err(IoError(msg))
            }
            Err(_) => {
                let _ = finish(active);
                // The worker may have ingested audio while being stopped.
                self.level.store(0, Ordering::Relaxed);
                Err(IoError(format!(
                    "audio input did not start within {:.1} s (no microphone, or the \
                     requested device is missing?)",
                    self.config.start_timeout.as_secs_f64()
                )))
            }
        }
    }

    fn stop(&mut self) -> Result<Vec<f32>, IoError> {
        self.stop_recording()
            .map(|mut rec| std::mem::take(&mut rec.samples))
    }

    fn cancel(&mut self) {
        if let Some(active) = self.active.take() {
            let _ = finish(active);
        }
        self.level.store(0, Ordering::Relaxed);
    }

    fn level(&self) -> f32 {
        f32::from_bits(self.level.load(Ordering::Relaxed))
    }

    fn input_available(&self) -> Option<bool> {
        self.presence.as_ref().and_then(PresenceMonitor::get)
    }

    /// Starts a [`PresenceMonitor`] for the configured target and remote. If
    /// the thread cannot start, presence stays unknown.
    fn watch_input(&mut self, notify: Box<dyn Fn() + Send + Sync>) {
        if self.presence.is_none() && self.validate().is_ok() {
            self.presence = PresenceMonitor::spawn(
                self.config.remote.clone(),
                self.config.target.clone(),
                notify,
            )
            .ok();
        }
    }
}

/// How long `stop`/`cancel` wait for the capture thread to exit. Normally a
/// few milliseconds; a hung PipeWire must not block the caller indefinitely.
const STOP_TIMEOUT: Duration = Duration::from_secs(2);

/// Wakes the capture thread and waits for it, at most [`STOP_TIMEOUT`]. A
/// thread that does not exit in time is detached; it still wipes its
/// buffers when it eventually ends (its state and any `Recording` it
/// returns wipe on drop).
fn finish(active: Active) -> Result<Recording, String> {
    active.wake.signal();
    let deadline = Instant::now() + STOP_TIMEOUT;
    while !active.thread.is_finished() {
        if Instant::now() >= deadline {
            return Err("audio capture did not stop in time".into());
        }
        std::thread::sleep(Duration::from_millis(1));
    }
    match active.thread.join() {
        Ok(r) => r,
        Err(_) => Err("capture thread panicked".into()),
    }
}

/// A Linux eventfd used to tell the PipeWire loop to stop. Unlike a pipe it
/// has no separate ends, so signalling never hits EPIPE/SIGPIPE.
struct EventFd(OwnedFd);

impl EventFd {
    fn new() -> std::io::Result<Self> {
        // SAFETY: valid flags; returns a new fd or -1.
        let fd = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: fresh fd owned by nobody else.
        Ok(Self(unsafe { OwnedFd::from_raw_fd(fd) }))
    }

    fn signal(&self) {
        let one: u64 = 1;
        // SAFETY: writes 8 bytes from a valid u64 to our eventfd.
        unsafe { libc::write(self.0.as_raw_fd(), (&one as *const u64).cast(), 8) };
    }

    fn signalled(&self) -> bool {
        let mut v: u64 = 0;
        // SAFETY: reads 8 bytes into a valid u64; non-blocking.
        let n = unsafe { libc::read(self.0.as_raw_fd(), (&mut v as *mut u64).cast(), 8) };
        n == 8 && v > 0
    }

    /// Waits up to `timeout` for a signal; true if signalled.
    fn wait(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            if self.signalled() {
                return true;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return false;
            }
            let mut fd = libc::pollfd {
                fd: self.0.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            let ms = left.as_millis().clamp(1, i32::MAX as u128) as libc::c_int;
            // SAFETY: polls one valid pollfd.
            unsafe { libc::poll(&mut fd, 1, ms) };
        }
    }
}

struct WakeFd(Arc<EventFd>);

impl AsRawFd for WakeFd {
    fn as_raw_fd(&self) -> RawFd {
        self.0.0.as_raw_fd()
    }
}

/// Per-recording state, touched only on the capture thread.
struct State {
    max_samples: usize,
    overflow: Overflow,
    started: Instant,
    level: Arc<AtomicU32>,
    ready: Option<mpsc::Sender<Result<(), String>>>,
    converter: Option<Converter>,
    negotiated: Option<(u32, u32)>,
    channels: usize,
    samples: Vec<f32>,
    truncated: bool,
    first_buffer: Option<Instant>,
    error: Option<String>,
    /// Set once a stop was requested; state changes caused by our own
    /// shutdown are not errors.
    stopping: bool,
    scratch: Vec<f32>,
    converted: Vec<f32>,
}

impl State {
    fn new(
        max_samples: usize,
        overflow: Overflow,
        started: Instant,
        level: Arc<AtomicU32>,
        ready: Option<mpsc::Sender<Result<(), String>>>,
    ) -> Self {
        Self {
            max_samples: max_samples.max(1),
            overflow,
            started,
            level,
            ready,
            converter: None,
            negotiated: None,
            channels: 1,
            // About 30 s up front; grows as needed up to max_samples.
            samples: Vec::with_capacity(max_samples.clamp(1, 30 * SAMPLE_RATE as usize)),
            truncated: false,
            first_buffer: None,
            error: None,
            stopping: false,
            scratch: Vec::new(),
            converted: Vec::new(),
        }
    }

    fn report_ready(&mut self, r: Result<(), String>) {
        if let Some(tx) = self.ready.take() {
            let _ = tx.send(r);
        }
    }

    fn fail(&mut self, msg: String) {
        if self.error.is_none() {
            self.error = Some(msg.clone());
        }
        self.report_ready(Err(msg));
    }

    /// Takes one buffer's data region and chunk header (interleaved
    /// little-endian f32).
    fn ingest(&mut self, data: &[u8], offset: u32, size: u32, stride: i32) {
        if self.converter.is_none() || self.error.is_some() {
            return; // no (valid) format yet, or already failed
        }
        self.scratch.clear();
        if let Err(e) = decode_chunk(data, offset, size, stride, self.channels, &mut self.scratch) {
            self.fail(format!("malformed PipeWire buffer: {e}"));
            return;
        }
        if self.scratch.is_empty() {
            return;
        }
        if self.first_buffer.is_none() {
            self.first_buffer = Some(Instant::now());
        }
        self.converted.clear();
        let conv = self.converter.as_mut().expect("checked above");
        if conv.is_identity() {
            std::mem::swap(&mut self.scratch, &mut self.converted);
        } else {
            // Room for the resampler's output, so `push` never reallocates
            // (which would leave an unwiped copy of the audio behind).
            let rate = self.negotiated.map_or(SAMPLE_RATE, |(r, _)| r).max(1);
            let ratio = (SAMPLE_RATE / rate) as usize + 1;
            wipe::reserve_wiping(&mut self.converted, self.scratch.len() * ratio + 64);
            conv.push(&self.scratch, &mut self.converted);
        }
        self.append_converted();
    }

    fn append_converted(&mut self) {
        let block = &self.converted;
        if !block.is_empty() {
            let rms = (block.iter().map(|&v| v * v).sum::<f32>() / block.len() as f32).sqrt();
            self.level
                .store(rms.clamp(0.0, 1.0).to_bits(), Ordering::Relaxed);
        }
        let room = self.max_samples - self.samples.len();
        if block.len() > room {
            self.truncated = true;
        }
        let take = block.len().min(room);
        let len = self.samples.len();
        // Grow geometrically, but never past max_samples, so memory stays
        // bounded by max_duration; the old allocation is wiped, not leaked.
        let want = (len * 2).max(len + take).min(self.max_samples);
        wipe::extend_wiping(
            &mut self.samples,
            block[..take].iter().map(|v| v.clamp(-1.0, 1.0)),
            want,
        );
    }

    /// Switches to a newly negotiated format. Returns false (and records an
    /// error) if it cannot be converted; capture must then stop.
    fn set_format(&mut self, rate: u32, channels: u32) -> bool {
        if self.converter.is_some() && self.negotiated == Some((rate, channels)) {
            return true;
        }
        // Build the replacement first, so a rejected format never leaves a
        // finished converter installed.
        let next = Converter::new(rate, channels);
        // Flush the previous format's tail (it is consumed, never reused).
        self.flush_converter();
        match next {
            Ok(c) => {
                self.converter = Some(c);
                self.channels = channels as usize;
                self.negotiated = Some((rate, channels));
                true
            }
            Err(e) => {
                self.fail(format!("unsupported capture format: {e}"));
                false
            }
        }
    }

    fn flush_converter(&mut self) {
        if let Some(old) = self.converter.take() {
            self.converted.clear();
            wipe::reserve_wiping(&mut self.converted, old.max_tail());
            old.finish(&mut self.converted);
            self.append_converted();
        }
    }

    fn into_recording(mut self) -> Result<Recording, String> {
        self.flush_converter();
        if let Some(e) = self.error.take() {
            // `self` is dropped here, which wipes the samples.
            return Err(e);
        }
        if self.truncated && self.overflow == Overflow::Error {
            return Err(format!(
                "recording exceeded the maximum length of {:.3} s",
                self.max_samples as f64 / f64::from(SAMPLE_RATE)
            ));
        }
        Ok(Recording {
            start_latency: self.first_buffer.map(|t| t - self.started),
            samples: std::mem::take(&mut self.samples),
            truncated: self.truncated,
            negotiated: self.negotiated,
        })
    }
}

/// Audio buffers are overwritten on every exit path: cancel, failed start,
/// capture errors and panics all drop the state.
impl Drop for State {
    fn drop(&mut self) {
        wipe::wipe(&mut self.samples);
        wipe::wipe(&mut self.scratch);
        wipe::wipe(&mut self.converted);
    }
}

/// The error to report for a stream the server put in the error state. The
/// server's message is never passed on (privacy contract: it can carry
/// device names); the fixed messages WirePlumber sends when there is no
/// input to link to are recognized, because "no microphone" is the common
/// case (e.g. a Bluetooth headset that went to sleep).
fn stream_error(server_message: &str) -> &'static str {
    match server_message {
        // WirePlumber, linking/prepare-link.lua: no default source, or the
        // requested `target.object` does not exist.
        "no target node available" | "target not found" => {
            "no microphone available (PipeWire has no matching audio source; is the device connected?)"
        }
        _ => "PipeWire stream error",
    }
}

/// NaN and infinities become silence; everything is clamped to [-1, 1] as
/// the `AudioCapture` contract requires.
fn sanitize(v: f32) -> f32 {
    if v.is_finite() {
        v.clamp(-1.0, 1.0)
    } else {
        0.0
    }
}

/// Decodes the valid region of one SPA data block into samples.
///
/// Per the SPA buffer contract the chunk offset is taken modulo the block
/// size (`data.len()`, i.e. `maxsize`), the size is clamped to it, and the
/// valid region may wrap around the end of the block. `stride` is the
/// distance between frames (0 or negative means packed). A trailing partial
/// frame is ignored.
fn decode_chunk(
    data: &[u8],
    offset: u32,
    size: u32,
    stride: i32,
    channels: usize,
    out: &mut Vec<f32>,
) -> Result<(), &'static str> {
    let max = data.len();
    if max == 0 || size == 0 {
        return Ok(());
    }
    let frame = 4 * channels;
    let stride = if stride <= 0 { frame } else { stride as usize };
    if stride < frame {
        return Err("stride smaller than a frame");
    }
    let start = offset as usize % max;
    let size = (size as usize).min(max);
    if size < frame {
        return Ok(());
    }
    // Frames whose bytes lie entirely within the valid region.
    let frames = (size - frame) / stride + 1;
    crate::wipe::reserve_wiping(out, frames * channels);
    let mut bytes = [0u8; 4];
    for f in 0..frames {
        let base = start + f * stride;
        for c in 0..channels {
            let at = base + 4 * c;
            for (k, b) in bytes.iter_mut().enumerate() {
                *b = data[(at + k) % max];
            }
            out.push(sanitize(f32::from_le_bytes(bytes)));
        }
    }
    Ok(())
}

/// Dequeues every available buffer and feeds it to `state`.
fn drain(stream: &pw::stream::Stream, state: &RefCell<State>) {
    while let Some(mut buffer) = stream.dequeue_buffer() {
        let datas = buffer.datas_mut();
        let Some(data) = datas.first_mut() else {
            continue;
        };
        let chunk = data.chunk();
        if chunk.flags().contains(spa::buffer::ChunkFlags::CORRUPTED) {
            continue;
        }
        let (offset, size, stride) = (chunk.offset(), chunk.size(), chunk.stride());
        let Some(bytes) = data.data() else {
            continue;
        };
        state.borrow_mut().ingest(bytes, offset, size, stride);
    }
}

fn format_param() -> Result<Vec<u8>, String> {
    let mut info = AudioInfoRaw::new();
    info.set_format(AudioFormat::F32LE);
    info.set_rate(SAMPLE_RATE);
    info.set_channels(1);
    let mut position = [0u32; spa::sys::SPA_AUDIO_MAX_CHANNELS as usize];
    position[0] = spa::sys::SPA_AUDIO_CHANNEL_MONO;
    info.set_position(position);
    let obj = spa::pod::Object {
        type_: spa::utils::SpaTypes::ObjectParamFormat.as_raw(),
        id: spa::param::ParamType::EnumFormat.as_raw(),
        properties: info.into(),
    };
    spa::pod::serialize::PodSerializer::serialize(
        std::io::Cursor::new(Vec::new()),
        &spa::pod::Value::Object(obj),
    )
    .map(|(cursor, _)| cursor.into_inner())
    .map_err(|e| format!("cannot build format parameter: {e:?}"))
}

/// The capture thread: runs one PipeWire main loop until woken.
fn run(
    config: CaptureConfig,
    wake: Arc<EventFd>,
    ready: mpsc::Sender<Result<(), String>>,
    level: Arc<AtomicU32>,
    started: Instant,
) -> Result<Recording, String> {
    let max_samples = (config.max_duration.as_secs_f64() * f64::from(SAMPLE_RATE))
        .min(usize::MAX as f64) as usize;
    let state = Rc::new(RefCell::new(State::new(
        max_samples,
        config.overflow,
        started,
        level,
        Some(ready),
    )));
    let fail = |msg: String| {
        state.borrow_mut().fail(msg.clone());
        Err(msg)
    };

    let mainloop = match pw::main_loop::MainLoopRc::new(None) {
        Ok(l) => l,
        Err(e) => return fail(format!("cannot create PipeWire loop: {e}")),
    };
    let context = match pw::context::ContextRc::new(&mainloop, None) {
        Ok(c) => c,
        Err(e) => return fail(format!("cannot create PipeWire context: {e}")),
    };
    let mut core_props = pw::properties::PropertiesBox::new();
    if let Some(remote) = &config.remote {
        core_props.insert("remote.name", remote.as_str());
    }
    let core = match context.connect_rc(Some(core_props)) {
        Ok(c) => c,
        Err(e) => return fail(format!("cannot connect to PipeWire: {e}")),
    };

    let weak_loop = mainloop.downgrade();
    let core_state = state.clone();
    let _core_listener = core
        .add_listener_local()
        .error(move |id, _seq, res, message| {
            // id 0 is the core itself: the connection is unusable.
            // The server's free-form message is dropped; only the errno is
            // kept.
            let _ = message;
            if id == pw::core::PW_ID_CORE {
                core_state.borrow_mut().fail(format!(
                    "PipeWire connection error: {}",
                    std::io::Error::from_raw_os_error(res.saturating_neg())
                ));
                if let Some(l) = weak_loop.upgrade() {
                    l.quit();
                }
            }
        })
        .register();

    let mut props = pw::properties::PropertiesBox::new();
    props.insert("media.type", "Audio");
    props.insert("media.category", "Capture");
    props.insert("media.role", "Communication");
    props.insert("node.name", CAPTURE_NODE_NAME);
    props.insert("node.description", "LocalFlow dictation");
    props.insert("application.name", "LocalFlow");
    if let Some(target) = &config.target {
        props.insert("target.object", target.as_str());
        // Neither fall back to another device when it is missing, nor let
        // stored or user re-routing metadata move the stream elsewhere.
        props.insert("node.dont-fallback", "true");
        props.insert("node.dont-move", "true");
    }
    for (k, v) in &config.extra_properties {
        props.insert(k.as_str(), v.as_str());
    }
    let stream = match pw::stream::StreamRc::new(core.clone(), "LocalFlow capture", props) {
        Ok(s) => s,
        Err(e) => return fail(format!("cannot create PipeWire stream: {e}")),
    };

    let s_state = state.clone();
    let s_loop = mainloop.downgrade();
    let p_state = state.clone();
    let p_loop = mainloop.downgrade();
    let d_state = state.clone();
    let _listener = stream
        .add_local_listener_with_user_data(())
        .state_changed(move |_, _, old, new| match new {
            pw::stream::StreamState::Streaming => s_state.borrow_mut().report_ready(Ok(())),
            pw::stream::StreamState::Error(msg) => {
                s_state.borrow_mut().fail(stream_error(&msg).into());
                if let Some(l) = s_loop.upgrade() {
                    l.quit();
                }
            }
            pw::stream::StreamState::Unconnected if !s_state.borrow().stopping => {
                let what = if old == pw::stream::StreamState::Connecting {
                    "PipeWire stream failed to connect"
                } else {
                    "PipeWire stream disconnected"
                };
                s_state.borrow_mut().fail(what.into());
                if let Some(l) = s_loop.upgrade() {
                    l.quit();
                }
            }
            _ => {}
        })
        .param_changed(move |_, _, id, param| {
            let Some(param) = param else { return };
            if id != spa::param::ParamType::Format.as_raw() {
                return;
            }
            let Ok((media_type, media_subtype)) = format_utils::parse_format(param) else {
                return;
            };
            if media_type != MediaType::Audio || media_subtype != MediaSubtype::Raw {
                return;
            }
            let mut info = AudioInfoRaw::new();
            let ok = {
                let mut st = p_state.borrow_mut();
                if info.parse(param).is_err() || info.format() != AudioFormat::F32LE {
                    st.fail("PipeWire negotiated an unexpected sample format".into());
                    false
                } else {
                    st.set_format(info.rate(), info.channels())
                }
            };
            if !ok && let Some(l) = p_loop.upgrade() {
                l.quit();
            }
        })
        .process(move |stream, _| drain(stream, &d_state))
        .register();
    let _listener = match _listener {
        Ok(l) => l,
        Err(e) => return fail(format!("cannot listen to PipeWire stream: {e}")),
    };

    let param_bytes = match format_param() {
        Ok(b) => b,
        Err(e) => return fail(e),
    };
    let Some(pod) = Pod::from_bytes(&param_bytes) else {
        return fail("invalid format parameter".into());
    };
    let mut params = [pod];
    if let Err(e) = stream.connect(
        spa::utils::Direction::Input,
        None,
        pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::MAP_BUFFERS,
        &mut params,
    ) {
        return fail(format!("cannot connect PipeWire stream: {e}"));
    }

    let w_loop = mainloop.downgrade();
    let w_stream = stream.downgrade();
    let w_state = state.clone();
    let _wake_source = mainloop.loop_().add_io(
        WakeFd(wake.clone()),
        spa::support::system::IoFlags::IN,
        move |fd| {
            if fd.0.signalled() {
                w_state.borrow_mut().stopping = true;
                // Take whatever is still queued, then stop.
                if let Some(s) = w_stream.upgrade() {
                    drain(&s, &w_state);
                }
                if let Some(l) = w_loop.upgrade() {
                    l.quit();
                }
            }
        },
    );
    // A stop requested before the source existed is still pending in the
    // eventfd, so the loop wakes immediately in that case.
    mainloop.run();

    state.borrow_mut().stopping = true;
    let _ = stream.disconnect();
    drop(_wake_source);
    drop(_listener);
    drop(_core_listener);
    drop(stream);
    drop(core);
    drop(context);
    drop(mainloop);
    let state = Rc::try_unwrap(state)
        .map_err(|_| "capture state still shared".to_string())?
        .into_inner();
    state.into_recording()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn le(samples: &[f32]) -> Vec<u8> {
        samples.iter().flat_map(|v| v.to_le_bytes()).collect()
    }

    fn decode(data: &[u8], offset: u32, size: u32, stride: i32, ch: usize) -> Vec<f32> {
        let mut out = Vec::new();
        decode_chunk(data, offset, size, stride, ch, &mut out).unwrap();
        out
    }

    fn state(max_samples: usize, overflow: Overflow) -> State {
        State::new(
            max_samples,
            overflow,
            Instant::now(),
            Arc::new(AtomicU32::new(0)),
            None,
        )
    }

    #[test]
    fn missing_source_is_reported_without_the_server_message() {
        for msg in ["no target node available", "target not found"] {
            assert!(stream_error(msg).starts_with("no microphone available"));
        }
        // Anything else stays generic, and no server text leaks through.
        let other = "failed to open device Someone's Headset (alsa_input.usb-Private_Name)";
        assert_eq!(stream_error(other), "PipeWire stream error");
        assert_eq!(stream_error(""), "PipeWire stream error");
    }

    #[test]
    fn chunk_offset_is_taken_modulo_maxsize() {
        let data = le(&[0.1, 0.2, 0.3, 0.4]);
        // offset == maxsize is offset 0, not "nothing".
        assert_eq!(decode(&data, 16, 8, 0, 1), vec![0.1, 0.2]);
        assert_eq!(decode(&data, 16 * 3 + 4, 8, 0, 1), vec![0.2, 0.3]);
    }

    #[test]
    fn chunk_wraps_around_the_end() {
        let data = le(&[0.1, 0.2, 0.3, 0.4]);
        assert_eq!(decode(&data, 8, 16, 0, 1), vec![0.3, 0.4, 0.1, 0.2]);
        // A frame straddling the end byte-wise (offset not 4-aligned).
        let mut bytes = le(&[0.5, 0.25]);
        bytes.rotate_left(2); // 0.5 now starts at byte 6 and wraps to 0..2
        assert_eq!(decode(&bytes, 6, 8, 0, 1), vec![0.5, 0.25]);
    }

    #[test]
    fn chunk_size_is_clamped_and_partial_frames_dropped() {
        let data = le(&[0.1, 0.2, 0.3]);
        assert_eq!(decode(&data, 0, 1000, 0, 1).len(), 3);
        assert_eq!(decode(&data, 0, 7, 0, 1), vec![0.1]);
        assert_eq!(decode(&data, 0, 3, 0, 1), Vec::<f32>::new());
        assert_eq!(decode(&[], 0, 8, 0, 1), Vec::<f32>::new());
        // Stereo: a trailing half frame is ignored.
        assert_eq!(decode(&data, 0, 12, 0, 2), vec![0.1, 0.2]);
    }

    #[test]
    fn chunk_stride_skips_padding() {
        // Mono frames padded to 8 bytes: value, junk.
        let data = le(&[0.1, 9.0, 0.2, 9.0, 0.3, 9.0]);
        assert_eq!(decode(&data, 0, 24, 8, 1), vec![0.1, 0.2, 0.3]);
        // The last frame needs only its own 4 bytes, not the padding.
        assert_eq!(decode(&data, 0, 20, 8, 1), vec![0.1, 0.2, 0.3]);
        let mut out = Vec::new();
        assert!(decode_chunk(&data, 0, 24, 4, 2, &mut out).is_err());
    }

    #[test]
    fn chunk_values_are_sanitized() {
        let data = le(&[f32::NAN, f32::INFINITY, 2.0, -3.0, 0.5]);
        assert_eq!(decode(&data, 0, 20, 0, 1), vec![0.0, 0.0, 1.0, -1.0, 0.5]);
    }

    #[test]
    fn rejected_format_change_stops_ingesting_without_panicking() {
        let mut st = state(16_000, Overflow::Truncate);
        assert!(st.set_format(8_000, 1));
        let tone = le(&[0.25; 100]);
        st.ingest(&tone, 0, tone.len() as u32, 0);
        // 44,101 Hz needs 16,000 filter phases: rejected.
        assert!(!st.set_format(44_101, 1));
        assert!(st.converter.is_none());
        assert!(st.error.is_some());
        // Further buffers are ignored rather than fed to a finished
        // resampler.
        for _ in 0..10 {
            st.ingest(&tone, 0, tone.len() as u32, 0);
        }
        assert!(st.into_recording().is_err());
    }

    #[test]
    fn format_change_flushes_the_previous_converter() {
        let mut st = state(16_000, Overflow::Truncate);
        assert!(st.set_format(8_000, 1));
        let tone = le(&[0.25; 400]);
        st.ingest(&tone, 0, tone.len() as u32, 0);
        assert!(st.set_format(16_000, 2));
        let stereo = le(&[0.5, 0.0, 0.5, 0.0]);
        st.ingest(&stereo, 0, stereo.len() as u32, 0);
        let rec = st.into_recording().unwrap();
        // 400 samples at 8 kHz -> 800 at 16 kHz, then 2 downmixed frames.
        assert_eq!(rec.samples.len(), 802);
        assert_eq!(&rec.samples[800..], &[0.25, 0.25]);
        assert_eq!(rec.negotiated, Some((16_000, 2)));
    }

    #[test]
    fn truncation_and_overflow_policies() {
        let mut st = state(1000, Overflow::Truncate);
        st.set_format(16_000, 1);
        let block = le(&[0.1; 600]);
        st.ingest(&block, 0, block.len() as u32, 0);
        st.ingest(&block, 0, block.len() as u32, 0);
        assert!(st.samples.capacity() <= 1000);
        let rec = st.into_recording().unwrap();
        assert_eq!(rec.samples.len(), 1000);
        assert!(rec.truncated);

        let mut st = state(1000, Overflow::Error);
        st.set_format(16_000, 1);
        st.ingest(&block, 0, block.len() as u32, 0);
        st.ingest(&block, 0, block.len() as u32, 0);
        assert!(st.into_recording().is_err());
    }

    #[test]
    fn first_buffer_needs_a_whole_frame() {
        let mut st = state(1000, Overflow::Truncate);
        st.set_format(16_000, 1);
        st.ingest(&[0, 0], 0, 2, 0);
        assert!(st.first_buffer.is_none());
        st.ingest(&le(&[0.1]), 0, 4, 0);
        assert!(st.first_buffer.is_some());
    }
}

//! Wires the pieces together: control socket thread, control loop,
//! recognition worker, and the `watch` subscribers the control loop owns.

use std::path::Path;
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use lf_io_api::{AudioCapture, MediaPlayers, TextOutput};

use crate::controller::{Controller, Limits};
use crate::history::{self, History};
use crate::media::MediaJoin;
use crate::protocol::{Reply, Request};
use crate::recognizer::RecognizerFactory;
use crate::server::Server;
use crate::watch::{Admission, MAX_WATCHERS, NewWatcher, Snapshot, Watchers};
use crate::worker::{self, WorkerEvent};

/// Everything the control loop reacts to.
pub enum Event {
    Request(Request, Sender<Reply>),
    /// A `watch` connection, authenticated, its request read and its place
    /// reserved (see `crate::watch::Admission`).
    Watch(NewWatcher),
    /// Microphone presence may have changed.
    Input,
    Worker(WorkerEvent),
    Shutdown,
}

pub struct Parts {
    pub capture: Box<dyn AudioCapture>,
    pub output: Box<dyn TextOutput>,
    pub recognizer: RecognizerFactory,
    pub settings: worker::Settings,
    pub limits: Limits,
    pub history: history::Setting,
    /// Media players to pause while recording (`pause_media`); `None`
    /// leaves them alone.
    pub media: Option<Box<dyn MediaPlayers>>,
}

/// How long stopping the daemon waits for the media thread to resume the
/// players it paused. Each call is bounded (250 ms), but a pass over several
/// hanging players could take longer; the daemon then exits anyway.
pub const MEDIA_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(3);

pub struct Handle {
    events: Sender<Event>,
    control: JoinHandle<Result<(), String>>,
    socket: JoinHandle<()>,
    worker: JoinHandle<()>,
    media: Option<MediaJoin>,
    server: Arc<Server>,
}

impl Handle {
    /// Asks the control loop to stop. Safe to call more than once.
    pub fn shutdown(&self) {
        let _ = self.events.send(Event::Shutdown);
    }

    pub fn events(&self) -> Sender<Event> {
        self.events.clone()
    }

    pub fn socket_path(&self) -> &Path {
        self.server.socket_path()
    }

    /// Waits for the control loop to end, then stops the socket thread,
    /// removes the socket and releases the instance lock.
    pub fn join(self) -> Result<(), String> {
        let result = self
            .control
            .join()
            .unwrap_or_else(|_| Err("control loop panicked".into()));
        self.server.stop();
        let _ = self.socket.join();
        // The control loop dropped the controller and with it the media
        // channel, so the media thread resumes what it paused and ends.
        if let Some(media) = self.media {
            media.join(MEDIA_SHUTDOWN_TIMEOUT);
        }
        // The control loop dropped the job queue, so the worker ends after its
        // current job (cancelled) or model load. Join it before the instance
        // lock is released with `server`.
        let _ = self.worker.join();
        result
    }
}

/// Binds the control socket under `runtime_dir`, then starts the worker
/// (which loads the model) and the control loop.
pub fn start(parts: Parts, runtime_dir: &Path) -> Result<Handle, String> {
    start_with(parts, runtime_dir, |_| {})
}

/// Like [`start`], and hands `on_events` the event sender before the socket
/// serves its first request. `localflowd` uses it to route termination
/// signals to [`Event::Shutdown`] before any recording can start, so a
/// signal never skips the shutdown path (which resumes paused media).
pub fn start_with(
    parts: Parts,
    runtime_dir: &Path,
    on_events: impl FnOnce(Sender<Event>),
) -> Result<Handle, String> {
    let server = Arc::new(Server::bind(runtime_dir)?);
    // Under the instance lock, so cleaning up temporary files is safe.
    let history = if parts.history.enabled {
        Some(History::open(&parts.history.dir)?)
    } else {
        history::remove_stale_temporaries(&parts.history.dir);
        None
    };
    let (events_tx, events_rx) = mpsc::channel::<Event>();
    let (jobs_tx, jobs_rx) = mpsc::channel();

    let worker_events = events_tx.clone();
    let worker = worker::spawn(
        parts.recognizer,
        parts.output,
        parts.settings,
        jobs_rx,
        move |e| {
            let _ = worker_events.send(Event::Worker(e));
        },
    )
    .map_err(|e| format!("cannot start the recognition thread: {e}"))?;

    // On a later failure, stop what already runs before the instance lock is
    // released (when `server` drops).
    let mut capture = parts.capture;
    let input_events = events_tx.clone();
    capture.watch_input(Box::new(move || {
        let _ = input_events.send(Event::Input);
    }));
    let mut controller = Controller::new(capture, Box::new(jobs_tx), parts.limits, history);
    let mut media = None;
    if let Some(players) = parts.media {
        match crate::media::spawn(players, lf_media::Timing::default()) {
            Ok((sender, join)) => {
                controller = controller.with_media(Box::new(sender));
                media = Some(join);
            }
            // Recording works without it.
            Err(e) => crate::warn!("media players will not be paused: cannot start a thread: {e}"),
        }
    }
    let admission = Admission::new(MAX_WATCHERS);
    let loop_admission = Arc::clone(&admission);
    let control = match std::thread::Builder::new()
        .name("lf-control".into())
        .spawn(move || run(controller, events_rx, loop_admission))
    {
        Ok(c) => c,
        Err(e) => {
            // The unstarted closure, with the job queue and the media
            // channel, is dropped: the worker ends after loading, and the
            // media thread at once (it paused nothing).
            let _ = worker.join();
            if let Some(media) = media {
                media.join(MEDIA_SHUTDOWN_TIMEOUT);
            }
            server.stop();
            return Err(format!("cannot start the control thread: {e}"));
        }
    };

    on_events(events_tx.clone());
    let serve_events = events_tx.clone();
    let serve_server = Arc::clone(&server);
    let socket = match std::thread::Builder::new()
        .name("lf-socket".into())
        .spawn(move || serve_server.serve(&serve_events, &admission))
    {
        Ok(s) => s,
        Err(e) => {
            let _ = events_tx.send(Event::Shutdown);
            let _ = control.join();
            if let Some(media) = media {
                media.join(MEDIA_SHUTDOWN_TIMEOUT);
            }
            let _ = worker.join();
            server.stop();
            return Err(format!("cannot start the socket thread: {e}"));
        }
    };

    crate::info!("listening on {}", server.socket_path().display());
    Ok(Handle {
        events: events_tx,
        control,
        socket,
        worker,
        media,
        server,
    })
}

fn snapshot(controller: &Controller) -> Snapshot {
    Snapshot {
        status: controller.status(),
        mic: controller.input_available(),
        level: controller.input_level(),
    }
}

/// Microphone presence changes are logged at most this often; a change
/// within the interval is logged with the next event after it.
const MIC_LOG_INTERVAL: Duration = Duration::from_secs(10);

fn mic_name(mic: Option<bool>) -> &'static str {
    match mic {
        Some(true) => "present",
        Some(false) => "absent",
        None => "unknown",
    }
}

/// The control loop. After every event and timer it publishes the status to
/// the watchers (which send only on a change, or a due level line).
fn run(
    mut controller: Controller,
    events: Receiver<Event>,
    admission: Arc<Admission>,
) -> Result<(), String> {
    let mut watchers = Watchers::new(admission);
    // Presence last logged, and when. The log is rate-limited so a flapping
    // device or PipeWire connection cannot flood it.
    let mut mic_logged: (Option<bool>, Option<Instant>) = (None, None);
    let result = loop {
        let now = Instant::now();
        controller.tick(now);
        let snap = snapshot(&controller);
        if snap.mic != mic_logged.0
            && mic_logged
                .1
                .is_none_or(|t| now.saturating_duration_since(t) >= MIC_LOG_INTERVAL)
        {
            mic_logged = (snap.mic, Some(now));
            crate::info!("microphone: {}", mic_name(snap.mic));
        }
        watchers.publish(snap, now);
        let deadline = match (controller.next_deadline(), watchers.next_deadline()) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        };
        let event = match deadline {
            Some(deadline) => {
                let wait = deadline
                    .saturating_duration_since(now)
                    .max(Duration::from_millis(1));
                match events.recv_timeout(wait) {
                    Ok(e) => e,
                    Err(RecvTimeoutError::Timeout) => continue,
                    Err(RecvTimeoutError::Disconnected) => break Ok(()),
                }
            }
            None => match events.recv() {
                Ok(e) => e,
                Err(_) => break Ok(()),
            },
        };
        match event {
            Event::Request(req, reply) => {
                let r = controller.handle_request(req, Instant::now());
                let _ = reply.send(r);
            }
            Event::Watch(new) => watchers.add(new, snapshot(&controller), Instant::now()),
            // Published at the top of the loop.
            Event::Input => {}
            Event::Worker(w) => {
                if let Err(e) = controller.handle_worker(w) {
                    break Err(e);
                }
            }
            Event::Shutdown => break Ok(()),
        }
    };
    controller.shutdown();
    result
}

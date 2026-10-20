//! The microphone, driven so the control loop never waits for it.
//!
//! The controller numbers each recording and sends its calls ([`Call`])
//! through a [`CapturePort`]; results come back as [`CaptureEvent`]s for
//! that number. [`spawn`] runs the calls on a `lf-capture` thread that owns
//! the [`AudioCapture`] and delivers results on the daemon's event channel;
//! [`Inline`] runs them at once and hands the results back through
//! [`CapturePort::poll`] (controller tests).
//!
//! Calls run in the order sent, each as the controller used to run it: a
//! failed `start` or `stop` is followed by `cancel`, so a half-open stream
//! is always closed. A `start` or `stop` for a recording already cancelled
//! when the thread comes to it is skipped, so press-and-cancel bursts
//! behind a slow start never reopen the microphone. A capture that panics fails the call instead of taking
//! the thread down.
//!
//! Privacy: stopped audio is wrapped in [`Audio`] on the capture thread, so
//! it is wiped wherever the event ends up, also when nobody takes it (a
//! cancelled recording, or a daemon shutting down).

use std::cell::Cell;
use std::collections::VecDeque;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, MutexGuard, TryLockError};
use std::thread::JoinHandle;
use std::time::Duration;

use lf_io_api::{AudioCapture, IoError};

use crate::worker::Audio;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Call {
    Start,
    Stop,
    Cancel,
}

/// The result of a call.
pub enum Done {
    Started(Result<(), IoError>),
    Stopped(Result<Audio, IoError>),
    /// Carries nothing; it wakes the control loop, so readings answered
    /// from the cache while the call held the capture are taken again.
    Cancelled,
}

pub struct CaptureEvent {
    /// The recording the call was for.
    pub generation: u64,
    pub done: Done,
}

/// Where the controller sends capture calls. Nothing here blocks.
pub trait CapturePort: Send {
    /// Queues `call` for recording `generation`.
    fn send(&mut self, generation: u64, call: Call);

    /// A result available at once: every result of an [`Inline`] port, or a
    /// failure for a call the capture thread can no longer take.
    fn poll(&mut self) -> Option<CaptureEvent>;

    /// See [`AudioCapture::level`].
    fn level(&self) -> f32;

    /// See [`AudioCapture::input_available`].
    fn input_available(&self) -> Option<bool>;
}

fn run(capture: &mut dyn AudioCapture, call: Call) -> Option<Done> {
    match call {
        Call::Start => {
            let started = capture.start();
            if started.is_err() {
                // A partial start must not leave the microphone open.
                capture.cancel();
            }
            Some(Done::Started(started))
        }
        Call::Stop => {
            let stopped = capture.stop();
            if stopped.is_err() {
                // Make sure the stream is closed whatever state it is in.
                capture.cancel();
            }
            Some(Done::Stopped(stopped.map(Audio::new)))
        }
        Call::Cancel => {
            capture.cancel();
            Some(Done::Cancelled)
        }
    }
}

fn failed(call: Call, why: &str) -> Option<Done> {
    let err = || IoError(why.into());
    match call {
        Call::Start => Some(Done::Started(Err(err()))),
        Call::Stop => Some(Done::Stopped(Err(err()))),
        Call::Cancel => None,
    }
}

/// Runs `call`, turning a panic into a failed call (and closing the stream).
fn run_guarded(capture: &mut dyn AudioCapture, call: Call) -> Option<Done> {
    match catch_unwind(AssertUnwindSafe(|| run(&mut *capture, call))) {
        Ok(done) => done,
        Err(_) => {
            let _ = catch_unwind(AssertUnwindSafe(|| capture.cancel()));
            failed(call, "audio capture panicked")
        }
    }
}

/// Runs every call at once, on the caller's thread.
pub struct Inline {
    capture: Box<dyn AudioCapture>,
    done: VecDeque<CaptureEvent>,
}

impl Inline {
    pub fn new(capture: Box<dyn AudioCapture>) -> Inline {
        Inline {
            capture,
            done: VecDeque::new(),
        }
    }
}

impl CapturePort for Inline {
    fn send(&mut self, generation: u64, call: Call) {
        if let Some(done) = run_guarded(&mut *self.capture, call) {
            self.done.push_back(CaptureEvent { generation, done });
        }
    }

    fn poll(&mut self) -> Option<CaptureEvent> {
        self.done.pop_front()
    }

    fn level(&self) -> f32 {
        self.capture.level()
    }

    fn input_available(&self) -> Option<bool> {
        self.capture.input_available()
    }
}

fn lock(m: &Mutex<Box<dyn AudioCapture>>) -> MutexGuard<'_, Box<dyn AudioCapture>> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// The capture thread, seen from the controller.
pub struct CaptureThread {
    calls: Sender<(u64, Call)>,
    /// The newest recording cancelled. Recordings are numbered in order
    /// and only the current one is ever cancelled, so every recording up
    /// to it is over.
    cancelled: Arc<AtomicU64>,
    /// Shared with the thread, which holds the lock only during a call.
    capture: Arc<Mutex<Box<dyn AudioCapture>>>,
    /// Failures for calls the thread could not take (it is gone).
    failed: VecDeque<CaptureEvent>,
    /// The last readings, answered while a call holds the capture.
    level: Cell<f32>,
    input: Cell<Option<bool>>,
}

impl CaptureThread {
    /// Reads from the capture unless a call holds it.
    fn read<T>(&self, f: impl FnOnce(&dyn AudioCapture) -> T) -> Option<T> {
        match self.capture.try_lock() {
            Ok(c) => Some(f(&**c)),
            Err(TryLockError::Poisoned(p)) => Some(f(&**p.into_inner())),
            Err(TryLockError::WouldBlock) => None,
        }
    }
}

impl CapturePort for CaptureThread {
    fn send(&mut self, generation: u64, call: Call) {
        match call {
            // A new recording never shows the last one's level.
            Call::Start => self.level.set(0.0),
            // Before sending, so the thread skips this recording's queued
            // calls.
            Call::Cancel => {
                self.cancelled.fetch_max(generation, Ordering::AcqRel);
            }
            Call::Stop => {}
        }
        if self.calls.send((generation, call)).is_err()
            && let Some(done) = failed(call, "the audio capture thread has stopped")
        {
            self.failed.push_back(CaptureEvent { generation, done });
        }
    }

    fn poll(&mut self) -> Option<CaptureEvent> {
        self.failed.pop_front()
    }

    fn level(&self) -> f32 {
        if let Some(level) = self.read(|c| c.level()) {
            self.level.set(level);
        }
        self.level.get()
    }

    fn input_available(&self) -> Option<bool> {
        if let Some(input) = self.read(|c| c.input_available()) {
            self.input.set(input);
        }
        self.input.get()
    }
}

pub struct CaptureJoin {
    /// Disconnects when the thread ends (also on a panic).
    done: Receiver<()>,
    thread: JoinHandle<()>,
}

impl CaptureJoin {
    /// Waits up to `timeout` for the thread to run the calls still queued
    /// and close the capture; it does so once the [`CaptureThread`] is
    /// dropped. A thread stuck in a call is left to finish on its own (its
    /// audio is wiped when it does). Returns whether it finished.
    pub fn join(self, timeout: Duration) -> bool {
        match self.done.recv_timeout(timeout) {
            Err(RecvTimeoutError::Disconnected) | Ok(()) => {
                let _ = self.thread.join();
                true
            }
            Err(RecvTimeoutError::Timeout) => {
                crate::warn!("audio capture: still busy at shutdown; not waiting");
                false
            }
        }
    }
}

/// Starts the capture thread. `deliver` gets every result, on that thread.
pub fn spawn(
    capture: Box<dyn AudioCapture>,
    deliver: impl Fn(CaptureEvent) + Send + 'static,
) -> std::io::Result<(CaptureThread, CaptureJoin)> {
    let input = capture.input_available();
    let capture = Arc::new(Mutex::new(capture));
    let shared = Arc::clone(&capture);
    let cancelled = Arc::new(AtomicU64::new(0));
    let skip = Arc::clone(&cancelled);
    let (calls, queued) = mpsc::channel::<(u64, Call)>();
    let (done_tx, done) = mpsc::channel::<()>();
    let thread = std::thread::Builder::new()
        .name("lf-capture".into())
        .spawn(move || {
            let _done = done_tx;
            while let Ok((generation, call)) = queued.recv() {
                if call != Call::Cancel && generation <= skip.load(Ordering::Acquire) {
                    continue;
                }
                let result = run_guarded(&mut **lock(&shared), call);
                if let Some(done) = result {
                    deliver(CaptureEvent { generation, done });
                }
            }
            // The controller is gone; it cancelled any recording first.
            // Closing again is harmless and covers a controller that
            // panicked.
            run_guarded(&mut **lock(&shared), Call::Cancel);
        })?;
    Ok((
        CaptureThread {
            calls,
            cancelled,
            capture,
            failed: VecDeque::new(),
            level: Cell::new(0.0),
            input: Cell::new(input),
        },
        CaptureJoin { done, thread },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::FakeCapture;

    #[test]
    fn a_failed_start_closes_the_stream_and_readings_never_wait_for_a_call() {
        let cap = FakeCapture::default();
        cap.state().fail_start = true;
        cap.state().input = Some(true);
        let gate = cap.gate_start();
        let (tx, rx) = mpsc::channel();
        let (mut port, join) = spawn(Box::new(cap.clone()), move |e| {
            let _ = tx.send(e);
        })
        .unwrap();
        port.send(1, Call::Start);
        gate.wait_entered(1);
        // The call holds the capture: the last readings are answered.
        cap.state().input = Some(false);
        assert_eq!((port.level(), port.input_available()), (0.0, Some(true)));
        gate.open();
        let e = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(matches!(e.done, Done::Started(Err(_))));
        assert_eq!(port.input_available(), Some(false));
        assert!(!cap.state().recording);
        assert_eq!(cap.state().cancels, 1);
        drop(port);
        assert!(join.join(Duration::from_secs(5)));
    }

    /// A start that never returns does not hold up shutdown beyond the
    /// timeout.
    #[test]
    fn joining_a_thread_stuck_in_a_call_is_bounded() {
        let cap = FakeCapture::default();
        let gate = cap.gate_start();
        let (mut port, join) = spawn(Box::new(cap.clone()), |_| {}).unwrap();
        port.send(1, Call::Start);
        gate.wait_entered(1);
        drop(port);
        assert!(!join.join(Duration::from_millis(50)));
        gate.open();
    }

    #[test]
    fn calls_after_the_thread_ended_fail_at_once() {
        struct Panics;
        impl AudioCapture for Panics {
            fn start(&mut self) -> Result<(), IoError> {
                panic!("synthetic")
            }
            fn stop(&mut self) -> Result<Vec<f32>, IoError> {
                panic!("synthetic")
            }
            fn cancel(&mut self) {}
        }
        // A panicking capture fails the call; the thread goes on.
        let (tx, rx) = mpsc::channel();
        let (mut port, join) = spawn(Box::new(Panics), move |e| {
            let _ = tx.send(e);
        })
        .unwrap();
        port.send(1, Call::Start);
        let e = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(matches!(e.done, Done::Started(Err(_))));
        port.send(2, Call::Stop);
        let e = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(matches!(e.done, Done::Stopped(Err(_))));
        assert!(port.poll().is_none());

        // With the thread gone, a call fails through `poll`.
        let (calls, _) = mpsc::channel();
        port.calls = calls;
        port.send(3, Call::Start);
        port.send(3, Call::Cancel);
        let e = port.poll().unwrap();
        assert!(e.generation == 3 && matches!(e.done, Done::Started(Err(_))));
        assert!(port.poll().is_none());
        drop(port);
        assert!(join.join(Duration::from_secs(5)));
    }
}

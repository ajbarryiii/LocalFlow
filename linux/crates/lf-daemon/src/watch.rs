//! `watch` subscribers, owned by the control loop.
//!
//! - **Admission is bounded on the socket thread.** [`Admission`] counts
//!   watchers connected plus watch connections queued for the control loop;
//!   at most [`MAX_WATCHERS`]. One more connection may be queued as an
//!   overflow, for which the control loop first reclaims watchers that went
//!   away (see below) and then admits or refuses it. Any further one is told
//!   `error busy` and closed by the socket thread at once, so queued watch
//!   connections (and their descriptors) never exceed `MAX_WATCHERS + 1`.
//! - The socket thread never keeps a watcher; the control loop sends each a
//!   watch line at once.
//! - After every event and timer the control loop calls
//!   [`Watchers::publish`], which sends a line to every watcher when the
//!   state, mode, model readiness or microphone presence changed, and every
//!   [`LEVEL_INTERVAL`] while recording (the level meter).
//! - Sends never block: `MSG_DONTWAIT`, and a small send buffer per watcher.
//!   A watcher whose buffer is full, that closed, or that failed is dropped,
//!   so a stuck client can never delay key handling.
//! - **Gone watchers:** a send to a watcher that closed, or shut down its
//!   reading side, fails and drops it. While idle nothing is sent, so the
//!   overflow admission first probes every watcher (a poll for hang-up, and
//!   a zero-length send, which fails once the peer can no longer receive).
//!   A watcher that only shut down its writing side still receives, so it
//!   stays subscribed.
//! - **Logging:** the control loop logs nothing about watchers. Refusals are
//!   counted and the socket thread reports the count at most once every
//!   [`REFUSAL_REPORT_INTERVAL`], so a client cannot flood the log.
//!
//! Watch lines carry state names, microphone presence and a level number
//! only: never text, notes or player names.

use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::protocol::{ErrorCode, Reply, State, Status, WatchStatus, level_percent};

pub const MAX_WATCHERS: usize = 8;

/// Level lines while recording: about 15 a second.
pub const LEVEL_INTERVAL: Duration = Duration::from_millis(66);

/// Requested send buffer per watcher (the kernel doubles it). Bounds how far
/// a watcher can fall behind before it is dropped: on the order of a hundred
/// lines, several seconds of level lines.
pub const SEND_BUFFER: usize = 64 * 1024;

/// Refused watchers are logged as a count at most this often.
pub const REFUSAL_REPORT_INTERVAL: Duration = Duration::from_secs(60);

/// Watcher slots, shared by the socket thread and the control loop.
pub struct Admission {
    cap: usize,
    /// Watchers connected plus watch connections queued with a slot.
    used: AtomicUsize,
    /// An over-cap connection is queued for the control loop.
    overflow: AtomicBool,
    /// Refusals not yet reported.
    refused: AtomicU64,
    /// When refusals were last reported (socket thread only).
    reported: Mutex<Option<Instant>>,
}

impl Admission {
    pub fn new(cap: usize) -> Arc<Admission> {
        Arc::new(Admission {
            cap,
            used: AtomicUsize::new(0),
            overflow: AtomicBool::new(false),
            refused: AtomicU64::new(0),
            reported: Mutex::new(None),
        })
    }

    /// Watchers connected plus queued with a slot.
    pub fn in_use(&self) -> usize {
        self.used.load(Ordering::Acquire)
    }

    /// Reserves room for a watch connection: a slot, or else the single
    /// overflow place. `Err` gives the stream back for [`Admission::refuse`].
    pub fn admit(self: &Arc<Self>, stream: UnixStream) -> Result<NewWatcher, UnixStream> {
        let ticket = if let Some(slot) = self.reserve() {
            Ticket::Slot(slot)
        } else if !self.overflow.swap(true, Ordering::AcqRel) {
            Ticket::Overflow(OverflowGuard(Arc::clone(self)))
        } else {
            return Err(stream);
        };
        Ok(NewWatcher { stream, ticket })
    }

    fn reserve(self: &Arc<Self>) -> Option<Slot> {
        self.used
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                (n < self.cap).then_some(n + 1)
            })
            .ok()
            .map(|_| Slot(Arc::clone(self)))
    }

    /// Answers `error busy` (without waiting) and closes the connection.
    /// Counts the refusal; nothing is logged here.
    pub fn refuse(&self, stream: UnixStream) {
        send_now(&stream, Reply::Error(ErrorCode::Busy).to_line().as_bytes());
        self.refused.fetch_add(1, Ordering::Relaxed);
    }

    /// Logs the refusals counted since the last report, at most once every
    /// [`REFUSAL_REPORT_INTERVAL`]. Called by the socket thread only.
    pub fn report_refusals(&self, now: Instant) {
        let mut reported = self.reported.lock().unwrap_or_else(|e| e.into_inner());
        if reported.is_some_and(|t| now.saturating_duration_since(t) < REFUSAL_REPORT_INTERVAL) {
            return;
        }
        let n = self.refused.swap(0, Ordering::Relaxed);
        if n > 0 {
            *reported = Some(now);
            crate::warn!(
                "refused {n} status watcher(s): {} already connected",
                self.cap
            );
        }
    }
}

/// A watcher slot; released when dropped.
struct Slot(Arc<Admission>);

impl Drop for Slot {
    fn drop(&mut self) {
        self.0.used.fetch_sub(1, Ordering::AcqRel);
    }
}

/// The overflow place; freed when dropped.
struct OverflowGuard(Arc<Admission>);

impl Drop for OverflowGuard {
    fn drop(&mut self) {
        self.0.overflow.store(false, Ordering::Release);
    }
}

enum Ticket {
    Slot(Slot),
    Overflow(OverflowGuard),
}

/// An admitted watch connection on its way to the control loop.
pub struct NewWatcher {
    stream: UnixStream,
    ticket: Ticket,
}

impl NewWatcher {
    /// The connection, giving up its reservation.
    pub fn into_stream(self) -> UnixStream {
        self.stream
    }
}

struct Watcher {
    stream: UnixStream,
    _slot: Slot,
}

/// What the control loop reports, for one round of publishing.
#[derive(Clone, Copy, Debug)]
pub struct Snapshot {
    pub status: Status,
    /// See `AudioCapture::input_available`.
    pub mic: Option<bool>,
    /// Input level in [0, 1]; sent only while recording.
    pub level: f32,
}

impl Snapshot {
    fn recording(&self) -> bool {
        self.status.state == State::Recording
    }

    fn key(&self) -> (Status, Option<bool>) {
        (self.status, self.mic)
    }

    fn line(&self) -> String {
        WatchStatus {
            status: self.status,
            mic: self.mic,
            level: self.recording().then(|| level_percent(self.level)),
        }
        .to_line()
    }
}

pub struct Watchers {
    admission: Arc<Admission>,
    watchers: Vec<Watcher>,
    send_buffer: usize,
    /// Status and presence last published (sent or not).
    last: Option<(Status, Option<bool>)>,
    /// When the next level line is due; set only while recording with
    /// watchers connected.
    next_level: Option<Instant>,
}

impl Watchers {
    pub fn new(admission: Arc<Admission>) -> Watchers {
        Watchers::with_send_buffer(admission, SEND_BUFFER)
    }

    pub fn with_send_buffer(admission: Arc<Admission>, send_buffer: usize) -> Watchers {
        Watchers {
            admission,
            watchers: Vec::new(),
            send_buffer,
            last: None,
            next_level: None,
        }
    }

    pub fn len(&self) -> usize {
        self.watchers.len()
    }

    pub fn is_empty(&self) -> bool {
        self.watchers.is_empty()
    }

    /// When [`Watchers::publish`] next needs to run (a level line is due).
    pub fn next_deadline(&self) -> Option<Instant> {
        self.next_level
    }

    /// Takes an admitted watcher and sends it the current watch line. An
    /// overflow admission first drops watchers that went away, then takes a
    /// freed slot or refuses with `error busy`.
    pub fn add(&mut self, new: NewWatcher, snap: Snapshot, now: Instant) {
        // Bring the others up to date first, so the new watcher's first line
        // is also everyone's latest.
        self.publish(snap, now);
        let NewWatcher { stream, ticket } = new;
        let slot = match ticket {
            Ticket::Slot(slot) => slot,
            Ticket::Overflow(guard) => {
                self.drop_gone();
                let slot = self.admission.reserve();
                drop(guard);
                match slot {
                    Some(slot) => slot,
                    None => {
                        self.admission.refuse(stream);
                        return;
                    }
                }
            }
        };
        set_send_buffer(&stream, self.send_buffer);
        if !send_now(&stream, snap.line().as_bytes()) {
            return;
        }
        self.watchers.push(Watcher {
            stream,
            _slot: slot,
        });
        if snap.recording() && self.next_level.is_none() {
            self.next_level = Some(now + LEVEL_INTERVAL);
        }
    }

    /// Sends the watch line when the status or presence changed, or when a
    /// level line is due. Watchers that cannot take it are dropped.
    pub fn publish(&mut self, snap: Snapshot, now: Instant) {
        let changed = self.last != Some(snap.key());
        self.last = Some(snap.key());
        if self.watchers.is_empty() || !snap.recording() {
            self.next_level = None;
        }
        if self.watchers.is_empty() {
            return;
        }
        let level_due = snap.recording() && self.next_level.is_none_or(|t| now >= t);
        if !(changed || level_due) {
            return;
        }
        let line = snap.line();
        self.watchers
            .retain(|w| send_now(&w.stream, line.as_bytes()));
        self.next_level =
            (snap.recording() && !self.watchers.is_empty()).then_some(now + LEVEL_INTERVAL);
    }

    /// Drops watchers that hung up or can no longer receive (without
    /// waiting). One that is merely slow to read stays.
    fn drop_gone(&mut self) {
        if self.watchers.is_empty() {
            return;
        }
        let mut fds: Vec<libc::pollfd> = self
            .watchers
            .iter()
            .map(|w| libc::pollfd {
                fd: w.stream.as_raw_fd(),
                // POLLHUP and POLLERR are always reported.
                events: 0,
                revents: 0,
            })
            .collect();
        // SAFETY: `fds` is a valid array of `fds.len()` pollfds; no wait.
        let n = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, 0) };
        let mut hung_up = fds
            .iter()
            .map(|p| n > 0 && p.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0);
        self.watchers
            .retain(|w| !hung_up.next().unwrap_or(false) && can_receive(&w.stream));
        if self.watchers.is_empty() {
            self.next_level = None;
        }
    }
}

/// A zero-length send: fails (`EPIPE`) once the peer closed or shut down
/// its reading side, and succeeds, sending nothing, even when the buffer is
/// full.
fn can_receive(stream: &UnixStream) -> bool {
    send_now(stream, &[])
}

/// Writes all of `line` at once or reports failure. Never blocks, and never
/// raises SIGPIPE.
fn send_now(stream: &UnixStream, line: &[u8]) -> bool {
    loop {
        // SAFETY: send on a valid descriptor from a buffer of `line.len()`
        // valid bytes.
        let n = unsafe {
            libc::send(
                stream.as_raw_fd(),
                line.as_ptr().cast(),
                line.len(),
                libc::MSG_DONTWAIT | libc::MSG_NOSIGNAL,
            )
        };
        if n < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        // A short write leaves a partial line behind: the watcher is
        // dropped, so it sees the connection close rather than a bad line.
        return n >= 0 && n as usize == line.len();
    }
}

fn set_send_buffer(stream: &UnixStream, bytes: usize) {
    let size = libc::c_int::try_from(bytes).unwrap_or(libc::c_int::MAX);
    // SAFETY: setsockopt on a valid descriptor with a c_int of the size
    // passed.
    unsafe {
        libc::setsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_SNDBUF,
            (&size as *const libc::c_int).cast(),
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        )
    };
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::Mode;
    use std::io::{ErrorKind, Read};
    use std::net::Shutdown;

    fn snap(state: State, mic: Option<bool>, level: f32) -> Snapshot {
        Snapshot {
            status: Status {
                state,
                mode: (state == State::Recording).then_some(Mode::Hold),
                prompt: false,
                model_ready: true,
            },
            mic,
            level,
        }
    }

    fn watchers(cap: usize) -> Watchers {
        Watchers::new(Admission::new(cap))
    }

    /// Whatever the client has received so far, without waiting.
    fn received(client: &mut UnixStream) -> String {
        client.set_nonblocking(true).unwrap();
        let mut out = Vec::new();
        let mut buf = [0u8; 4096];
        loop {
            match client.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => out.extend_from_slice(&buf[..n]),
                Err(e) if e.kind() == ErrorKind::WouldBlock => break,
                Err(e) => panic!("{e}"),
            }
        }
        String::from_utf8(out).unwrap()
    }

    fn closed(client: &mut UnixStream) -> bool {
        client.set_nonblocking(true).unwrap();
        let mut buf = [0u8; 4096];
        loop {
            match client.read(&mut buf) {
                Ok(0) => return true,
                Ok(_) => continue,
                Err(_) => return false,
            }
        }
    }

    /// Admits a new connection as the socket thread would, and hands it to
    /// `w` (or refuses it, as the socket thread would).
    fn watcher(w: &mut Watchers, s: Snapshot, now: Instant) -> UnixStream {
        let (server, client) = UnixStream::pair().unwrap();
        match w.admission.admit(server) {
            Ok(new) => w.add(new, s, now),
            Err(stream) => w.admission.refuse(stream),
        }
        client
    }

    #[test]
    fn sends_the_current_line_then_only_changes() {
        let t = Instant::now();
        let mut w = watchers(MAX_WATCHERS);
        let idle = snap(State::Idle, Some(true), 0.0);
        w.publish(idle, t);
        let mut c = watcher(&mut w, idle, t);
        assert_eq!(
            received(&mut c),
            "localflow/1 ok state=idle model=ready mic=present\n"
        );
        w.publish(idle, t);
        w.publish(idle, t + Duration::from_secs(5));
        assert_eq!(received(&mut c), "");
        assert_eq!(w.next_deadline(), None, "no wakeups while idle");
        w.publish(snap(State::Idle, Some(false), 0.0), t);
        w.publish(snap(State::Transcribing, Some(false), 0.0), t);
        assert_eq!(
            received(&mut c),
            "localflow/1 ok state=idle model=ready mic=absent\n\
             localflow/1 ok state=transcribing model=ready mic=absent\n"
        );
    }

    #[test]
    fn level_lines_flow_only_while_recording_with_watchers() {
        let t = Instant::now();
        let mut w = watchers(MAX_WATCHERS);
        let rec = snap(State::Recording, None, 0.25);
        // Nobody watching: no level deadline.
        w.publish(rec, t);
        assert_eq!(w.next_deadline(), None);

        let mut c = watcher(&mut w, rec, t);
        assert_eq!(
            received(&mut c),
            "localflow/1 ok state=recording mode=hold model=ready mic=unknown level=25\n"
        );
        assert_eq!(w.next_deadline(), Some(t + LEVEL_INTERVAL));
        // Not due yet.
        w.publish(rec, t + LEVEL_INTERVAL / 2);
        assert_eq!(received(&mut c), "");
        // Due: sent even though nothing changed (the meter keeps scrolling).
        let t1 = t + LEVEL_INTERVAL;
        w.publish(rec, t1);
        w.publish(snap(State::Recording, None, 0.5), t1 + LEVEL_INTERVAL);
        assert_eq!(
            received(&mut c),
            "localflow/1 ok state=recording mode=hold model=ready mic=unknown level=25\n\
             localflow/1 ok state=recording mode=hold model=ready mic=unknown level=50\n"
        );
        assert_eq!(w.next_deadline(), Some(t1 + 2 * LEVEL_INTERVAL));
        // Recording ends: one line, no more deadline, no level field.
        w.publish(snap(State::Transcribing, None, 0.5), t1 + LEVEL_INTERVAL);
        assert_eq!(
            received(&mut c),
            "localflow/1 ok state=transcribing model=ready mic=unknown\n"
        );
        assert_eq!(w.next_deadline(), None);

        // The last watcher leaving stops the level timer.
        w.publish(rec, t1);
        assert!(w.next_deadline().is_some());
        drop(c);
        w.publish(rec, t1 + 2 * LEVEL_INTERVAL);
        assert!(w.is_empty());
        assert_eq!(w.next_deadline(), None);
    }

    #[test]
    fn a_watcher_that_never_reads_is_dropped_without_blocking() {
        // A blocking send would hang this test rather than fail it; the
        // sends are non-blocking, so it runs to the drop.
        let t = Instant::now();
        let admission = Admission::new(MAX_WATCHERS);
        let mut w = Watchers::with_send_buffer(admission.clone(), 4096);
        let mut stuck = watcher(&mut w, snap(State::Idle, None, 0.0), t);
        let mut reader = watcher(&mut w, snap(State::Idle, None, 0.0), t);
        let mut lines = 0;
        let mut flips = 0;
        while w.len() == 2 {
            flips += 1;
            assert!(flips < 100_000, "never dropped");
            let state = if flips % 2 == 1 {
                State::Typing
            } else {
                State::Idle
            };
            w.publish(snap(state, None, 0.0), t);
            lines += received(&mut reader).lines().count();
        }
        assert_eq!(w.len(), 1);
        assert_eq!(admission.in_use(), 1, "the slot was released");
        lines += received(&mut reader).lines().count();
        assert_eq!(lines, flips + 1, "the reading watcher missed nothing");
        // The stuck one gets what fit, then the close; never a partial line.
        let mut got = String::new();
        stuck.set_nonblocking(false).unwrap();
        stuck.read_to_string(&mut got).unwrap();
        assert!(got.ends_with('\n') && got.lines().count() <= flips);
    }

    #[test]
    fn admission_counts_queued_watchers_and_allows_one_overflow() {
        let a = Admission::new(2);
        let conn = || UnixStream::pair().unwrap().0;
        // Admitted but not yet taken by the control loop: still counted.
        let first = a.admit(conn()).ok().unwrap();
        let second = a.admit(conn()).ok().unwrap();
        assert_eq!(a.in_use(), 2);
        let overflow = a.admit(conn()).ok().unwrap();
        assert!(matches!(overflow.ticket, Ticket::Overflow(_)));
        // Everything else is refused on the spot, however many arrive.
        for _ in 0..100 {
            assert!(a.admit(conn()).is_err());
        }
        assert_eq!(a.in_use(), 2);
        // Giving up a reservation frees it.
        drop(first.into_stream());
        assert_eq!(a.in_use(), 1);
        drop(overflow);
        let third = a.admit(conn()).ok().unwrap();
        assert!(matches!(third.ticket, Ticket::Slot(_)));
        assert!(matches!(
            a.admit(conn()).ok().unwrap().ticket,
            Ticket::Overflow(_)
        ));
        drop((second, third));
        assert_eq!(a.in_use(), 0);
    }

    #[test]
    fn refusals_are_reported_as_a_rate_limited_count() {
        let a = Admission::new(1);
        let t = Instant::now();
        for _ in 0..5 {
            a.refuse(UnixStream::pair().unwrap().0);
        }
        a.report_refusals(t);
        assert_eq!(a.refused.load(Ordering::Relaxed), 0);
        // More refusals within the interval are held, not logged.
        for _ in 0..3 {
            a.refuse(UnixStream::pair().unwrap().0);
            a.report_refusals(t + Duration::from_secs(1));
        }
        assert_eq!(a.refused.load(Ordering::Relaxed), 3);
        a.report_refusals(t + REFUSAL_REPORT_INTERVAL);
        assert_eq!(a.refused.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn the_cap_is_enforced_and_gone_watchers_make_room() {
        let t = Instant::now();
        let idle = snap(State::Idle, Some(true), 0.0);
        let mut w = watchers(2);
        let mut a = watcher(&mut w, idle, t);
        let b = watcher(&mut w, idle, t);
        // Over the cap with nobody gone: the overflow is refused too.
        let mut refused = watcher(&mut w, idle, t);
        assert_eq!(w.len(), 2);
        assert_eq!(received(&mut refused), "localflow/1 error busy\n");
        assert!(closed(&mut refused));

        // A watcher that closed is reclaimed by the next arrival, even with
        // nothing published in between.
        drop(b);
        let mut c = watcher(&mut w, idle, t);
        assert_eq!(w.len(), 2);
        assert_eq!(
            received(&mut c),
            "localflow/1 ok state=idle model=ready mic=present\n"
        );
        received(&mut a);
        // And on the next change, a failed send drops it too.
        drop(a);
        w.publish(snap(State::Typing, Some(true), 0.0), t);
        assert_eq!(w.len(), 1);
        assert_eq!(w.admission.in_use(), 1);
        assert!(!closed(&mut c));
    }

    #[test]
    fn a_watcher_that_stops_reading_is_reclaimed_but_one_that_stops_writing_is_not() {
        let t = Instant::now();
        let idle = snap(State::Idle, None, 0.0);
        let mut w = watchers(2);
        // Shut down its reading side: it can never receive again, though
        // the socket is not closed (no hang-up is reported for this).
        let deaf = watcher(&mut w, idle, t);
        deaf.shutdown(Shutdown::Read).unwrap();
        // Shut down its writing side only: still a valid watcher.
        let mut quiet = watcher(&mut w, idle, t);
        quiet.shutdown(Shutdown::Write).unwrap();
        assert_eq!(w.len(), 2);

        let mut next = watcher(&mut w, idle, t);
        assert_eq!(
            received(&mut next),
            "localflow/1 ok state=idle model=ready mic=unknown\n"
        );
        assert_eq!(w.len(), 2);
        // `quiet` kept its place and still gets updates.
        received(&mut quiet);
        w.publish(snap(State::Typing, None, 0.0), t);
        assert_eq!(
            received(&mut quiet),
            "localflow/1 ok state=typing model=ready mic=unknown\n"
        );
        drop(deaf);
    }

    #[test]
    fn a_full_but_alive_watcher_is_not_reclaimed() {
        let t = Instant::now();
        let mut w = Watchers::with_send_buffer(Admission::new(1), 4096);
        let _stuck = watcher(&mut w, snap(State::Idle, None, 0.0), t);
        // Fill its buffer without dropping it: write directly.
        let s = &w.watchers[0].stream;
        while send_now(s, b"localflow/1 ok state=idle model=ready mic=unknown\n") {}
        assert!(
            can_receive(s),
            "a zero-length send succeeds on a full buffer"
        );
        let mut refused = watcher(&mut w, snap(State::Idle, None, 0.0), t);
        assert_eq!(received(&mut refused), "localflow/1 error busy\n");
        assert_eq!(w.len(), 1);
    }
}

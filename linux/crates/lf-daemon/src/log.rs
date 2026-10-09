//! Minimal leveled logging to stderr.
//!
//! Privacy rule for every call site: log states, durations, error kinds and
//! configuration problems only. Never transcripts, macro text, typed text,
//! audio, or anything derived from their content (such as lengths or
//! levels). journald persists stderr.
//!
//! Under systemd (`JOURNAL_STREAM` set) lines carry `<N>` syslog priority
//! prefixes so journald records the level.
//!
//! Logging never blocks the caller: lines go through a bounded queue to a
//! logger thread (see [`Logger`]). If stderr stalls (a pipe nobody reads),
//! lines are dropped and counted instead of stalling key handling; a note
//! with the count follows once output moves again (a warning, filtered and
//! formatted like any other). `localflowd` calls [`flush`] before it exits,
//! with a bounded wait, and replaces the default panic hook (which writes to
//! stderr synchronously) with [`panic_hook`], which logs the thread name and
//! location through the same queue and never the formatted panic message.

use std::io::Write;
use std::sync::atomic::{AtomicU8, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Error = 0,
    Warn = 1,
    Info = 2,
    Debug = 3,
}

impl Level {
    pub fn parse(s: &str) -> Option<Level> {
        Some(match s {
            "error" => Level::Error,
            "warn" => Level::Warn,
            "info" => Level::Info,
            "debug" => Level::Debug,
            _ => return None,
        })
    }

    fn label(self) -> &'static str {
        match self {
            Level::Error => "error",
            Level::Warn => "warning",
            Level::Info => "info",
            Level::Debug => "debug",
        }
    }

    fn syslog(self) -> u8 {
        match self {
            Level::Error => 3,
            Level::Warn => 4,
            Level::Info => 6,
            Level::Debug => 7,
        }
    }
}

static LEVEL: AtomicU8 = AtomicU8::new(Level::Info as u8);

pub fn set_level(level: Level) {
    LEVEL.store(level as u8, Ordering::Relaxed);
}

pub fn enabled(level: Level) -> bool {
    level as u8 <= LEVEL.load(Ordering::Relaxed)
}

/// Whether stderr is the journal stream systemd connected (`JOURNAL_STREAM`
/// names its device and inode; a child started from such a service inherits
/// the variable but may have a different stderr).
fn journal() -> bool {
    static JOURNAL: OnceLock<bool> = OnceLock::new();
    *JOURNAL.get_or_init(|| {
        let Some(value) = std::env::var_os("JOURNAL_STREAM") else {
            return false;
        };
        let Some((dev, ino)) = value.to_str().and_then(|s| s.split_once(':')) else {
            return false;
        };
        let (Ok(dev), Ok(ino)) = (dev.parse::<u64>(), ino.parse::<u64>()) else {
            return false;
        };
        // SAFETY: fstat writes into a zeroed, correctly sized stat buffer.
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe { libc::fstat(libc::STDERR_FILENO, &mut st) } != 0 {
            return false;
        }
        st.st_dev == dev && st.st_ino == ino
    })
}

#[doc(hidden)]
pub fn write(level: Level, args: std::fmt::Arguments<'_>) {
    if !enabled(level) {
        return;
    }
    global().submit(format_line(level, args));
}

/// One log line as written, with its newline: a journald priority prefix
/// under systemd, `localflowd <level>: ` otherwise.
fn format_line(level: Level, args: std::fmt::Arguments<'_>) -> String {
    if journal() {
        format!("<{}>{args}\n", level.syslog())
    } else {
        format!("localflowd {}: {args}\n", level.label())
    }
}

/// The daemon's drop note: a warning, subject to the configured level.
fn drop_note(n: u64) -> Option<String> {
    enabled(Level::Warn).then(|| {
        format_line(
            Level::Warn,
            format_args!("{n} log lines dropped (output stalled)"),
        )
    })
}

/// Replaces the default panic hook, which writes to stderr synchronously
/// (and so could block a daemon thread on a stalled stderr), with one that
/// logs through the non-blocking logger. Call before any thread starts.
pub fn install_panic_hook() {
    std::panic::set_hook(Box::new(panic_hook));
}

/// See [`install_panic_hook`].
pub fn panic_hook(info: &std::panic::PanicHookInfo<'_>) {
    let thread = std::thread::current();
    write(
        Level::Error,
        format_args!("{}", panic_line(thread.name(), info.location())),
    );
}

/// The logged panic message: thread name and source location only. The
/// payload is never logged: a formatted one (`expect`, `panic!` with
/// arguments) may include values such as recognized text, and even a
/// `&'static str` is not guaranteed to be a literal (`Box::leak` +
/// `panic_any`). The location identifies the panic site.
pub fn panic_line(thread: Option<&str>, location: Option<&std::panic::Location<'_>>) -> String {
    let mut line = format!("thread '{}' panicked", thread.unwrap_or("<unnamed>"));
    if let Some(l) = location {
        line += &format!(" at {}:{}:{}", l.file(), l.line(), l.column());
    }
    line
}

/// Lines the logger thread may hold before new ones are dropped.
pub const QUEUE_LINES: usize = 256;

/// How long the logger thread waits for more lines before it reports
/// dropped ones on its own.
const IDLE_REPORT: Duration = Duration::from_millis(100);

/// A logger that never blocks its callers: lines go through a bounded queue
/// to a thread that writes them to `sink`. When the queue is full (the sink
/// is slow or stalled, e.g. a stderr pipe nobody reads) lines are dropped
/// and counted, and a single "N log lines dropped" note is written once the
/// sink takes lines again.
pub struct Logger {
    /// `None` if the thread could not start: lines are then dropped.
    queue: Option<SyncSender<String>>,
    shared: Arc<LoggerState>,
}

#[derive(Default)]
struct LoggerState {
    /// Lines queued or being written, drop notes being written included.
    pending: AtomicUsize,
    /// Dropped lines not yet reported in a note.
    unreported: AtomicU64,
    /// All lines ever dropped.
    dropped: AtomicU64,
}

impl Logger {
    /// Starts the logger thread, writing to `sink`. `note` formats the drop
    /// note for a count of dropped lines (with its newline), or returns
    /// `None` to leave it out.
    pub fn spawn(
        sink: impl Write + Send + 'static,
        capacity: usize,
        note: impl Fn(u64) -> Option<String> + Send + 'static,
    ) -> Logger {
        let (tx, rx) = mpsc::sync_channel::<String>(capacity);
        let shared = Arc::new(LoggerState::default());
        let state = Arc::clone(&shared);
        let started = std::thread::Builder::new()
            .name("lf-log".into())
            .spawn(move || run_logger(sink, &rx, &state, capacity, note));
        Logger {
            queue: started.is_ok().then_some(tx),
            shared,
        }
    }

    /// Queues `line` (with its newline), or drops it if the queue is full.
    /// Never blocks.
    pub fn submit(&self, line: String) {
        let Some(queue) = &self.queue else {
            self.drop_line();
            return;
        };
        self.shared.pending.fetch_add(1, Ordering::AcqRel);
        if queue.try_send(line).is_err() {
            self.shared.pending.fetch_sub(1, Ordering::AcqRel);
            self.drop_line();
        }
    }

    fn drop_line(&self) {
        self.shared.unreported.fetch_add(1, Ordering::AcqRel);
        self.shared.dropped.fetch_add(1, Ordering::AcqRel);
    }

    /// Lines dropped so far because the sink could not keep up.
    pub fn dropped(&self) -> u64 {
        self.shared.dropped.load(Ordering::Acquire)
    }

    /// Waits until every queued line (and any drop note) is written, at most
    /// `timeout`. Returns whether everything was written; a stalled sink
    /// makes it give up rather than wait.
    pub fn flush(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            // The count first: the logger marks a note pending before it
            // takes the count, so once the count reads zero, a note still
            // being written shows up as pending.
            let reported =
                self.queue.is_none() || self.shared.unreported.load(Ordering::Acquire) == 0;
            let done = reported && self.shared.pending.load(Ordering::Acquire) == 0;
            if done {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
    }
}

/// The logger thread. A drop note is written once every line that was
/// queued when the drops were noticed is out: when the queue runs empty,
/// after `capacity` more lines, or when no line arrives for a while.
fn run_logger(
    mut sink: impl Write,
    rx: &Receiver<String>,
    state: &LoggerState,
    capacity: usize,
    note: impl Fn(u64) -> Option<String>,
) {
    let report = |sink: &mut dyn Write| {
        // Counted as pending before the count is taken, so `flush` cannot
        // see neither a count nor a pending write while the note is out.
        state.pending.fetch_add(1, Ordering::AcqRel);
        let n = state.unreported.swap(0, Ordering::AcqRel);
        if n > 0
            && let Some(line) = note(n)
        {
            let _ = sink.write_all(line.as_bytes());
            let _ = sink.flush();
        }
        state.pending.fetch_sub(1, Ordering::AcqRel);
    };
    let mut written = 0usize;
    // `written` when unreported drops were first seen.
    let mut drops_seen: Option<usize> = None;
    loop {
        match rx.recv_timeout(IDLE_REPORT) {
            Ok(line) => {
                if drops_seen.is_none() && state.unreported.load(Ordering::Acquire) > 0 {
                    drops_seen = Some(written);
                }
                let _ = sink.write_all(line.as_bytes());
                let _ = sink.flush();
                written += 1;
                let left = state.pending.fetch_sub(1, Ordering::AcqRel) - 1;
                if drops_seen.is_some_and(|seen| left == 0 || written - seen >= capacity) {
                    report(&mut sink);
                    drops_seen = None;
                }
            }
            Err(RecvTimeoutError::Timeout) => {
                report(&mut sink);
                drops_seen = None;
            }
            Err(RecvTimeoutError::Disconnected) => {
                report(&mut sink);
                return;
            }
        }
    }
}

/// The daemon's logger, writing to stderr; started on first use.
fn global() -> &'static Logger {
    static LOGGER: OnceLock<Logger> = OnceLock::new();
    LOGGER.get_or_init(|| Logger::spawn(std::io::stderr(), QUEUE_LINES, drop_note))
}

/// Lines the daemon's logger dropped so far.
pub fn dropped() -> u64 {
    global().dropped()
}

/// Writes what the daemon's logger still holds, waiting at most `timeout`.
/// Call before the process exits.
pub fn flush(timeout: Duration) -> bool {
    global().flush(timeout)
}

#[macro_export]
macro_rules! error {
    ($($t:tt)*) => { $crate::log::write($crate::log::Level::Error, format_args!($($t)*)) };
}

#[macro_export]
macro_rules! warn {
    ($($t:tt)*) => { $crate::log::write($crate::log::Level::Warn, format_args!($($t)*)) };
}

#[macro_export]
macro_rules! info {
    ($($t:tt)*) => { $crate::log::write($crate::log::Level::Info, format_args!($($t)*)) };
}

#[macro_export]
macro_rules! debug {
    ($($t:tt)*) => { $crate::log::write($crate::log::Level::Debug, format_args!($($t)*)) };
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// A sink that blocks every write until the test opens it, like a
    /// stderr pipe nobody reads.
    struct Gate {
        open: Receiver<()>,
        /// Told when the first write starts.
        entered: mpsc::Sender<()>,
        opened: bool,
        out: Arc<Mutex<Vec<u8>>>,
    }

    impl Write for Gate {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            if !self.opened {
                let _ = self.entered.send(());
                let _ = self.open.recv();
                self.opened = true;
            }
            self.out.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    type Output = Arc<Mutex<Vec<u8>>>;

    fn gated(capacity: usize) -> (Logger, mpsc::Sender<()>, Receiver<()>, Output) {
        let (tx, rx) = mpsc::channel();
        let (entered_tx, entered) = mpsc::channel();
        let out = Arc::new(Mutex::new(Vec::new()));
        let gate = Gate {
            open: rx,
            entered: entered_tx,
            opened: false,
            out: Arc::clone(&out),
        };
        (Logger::spawn(gate, capacity, test_note), tx, entered, out)
    }

    fn text(out: &Output) -> String {
        String::from_utf8(out.lock().unwrap().clone()).unwrap()
    }

    fn test_note(n: u64) -> Option<String> {
        Some(format!("synthetic note: {n} dropped\n"))
    }

    /// Writes instantly, except that the first line (so later ones are
    /// dropped) and a drop note take a while.
    struct SlowNotes(Output);

    impl Write for SlowNotes {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            if buf.starts_with(b"synthetic note") || buf == b"synthetic 0\n" {
                std::thread::sleep(Duration::from_millis(300));
            }
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn flush_waits_for_a_drop_note_being_written() {
        let out: Output = Arc::default();
        // A queue of one, flooded: some lines are dropped.
        let logger = Logger::spawn(SlowNotes(Arc::clone(&out)), 1, test_note);
        for i in 0..100 {
            logger.submit(format!("synthetic {i}\n"));
        }
        assert!(logger.dropped() > 0);
        assert!(logger.flush(Duration::from_secs(10)));
        let all = text(&out);
        assert!(
            all.ends_with(&format!("synthetic note: {} dropped\n", logger.dropped())),
            "{all}"
        );
    }

    #[test]
    fn drop_notes_follow_the_level_and_the_line_format() {
        // Leaving the note out still clears the count, so flush completes.
        let (logger, open, entered, out) = {
            let (tx, rx) = mpsc::channel();
            let (entered_tx, entered) = mpsc::channel();
            let out: Output = Arc::default();
            let gate = Gate {
                open: rx,
                entered: entered_tx,
                opened: false,
                out: Arc::clone(&out),
            };
            (Logger::spawn(gate, 1, |_| None), tx, entered, out)
        };
        logger.submit("synthetic 0\n".into());
        entered.recv().unwrap();
        for i in 1..10 {
            logger.submit(format!("synthetic {i}\n"));
        }
        assert_eq!(logger.dropped(), 8);
        open.send(()).unwrap();
        assert!(logger.flush(Duration::from_secs(10)));
        assert_eq!(text(&out), "synthetic 0\nsynthetic 1\n");

        // The daemon's note is a warning in the usual format, and is left
        // out when warnings are filtered.
        let note = drop_note(3).unwrap();
        assert_eq!(
            note,
            format_line(
                Level::Warn,
                format_args!("3 log lines dropped (output stalled)")
            )
        );
        // Plain stderr ("localflowd warning: ...") or the journal ("<4>...").
        assert!(note.ends_with("3 log lines dropped (output stalled)\n"));
        set_level(Level::Error);
        let filtered = drop_note(3);
        set_level(Level::Info);
        assert_eq!(filtered, None);
    }

    #[test]
    fn panic_lines_carry_only_thread_and_location() {
        let here = std::panic::Location::caller();
        assert_eq!(
            panic_line(Some("lf-recognizer"), Some(here)),
            format!(
                "thread 'lf-recognizer' panicked at {}:{}:{}",
                here.file(),
                here.line(),
                here.column()
            )
        );
        assert_eq!(panic_line(None, None), "thread '<unnamed>' panicked");
    }

    #[test]
    fn a_stalled_sink_never_blocks_callers_and_drops_are_reported() {
        let (logger, open, entered, out) = gated(4);
        logger.submit("synthetic line 0\n".into());
        // The logger thread is now stuck writing line 0.
        entered.recv().unwrap();
        // With the sink stalled, every submit still returns (a blocking one
        // would hang this test).
        for i in 1..1000 {
            logger.submit(format!("synthetic line {i}\n"));
        }
        // The line being written plus a full queue (lines 1-4) are kept.
        let dropped = logger.dropped();
        assert_eq!(dropped, 995);
        assert!(!logger.flush(Duration::from_millis(20)), "stalled");

        open.send(()).unwrap();
        assert!(logger.flush(Duration::from_secs(10)));
        let all = text(&out);
        let lines: Vec<&str> = all.lines().collect();
        let kept = (1000 - dropped) as usize;
        assert_eq!(lines.len(), kept + 1, "{all}");
        for (i, line) in lines[..kept].iter().enumerate() {
            assert_eq!(*line, format!("synthetic line {i}"));
        }
        assert_eq!(lines[kept], format!("synthetic note: {dropped} dropped"));

        // Afterwards lines flow normally, without another note.
        logger.submit("synthetic after\n".into());
        assert!(logger.flush(Duration::from_secs(10)));
        assert!(
            text(&out).ends_with(" dropped\nsynthetic after\n"),
            "{}",
            text(&out)
        );
        assert_eq!(logger.dropped(), dropped);
    }

    #[test]
    fn a_working_sink_gets_every_line_in_order() {
        let (logger, open, _entered, out) = gated(QUEUE_LINES);
        open.send(()).unwrap();
        for i in 0..100 {
            logger.submit(format!("{i}\n"));
            // Stay within the queue so nothing is dropped.
            if i % 50 == 49 {
                assert!(logger.flush(Duration::from_secs(10)));
            }
        }
        assert!(logger.flush(Duration::from_secs(10)));
        let want: String = (0..100).map(|i| format!("{i}\n")).collect();
        assert_eq!(text(&out), want);
        assert_eq!(logger.dropped(), 0);
    }
}

//! Microphone presence: a PipeWire registry monitor on its own thread.
//!
//! [`PresenceMonitor`] watches the global node list and reports whether an
//! audio source exists (`Audio/Source`, `Audio/Source/Virtual` or
//! `Audio/Duplex`), or, with a capture target configured, whether that node
//! exists. LocalFlow's own capture stream never counts. When PipeWire cannot
//! be reached the answer is unknown, not absent; the monitor reconnects every
//! [`RETRY`].
//!
//! Privacy: node names and descriptions (which can contain a person's name)
//! are compared, never stored beyond the node id, logged or passed on. Only
//! the yes/no/unknown answer leaves this module.

use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use pipewire as pw;
use pw::types::ObjectType;

use crate::{CAPTURE_NODE_NAME, EventFd, WakeFd};

/// Media classes of nodes that count as a microphone.
pub const SOURCE_CLASSES: [&str; 3] = ["Audio/Source", "Audio/Source/Virtual", "Audio/Duplex"];

/// How long the monitor waits before reconnecting to PipeWire.
pub const RETRY: Duration = Duration::from_secs(2);

/// How long dropping the monitor waits for its thread.
const STOP_TIMEOUT: Duration = Duration::from_secs(2);

/// The registry bookkeeping, without PipeWire: which global node ids are
/// matching sources.
#[derive(Debug, Default)]
pub struct SourceSet {
    target: Option<String>,
    ids: HashSet<u32>,
}

impl SourceSet {
    /// `target` is the configured input (`node.name` or `object.serial`);
    /// `None` accepts any source.
    pub fn new(target: Option<String>) -> SourceSet {
        SourceSet {
            target,
            ids: HashSet::new(),
        }
    }

    /// A node global appeared (or was announced again).
    pub fn node_added(
        &mut self,
        id: u32,
        media_class: Option<&str>,
        node_name: Option<&str>,
        serial: Option<&str>,
    ) {
        let source = media_class.is_some_and(|c| SOURCE_CLASSES.contains(&c))
            && node_name != Some(CAPTURE_NODE_NAME);
        let wanted = match &self.target {
            None => true,
            Some(t) => node_name == Some(t.as_str()) || serial == Some(t.as_str()),
        };
        if source && wanted {
            self.ids.insert(id);
        } else {
            self.ids.remove(&id);
        }
    }

    /// A global (of any type) was removed.
    pub fn removed(&mut self, id: u32) {
        self.ids.remove(&id);
    }

    pub fn present(&self) -> bool {
        !self.ids.is_empty()
    }

    /// Number of matching sources.
    pub fn count(&self) -> usize {
        self.ids.len()
    }
}

/// The shared answer, encoded for an atomic.
const UNKNOWN: u8 = 0;
const ABSENT: u8 = 1;
const PRESENT: u8 = 2;

fn encode(v: Option<bool>) -> u8 {
    match v {
        None => UNKNOWN,
        Some(false) => ABSENT,
        Some(true) => PRESENT,
    }
}

fn decode(v: u8) -> Option<bool> {
    match v {
        ABSENT => Some(false),
        PRESENT => Some(true),
        _ => None,
    }
}

struct Shared {
    value: AtomicU8,
    notify: Box<dyn Fn() + Send + Sync>,
}

impl Shared {
    /// Publishes `v`, then calls `notify` if it changed. The value is stored
    /// first so a notified reader always sees it (or a later one); a reader
    /// polling the value may therefore see it shortly before the call.
    fn set(&self, v: Option<bool>) {
        if self.value.swap(encode(v), Ordering::AcqRel) != encode(v) {
            (self.notify)();
        }
    }
}

/// Tracks microphone presence on a background thread. Stopped on drop.
pub struct PresenceMonitor {
    shared: Arc<Shared>,
    wake: Arc<EventFd>,
    thread: Option<JoinHandle<()>>,
}

impl PresenceMonitor {
    /// Starts the monitor thread. `notify` is called on that thread whenever
    /// [`PresenceMonitor::get`] changes.
    pub fn spawn(
        remote: Option<String>,
        target: Option<String>,
        notify: Box<dyn Fn() + Send + Sync>,
    ) -> std::io::Result<PresenceMonitor> {
        let shared = Arc::new(Shared {
            value: AtomicU8::new(UNKNOWN),
            notify,
        });
        let wake = Arc::new(EventFd::new()?);
        let (t_shared, t_wake) = (shared.clone(), wake.clone());
        let thread = std::thread::Builder::new()
            .name("lf-pw-presence".into())
            .spawn(move || monitor(remote, target, &t_wake, &t_shared))?;
        Ok(PresenceMonitor {
            shared,
            wake,
            thread: Some(thread),
        })
    }

    /// `Some(true)` if a matching source exists, `Some(false)` if none does,
    /// `None` until the first listing completes or while PipeWire is
    /// unreachable.
    pub fn get(&self) -> Option<bool> {
        decode(self.shared.value.load(Ordering::Acquire))
    }
}

impl Drop for PresenceMonitor {
    /// Stops the thread, waiting at most [`STOP_TIMEOUT`]; a thread that
    /// does not exit in time is detached.
    fn drop(&mut self) {
        self.wake.signal();
        let Some(thread) = self.thread.take() else {
            return;
        };
        let deadline = Instant::now() + STOP_TIMEOUT;
        while !thread.is_finished() {
            if Instant::now() >= deadline {
                return;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        let _ = thread.join();
    }
}

/// The monitor thread: watches until woken, reconnecting after failures.
fn monitor(
    remote: Option<String>,
    target: Option<String>,
    wake: &Arc<EventFd>,
    shared: &Arc<Shared>,
) {
    loop {
        if watch(remote.as_deref(), target.clone(), wake, shared) {
            return;
        }
        shared.set(None);
        if wake.wait(RETRY) {
            return;
        }
    }
}

/// One connection's worth of watching. Returns true when woken (stop), false
/// when the connection failed or was lost.
fn watch(
    remote: Option<&str>,
    target: Option<String>,
    wake: &Arc<EventFd>,
    shared: &Arc<Shared>,
) -> bool {
    let Ok(mainloop) = pw::main_loop::MainLoopRc::new(None) else {
        return false;
    };
    let Ok(context) = pw::context::ContextRc::new(&mainloop, None) else {
        return false;
    };
    let mut core_props = pw::properties::PropertiesBox::new();
    if let Some(remote) = remote {
        core_props.insert("remote.name", remote);
    }
    let Ok(core) = context.connect_rc(Some(core_props)) else {
        return false;
    };
    let Ok(registry) = core.get_registry_rc() else {
        return false;
    };

    let sources = Rc::new(RefCell::new(SourceSet::new(target)));
    // Answers are published only once the initial listing is complete, so a
    // source listed late is never reported absent first.
    let listed = Rc::new(Cell::new(false));
    let woken = Rc::new(Cell::new(false));

    let publish = {
        let (sources, listed, shared) = (sources.clone(), listed.clone(), shared.clone());
        Rc::new(move || {
            if listed.get() {
                shared.set(Some(sources.borrow().present()));
            }
        })
    };

    let (g_sources, g_publish) = (sources.clone(), publish.clone());
    let (r_sources, r_publish) = (sources.clone(), publish.clone());
    let _registry_listener = registry
        .add_listener_local()
        .global(move |global| {
            if global.type_ != ObjectType::Node {
                return;
            }
            let get = |k: &str| global.props.and_then(|p| p.get(k));
            g_sources.borrow_mut().node_added(
                global.id,
                get("media.class"),
                get("node.name"),
                get("object.serial"),
            );
            g_publish();
        })
        .global_remove(move |id| {
            r_sources.borrow_mut().removed(id);
            r_publish();
        })
        .register();

    let Ok(pending) = core.sync(0) else {
        return false;
    };
    let d_loop = mainloop.downgrade();
    let (d_listed, d_publish) = (listed.clone(), publish.clone());
    let _core_listener = core
        .add_listener_local()
        .done(move |id, seq| {
            if id == pw::core::PW_ID_CORE && seq == pending && !d_listed.get() {
                d_listed.set(true);
                d_publish();
            }
        })
        .error(move |id, _seq, _res, _message| {
            // id 0 is the core: the connection is gone. The server's message
            // is never used.
            if id == pw::core::PW_ID_CORE
                && let Some(l) = d_loop.upgrade()
            {
                l.quit();
            }
        })
        .register();

    let (w_loop, w_woken) = (mainloop.downgrade(), woken.clone());
    let _wake_source = mainloop.loop_().add_io(
        WakeFd(wake.clone()),
        pw::spa::support::system::IoFlags::IN,
        move |fd| {
            if fd.0.signalled() {
                w_woken.set(true);
                if let Some(l) = w_loop.upgrade() {
                    l.quit();
                }
            }
        },
    );
    // A stop requested before the source existed is still pending in the
    // eventfd, so the loop wakes immediately in that case.
    mainloop.run();
    woken.get()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    #[test]
    fn any_source_counts_but_streams_and_sinks_do_not() {
        let mut s = SourceSet::new(None);
        assert!(!s.present());
        s.node_added(30, Some("Audio/Sink"), Some("synthetic.sink"), Some("100"));
        s.node_added(
            31,
            Some("Stream/Output/Audio"),
            Some("synthetic.player"),
            None,
        );
        s.node_added(32, Some("Video/Source"), Some("synthetic.camera"), None);
        s.node_added(33, None, Some("synthetic.unclassified"), None);
        // LocalFlow's own capture stream, even if it claimed a source class.
        s.node_added(
            34,
            Some("Stream/Input/Audio"),
            Some(CAPTURE_NODE_NAME),
            None,
        );
        s.node_added(35, Some("Audio/Source"), Some(CAPTURE_NODE_NAME), None);
        assert!(!s.present());

        s.node_added(40, Some("Audio/Source"), Some("synthetic.mic"), Some("101"));
        assert!(s.present());
        s.node_added(
            41,
            Some("Audio/Source/Virtual"),
            Some("synthetic.virtual"),
            None,
        );
        s.node_added(42, Some("Audio/Duplex"), Some("synthetic.duplex"), None);
        assert_eq!(s.count(), 3);
        s.removed(40);
        s.removed(41);
        assert!(s.present());
        s.removed(42);
        assert!(!s.present());
        // Removing unknown ids is harmless.
        s.removed(40);
        s.removed(999);
        assert!(!s.present());
    }

    #[test]
    fn a_reannounced_node_is_reclassified() {
        let mut s = SourceSet::new(None);
        s.node_added(7, Some("Audio/Source"), Some("synthetic.mic"), None);
        assert!(s.present());
        s.node_added(7, Some("Audio/Sink"), Some("synthetic.mic"), None);
        assert!(!s.present());
    }

    #[test]
    fn a_target_matches_by_name_or_serial_only() {
        let mut s = SourceSet::new(Some("synthetic.wanted".into()));
        s.node_added(
            10,
            Some("Audio/Source"),
            Some("synthetic.other"),
            Some("200"),
        );
        assert!(!s.present());
        s.node_added(11, Some("Audio/Sink"), Some("synthetic.wanted"), None);
        assert!(
            !s.present(),
            "a sink with the target's name is not a source"
        );
        s.node_added(
            12,
            Some("Audio/Source"),
            Some("synthetic.wanted"),
            Some("201"),
        );
        assert!(s.present());
        s.removed(12);
        assert!(!s.present());

        let mut s = SourceSet::new(Some("305".into()));
        s.node_added(13, Some("Audio/Source"), Some("synthetic.mic"), Some("305"));
        assert!(s.present());
        s.removed(10);
        assert!(s.present());
    }

    #[test]
    fn notifications_fire_only_on_change() {
        let count = Arc::new(AtomicUsize::new(0));
        let c = count.clone();
        let shared = Shared {
            value: AtomicU8::new(UNKNOWN),
            notify: Box::new(move || {
                c.fetch_add(1, Ordering::Relaxed);
            }),
        };
        for v in [None, Some(false), Some(false), Some(true), Some(true), None] {
            shared.set(v);
            assert_eq!(decode(shared.value.load(Ordering::Relaxed)), v);
        }
        assert_eq!(count.load(Ordering::Relaxed), 3);
    }
}

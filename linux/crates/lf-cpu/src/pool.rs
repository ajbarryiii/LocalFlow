//! A small persistent thread pool with pinned workers.
//!
//! `run` hands the same job to every thread, including the caller as index 0,
//! and returns when all of them finish. Workers spin briefly between jobs and
//! then park, so back-to-back GEMMs avoid wake-up latency.
//!
//! Soundness rules:
//! - `run` is exclusive. A concurrent or reentrant call panics before touching
//!   shared state.
//! - A panic inside a job aborts the process. Workers hold a lifetime-erased
//!   pointer to the caller's closure, and jobs synchronize through barriers, so
//!   unwinding past either would leave dangling references or deadlocked threads.
//!   Validate inputs before calling `run`.

use std::cell::UnsafeCell;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::thread::{self, JoinHandle, Thread};

type Job = *const (dyn Fn(usize) + Sync);

struct Shared {
    generation: AtomicU64,
    pending: AtomicUsize,
    shutdown: AtomicBool,
    job: UnsafeCell<Option<Job>>,
}

// `job` is written by the caller before publishing a new generation (Release)
// and read by workers after observing it (Acquire).
unsafe impl Sync for Shared {}
unsafe impl Send for Shared {}

pub struct ThreadPool {
    shared: Arc<Shared>,
    workers: Vec<(Thread, JoinHandle<()>)>,
    busy: AtomicBool,
}

const SPIN_ITERATIONS: u32 = 200_000;

impl ThreadPool {
    /// One thread per CPU in `cpus`; the caller becomes index 0 and is pinned to `cpus[0]`.
    pub fn new(cpus: &[usize]) -> Self {
        assert!(!cpus.is_empty());
        pin_current_thread(cpus[0]);
        let shared = Arc::new(Shared {
            generation: AtomicU64::new(0),
            pending: AtomicUsize::new(0),
            shutdown: AtomicBool::new(false),
            job: UnsafeCell::new(None),
        });
        let workers = cpus[1..]
            .iter()
            .enumerate()
            .map(|(i, &cpu)| {
                let shared = Arc::clone(&shared);
                let handle = thread::Builder::new()
                    .name(format!("lf-cpu-{}", i + 1))
                    .spawn(move || {
                        pin_current_thread(cpu);
                        worker_loop(&shared, i + 1);
                    })
                    .expect("spawn worker");
                (handle.thread().clone(), handle)
            })
            .collect();
        ThreadPool {
            shared,
            workers,
            busy: AtomicBool::new(false),
        }
    }

    pub fn threads(&self) -> usize {
        self.workers.len() + 1
    }

    pub fn run(&self, f: &(dyn Fn(usize) + Sync)) {
        if self.busy.swap(true, Ordering::Acquire) {
            panic!("ThreadPool::run called while the pool is already running a job");
        }
        if self.workers.is_empty() {
            run_job(f, 0);
            self.busy.store(false, Ordering::Release);
            return;
        }
        // Erase the lifetime: `run` does not return (and cannot unwind) until every
        // worker is done with `f`.
        let job: Job = unsafe { std::mem::transmute::<&(dyn Fn(usize) + Sync), Job>(f) };
        unsafe { *self.shared.job.get() = Some(job) };
        self.shared
            .pending
            .store(self.workers.len(), Ordering::Relaxed);
        self.shared.generation.fetch_add(1, Ordering::Release);
        for (t, _) in &self.workers {
            t.unpark();
        }
        run_job(f, 0);
        while self.shared.pending.load(Ordering::Acquire) != 0 {
            std::hint::spin_loop();
        }
        unsafe { *self.shared.job.get() = None };
        self.busy.store(false, Ordering::Release);
    }
}

/// Runs one thread's share of a job; a panic aborts (see the module docs).
fn run_job(f: &(dyn Fn(usize) + Sync), idx: usize) {
    if let Err(payload) = catch_unwind(AssertUnwindSafe(|| f(idx))) {
        // Never drop the payload: its destructor could panic and unwind past
        // workers that still hold the closure. Abort directly, without
        // formatting or locking anything that could fail.
        std::mem::forget(payload);
        std::process::abort();
    }
}

fn worker_loop(shared: &Shared, idx: usize) {
    let mut seen = 0u64;
    loop {
        let mut spins = 0;
        let generation = loop {
            let g = shared.generation.load(Ordering::Acquire);
            if g != seen {
                break g;
            }
            if spins < SPIN_ITERATIONS {
                spins += 1;
                std::hint::spin_loop();
            } else {
                thread::park();
            }
        };
        seen = generation;
        if shared.shutdown.load(Ordering::Acquire) {
            return;
        }
        let job = unsafe { (*shared.job.get()).expect("job published") };
        run_job(unsafe { &*job }, idx);
        shared.pending.fetch_sub(1, Ordering::Release);
    }
}

impl Drop for ThreadPool {
    fn drop(&mut self) {
        self.shared.shutdown.store(true, Ordering::Release);
        self.shared.generation.fetch_add(1, Ordering::Release);
        for (t, _) in &self.workers {
            t.unpark();
        }
        for (_, handle) in self.workers.drain(..) {
            let _ = handle.join();
        }
    }
}

fn pin_current_thread(cpu: usize) {
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        libc::CPU_SET(cpu, &mut set);
        // Best effort: an unavailable CPU leaves the thread unpinned.
        libc::sched_setaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &set);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_index_runs_once_per_job() {
        let pool = ThreadPool::new(&[0, 1, 2, 3]);
        let hits: Vec<AtomicUsize> = (0..4).map(|_| AtomicUsize::new(0)).collect();
        for _ in 0..100 {
            pool.run(&|i| {
                hits[i].fetch_add(1, Ordering::Relaxed);
            });
        }
        assert!(hits.iter().all(|h| h.load(Ordering::Relaxed) == 100));
    }

    /// Child half of `job_panic_aborts_even_with_a_panicking_payload`.
    #[test]
    #[ignore = "run by job_panic_aborts_even_with_a_panicking_payload in a subprocess"]
    fn child_job_panics_with_bad_payload() {
        struct Bomb;
        impl Drop for Bomb {
            fn drop(&mut self) {
                panic!("payload destructor");
            }
        }
        let pool = ThreadPool::new(&[0, 1]);
        pool.run(&|idx| {
            if idx == 1 {
                std::panic::panic_any(Bomb);
            }
        });
        // Reaching here would mean the panic was swallowed or unwound.
        std::process::exit(0);
    }

    #[test]
    fn job_panic_aborts_even_with_a_panicking_payload() {
        use std::os::unix::process::ExitStatusExt;
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--ignored",
                "--exact",
                "pool::tests::child_job_panics_with_bad_payload",
                "--nocapture",
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap();
        assert_eq!(
            status.signal(),
            Some(libc::SIGABRT),
            "child status {status:?}"
        );
    }

    #[test]
    fn reentrant_run_is_rejected() {
        let pool = ThreadPool::new(&[0]);
        let rejected = AtomicBool::new(false);
        // The inner call panics before touching shared state; catch it inside
        // the job so the outer job itself completes normally.
        pool.run(&|_| {
            let inner = catch_unwind(AssertUnwindSafe(|| pool.run(&|_| {})));
            rejected.store(inner.is_err(), Ordering::Relaxed);
        });
        assert!(rejected.load(Ordering::Relaxed));
        // The pool stays usable afterwards.
        pool.run(&|_| {});
    }
}

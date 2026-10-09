//! Spinning barrier for threads already running inside one `ThreadPool::run`.

use std::sync::atomic::{AtomicUsize, Ordering};

pub struct SpinBarrier {
    threads: usize,
    arrived: AtomicUsize,
    generation: AtomicUsize,
}

impl SpinBarrier {
    pub fn new(threads: usize) -> Self {
        SpinBarrier {
            threads,
            arrived: AtomicUsize::new(0),
            generation: AtomicUsize::new(0),
        }
    }

    /// Returns once all `threads` callers have arrived. Writes before the
    /// barrier are visible to every thread after it.
    pub fn wait(&self) {
        if self.threads == 1 {
            return;
        }
        let generation = self.generation.load(Ordering::Acquire);
        if self.arrived.fetch_add(1, Ordering::AcqRel) + 1 == self.threads {
            self.arrived.store(0, Ordering::Relaxed);
            self.generation.fetch_add(1, Ordering::Release);
        } else {
            while self.generation.load(Ordering::Acquire) == generation {
                std::hint::spin_loop();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ThreadPool;

    #[test]
    fn phases_never_overlap() {
        let pool = ThreadPool::new(&[0, 1, 2, 3]);
        let barrier = SpinBarrier::new(4);
        let counter = AtomicUsize::new(0);
        pool.run(&|_| {
            for phase in 0..1000 {
                counter.fetch_add(1, Ordering::Relaxed);
                barrier.wait();
                assert_eq!(counter.load(Ordering::Relaxed), 4 * (phase + 1));
                barrier.wait();
            }
        });
    }
}

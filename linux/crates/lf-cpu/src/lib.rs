//! CPU inference kernels (AVX-512) for the ternary Parakeet encoder.
//!
//! Every ternary GEMM computes `Y[t][o] = scale[o] * sum_i code(o, i) * X[t][i]`
//! for `T` frames, `K` inputs and `O` outputs, with row-major `X` and `Y`.

pub mod attention;
pub mod barrier;
pub mod conv2d;
pub mod decoder;
pub mod dense;
pub mod gemm_f32;
pub mod gemm_i8;
pub mod gemm_lut;
pub mod gemm_ref;
pub mod ops;
pub mod pack;
pub mod peak;
pub mod pool;
pub mod quant;

mod aligned;
mod math;

pub use aligned::AlignedBuf;
pub use pack::PackedTernary;
pub use pool::ThreadPool;
pub use quant::QuantizedActs;

/// Whether this CPU has the AVX-512 subsets the kernels use.
pub fn cpu_supported() -> bool {
    #[cfg(target_arch = "x86_64")]
    {
        std::arch::is_x86_feature_detected!("avx512f")
            && std::arch::is_x86_feature_detected!("avx512bw")
            && std::arch::is_x86_feature_detected!("avx512vnni")
            && std::arch::is_x86_feature_detected!("avx512vbmi")
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        false
    }
}

/// `a * b` for size and bounds checks at kernel entry points; panics on
/// overflow so a wrapped product can never pass a length check.
pub(crate) fn size(a: usize, b: usize) -> usize {
    a.checked_mul(b).expect("size overflow")
}

/// Elements spanned by `rows` rows of `width` values at stride `ld`.
pub(crate) fn span(rows: usize, ld: usize, width: usize) -> usize {
    if rows == 0 {
        return 0;
    }
    (rows - 1)
        .checked_mul(ld)
        .and_then(|v| v.checked_add(width))
        .expect("size overflow")
}

/// Splits `0..len` into `parts` nearly equal contiguous ranges.
pub fn split_range(len: usize, parts: usize, idx: usize) -> std::ops::Range<usize> {
    let base = len / parts;
    let extra = len % parts;
    let start = idx * base + idx.min(extra);
    start..start + base + usize::from(idx < extra)
}

/// Per-thread scratch buffers, indexed by pool thread index. A kernel takes an
/// exclusive [`ScratchLease`] before handing buffers to pool threads, so two
/// concurrent kernels can never share one.
pub struct Scratch {
    bufs: Vec<std::cell::UnsafeCell<AlignedBuf>>,
    leased: std::sync::atomic::AtomicBool,
}

// Buffers are only reachable through a lease, and each pool thread only
// touches its own index.
unsafe impl Sync for Scratch {}

impl Scratch {
    pub fn new(threads: usize, bytes: usize) -> Self {
        Scratch {
            bufs: (0..threads)
                .map(|_| std::cell::UnsafeCell::new(AlignedBuf::new(bytes)))
                .collect(),
            leased: std::sync::atomic::AtomicBool::new(false),
        }
    }

    pub fn threads(&self) -> usize {
        self.bufs.len()
    }

    /// Exclusive access for one kernel call; panics if already leased or if
    /// any buffer is smaller than `min_bytes` or there are fewer than `threads`.
    pub fn lease(&self, threads: usize, min_bytes: usize) -> ScratchLease<'_> {
        use std::sync::atomic::Ordering;
        assert!(
            !self.leased.swap(true, Ordering::Acquire),
            "scratch is already in use by another kernel"
        );
        let lease = ScratchLease { scratch: self };
        assert!(
            self.bufs.len() >= threads,
            "scratch has too few thread buffers"
        );
        for b in &self.bufs {
            assert!(
                unsafe { (*b.get()).len() } >= min_bytes,
                "scratch buffer too small"
            );
        }
        lease
    }
}

pub struct ScratchLease<'a> {
    scratch: &'a Scratch,
}

impl ScratchLease<'_> {
    /// # Safety
    /// Only the thread running pool index `idx` may call this, once per job.
    #[allow(clippy::mut_from_ref)]
    pub unsafe fn get(&self, idx: usize) -> &mut AlignedBuf {
        unsafe { &mut *self.scratch.bufs[idx].get() }
    }
}

impl Drop for ScratchLease<'_> {
    fn drop(&mut self) {
        self.scratch
            .leased
            .store(false, std::sync::atomic::Ordering::Release);
    }
}

/// Raw pointer wrapper so disjoint output regions can be written from pool threads.
pub(crate) struct SendPtr<T>(pub *mut T);

// Manual impls: `derive` would require `T: Copy`.
impl<T> Clone for SendPtr<T> {
    fn clone(&self) -> Self {
        *self
    }
}
impl<T> Copy for SendPtr<T> {}
unsafe impl<T> Send for SendPtr<T> {}
unsafe impl<T> Sync for SendPtr<T> {}

impl<T> SendPtr<T> {
    /// Method access makes closures capture the whole wrapper, not the raw field.
    pub fn get(self) -> *mut T {
        self.0
    }
}

#[cfg(test)]
mod tests {
    use super::split_range;

    #[test]
    fn split_covers_everything_once() {
        for len in [0, 1, 5, 16, 17] {
            for parts in [1, 3, 8] {
                let mut next = 0;
                for i in 0..parts {
                    let r = split_range(len, parts, i);
                    assert_eq!(r.start, next);
                    next = r.end;
                }
                assert_eq!(next, len);
            }
        }
    }
}

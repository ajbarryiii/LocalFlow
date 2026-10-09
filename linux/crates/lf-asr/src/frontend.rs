//! NeMo `AudioToMelSpectrogramPreprocessor` at inference time.
//!
//! Pre-emphasis 0.97; centred STFT (n_fft 512, hop 160, 400-sample Hann window
//! from the export, zero padding); power spectrum; Slaney mel filterbank from
//! the export; `ln(x + 2^-24)`; per-feature mean and unbiased standard deviation
//! over the valid frames (`samples / 160` of them; NeMo masks the trailing STFT
//! frame), with 1e-5 added to the deviation. The STFT is one GEMM against a DFT
//! basis and the filterbank another.

use lf_cpu::ThreadPool;
use lf_cpu::dense::gemm;
use lf_cpu::ops::for_each_row_mut;
use lf_model::{Error, Result};

use crate::config::*;
use crate::model::Frontend;

/// Zeroes a buffer in a way the optimizer cannot drop as a dead store.
fn scrub(v: &mut [f32]) {
    v.fill(0.0);
    std::hint::black_box(&*v);
}

/// Reusable frontend buffers. The raw waveform copies (`pre`, `framed`) are
/// zeroed as soon as the spectrum is computed.
#[derive(Default)]
pub struct FrontendBuffers {
    pre: Vec<f32>,
    framed: Vec<f32>,
    spec: Vec<f32>,
    power: Vec<f32>,
    /// Normalized log-mel features, `[frames][128]`.
    pub feat: Vec<f32>,
}

/// Fills `buf.feat` and returns the number of frames.
pub fn features(
    fe: &Frontend,
    pool: &ThreadPool,
    samples: &[f32],
    buf: &mut FrontendBuffers,
) -> Result<usize> {
    let n = samples.len();
    let frames = n / HOP_LENGTH;
    if frames == 0 {
        return Err(Error("audio is shorter than one 10 ms frame".into()));
    }
    if samples.iter().any(|s| !s.is_finite()) {
        return Err(Error("audio contains non-finite samples".into()));
    }
    let bins = N_FFT / 2 + 1;

    // Pre-emphasis, as torch evaluates it: x[i] - (0.97 * x[i - 1]) in f32.
    buf.pre.clear();
    buf.pre.reserve(n);
    buf.pre.push(samples[0]);
    buf.pre
        .extend(samples.windows(2).map(|w| w[1] - PREEMPH * w[0]));

    // Frame t covers padded samples [160 t, 160 t + 512); the window occupies
    // offsets 56..456 of it, so the first windowed sample is 160 t + 56 - 256.
    buf.framed.resize(frames * WIN_LENGTH, 0.0);
    let (pre, window) = (&buf.pre, &fe.window);
    for_each_row_mut(pool, &mut buf.framed, WIN_LENGTH, &|t, row| {
        let start =
            (t * HOP_LENGTH) as isize + ((N_FFT - WIN_LENGTH) / 2) as isize - (N_FFT / 2) as isize;
        for (m, out) in row.iter_mut().enumerate() {
            let i = start + m as isize;
            *out = if i >= 0 && (i as usize) < n {
                pre[i as usize] * window[m]
            } else {
                0.0
            };
        }
    });

    buf.spec.resize(frames * 2 * bins, 0.0);
    gemm(
        pool,
        &buf.framed,
        frames,
        WIN_LENGTH,
        &fe.dft,
        &mut buf.spec,
        2 * bins,
        None,
    );
    // The two waveform copies are no longer needed; don't keep the user's
    // audio in reusable buffers until the next call.
    scrub(&mut buf.pre);
    scrub(&mut buf.framed);

    buf.power.resize(frames * bins, 0.0);
    let spec = &buf.spec;
    for_each_row_mut(pool, &mut buf.power, bins, &|t, row| {
        let s = &spec[t * 2 * bins..(t + 1) * 2 * bins];
        for (j, p) in row.iter_mut().enumerate() {
            // torch: |X| = sqrt(re^2 + im^2), then |X|^2.
            let mag = (s[j] * s[j] + s[bins + j] * s[bins + j]).sqrt();
            *p = mag * mag;
        }
    });

    buf.feat.resize(frames * FEATURES, 0.0);
    gemm(
        pool,
        &buf.power,
        frames,
        bins,
        &fe.mel,
        &mut buf.feat,
        FEATURES,
        None,
    );
    for_each_row_mut(pool, &mut buf.feat, FEATURES, &|_, row| {
        for v in row.iter_mut() {
            *v = (*v + LOG_GUARD).ln();
        }
    });

    // Per-feature normalization over all (valid) frames, in f64.
    let mut mean = [0.0f64; FEATURES];
    for row in buf.feat.as_chunks::<FEATURES>().0 {
        for (m, &v) in mean.iter_mut().zip(row) {
            *m += v as f64;
        }
    }
    mean.iter_mut().for_each(|m| *m /= frames as f64);
    let mut var = [0.0f64; FEATURES];
    for row in buf.feat.as_chunks::<FEATURES>().0 {
        for ((s, &v), m) in var.iter_mut().zip(row).zip(&mean) {
            *s += (v as f64 - m).powi(2);
        }
    }
    let inv_std: Vec<f64> = var
        .iter()
        .map(|&s| {
            // One frame gives 0/0; NeMo turns that NaN into 0 before adding eps.
            let std = if frames > 1 {
                (s / (frames - 1) as f64).sqrt()
            } else {
                0.0
            };
            1.0 / (std + NORM_EPS as f64)
        })
        .collect();
    for_each_row_mut(pool, &mut buf.feat, FEATURES, &|_, row| {
        for (i, v) in row.iter_mut().enumerate() {
            *v = ((*v as f64 - mean[i]) * inv_std[i]) as f32;
        }
    });
    Ok(frames)
}

#[cfg(test)]
mod tests {
    use super::*;
    use lf_cpu::dense::Panels;
    use lf_model::rng::SplitMix64;

    #[test]
    fn waveform_copies_are_zeroed_after_each_call() {
        if !lf_cpu::cpu_supported() {
            return;
        }
        let bins = N_FFT / 2 + 1;
        let mut rng = SplitMix64::new(1);
        let mut rand = |n: usize| -> Vec<f32> { (0..n).map(|_| rng.next_f32()).collect() };
        let mut dft = Panels::default();
        dft.pack_cols(&rand(WIN_LENGTH * 2 * bins), WIN_LENGTH, 2 * bins, 2 * bins);
        let mut mel = Panels::default();
        mel.pack_rows(&rand(FEATURES * bins), FEATURES, bins, bins);
        let fe = Frontend {
            dft,
            mel,
            window: vec![1.0; WIN_LENGTH],
        };
        let pool = ThreadPool::new(&[0, 1]);
        let mut buf = FrontendBuffers::default();
        let samples: Vec<f32> = rand(16_000).iter().map(|v| v - 0.5).collect();
        let frames = features(&fe, &pool, &samples, &mut buf).unwrap();
        assert_eq!(frames, 100);
        assert!(!buf.pre.is_empty() && !buf.framed.is_empty());
        assert!(buf.pre.iter().chain(&buf.framed).all(|&v| v == 0.0));
        assert!(buf.feat.iter().any(|&v| v != 0.0));
    }
}

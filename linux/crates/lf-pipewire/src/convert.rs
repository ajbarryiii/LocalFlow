//! Fallback conversion to 16 kHz mono: channel downmix and a windowed-sinc
//! resampler.
//!
//! The capture stream asks PipeWire for 16 kHz mono f32, and PipeWire's
//! adapter normally converts for us, so this path only runs if the server
//! negotiates a different rate or channel count.

use lf_io_api::SAMPLE_RATE;

/// Converts interleaved f32 frames at any rate and channel count to mono
/// 16 kHz.
pub struct Converter {
    channels: usize,
    resampler: Option<Resampler>,
}

impl Converter {
    pub fn new(in_rate: u32, channels: u32) -> Result<Self, String> {
        if channels == 0 || channels > 64 {
            return Err(format!("unsupported channel count {channels}"));
        }
        let resampler = if in_rate == SAMPLE_RATE {
            None
        } else {
            Some(Resampler::new(in_rate, SAMPLE_RATE)?)
        };
        Ok(Self {
            channels: channels as usize,
            resampler,
        })
    }

    /// True if input passes through unchanged (16 kHz mono).
    pub fn is_identity(&self) -> bool {
        self.channels == 1 && self.resampler.is_none()
    }

    /// Converts whole frames of `interleaved` (a trailing partial frame is
    /// ignored) and appends the result to `out`.
    pub fn push(&mut self, interleaved: &[f32], out: &mut Vec<f32>) {
        match self.resampler.as_mut() {
            None => downmix(interleaved, self.channels, out),
            Some(r) => {
                // Exact capacity: `downmix` never reallocates it.
                let mut mono =
                    crate::wipe::Wiped(Vec::with_capacity(interleaved.len() / self.channels));
                downmix(interleaved, self.channels, &mut mono.0);
                r.push(&mono.0, out);
            }
        }
    }

    /// Emits the resampler's remaining output, treating the input as
    /// followed by silence. Consumes the converter, so it cannot be fed
    /// again afterwards.
    pub fn finish(self, out: &mut Vec<f32>) {
        if let Some(r) = self.resampler {
            r.finish(out);
        }
    }

    /// Upper bound on the samples [`Self::finish`] appends, so callers can
    /// reserve without reallocating.
    pub fn max_tail(&self) -> usize {
        self.resampler.as_ref().map_or(0, Resampler::max_tail)
    }
}

/// Averages each frame's channels into one sample.
pub fn downmix(interleaved: &[f32], channels: usize, out: &mut Vec<f32>) {
    if channels == 1 {
        out.extend_from_slice(interleaved);
        return;
    }
    let scale = 1.0 / channels as f32;
    out.extend(
        interleaved
            .chunks_exact(channels)
            .map(|frame| frame.iter().sum::<f32>() * scale),
    );
}

fn gcd(mut a: u64, mut b: u64) -> u64 {
    while b != 0 {
        (a, b) = (b, a % b);
    }
    a
}

/// Zeroth-order modified Bessel function of the first kind (series).
fn bessel_i0(x: f64) -> f64 {
    let mut sum = 1.0;
    let mut term = 1.0;
    let q = x * x / 4.0;
    for k in 1..64 {
        term *= q / (k * k) as f64;
        sum += term;
        if term < sum * 1e-17 {
            break;
        }
    }
    sum
}

/// Zero crossings of the sinc on each side of the kernel centre.
const ZERO_CROSSINGS: f64 = 16.0;
/// Passband edge as a fraction of the lower Nyquist frequency.
const ROLLOFF: f64 = 0.92;
/// Kaiser window shape (about 85 dB stopband).
const KAISER_BETA: f64 = 8.6;
/// Largest number of filter phases (output rate / gcd) supported.
const MAX_PHASES: u64 = 4096;
/// Supported input rates. Real devices run at 8-384 kHz.
const MIN_RATE: u32 = 1_000;
const MAX_RATE: u32 = 768_000;
/// Upper bound on the coefficient table (4 MiB of f32).
const MAX_COEFFS: usize = 1 << 20;

/// Streaming rational-ratio resampler: a Kaiser-windowed sinc low-pass
/// evaluated as a polyphase filter bank. Output sample `n` is the band-limited
/// input at time `n * in_rate / out_rate` (input samples), with no delay;
/// input before the first sample counts as silence.
pub struct Resampler {
    /// Output samples per `down` input samples (reduced ratio).
    up: u64,
    down: u64,
    /// Taps on each side of the centre.
    half: usize,
    /// `up` phases of `2 * half` taps each, every phase normalized to unit
    /// DC gain.
    table: Vec<f32>,
    /// Input history; `hist[0]` is input index `base`.
    hist: Vec<f32>,
    base: i64,
    /// Total input samples pushed.
    consumed: u64,
    /// Next output index.
    next: u64,
}

impl Resampler {
    pub fn new(in_rate: u32, out_rate: u32) -> Result<Self, String> {
        let supported = MIN_RATE..=MAX_RATE;
        if !supported.contains(&in_rate) || !supported.contains(&out_rate) {
            return Err(format!("unsupported sample rate {in_rate} Hz"));
        }
        let g = gcd(u64::from(in_rate), u64::from(out_rate));
        let (up, down) = (u64::from(out_rate) / g, u64::from(in_rate) / g);
        if up > MAX_PHASES {
            return Err(format!("unsupported sample rate {in_rate} Hz"));
        }
        // Cutoff in cycles per input sample.
        let fc = 0.5 * ROLLOFF * (up as f64 / down as f64).min(1.0);
        let half = (ZERO_CROSSINGS / (2.0 * fc)).ceil() as usize;
        let taps = 2 * half;
        let coeffs = (up as usize)
            .checked_mul(taps)
            .filter(|&n| n <= MAX_COEFFS)
            .ok_or_else(|| format!("unsupported sample rate {in_rate} Hz"))?;
        let mut table = vec![0f32; coeffs];
        let i0_beta = bessel_i0(KAISER_BETA);
        for p in 0..up as usize {
            let frac = p as f64 / up as f64;
            let row = &mut table[p * taps..(p + 1) * taps];
            let mut sum = 0.0f64;
            let mut vals = vec![0f64; taps];
            for (j, v) in vals.iter_mut().enumerate() {
                // Tap j multiplies input index (i0 - half + 1 + j) for an
                // output at input time i0 + frac.
                let x = j as f64 - half as f64 + 1.0 - frac;
                let r = x / half as f64;
                if r.abs() >= 1.0 {
                    continue;
                }
                let arg = 2.0 * fc * x;
                let sinc = if arg.abs() < 1e-12 {
                    1.0
                } else {
                    (std::f64::consts::PI * arg).sin() / (std::f64::consts::PI * arg)
                };
                let w = bessel_i0(KAISER_BETA * (1.0 - r * r).sqrt()) / i0_beta;
                *v = 2.0 * fc * sinc * w;
                sum += *v;
            }
            for (t, v) in row.iter_mut().zip(&vals) {
                *t = (v / sum) as f32;
            }
        }
        Ok(Self {
            up,
            down,
            half,
            table,
            hist: vec![0.0; half],
            base: -(half as i64),
            consumed: 0,
            next: 0,
        })
    }

    /// Upper bound on the samples [`Self::finish`] appends.
    pub fn max_tail(&self) -> usize {
        let inputs = (self.hist.len() + self.half + 1) as u64;
        ((inputs * self.up).div_ceil(self.down) + 2) as usize
    }

    pub fn push(&mut self, input: &[f32], out: &mut Vec<f32>) {
        crate::wipe::reserve_wiping(&mut self.hist, input.len());
        self.hist.extend_from_slice(input);
        self.consumed += input.len() as u64;
        self.drain(out);
    }

    /// Produces every output sample whose filter window is fully available.
    fn drain(&mut self, out: &mut Vec<f32>) {
        let taps = 2 * self.half;
        let available_end = self.base + self.hist.len() as i64; // exclusive
        loop {
            let pos = self.next * self.down;
            let i0 = (pos / self.up) as i64;
            let phase = (pos % self.up) as usize;
            let first = i0 - self.half as i64 + 1;
            if first + taps as i64 > available_end {
                break;
            }
            let start = (first - self.base) as usize;
            let window = &self.hist[start..start + taps];
            let coeffs = &self.table[phase * taps..(phase + 1) * taps];
            let acc: f32 = window.iter().zip(coeffs).map(|(x, c)| x * c).sum();
            out.push(acc);
            self.next += 1;
        }
        // Drop history no future output needs.
        let pos = self.next * self.down;
        let keep_from = (pos / self.up) as i64 - self.half as i64 + 1;
        if keep_from > self.base {
            let drop = ((keep_from - self.base) as usize).min(self.hist.len());
            self.hist.drain(..drop);
            self.base += drop as i64;
        }
    }

    /// Flushes with trailing silence so the output covers all input:
    /// `ceil(consumed * out_rate / in_rate)` samples in total. Consumes the
    /// resampler.
    pub fn finish(mut self, out: &mut Vec<f32>) {
        let total = (self.consumed * self.up).div_ceil(self.down);
        // Output total-1 sits at input time < consumed, so its window ends
        // before input index consumed + half. Every output beyond `total`
        // is produced by this final drain, so trimming the tail of `out`
        // removes exactly those.
        crate::wipe::reserve_wiping(&mut self.hist, self.half + 1);
        self.hist.extend(std::iter::repeat_n(0.0, self.half + 1));
        self.drain(out);
        if self.next > total {
            out.truncate(out.len() - (self.next - total) as usize);
            self.next = total;
        }
        debug_assert_eq!(self.next, total);
    }
}

/// The input history is audio; overwrite it before it is freed.
impl Drop for Resampler {
    fn drop(&mut self) {
        crate::wipe::wipe(&mut self.hist);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f64::consts::PI;

    fn sine(rate: u32, freq: f64, amp: f64, seconds: f64) -> Vec<f32> {
        let n = (rate as f64 * seconds) as usize;
        (0..n)
            .map(|i| (amp * (2.0 * PI * freq * i as f64 / rate as f64).sin()) as f32)
            .collect()
    }

    fn resample_all(input: &[f32], in_rate: u32) -> Vec<f32> {
        let mut r = Resampler::new(in_rate, 16_000).unwrap();
        let mut out = Vec::new();
        r.push(input, &mut out);
        r.finish(&mut out);
        out
    }

    /// Max error against the ideal 16 kHz sine, skipping the edges where
    /// the implicit silence before and after the input matters.
    fn max_err_vs_ideal(out: &[f32], freq: f64, amp: f64) -> f64 {
        let skip = 200;
        out[skip..out.len() - skip]
            .iter()
            .enumerate()
            .map(|(i, &y)| {
                let n = (i + skip) as f64;
                (y as f64 - amp * (2.0 * PI * freq * n / 16_000.0).sin()).abs()
            })
            .fold(0.0, f64::max)
    }

    fn rms(x: &[f32]) -> f64 {
        (x.iter().map(|&v| (v as f64) * (v as f64)).sum::<f64>() / x.len() as f64).sqrt()
    }

    #[test]
    fn downmix_averages_channels() {
        let mut out = Vec::new();
        downmix(&[1.0, 0.0, 0.5, 0.5, -1.0, 1.0, 0.25], 2, &mut out);
        assert_eq!(out, vec![0.5, 0.5, 0.0]); // trailing partial frame dropped
        out.clear();
        downmix(&[0.6, 0.0, 0.0, 0.0, 0.0, 0.0], 6, &mut out);
        assert!((out[0] - 0.1).abs() < 1e-7);
        out.clear();
        downmix(&[0.3, -0.2], 1, &mut out);
        assert_eq!(out, vec![0.3, -0.2]);
    }

    #[test]
    fn identity_converter_passes_through() {
        let mut c = Converter::new(16_000, 1).unwrap();
        assert!(c.is_identity());
        let mut out = Vec::new();
        c.push(&[0.1, -0.2, 0.3], &mut out);
        c.finish(&mut out);
        assert_eq!(out, vec![0.1, -0.2, 0.3]);
        assert!(Converter::new(16_000, 0).is_err());
    }

    #[test]
    fn downsample_48k_sine_is_accurate() {
        let input = sine(48_000, 1_000.0, 0.5, 1.0);
        let out = resample_all(&input, 48_000);
        assert_eq!(out.len(), 16_000);
        assert!(max_err_vs_ideal(&out, 1_000.0, 0.5) < 2e-4);
    }

    #[test]
    fn downsample_44k1_sine_is_accurate() {
        let input = sine(44_100, 440.0, 0.8, 1.0);
        let out = resample_all(&input, 44_100);
        assert_eq!(out.len(), 16_000);
        assert!(max_err_vs_ideal(&out, 440.0, 0.8) < 2e-4);
        let input = sine(44_100, 6_000.0, 0.5, 0.5);
        let out = resample_all(&input, 44_100);
        assert!(max_err_vs_ideal(&out, 6_000.0, 0.5) < 2e-3);
    }

    #[test]
    fn upsample_8k_sine_is_accurate() {
        let input = sine(8_000, 1_000.0, 0.5, 1.0);
        let out = resample_all(&input, 8_000);
        assert_eq!(out.len(), 16_000);
        assert!(max_err_vs_ideal(&out, 1_000.0, 0.5) < 2e-4);
    }

    #[test]
    fn dc_gain_is_one() {
        for rate in [8_000, 22_050, 44_100, 48_000, 96_000] {
            let input = vec![0.25f32; rate as usize / 2];
            let out = resample_all(&input, rate);
            for &y in &out[100..out.len() - 100] {
                assert!((y - 0.25).abs() < 1e-5, "rate {rate}: {y}");
            }
        }
    }

    #[test]
    fn frequencies_above_new_nyquist_are_rejected() {
        // 12 kHz would alias to 4 kHz at 16 kHz; 9 kHz to 7 kHz.
        for freq in [9_000.0, 12_000.0, 20_000.0] {
            let input = sine(48_000, freq, 1.0, 0.5);
            let out = resample_all(&input, 48_000);
            let r = rms(&out[200..out.len() - 200]);
            assert!(r < 3e-4, "{freq} Hz leaked with RMS {r}");
        }
    }

    #[test]
    fn chunked_streaming_matches_one_shot() {
        let input = sine(44_100, 523.0, 0.7, 0.3);
        let one = resample_all(&input, 44_100);
        let mut r = Resampler::new(44_100, 16_000).unwrap();
        let mut out = Vec::new();
        let mut i = 0;
        let mut step = 1;
        while i < input.len() {
            let end = (i + step).min(input.len());
            r.push(&input[i..end], &mut out);
            i = end;
            step = step * 7 % 1013 + 1;
        }
        r.finish(&mut out);
        assert_eq!(out, one);
    }

    #[test]
    fn output_length_rounds_up() {
        for (rate, n) in [(48_000u32, 1usize), (48_000, 4), (44_100, 1000), (8_000, 3)] {
            let out = resample_all(&vec![0.0; n], rate);
            assert_eq!(out.len() as u64, (n as u64 * 16_000).div_ceil(rate as u64));
        }
        assert!(resample_all(&[], 48_000).is_empty());
    }

    #[test]
    fn stereo_48k_converter() {
        let mono = sine(48_000, 700.0, 0.4, 0.5);
        let stereo: Vec<f32> = mono.iter().flat_map(|&s| [s, s]).collect();
        let mut c = Converter::new(48_000, 2).unwrap();
        assert!(!c.is_identity());
        let mut out = Vec::new();
        for chunk in stereo.chunks(1024 * 2) {
            c.push(chunk, &mut out);
        }
        c.finish(&mut out);
        assert_eq!(out.len(), 8_000);
        assert!(max_err_vs_ideal(&out, 700.0, 0.4) < 2e-4);
    }

    #[test]
    fn rejects_unsupported_rates() {
        assert!(Resampler::new(0, 16_000).is_err());
        assert!(Resampler::new(44_101, 16_000).is_err()); // 16000 phases
        // Few phases but an absurd ratio: rejected before any allocation.
        assert!(Resampler::new(1_000_000_004, 16_000).is_err());
        assert!(Resampler::new(768_001, 16_000).is_err());
        assert!(Converter::new(u32::MAX, 2).is_err());
        for rate in [
            8_000, 11_025, 22_050, 44_100, 48_000, 96_000, 192_000, 384_000, 768_000,
        ] {
            let r = Resampler::new(rate, 16_000).unwrap();
            assert!(r.table.len() <= MAX_COEFFS, "{rate}: {}", r.table.len());
        }
    }
}

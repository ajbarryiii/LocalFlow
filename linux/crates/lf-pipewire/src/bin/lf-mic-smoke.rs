//! Manual test only: records from the default microphone (or a named
//! PipeWire node) and prints duration, RMS and peak. The audio is kept in
//! memory and discarded; nothing is written or played back.
//!
//! ```text
//! lf-mic-smoke [--seconds N] [--target NODE_NAME] [--cycles K]
//! ```

use std::process::ExitCode;
use std::time::{Duration, Instant};

use lf_io_api::{AudioCapture, SAMPLE_RATE};
use lf_pipewire::{CaptureConfig, PipeWireCapture};

fn usage() -> ExitCode {
    eprintln!("usage: lf-mic-smoke [--seconds N] [--target NODE_NAME] [--cycles K]");
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let mut seconds = 3.0f64;
    let mut cycles = 1u32;
    let mut config = CaptureConfig::default();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--seconds" => match args.next().and_then(|v| v.parse::<f64>().ok()) {
                Some(v) if v > 0.0 && v <= 600.0 => seconds = v,
                _ => return usage(),
            },
            "--target" => match args.next() {
                Some(v) => config.target = Some(v),
                None => return usage(),
            },
            "--cycles" => match args.next().and_then(|v| v.parse::<u32>().ok()) {
                Some(v) if (1..=100).contains(&v) => cycles = v,
                _ => return usage(),
            },
            _ => return usage(),
        }
    }

    let mut capture = PipeWireCapture::new(config);
    for cycle in 1..=cycles {
        let t0 = Instant::now();
        if let Err(e) = capture.start() {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
        let start_call = t0.elapsed();
        eprintln!("recording {seconds} s (cycle {cycle}/{cycles})...");
        let deadline = t0 + Duration::from_secs_f64(seconds);
        let mut peak_level = 0f32;
        while Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
            peak_level = peak_level.max(capture.level());
        }
        let rec = match capture.stop_recording() {
            Ok(r) => r,
            Err(e) => {
                eprintln!("error: {e}");
                return ExitCode::FAILURE;
            }
        };
        let n = rec.samples.len();
        let rms = if n == 0 {
            0.0
        } else {
            (rec.samples.iter().map(|&v| f64::from(v * v)).sum::<f64>() / n as f64).sqrt()
        };
        let peak = rec.samples.iter().fold(0f32, |m, &v| m.max(v.abs()));
        println!(
            "cycle {cycle}: {:.2} s of audio ({n} samples), RMS {rms:.4} ({:.1} dBFS), peak {peak:.3}, \
             max level {peak_level:.3}, start() {:.1} ms, first buffer {}, format {:?}{}",
            n as f64 / f64::from(SAMPLE_RATE),
            20.0 * rms.max(1e-9).log10(),
            start_call.as_secs_f64() * 1e3,
            rec.start_latency
                .map(|d| format!("{:.1} ms", d.as_secs_f64() * 1e3))
                .unwrap_or_else(|| "none".into()),
            rec.negotiated,
            if rec.truncated { ", truncated" } else { "" },
        );
    }
    ExitCode::SUCCESS
}

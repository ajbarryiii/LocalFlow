//! Decoder microbenchmark: encoder-side joint projection plus the TDT greedy
//! loop (two LSTM layers, prediction projection, joint output) on the CPU.
//!
//! Weights come from a verified export (`--export DIR`) or are synthetic.
//! Encoder outputs are synthetic, so decisions follow a fixed schedule of
//! `--tokens-per-second` emissions (argmax is still computed every step).
//! `--check` instead decodes with real argmax decisions and compares against
//! the f64 reference.

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use lf_cpu::ThreadPool;
use lf_cpu::decoder::{DecoderParams, PackedDecoder, Storage, reference, synthetic_schedule};
use lf_model::Export;
use lf_model::rng::SplitMix64;

const FRAMES_PER_SECOND: f64 = 12.5;

struct Args {
    export: Option<PathBuf>,
    threads: Vec<usize>,
    seconds: Vec<f64>,
    storages: Vec<Storage>,
    tokens_per_second: f64,
    warmup: usize,
    reps: usize,
    check: bool,
}

fn parse_args() -> Result<Args, String> {
    let mut a = Args {
        export: None,
        threads: vec![1, 4, 8, 16],
        seconds: vec![10.0, 30.0, 60.0],
        storages: vec![Storage::F32, Storage::F16],
        tokens_per_second: 4.0,
        warmup: 3,
        reps: 15,
        check: false,
    };
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let mut value = || it.next().ok_or(format!("{flag} needs a value"));
        let nums = |s: String| -> Result<Vec<f64>, String> {
            s.split(',')
                .map(|v| v.trim().parse().map_err(|_| format!("bad number {v}")))
                .collect()
        };
        match flag.as_str() {
            "--export" => a.export = Some(value()?.into()),
            "--threads" => a.threads = nums(value()?)?.into_iter().map(|v| v as usize).collect(),
            "--seconds" => a.seconds = nums(value()?)?,
            "--storage" => {
                a.storages = value()?
                    .split(',')
                    .map(|s| match s.trim() {
                        "f32" => Ok(Storage::F32),
                        "f16" => Ok(Storage::F16),
                        other => Err(format!("unknown storage {other}")),
                    })
                    .collect::<Result<_, _>>()?
            }
            "--tokens-per-second" => {
                a.tokens_per_second = value()?.parse().map_err(|_| "bad rate")?
            }
            "--warmup" => a.warmup = value()?.parse().map_err(|_| "bad --warmup")?,
            "--reps" => a.reps = value()?.parse().map_err(|_| "bad --reps")?,
            "--check" => a.check = true,
            "-h" | "--help" => {
                return Err(
                    "usage: lf-decoder-bench [--export DIR] [--threads 1,4,8,16] \
                     [--seconds 10,30,60] [--storage f32,f16] [--tokens-per-second 4] \
                     [--warmup N] [--reps N] [--check]"
                        .into(),
                );
            }
            _ => return Err(format!("unknown argument {flag}")),
        }
    }
    if a.threads.iter().any(|&t| t == 0 || t > 16) || a.reps == 0 {
        return Err("--threads must be 1..=16 and --reps at least 1".into());
    }
    Ok(a)
}

fn median(mut v: Vec<Duration>) -> Duration {
    v.sort();
    v[v.len() / 2]
}

fn encoder_frames(frames: usize, dim: usize, seed: u64) -> Vec<f32> {
    let mut rng = SplitMix64::new(seed);
    (0..frames * dim).map(|_| rng.next_gaussian()).collect()
}

/// Returns whether every configuration matched the reference.
fn check(p: &DecoderParams) -> bool {
    let mut all_match = true;
    println!("\nReal-argmax decode vs f64 reference (synthetic encoder output)");
    let frames = 125;
    let enc = encoder_frames(frames, p.enc_dim, 99);
    let start = Instant::now();
    let (expected, decisions) = reference::decode(p, &enc, frames);
    println!(
        "reference: {} decisions, {} emissions in {:.1?}",
        decisions.len(),
        expected.len(),
        start.elapsed()
    );
    for storage in [Storage::F32, Storage::F16] {
        let d = PackedDecoder::new(p, storage);
        for threads in [1, 8] {
            let pool = ThreadPool::new(&(0..threads).collect::<Vec<_>>());
            let proj = d.project_encoder(&pool, &enc, frames);
            let got = d.decode(&pool, &proj, frames, None);
            all_match &= got == expected;
            println!(
                "{storage:?}, {threads} threads: {}",
                if got == expected {
                    "identical emissions".to_string()
                } else {
                    format!("DIFFERS ({} vs {})", got.len(), expected.len())
                }
            );
        }
    }
    all_match
}

fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    if !lf_cpu::cpu_supported() {
        eprintln!("this CPU lacks AVX-512 F/BW/VNNI/VBMI");
        return ExitCode::FAILURE;
    }
    let load = Instant::now();
    let params = match &args.export {
        Some(dir) => match Export::open(dir)
            .and_then(|e| DecoderParams::from_export(&e.tensors, vec![0, 1, 2, 3, 4]))
        {
            Ok(p) => p,
            Err(e) => {
                eprintln!("{}: {e}", dir.display());
                return ExitCode::FAILURE;
            }
        },
        None => DecoderParams::random(1025, 640, 1024, 640, 1),
    };
    let blank_row = &params.embed[params.blank() * params.hidden..];
    println!(
        "weights: {}, loaded in {:.2?}; blank embedding all zero: {}",
        if args.export.is_some() {
            "export (hash-verified)"
        } else {
            "synthetic"
        },
        load.elapsed(),
        blank_row.iter().all(|&v| v == 0.0)
    );

    let max_frames = args
        .seconds
        .iter()
        .map(|s| (s * FRAMES_PER_SECOND).round() as usize)
        .max()
        .unwrap_or(1);
    let enc = encoder_frames(max_frames, params.enc_dim, 7);

    println!(
        "\nDecoder: {} tokens/s, 1 blank decision per 10 emissions; times are medians",
        args.tokens_per_second
    );
    println!(
        "| storage | threads | audio s | tokens | enc proj ms | decode ms | µs / token | total ms |"
    );
    println!("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |");
    for &storage in &args.storages {
        let d = PackedDecoder::new(&params, storage);
        eprintln!(
            "{storage:?}: {:.1} MB of weights per token step",
            d.bytes_per_token_step() as f64 / 1e6
        );
        for &threads in &args.threads {
            let pool = ThreadPool::new(&(0..threads).collect::<Vec<_>>());
            for &secs in &args.seconds {
                let frames = (secs * FRAMES_PER_SECOND).round() as usize;
                let tokens = (secs * args.tokens_per_second).round() as usize;
                let sched = synthetic_schedule(frames, tokens, params.vocab, 3);
                let mut proj_t = Vec::new();
                let mut dec_t = Vec::new();
                for rep in 0..args.warmup + args.reps {
                    let t0 = Instant::now();
                    let proj = d.project_encoder(&pool, &enc, frames);
                    let t1 = Instant::now();
                    let out = d.decode(&pool, &proj, frames, Some(&sched));
                    let t2 = Instant::now();
                    assert_eq!(out.len(), tokens);
                    if rep >= args.warmup {
                        proj_t.push(t1 - t0);
                        dec_t.push(t2 - t1);
                    }
                }
                let (p, dd) = (median(proj_t), median(dec_t));
                println!(
                    "| {storage:?} | {threads} | {secs:.0} | {tokens} | {:.2} | {:.2} | {:.1} | {:.2} |",
                    p.as_secs_f64() * 1e3,
                    dd.as_secs_f64() * 1e3,
                    dd.as_secs_f64() * 1e6 / tokens as f64,
                    (p + dd).as_secs_f64() * 1e3,
                );
            }
        }
    }

    if args.check && !check(&params) {
        eprintln!("decoder output differs from the f64 reference");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

//! Phase 0 microbenchmark: all ternary encoder GEMMs of Parakeet TDT 0.6B on
//! the CPU, per activation variant, frame count and thread count.
//!
//! Weights come from verified exports (`--export DIR`, ternary or binary) or
//! are synthetic. With several exports, each repetition times one pass of
//! every export in a rotating order, and the table adds each export's median
//! paired time ratio to the first, so a busy machine affects all of them alike.
//! Activations are always synthetic. Only the ternary projections are timed;
//! attention scores, convolutions, norms, the frontend and the decoder are not.

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use lf_cpu::gemm_lut::{LutConfig, LutWorkspace};
use lf_cpu::gemm_ref::{compare, reference};
use lf_cpu::{
    Encoding, PackedTernary, QuantizedActs, Scratch, ThreadPool, gemm_f32, gemm_i8, gemm_lut,
};
use lf_model::rng::SplitMix64;
use lf_model::{
    BinaryMatrix, ENCODER_LAYERS, Export, LAYER_TERNARY_MODULES, QuantizedMatrix, TernaryMatrix,
    WeightFormat,
};

const POS: usize = 5;
/// Encoder frames per second of audio (10 ms hop, 8x subsampling).
const FRAMES_PER_SECOND: f64 = 12.5;

#[derive(Clone, Copy)]
enum Variant {
    F32,
    I8(usize),
    /// Exact-FP32 lookup tables (`gemm_lut`), configured by `--lut-*`.
    Lut,
}

impl Variant {
    fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "f32" => Variant::F32,
            "i8x1" => Variant::I8(1),
            "i8x2" => Variant::I8(2),
            "i8x3" => Variant::I8(3),
            "lut" => Variant::Lut,
            _ => return None,
        })
    }

    fn name(self) -> String {
        match self {
            Variant::F32 => "f32".into(),
            Variant::I8(n) => format!("i8x{n}"),
            Variant::Lut => "lut".into(),
        }
    }
}

struct Args {
    /// Every export is timed, interleaved pass by pass (paired timing).
    exports: Vec<PathBuf>,
    /// Weight format of the synthetic model when no export is given.
    synthetic: WeightFormat,
    /// CPUs to pin the pool to, in order; `threads` takes the first entries.
    cpus: Vec<usize>,
    /// MiB written between timed passes to evict the caches; 0 keeps them warm.
    cold_mib: usize,
    threads: Vec<usize>,
    frames: Vec<usize>,
    variants: Vec<Variant>,
    warmup: usize,
    reps: usize,
    accuracy: bool,
    peak: bool,
    lut: LutConfig,
}

fn parse_args() -> Result<Args, String> {
    let mut a = Args {
        exports: Vec::new(),
        synthetic: WeightFormat::Ternary,
        // Physical cores only; 0-7 share the 96 MiB V-cache L3.
        cpus: (0..16).collect(),
        cold_mib: 0,
        threads: vec![8],
        frames: vec![25, 63, 125, 188, 375],
        variants: vec![Variant::F32, Variant::I8(1), Variant::I8(2), Variant::I8(3)],
        warmup: 2,
        reps: 7,
        accuracy: false,
        peak: false,
        lut: LutConfig::default(),
    };
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let mut value = || it.next().ok_or(format!("{flag} needs a value"));
        let list = |s: String| -> Result<Vec<usize>, String> {
            s.split(',')
                .map(|v| v.trim().parse().map_err(|_| format!("bad number {v}")))
                .collect()
        };
        match flag.as_str() {
            "--export" => a.exports.push(value()?.into()),
            "--synthetic" => {
                a.synthetic = match value()?.as_str() {
                    "ternary" => WeightFormat::Ternary,
                    "binary" => WeightFormat::Binary,
                    _ => return Err("--synthetic takes ternary or binary".into()),
                }
            }
            "--cpus" => a.cpus = list(value()?)?,
            "--cold-mib" => a.cold_mib = value()?.parse().map_err(|_| "bad --cold-mib")?,
            "--threads" => a.threads = list(value()?)?,
            "--frames" => a.frames = list(value()?)?,
            "--variants" => {
                a.variants = value()?
                    .split(',')
                    .map(|v| Variant::parse(v.trim()).ok_or(format!("unknown variant {v}")))
                    .collect::<Result<_, _>>()?
            }
            "--warmup" => a.warmup = value()?.parse().map_err(|_| "bad --warmup")?,
            "--reps" => a.reps = value()?.parse().map_err(|_| "bad --reps")?,
            "--accuracy" => a.accuracy = true,
            "--peak" => a.peak = true,
            "--lut-panel" => {
                a.lut.panel_vectors = value()?.parse().map_err(|_| "bad --lut-panel")?
            }
            "--lut-micro" => {
                a.lut.micro_frames = value()?.parse().map_err(|_| "bad --lut-micro")?
            }
            "--lut-chunk" => {
                a.lut.chunk_frames = value()?.parse().map_err(|_| "bad --lut-chunk")?
            }
            "--lut-kc" => a.lut.kc_groups = value()?.parse().map_err(|_| "bad --lut-kc")?,
            "--lut-groups" => {
                let v = value()?;
                a.lut.frame_groups = match v.as_str() {
                    "auto" => 0,
                    _ => v.parse().map_err(|_| "bad --lut-groups")?,
                };
            }
            "--lut-budget-mib" => {
                let mib: usize = value()?.parse().map_err(|_| "bad --lut-budget-mib")?;
                a.lut.table_budget = mib.checked_mul(1 << 20).ok_or("bad --lut-budget-mib")?;
            }
            "-h" | "--help" => {
                return Err(
                    "usage: lf-gemm-bench [--export DIR]... [--synthetic ternary|binary] \
                     [--cpus 0,1,...] [--cold-mib N] [--threads 1,4,8,16] \
                     [--frames 25,63,125,188,375] [--variants f32,i8x1,i8x2,i8x3,lut] \
                     [--warmup N] [--reps N] [--accuracy] [--peak] \
                     [--lut-panel 4|8] [--lut-micro N] [--lut-chunk FRAMES] \
                     [--lut-budget-mib N] [--lut-kc GROUPS] [--lut-groups N|auto]"
                        .into(),
                );
            }
            _ => return Err(format!("unknown argument {flag}")),
        }
    }
    a.lut.validate()?;
    if a.threads.iter().any(|&t| t == 0 || t > 16) {
        return Err("--threads values must be 1..=16".into());
    }
    if a.threads.iter().any(|&t| t > a.cpus.len()) {
        return Err("--threads values must not exceed the number of --cpus".into());
    }
    if a.reps == 0 {
        return Err("--reps must be at least 1".into());
    }
    Ok(a)
}

struct Model {
    /// The weight format, as the table and memory report show it.
    name: String,
    /// `[layer][module]`, module order as in `LAYER_TERNARY_MODULES`.
    layers: Vec<Vec<PackedTernary>>,
    /// Layer 0 as ternary codes (binary widened), for accuracy checks.
    layer0: Vec<TernaryMatrix>,
}

fn load_model(export: Option<&PathBuf>, synthetic: WeightFormat) -> Result<Model, String> {
    let export = match export {
        Some(dir) => Some(Export::open(dir).map_err(|e| format!("{}: {e}", dir.display()))?),
        None => None,
    };
    let name = match &export {
        Some(e) => e.format.name().to_string(),
        None => format!("synthetic {}", synthetic.name()),
    };
    let mut layers = Vec::with_capacity(ENCODER_LAYERS);
    let mut layer0 = Vec::new();
    for l in 0..ENCODER_LAYERS {
        let mut mats = Vec::with_capacity(LAYER_TERNARY_MODULES.len());
        for (mi, module) in LAYER_TERNARY_MODULES.iter().enumerate() {
            let m = match &export {
                Some(e) => QuantizedMatrix::from_export(
                    &e.tensors,
                    e.format,
                    &format!("encoder.layers.{l}.{module}"),
                )
                .map_err(|e| e.to_string())?,
                None => {
                    let (rows, cols) = synthetic_shape(module);
                    let seed = (l * 100 + mi) as u64;
                    match synthetic {
                        WeightFormat::Ternary => {
                            QuantizedMatrix::Ternary(TernaryMatrix::random(rows, cols, seed))
                        }
                        WeightFormat::Binary => {
                            QuantizedMatrix::Binary(BinaryMatrix::random(rows, cols, seed))
                        }
                    }
                }
            };
            mats.push(PackedTernary::pack(&m).map_err(|e| format!("{module}: {e}"))?);
            if l == 0 {
                layer0.push(m.to_ternary());
            }
        }
        layers.push(mats);
    }
    Ok(Model {
        name,
        layers,
        layer0,
    })
}

fn synthetic_shape(module: &str) -> (usize, usize) {
    match module {
        "feed_forward1.linear1" | "feed_forward2.linear1" => (4096, 1024),
        "feed_forward1.linear2" | "feed_forward2.linear2" => (1024, 4096),
        "conv.pointwise_conv1" => (2048, 1024),
        _ => (1024, 1024),
    }
}

/// LayerNorm-like activations: unit Gaussian with a few large outlier channels.
fn activations(rows: usize, cols: usize, seed: u64) -> Vec<f32> {
    let mut rng = SplitMix64::new(seed);
    (0..rows * cols)
        .map(|i| {
            rng.next_gaussian()
                * if (i % cols).is_multiple_of(97) {
                    12.0
                } else {
                    1.0
                }
        })
        .collect()
}

struct Buffers {
    x1024: Vec<f32>,
    x4096: Vec<f32>,
    y: Vec<f32>,
    q1024: Vec<QuantizedActs>,
    q4096: Vec<QuantizedActs>,
}

impl Buffers {
    fn new(max_frames: usize) -> Self {
        let rows = 2 * max_frames;
        Buffers {
            x1024: activations(rows, 1024, 1),
            x4096: activations(rows, 4096, 2),
            y: vec![0.0; rows * 4096],
            q1024: (1..=3)
                .map(|n| QuantizedActs::with_capacity(rows, 1024, n))
                .collect(),
            q4096: (1..=3)
                .map(|n| QuantizedActs::with_capacity(rows, 4096, n))
                .collect(),
        }
    }
}

/// Runs one pass over the selected modules of every layer.
#[allow(clippy::too_many_arguments)]
fn run_pass(
    pool: &ThreadPool,
    scratch: &Scratch,
    lut: &mut LutWorkspace,
    model: &Model,
    buf: &mut Buffers,
    variant: Variant,
    frames: usize,
    pos_only: bool,
) {
    for layer in &model.layers {
        for (mi, w) in layer.iter().enumerate() {
            if (mi == POS) != pos_only {
                continue;
            }
            let rows = if mi == POS { 2 * frames - 1 } else { frames };
            let x = if w.cols() == 4096 {
                &buf.x4096
            } else {
                &buf.x1024
            };
            match variant {
                Variant::F32 => gemm_f32::gemm(pool, scratch, w, x, rows, &mut buf.y),
                Variant::I8(n) => {
                    let qs = if w.cols() == 4096 {
                        &mut buf.q4096
                    } else {
                        &mut buf.q1024
                    };
                    let qa = &mut qs[n - 1];
                    // k and v reuse the activations quantized for q.
                    if !(mi == 3 || mi == 4) {
                        qa.quantize(pool, x, rows).expect("finite activations");
                    }
                    gemm_i8::gemm(pool, scratch, w, qa, &mut buf.y);
                }
                Variant::Lut => gemm_lut::gemm(pool, lut, w, x, rows, &mut buf.y),
            }
        }
    }
}

/// Times `reps` passes of each of `models` after `warmup` untimed rounds.
/// Round `r` runs the models in order starting at `r % models`, and `evict`
/// runs untimed before every pass. Returns each model's times in round order.
fn time_paired(
    models: usize,
    reps: usize,
    warmup: usize,
    mut evict: impl FnMut(),
    mut pass: impl FnMut(usize),
) -> Vec<Vec<Duration>> {
    let mut times = vec![Vec::with_capacity(reps); models];
    for round in 0..warmup + reps {
        for i in 0..models {
            let m = (round + i) % models;
            evict();
            let start = Instant::now();
            pass(m);
            let elapsed = start.elapsed();
            if round >= warmup {
                times[m].push(elapsed);
            }
        }
    }
    times
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(f64::total_cmp);
    v[v.len() / 2]
}

/// Per-thread buffers written between passes to push the weights out of
/// every cache the pool's CPUs use (each CCD has its own L3).
struct Evictor {
    bufs: Vec<std::sync::Mutex<Vec<u8>>>,
}

impl Evictor {
    fn new(threads: usize, mib: usize) -> Self {
        let per_thread = (mib << 20).div_ceil(threads.max(1));
        Evictor {
            bufs: (0..threads)
                .map(|_| std::sync::Mutex::new(vec![0u8; if mib == 0 { 0 } else { per_thread }]))
                .collect(),
        }
    }

    fn run(&self, pool: &ThreadPool) {
        if self.bufs.iter().all(|b| b.lock().unwrap().is_empty()) {
            return;
        }
        pool.run(&|idx| {
            let mut buf = self.bufs[idx].lock().unwrap();
            for line in buf.chunks_mut(64) {
                line[0] = line[0].wrapping_add(1);
            }
            std::hint::black_box(&*buf);
        });
    }
}

/// Multiply-accumulates per frame across the timed (non-`linear_pos`) projections.
fn macs_per_frame(model: &Model) -> f64 {
    model.layers[0]
        .iter()
        .enumerate()
        .filter(|(mi, _)| *mi != POS)
        .map(|(_, w)| (w.rows() * w.cols()) as f64)
        .sum::<f64>()
        * model.layers.len() as f64
}

fn accuracy(model: &Model, lut: LutConfig) {
    let pool = ThreadPool::new(&[0]);
    let scratch = Scratch::new(
        1,
        gemm_i8::scratch_bytes(4096).max(gemm_f32::scratch_bytes()),
    );
    let mut lut = LutWorkspace::new(lut).expect("validated config");
    let frames = 63;
    println!("\nAccuracy vs f64 reference, layer 0, {frames} frames, synthetic activations");
    println!("| module | variant | rel RMS error | worst abs / RMS |");
    println!("| --- | --- | ---: | ---: |");
    for mi in [0, 1, 2, 7] {
        let m = &model.layer0[mi];
        let w = &model.layers[0][mi];
        let x = activations(frames, m.cols, 3);
        let reference = reference(m, &x, frames);
        let mut y = vec![0.0; frames * m.rows];
        gemm_f32::gemm(&pool, &scratch, w, &x, frames, &mut y);
        let row = |name: String, (rel, worst): (f64, f64)| {
            println!(
                "| {} | {name} | {rel:.2e} | {worst:.2e} |",
                LAYER_TERNARY_MODULES[mi]
            );
        };
        row("f32".into(), compare(&y, &reference));
        for n in 1..=3 {
            let mut qa = QuantizedActs::with_capacity(frames, m.cols, n);
            qa.quantize(&pool, &x, frames).unwrap();
            gemm_i8::gemm(&pool, &scratch, w, &qa, &mut y);
            row(format!("i8x{n}"), compare(&y, &reference));
        }
        if w.encoding() == Encoding::Ternary {
            gemm_lut::gemm(&pool, &mut lut, w, &x, frames, &mut y);
            row("lut".into(), compare(&y, &reference));
        }
    }
}

/// Resident bytes per ternary weight, and the kernel workspace each variant
/// needs beyond the activations `x` and outputs `y` (which every variant
/// shares). Workspace is the most any timed configuration needs: every
/// thread count and frame count in the run, every call shape of a pass.
fn memory(model: &Model, args: &Args, lut_retained: usize) {
    let (mut params, mut bytes) = (0usize, 0usize);
    for w in model.layers.iter().flatten() {
        params += w.rows() * w.cols();
        // Packed codes, f32 scale and i32 row sum per output row.
        bytes += w.code_bytes() + w.rows() * 8;
    }
    println!(
        "\nMemory ({}): {params} weights in 264 projections; workspace excludes x and y, \
         maximized over threads {:?} and frames {:?}",
        model.name, args.threads, args.frames
    );
    println!("| variant | weights MB | bytes / weight | workspace MB | workspace contents |");
    println!("| --- | ---: | ---: | ---: | --- |");
    let mb = |b: usize| b as f64 / 1e6;
    let per_weight = bytes as f64 / params as f64;
    let configs = || {
        args.threads
            .iter()
            .flat_map(|&th| args.frames.iter().map(move |&f| (th, f)))
    };
    for &variant in &args.variants {
        let (ws, what) = match variant {
            Variant::F32 => (
                configs()
                    .map(|(th, _)| th * gemm_f32::scratch_bytes())
                    .max()
                    .unwrap_or(0),
                "per-thread f32 tiles".to_string(),
            ),
            // As `lf-asr`'s `Projector` holds them: 1024-wide model inputs,
            // 4096-wide FF inputs and the 1024-wide position embedding
            // (2T - 1 rows), each with a per-frame scale.
            Variant::I8(n) => (
                configs()
                    .map(|(th, f)| {
                        let rows = f + f + (2 * f - 1);
                        th * gemm_i8::scratch_bytes(4096)
                            + n * (f * 1024 + f * 4096 + (2 * f - 1) * 1024)
                            + 4 * rows
                    })
                    .max()
                    .unwrap_or(0),
                "per-thread s8 tiles + quantized activations".to_string(),
            ),
            Variant::Lut => {
                let need = configs()
                    .map(|(th, f)| {
                        let tables = [(2 * f - 1, 1024), (f, 1024), (f, 4096)]
                            .iter()
                            .map(|&(t, k)| {
                                let p = gemm_lut::Plan::new(&args.lut, th, t, k);
                                p.groups * p.table_bytes()
                            })
                            .max()
                            .unwrap_or(0);
                        tables + th * args.lut.kc_groups * args.lut.panel_vectors * 64
                    })
                    .max()
                    .unwrap_or(0);
                (
                    need,
                    format!(
                        "per-group tables + per-thread index tiles; retained by the \
                         grow-only workspace in this run: {:.2} MB",
                        mb(lut_retained)
                    ),
                )
            }
        };
        println!(
            "| {} | {:.1} | {per_weight:.3} | {:.2} | {what} |",
            variant.name(),
            mb(bytes),
            mb(ws)
        );
    }
}

/// Register-only VNNI and FMA throughput with every thread busy.
fn peak(thread_counts: &[usize]) {
    use lf_cpu::peak;
    use peak::LutAccumulate;
    use std::sync::atomic::{AtomicU64, Ordering};
    const ITERS: u64 = 20_000_000;
    type Probe = (&'static str, fn(u64) -> u64, fn(u64) -> u64);
    let probes: [Probe; 9] = [
        ("VNNI u8xs8", |n| peak::vnni(n) as u64, peak::vnni_macs),
        ("FMA f32", |n| peak::fma(n) as u64, peak::fma_macs),
        (
            "LUT perm+add",
            |n| peak::lut(n, LutAccumulate::Add) as u64,
            peak::lut_macs,
        ),
        (
            "LUT perm+fma1",
            |n| peak::lut(n, LutAccumulate::FmaOne) as u64,
            peak::lut_macs,
        ),
        (
            "LUT mixed",
            |n| peak::lut(n, LutAccumulate::Mixed) as u64,
            peak::lut_macs,
        ),
        (
            "LUT load idx+permi2+add",
            |n| peak::lut_load(n, false) as u64,
            peak::lut_macs,
        ),
        (
            "LUT load table+permt2+add",
            |n| peak::lut_load(n, true) as u64,
            peak::lut_macs,
        ),
        (
            "LUT sym vpermps+fma",
            |n| peak::lut_sym(n, true) as u64,
            peak::lut_macs,
        ),
        (
            "LUT sym vpermps+add",
            |n| peak::lut_sym(n, false) as u64,
            peak::lut_macs,
        ),
    ];
    println!("GMAC/s (LUT rows count 48 multiply-accumulate equivalents per lookup)");
    print!("| threads |");
    probes.iter().for_each(|(name, _, _)| print!(" {name} |"));
    println!("\n| ---: |{}", " ---: |".repeat(probes.len()));
    for &threads in thread_counts {
        let pool = ThreadPool::new(&(0..threads).collect::<Vec<_>>());
        let sink = AtomicU64::new(0);
        print!("| {threads} |");
        for (_, run, macs) in probes {
            // One warm-up pass lets clocks settle at their all-core level.
            let mut rate = 0.0;
            for timed in [false, true] {
                let start = Instant::now();
                pool.run(&|_| {
                    sink.fetch_add(run(ITERS), Ordering::Relaxed);
                });
                if timed {
                    rate =
                        macs(ITERS) as f64 * threads as f64 / start.elapsed().as_secs_f64() / 1e9;
                }
            }
            print!(" {rate:.0} |");
        }
        println!();
        std::hint::black_box(sink.load(Ordering::Relaxed));
    }
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
    if args.peak {
        peak(&args.threads);
        return ExitCode::SUCCESS;
    }
    let load_start = Instant::now();
    let sources: Vec<Option<&PathBuf>> = if args.exports.is_empty() {
        vec![None]
    } else {
        args.exports.iter().map(Some).collect()
    };
    let mut models = Vec::with_capacity(sources.len());
    for source in sources {
        match load_model(source, args.synthetic) {
            Ok(m) => models.push(m),
            Err(e) => {
                eprintln!("{e}");
                return ExitCode::FAILURE;
            }
        }
    }
    let source = if args.exports.is_empty() {
        "synthetic"
    } else {
        "export (hash-verified)"
    };
    println!(
        "weights: {source}, {} model(s) loaded and packed in {:.2?}; cache eviction between \
         passes: {} MiB",
        models.len(),
        load_start.elapsed(),
        args.cold_mib
    );

    let max_frames = args.frames.iter().copied().max().unwrap_or(1);
    let mut buf = Buffers::new(max_frames);
    let scratch_bytes = gemm_i8::scratch_bytes(4096).max(gemm_f32::scratch_bytes());
    let enc_macs = macs_per_frame(&models[0]);

    println!("\nTernary encoder GEMMs (24 layers x 10 projections; linear_pos timed separately)");
    println!(
        "| model | variant | threads | frames | audio s | median ms | min ms | GMAC/s | \
         vs first | linear_pos ms |"
    );
    println!("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |");
    let mut lut_retained = 0;
    for &threads in &args.threads {
        let pool = ThreadPool::new(&args.cpus[..threads]);
        let scratch = Scratch::new(threads, scratch_bytes);
        let evictor = Evictor::new(threads, args.cold_mib);
        let mut lut = LutWorkspace::new(args.lut).expect("validated config");
        for &variant in &args.variants {
            // The lookup-table kernel reads 2-bit codes only.
            let timed: Vec<usize> = (0..models.len())
                .filter(|&m| {
                    !matches!(variant, Variant::Lut)
                        || models[m].layers[0][0].encoding() == Encoding::Ternary
                })
                .collect();
            if timed.is_empty() {
                continue;
            }
            for &frames in &args.frames {
                let mut time = |pos_only: bool| {
                    time_paired(
                        timed.len(),
                        args.reps,
                        args.warmup,
                        || evictor.run(&pool),
                        |i| {
                            run_pass(
                                &pool,
                                &scratch,
                                &mut lut,
                                &models[timed[i]],
                                &mut buf,
                                variant,
                                frames,
                                pos_only,
                            )
                        },
                    )
                };
                let main = time(false);
                let pos = time(true);
                let ms = |d: &Duration| d.as_secs_f64() * 1e3;
                for (i, &m) in timed.iter().enumerate() {
                    let med = median(main[i].iter().map(ms).collect());
                    let min = main[i].iter().map(ms).fold(f64::INFINITY, f64::min);
                    let ratio = median(
                        main[i]
                            .iter()
                            .zip(&main[0])
                            .map(|(a, b)| a.as_secs_f64() / b.as_secs_f64())
                            .collect(),
                    );
                    let gmacs = enc_macs * frames as f64 / med / 1e6;
                    println!(
                        "| {} | {} | {threads} | {frames} | {:.1} | {med:.2} | {min:.2} | \
                         {gmacs:.0} | {ratio:.3} | {:.2} |",
                        models[m].name,
                        variant.name(),
                        frames as f64 / FRAMES_PER_SECOND,
                        median(pos[i].iter().map(ms).collect()),
                    );
                }
            }
        }
        lut_retained = lut_retained.max(lut.bytes());
    }

    if args.variants.iter().any(|v| matches!(v, Variant::Lut)) {
        println!(
            "\nlut config: {:?} (frame_groups 0 = threads / 2, at most 4)",
            args.lut
        );
    }
    for model in &models {
        memory(model, &args, lut_retained);
    }
    if args.accuracy {
        accuracy(&models[0], args.lut);
    }
    ExitCode::SUCCESS
}

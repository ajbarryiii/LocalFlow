//! End-to-end evaluation on public test sets.
//!
//! Sources (combine freely):
//! - `--eval EVAL_JSON:MANIFEST_JSONL`: an M1 evaluation file (records with
//!   `id`, `ref`, `hyp`) joined by `id` with a manifest (`audio_filepath`,
//!   `duration`); utterances between `--min-seconds` and `--max-seconds`.
//!   Audio is decoded one utterance at a time, so whole sets fit in memory.
//! - `--joined LIBRISPEECH_SPLIT_DIR`: consecutive utterances of one chapter
//!   concatenated to `--min-seconds`..`--max-seconds`, at most `--joined-count`
//!   clips, one per chapter. Reference texts are joined; with
//!   `--joined-hyps EVAL_JSON` the per-segment M1 hypotheses are joined too
//!   (a rough comparison, since the model saw the segments separately).
//!
//! Selection: `--ids FILE` keeps only the listed ids (one per line), then
//! `--offset N --limit N` take a chunk, so long sets can be run in pieces.
//!
//! Outputs: per-utterance metrics (unless `--quiet`) and a summary.
//! Transcripts are only printed with `--show`. `--save-hyps PATH` writes one
//! JSON line per utterance (`id`, `set`, `precision`, `text`, `tokens`, ...)
//! for `lf-hypcompare`; the path must be outside any Git work tree.
//!
//! `--analyze f32,i8x3,i8x2` runs a diagnostic instead: for each selected
//! utterance the encoder runs at every listed precision and the scalar f64
//! reference decoder reports, per precision, where its greedy decisions first
//! diverge from the first listed precision and the top-2 logit margins there,
//! and the smallest margins in the stretch where the text leaves M1's.

mod wer;

use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

use lf_asr::config::{D_MODEL, DURATIONS};
use lf_asr::encoder::{self, EncoderBuffers, Projector};
use lf_asr::frontend::{self, FrontendBuffers};
use lf_asr::{MAX_SECONDS, Model, Precision, Timings, Transcriber};
use lf_cpu::ThreadPool;
use lf_cpu::decoder::{DecoderParams, Storage, reference};
use lf_model::Export;
use wer::{Errors, align, edits, normalize, text_edits};

const SAMPLE_RATE: u32 = 16_000;

enum Audio {
    Memory(Vec<f32>),
    /// Decoded when the utterance is processed.
    Flac(PathBuf),
}

struct Item {
    id: String,
    set: String,
    audio: Audio,
    reference: String,
    /// M1 hypothesis on exactly this audio, if known.
    m1: Option<String>,
    /// M1 hypotheses of the segments, joined (for concatenated clips).
    m1_joined: Option<String>,
}

impl Item {
    fn samples(&self) -> Result<Cow<'_, [f32]>, String> {
        match &self.audio {
            Audio::Memory(s) => Ok(Cow::Borrowed(s)),
            Audio::Flac(p) => read_flac(p).map(Cow::Owned),
        }
    }
}

struct Args {
    export: PathBuf,
    evals: Vec<(PathBuf, PathBuf)>,
    joined: Option<PathBuf>,
    joined_count: usize,
    joined_hyps: Option<PathBuf>,
    min_s: f64,
    max_s: f64,
    threads: usize,
    precision: Precision,
    warmup: usize,
    show: bool,
    quiet: bool,
    /// Synthetic signal lengths (seconds) for a smoke and timing run without data.
    synthetic: Vec<f64>,
    ids: Option<PathBuf>,
    offset: usize,
    limit: Option<usize>,
    save_hyps: Option<PathBuf>,
    analyze: Vec<Precision>,
}

/// Deterministic tones plus noise; no speech, so only timing and robustness are meaningful.
fn synthetic_item(seconds: f64) -> Item {
    let n = (seconds * SAMPLE_RATE as f64) as usize;
    let mut rng = lf_model::rng::SplitMix64::new(42);
    let samples = (0..n)
        .map(|i| {
            let t = i as f32 / SAMPLE_RATE as f32;
            0.1 * (2.0 * std::f32::consts::PI * 220.0 * t).sin()
                + 0.05 * (2.0 * std::f32::consts::PI * 1375.0 * t).sin()
                + 0.01 * rng.next_gaussian()
        })
        .collect();
    Item {
        id: format!("synthetic-{seconds}s"),
        set: "synthetic".into(),
        audio: Audio::Memory(samples),
        reference: String::new(),
        m1: None,
        m1_joined: None,
    }
}

fn parse_precision(s: &str) -> Result<Precision, String> {
    Ok(match s {
        "f32" => Precision::F32,
        "i8x1" => Precision::Int8(1),
        "i8x2" => Precision::Int8(2),
        "i8x3" => Precision::Int8(3),
        other => return Err(format!("unknown precision {other}")),
    })
}

fn precision_name(p: Precision) -> String {
    match p {
        Precision::F32 => "f32".into(),
        Precision::Int8(n) => format!("i8x{n}"),
    }
}

fn parse_args_from(argv: impl IntoIterator<Item = String>) -> Result<Args, String> {
    let mut export = None;
    let mut a = Args {
        export: PathBuf::new(),
        evals: Vec::new(),
        joined: None,
        joined_count: 20,
        joined_hyps: None,
        min_s: 30.0,
        max_s: 60.0,
        threads: 8,
        precision: Precision::Int8(3),
        warmup: 1,
        show: false,
        quiet: false,
        synthetic: Vec::new(),
        ids: None,
        offset: 0,
        limit: None,
        save_hyps: None,
        analyze: Vec::new(),
    };
    let mut it = argv.into_iter();
    while let Some(flag) = it.next() {
        let mut value = || it.next().ok_or(format!("{flag} needs a value"));
        match flag.as_str() {
            "--export" => export = Some(PathBuf::from(value()?)),
            "--eval" => {
                let v = value()?;
                let (e, m) = v
                    .split_once(':')
                    .ok_or("--eval takes EVAL_JSON:MANIFEST_JSONL")?;
                a.evals.push((e.into(), m.into()));
            }
            "--joined" => a.joined = Some(value()?.into()),
            "--joined-count" => {
                a.joined_count = value()?.parse().map_err(|_| "bad --joined-count")?
            }
            "--joined-hyps" => a.joined_hyps = Some(value()?.into()),
            "--min-seconds" => a.min_s = value()?.parse().map_err(|_| "bad --min-seconds")?,
            "--max-seconds" => a.max_s = value()?.parse().map_err(|_| "bad --max-seconds")?,
            "--threads" => a.threads = value()?.parse().map_err(|_| "bad --threads")?,
            "--precision" => a.precision = parse_precision(&value()?)?,
            "--warmup" => a.warmup = value()?.parse().map_err(|_| "bad --warmup")?,
            "--show" => a.show = true,
            "--quiet" => a.quiet = true,
            "--synthetic" => {
                a.synthetic = value()?
                    .split(',')
                    .map(|s| {
                        s.trim()
                            .parse::<f64>()
                            .map_err(|_| format!("bad seconds {s}"))
                    })
                    .collect::<Result<_, _>>()?
            }
            "--ids" => a.ids = Some(value()?.into()),
            "--offset" => a.offset = value()?.parse().map_err(|_| "bad --offset")?,
            "--limit" => a.limit = Some(value()?.parse().map_err(|_| "bad --limit")?),
            "--save-hyps" => a.save_hyps = Some(value()?.into()),
            "--analyze" => {
                a.analyze = value()?
                    .split(',')
                    .map(|s| parse_precision(s.trim()))
                    .collect::<Result<_, _>>()?
            }
            "-h" | "--help" => {
                return Err("usage: lf-transcribe --export DIR [--eval EVAL_JSON:MANIFEST_JSONL]... \
                     [--joined LIBRISPEECH_SPLIT_DIR [--joined-count N] [--joined-hyps EVAL_JSON]] \
                     [--min-seconds 30] [--max-seconds 60] [--ids FILE] [--offset N] [--limit N] \
                     [--threads 8] [--precision f32|i8x1|i8x2|i8x3] [--warmup 1] [--show] [--quiet] \
                     [--save-hyps PATH.jsonl] [--synthetic 10,30,60] [--analyze f32,i8x3,i8x2]"
                    .into());
            }
            _ => return Err(format!("unknown argument {flag}")),
        }
    }
    a.export = export.ok_or("--export is required")?;
    if a.threads == 0 || a.threads > 16 {
        return Err("--threads must be 1..=16".into());
    }
    if a.min_s.is_nan() || a.max_s.is_nan() || a.min_s > a.max_s {
        return Err("--min-seconds must not exceed --max-seconds".into());
    }
    if a.analyze.len() == 1 {
        return Err("--analyze needs at least two precisions".into());
    }
    if !a.analyze.is_empty() && a.save_hyps.is_some() {
        return Err("--analyze does not save hypotheses".into());
    }
    if let Some(p) = &a.save_hyps {
        check_output_path(p)?;
    }
    Ok(a)
}

/// Hypotheses must not land in a repository: refuse paths inside a Git work tree.
/// A symbolic link is refused too, since it could point into a repository; the
/// file is then opened without following links (`create_output`).
fn check_output_path(path: &Path) -> Result<(), String> {
    if let Ok(m) = std::fs::symlink_metadata(path)
        && m.file_type().is_symlink()
    {
        return Err(format!(
            "{}: is a symbolic link; refusing to write through it",
            path.display()
        ));
    }
    let parent = match path.parent() {
        Some(p) if !p.as_os_str().is_empty() => p.to_path_buf(),
        _ => PathBuf::from("."),
    };
    let dir = parent
        .canonicalize()
        .map_err(|e| format!("{}: {e}", parent.display()))?;
    if let Some(repo) = dir.ancestors().find(|d| d.join(".git").exists()) {
        return Err(format!(
            "{}: inside the Git work tree {}; write hypotheses outside any repository",
            path.display(),
            repo.display()
        ));
    }
    Ok(())
}

/// Creates or truncates a checked output file, failing if it is a symbolic link.
/// An existing file is truncated only if it is a regular file with a single
/// link, checked on the opened file itself, so a hard link to a file elsewhere
/// (for example in a repository) is never overwritten.
fn create_output(path: &Path) -> Result<std::fs::File, String> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    check_output_path(path)?;
    let err = |e: std::io::Error| format!("{}: {e}", path.display());
    let file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(err)?;
    let meta = file.metadata().map_err(err)?;
    if !meta.is_file() || meta.nlink() != 1 {
        return Err(format!(
            "{}: not a regular file with a single link; refusing to overwrite it",
            path.display()
        ));
    }
    file.set_len(0).map_err(err)?;
    Ok(file)
}

fn read_flac(path: &Path) -> Result<Vec<f32>, String> {
    let mut reader =
        claxon::FlacReader::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let info = reader.streaminfo();
    if info.sample_rate != SAMPLE_RATE || info.channels != 1 || info.bits_per_sample != 16 {
        return Err(format!(
            "{}: need 16 kHz mono 16-bit, got {} Hz, {} ch, {} bit",
            path.display(),
            info.sample_rate,
            info.channels,
            info.bits_per_sample
        ));
    }
    // soundfile's int16 -> float32 conversion: divide by 32768.
    reader
        .samples()
        .map(|s| {
            s.map(|v| v as f32 / 32768.0)
                .map_err(|e| format!("{}: {e}", path.display()))
        })
        .collect()
}

fn read_json(path: &Path) -> Result<serde_json::Value, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    serde_json::from_slice(&bytes).map_err(|e| format!("{}: {e}", path.display()))
}

/// `id -> (ref, hyp)` from an evaluation file.
fn eval_records(path: &Path) -> Result<BTreeMap<String, (String, String)>, String> {
    let v = read_json(path)?;
    let records = v
        .get("records")
        .and_then(|r| r.as_array())
        .ok_or(format!("{}: no records", path.display()))?;
    let mut out = BTreeMap::new();
    for r in records {
        let s = |k: &str| r.get(k).and_then(|v| v.as_str()).map(str::to_owned);
        if let (Some(id), Some(rf), Some(hyp)) = (s("id"), s("ref"), s("hyp"))
            && out.insert(id.clone(), (rf, hyp)).is_some()
        {
            return Err(format!("{}: duplicate id {id}", path.display()));
        }
    }
    Ok(out)
}

fn eval_items(eval: &Path, manifest: &Path, min_s: f64, max_s: f64) -> Result<Vec<Item>, String> {
    let records = eval_records(eval)?;
    let set = eval
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("eval")
        .to_owned();
    let text =
        std::fs::read_to_string(manifest).map_err(|e| format!("{}: {e}", manifest.display()))?;
    let mut items = Vec::new();
    let (mut in_range, mut missing) = (0usize, 0usize);
    let mut seen = BTreeSet::new();
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        let v: serde_json::Value =
            serde_json::from_str(line).map_err(|e| format!("{}: {e}", manifest.display()))?;
        let dur = v.get("duration").and_then(|d| d.as_f64()).unwrap_or(0.0);
        if dur < min_s || dur > max_s {
            continue;
        }
        let (Some(id), Some(audio)) = (
            v.get("id").and_then(|x| x.as_str()),
            v.get("audio_filepath").and_then(|x| x.as_str()),
        ) else {
            continue;
        };
        in_range += 1;
        let Some((reference, hyp)) = records.get(id) else {
            missing += 1;
            continue;
        };
        if !seen.insert(id.to_owned()) {
            return Err(format!("{}: duplicate id {id}", manifest.display()));
        }
        items.push(Item {
            id: id.to_owned(),
            set: set.clone(),
            audio: Audio::Flac(audio.into()),
            reference: reference.clone(),
            m1: Some(hyp.clone()),
            m1_joined: None,
        });
    }
    eprintln!(
        "{set}: {in_range} manifest entries in {min_s}-{max_s} s, {missing} without an M1 record, {} selected",
        items.len()
    );
    Ok(items)
}

/// Concatenated consecutive utterances of LibriSpeech chapters.
fn joined_items(
    dir: &Path,
    count: usize,
    min_s: f64,
    max_s: f64,
    hyps: Option<&BTreeMap<String, (String, String)>>,
) -> Result<Vec<Item>, String> {
    let mut chapters = Vec::new();
    for spk in sorted_dirs(dir)? {
        for chap in sorted_dirs(&spk)? {
            chapters.push(chap);
        }
    }
    let mut items = Vec::new();
    for chap in chapters {
        if items.len() >= count {
            break;
        }
        let name = |p: &Path| {
            p.file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_owned()
        };
        let trans = chap.join(format!(
            "{}-{}.trans.txt",
            name(chap.parent().unwrap()),
            name(&chap)
        ));
        let text =
            std::fs::read_to_string(&trans).map_err(|e| format!("{}: {e}", trans.display()))?;
        let (mut samples, mut refs, mut segment_hyps, mut ids) =
            (Vec::new(), Vec::new(), Vec::new(), Vec::new());
        for line in text.lines() {
            let Some((id, words)) = line.split_once(' ') else {
                continue;
            };
            let audio = read_flac(&chap.join(format!("{id}.flac")))?;
            if (samples.len() + audio.len()) as f64 / SAMPLE_RATE as f64 > max_s {
                break;
            }
            samples.extend_from_slice(&audio);
            refs.push(words.to_lowercase());
            segment_hyps.push(hyps.and_then(|h| h.get(id)).map(|(_, hyp)| hyp.clone()));
            ids.push(id.to_owned());
        }
        if ids.is_empty() || (samples.len() as f64 / SAMPLE_RATE as f64) < min_s {
            continue;
        }
        let m1_joined = segment_hyps.iter().all(Option::is_some).then(|| {
            segment_hyps
                .iter()
                .flatten()
                .cloned()
                .collect::<Vec<_>>()
                .join(" ")
        });
        items.push(Item {
            id: format!(
                "{}..{}",
                ids[0],
                ids.last().unwrap().rsplit('-').next().unwrap_or("")
            ),
            set: "librispeech_joined".into(),
            audio: Audio::Memory(samples),
            reference: refs.join(" "),
            m1: None,
            m1_joined: if hyps.is_some() { m1_joined } else { None },
        });
    }
    Ok(items)
}

fn sorted_dirs(dir: &Path) -> Result<Vec<PathBuf>, String> {
    let mut v: Vec<PathBuf> = std::fs::read_dir(dir)
        .map_err(|e| format!("{}: {e}", dir.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.is_dir())
        .collect();
    v.sort();
    Ok(v)
}

/// Ids listed one per line; blank lines and `#` comments are ignored.
fn parse_id_list(text: &str) -> BTreeSet<String> {
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(str::to_owned)
        .collect()
}

/// Applies `--ids`, then `--offset`/`--limit`, keeping the original order.
fn select(
    items: Vec<Item>,
    ids: Option<&BTreeSet<String>>,
    offset: usize,
    limit: Option<usize>,
) -> Vec<Item> {
    items
        .into_iter()
        .filter(|i| ids.is_none_or(|s| s.contains(&i.id)))
        .skip(offset)
        .take(limit.unwrap_or(usize::MAX))
        .collect()
}

#[derive(Default)]
struct SetStats {
    utterances: usize,
    audio_s: f64,
    words: usize,
    ours: Errors,
    /// M1 on exactly this audio.
    m1: Errors,
    m1_words: usize,
    /// Joined per-segment M1 hypotheses (segmentation baseline).
    seg: Errors,
    seg_words: usize,
    same_text: usize,
    compared: usize,
    /// Word edits between our and M1's normalized hypotheses.
    disagreement: usize,
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    sorted[((sorted.len() - 1) as f64 * p).round() as usize]
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1e3
}

fn main() -> ExitCode {
    match run() {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<bool, String> {
    let args = parse_args_from(std::env::args().skip(1))?;
    let load = Instant::now();
    let export =
        Export::open(&args.export).map_err(|e| format!("{}: {e}", args.export.display()))?;
    let model = Model::load(&export, Storage::F16).map_err(|e| e.to_string())?;
    let params = if args.analyze.is_empty() {
        None
    } else {
        Some(
            DecoderParams::from_export(&export.tensors, DURATIONS.to_vec())
                .map_err(|e| e.to_string())?,
        )
    };
    drop(export);
    eprintln!("model loaded and packed in {:.2?}", load.elapsed());
    let after_load = memory_mib();

    let mut items = Vec::new();
    for (eval, manifest) in &args.evals {
        items.extend(eval_items(eval, manifest, args.min_s, args.max_s)?);
    }
    if let Some(dir) = &args.joined {
        let hyps = args.joined_hyps.as_deref().map(eval_records).transpose()?;
        items.extend(joined_items(
            dir,
            args.joined_count,
            args.min_s,
            args.max_s,
            hyps.as_ref(),
        )?);
    }
    items.extend(args.synthetic.iter().map(|&s| synthetic_item(s)));
    let ids = match &args.ids {
        Some(p) => Some(parse_id_list(
            &std::fs::read_to_string(p).map_err(|e| format!("{}: {e}", p.display()))?,
        )),
        None => None,
    };
    let items = select(items, ids.as_ref(), args.offset, args.limit);
    if items.is_empty() {
        return Err("no utterances selected".into());
    }
    let resident_audio_mib = items
        .iter()
        .map(|i| match &i.audio {
            Audio::Memory(s) => s.len() as f64 * 4.0 / (1024.0 * 1024.0),
            Audio::Flac(_) => 0.0,
        })
        .sum::<f64>();
    eprintln!("{} utterances selected", items.len());

    let cpus: Vec<usize> = (0..args.threads).collect();
    if let Some(params) = params {
        return analyze(&args, &model, &params, &cpus, &items);
    }

    let mut hyp_out = match &args.save_hyps {
        Some(p) => Some(std::io::BufWriter::new(create_output(p)?)),
        None => None,
    };
    let precision = precision_name(args.precision);
    let mut tr = Transcriber::new(model, &cpus, args.precision);
    for item in items.iter().take(args.warmup) {
        // Warm-up items are measured again below, where failures are counted.
        if let Ok(samples) = item.samples() {
            let _ = tr.transcribe(&samples);
        }
    }
    let after_warmup = memory_mib();

    println!(
        "precision {precision}, {} threads (CPUs 0-{})",
        args.threads,
        args.threads - 1
    );
    if !args.quiet {
        println!(
            "| set | id | audio s | total ms | RTFx | ref words | WER ours | WER M1 | same text as M1 |"
        );
        println!("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |");
    }
    let mut sets: BTreeMap<String, SetStats> = BTreeMap::new();
    // (audio seconds, wall-clock ms of the whole transcribe call)
    let mut runs: Vec<(f64, f64)> = Vec::new();
    let mut sum = Timings::default();
    let mut failures = 0usize;
    let mut audio_s = 0.0;
    for item in &items {
        // Audio is decoded outside the timed call.
        let result = item.samples().and_then(|samples| {
            let secs = samples.len() as f64 / SAMPLE_RATE as f64;
            let start = Instant::now();
            let t = tr.transcribe(&samples).map_err(|e| e.to_string())?;
            Ok((t, secs, ms(start.elapsed())))
        });
        let (t, secs, wall) = match result {
            Ok(r) => r,
            Err(e) => {
                // Not fatal for bulk runs, but counted and reported, and the exit status fails.
                eprintln!("{} {}: {e}", item.set, item.id);
                failures += 1;
                if let Some(w) = hyp_out.as_mut() {
                    writeln!(w, "{}", failure_record(item, &precision, &e))
                        .map_err(|e| e.to_string())?;
                }
                continue;
            }
        };
        audio_s += secs;
        runs.push((secs, wall));
        sum.frontend += t.timings.frontend;
        sum.subsampling += t.timings.subsampling;
        sum.projections += t.timings.projections;
        sum.attention += t.timings.attention;
        sum.elementwise += t.timings.elementwise;
        sum.decoder += t.timings.decoder;
        if let Some(w) = hyp_out.as_mut() {
            let rec = serde_json::json!({
                "id": item.id, "set": item.set, "precision": precision,
                "text": t.text, "tokens": t.tokens, "frames": t.frames,
                "audio_s": secs, "ms": wall,
            });
            writeln!(w, "{rec}").map_err(|e| e.to_string())?;
        }

        let st = sets.entry(item.set.clone()).or_default();
        st.utterances += 1;
        st.audio_s += secs;
        let reference = normalize(&item.reference);
        let ours = normalize(&t.text);
        let e = align(&reference, &ours);
        st.ours.add(e);
        st.words += reference.len();
        let wer = |e: Errors| 100.0 * e.total() as f64 / reference.len().max(1) as f64;
        let m1_wer = item.m1.as_ref().map(|h| {
            let em = align(&reference, &normalize(h));
            st.m1.add(em);
            st.m1_words += reference.len();
            wer(em)
        });
        if let Some(h) = &item.m1_joined {
            st.seg.add(align(&reference, &normalize(h)));
            st.seg_words += reference.len();
        }
        let same_text = item.m1.as_ref().map(|h| {
            st.compared += 1;
            st.disagreement += edits(&normalize(h), &ours);
            let s = *h == t.text;
            st.same_text += usize::from(s);
            s
        });
        if !args.quiet {
            println!(
                "| {} | {} | {:.1} | {:.1} | {:.0} | {} | {:.2}% | {} | {} |",
                item.set,
                item.id,
                secs,
                wall,
                secs * 1e3 / wall,
                reference.len(),
                wer(e),
                m1_wer.map_or("-".into(), |w| format!("{w:.2}%")),
                same_text.map_or("-", |s| if s { "yes" } else { "NO" }),
            );
        }
        if args.show {
            println!("    ours: {}", t.text);
            if let Some(h) = item.m1.as_ref().or(item.m1_joined.as_ref()) {
                println!("    M1:   {h}");
            }
        }
    }
    if let Some(w) = hyp_out.as_mut() {
        w.flush().map_err(|e| e.to_string())?;
    }
    if runs.is_empty() {
        return Err(format!("all {failures} utterances failed"));
    }

    let pct = |e: Errors, w: usize| 100.0 * e.total() as f64 / w.max(1) as f64;
    let sdi = |e: Errors| format!("{}/{}/{}", e.sub, e.del, e.ins);
    println!(
        "\nPer set (simple normalizer applied to every text; S/D/I = substitutions/deletions/insertions)"
    );
    println!(
        "| set | utts | audio min | ref words | WER ours | S/D/I ours | WER M1 same audio | S/D/I M1 | identical text | word edits ours vs M1 | WER M1 per-segment, joined |"
    );
    println!("| --- | ---: | ---: | ---: | ---: | --- | ---: | --- | ---: | ---: | ---: |");
    let mut all = SetStats::default();
    for (name, s) in &sets {
        println!(
            "| {name} | {} | {:.1} | {} | {:.2}% | {} | {} | {} | {} | {} | {} |",
            s.utterances,
            s.audio_s / 60.0,
            s.words,
            pct(s.ours, s.words),
            sdi(s.ours),
            if s.m1_words > 0 {
                format!("{:.2}%", pct(s.m1, s.m1_words))
            } else {
                "-".into()
            },
            if s.m1_words > 0 {
                sdi(s.m1)
            } else {
                "-".into()
            },
            if s.compared > 0 {
                format!("{}/{}", s.same_text, s.compared)
            } else {
                "-".into()
            },
            if s.compared > 0 {
                s.disagreement.to_string()
            } else {
                "-".into()
            },
            if s.seg_words > 0 {
                format!("{:.2}%", pct(s.seg, s.seg_words))
            } else {
                "-".into()
            },
        );
        all.utterances += s.utterances;
        all.audio_s += s.audio_s;
        if s.m1_words > 0 {
            // Totals over sets with M1 on the same audio, so both columns cover the same words.
            all.words += s.words;
            all.ours.add(s.ours);
            all.m1.add(s.m1);
            all.m1_words += s.m1_words;
            all.same_text += s.same_text;
            all.compared += s.compared;
            all.disagreement += s.disagreement;
        }
    }
    if all.m1_words > 0 {
        println!(
            "| all sets with M1 on the same audio | | | {} | {:.2}% | {} | {:.2}% | {} | {}/{} | {} | |",
            all.words,
            pct(all.ours, all.words),
            sdi(all.ours),
            pct(all.m1, all.m1_words),
            sdi(all.m1),
            all.same_text,
            all.compared,
            all.disagreement,
        );
    }
    if failures > 0 {
        println!("\nFAILED: {failures} utterances could not be transcribed (see stderr)");
    }

    let n = runs.len() as f64;
    let mut lat: Vec<f64> = runs.iter().map(|&(_, m)| m).collect();
    lat.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!(
        "\nLatency (wall clock of transcribe, warm, {} utterances, {:.1} min): mean {:.1} ms, p50 {:.1} ms, p95 {:.1} ms, max {:.1} ms",
        runs.len(),
        audio_s / 60.0,
        lat.iter().sum::<f64>() / n,
        percentile(&lat, 0.5),
        percentile(&lat, 0.95),
        lat[lat.len() - 1]
    );
    for (lo, hi) in [(0.0, 30.0), (30.0, 40.0), (40.0, 50.0), (50.0, 60.5)] {
        let mut b: Vec<f64> = runs
            .iter()
            .filter(|&&(s, _)| s >= lo && s < hi)
            .map(|&(_, m)| m)
            .collect();
        if b.is_empty() {
            continue;
        }
        b.sort_by(|a, x| a.partial_cmp(x).unwrap());
        println!(
            "- {lo:.0}-{hi:.0} s: {} utterances, p50 {:.1} ms, p95 {:.1} ms",
            b.len(),
            percentile(&b, 0.5),
            percentile(&b, 0.95)
        );
    }
    println!(
        "- mean stage times (ms): frontend {:.1}, subsampling {:.1}, projections {:.1}, attention {:.1}, elementwise {:.1}, decoder {:.1}",
        ms(sum.frontend) / n,
        ms(sum.subsampling) / n,
        ms(sum.projections) / n,
        ms(sum.attention) / n,
        ms(sum.elementwise) / n,
        ms(sum.decoder) / n
    );
    let end = memory_mib();
    println!(
        "\nMemory (MiB, from /proc/self/status; the harness also holds {resident_audio_mib:.0} MiB of in-memory test audio, loaded after the model; set audio is decoded one utterance at a time):"
    );
    println!(
        "- after model load: RSS {:.0}, peak {:.0} (peak includes load-time temporaries)",
        after_load.0, after_load.1
    );
    println!(
        "- after warm-up: RSS {:.0}; at end: RSS {:.0}, peak {:.0}",
        after_warmup.0, end.0, end.1
    );
    println!(
        "- estimated transcriber working set at end (RSS minus in-memory test audio): {:.0}",
        end.0 - resident_audio_mib
    );
    Ok(failures == 0)
}

/// `(VmRSS, VmHWM)` of this process in MiB.
fn memory_mib() -> (f64, f64) {
    let status = std::fs::read_to_string("/proc/self/status").unwrap_or_default();
    let field = |key: &str| {
        status
            .lines()
            .find_map(|l| l.strip_prefix(key))
            .and_then(|v| v.split_whitespace().next()?.parse::<f64>().ok())
            .map_or(f64::NAN, |kib| kib / 1024.0)
    };
    (field("VmRSS:"), field("VmHWM:"))
}

// ----------------------------------------------------------------------------- analysis

/// Top-1 minus top-2 of `v` (infinite with fewer than two values).
fn top2_margin(v: &[f64]) -> f64 {
    let (mut a, mut b) = (f64::NEG_INFINITY, f64::NEG_INFINITY);
    for &x in v {
        if x > a {
            b = a;
            a = x;
        } else if x > b {
            b = x;
        }
    }
    a - b
}

/// Index of the runner-up of `v` (the best index other than the argmax, first max wins).
fn runner_up(v: &[f64]) -> Option<usize> {
    let best = (0..v.len()).fold(None, |b: Option<usize>, i| match b {
        Some(j) if v[j] >= v[i] => Some(j),
        _ => Some(i),
    })?;
    (0..v.len())
        .filter(|&i| i != best)
        .fold(None, |b: Option<usize>, i| match b {
            Some(j) if v[j] >= v[i] => Some(j),
            _ => Some(i),
        })
}

/// One greedy decision as the analysis sees it.
#[derive(Clone, Debug, PartialEq)]
struct Step {
    frame: usize,
    token: usize,
    duration: usize,
    tok_margin: f64,
    dur_margin: f64,
    /// Token runner-up and duration-index runner-up.
    tok_second: Option<usize>,
    dur_second: Option<usize>,
}

fn steps(decisions: &[reference::Decision], vocab: usize) -> Vec<Step> {
    decisions
        .iter()
        .map(|d| Step {
            frame: d.frame,
            token: d.token,
            duration: d.duration,
            tok_margin: top2_margin(&d.logits[..vocab]),
            dur_margin: top2_margin(&d.logits[vocab..]),
            tok_second: runner_up(&d.logits[..vocab]),
            dur_second: runner_up(&d.logits[vocab..]),
        })
        .collect()
}

/// First decision where two greedy decision sequences differ. Until then both
/// runs are in the same decoder state, so the decisions are directly comparable.
fn first_divergence(a: &[Step], b: &[Step]) -> Option<usize> {
    let n = a.len().min(b.len());
    (0..n)
        .find(|&i| {
            (a[i].frame, a[i].token, a[i].duration) != (b[i].frame, b[i].token, b[i].duration)
        })
        .or((a.len() != b.len()).then_some(n))
}

/// Decisions around the place where our text stops being a prefix of `other`:
/// from the decision after the last emission whose text is still a prefix,
/// through the decision that emits the first token breaking it (or to the end
/// if ours is a strict prefix). `prefix_text(k)` is the text of the first `k`
/// tokens; `emitted_at[k]` is the decision index of token `k`.
fn text_divergence_window(
    ours_full: &str,
    other: &str,
    tokens: usize,
    emitted_at: &[usize],
    decisions: usize,
    prefix_text: impl Fn(usize) -> String,
) -> Option<std::ops::Range<usize>> {
    if ours_full == other {
        return None;
    }
    // NeMo strips one whitespace character before punctuation, so a prefix's
    // last character can be a space that a later token removes. Only then
    // (the prefix is not a prefix of our final text) is that one character
    // dropped; everything else in a prefix is final.
    let finalized = |k: usize| {
        let p = prefix_text(k);
        if ours_full.starts_with(&p) {
            return p;
        }
        let mut chars = p.chars();
        match chars.next_back() {
            Some(c) if lf_asr::tokenizer::is_python_space(c) => chars.as_str().to_owned(),
            _ => p,
        }
    };
    let bad = (1..=tokens).find(|&k| !other.starts_with(&finalized(k)));
    let start = |j: usize| if j == 0 { 0 } else { emitted_at[j - 1] + 1 };
    Some(match bad {
        Some(k) => start(k - 1)..emitted_at[k - 1] + 1,
        None => start(tokens)..decisions,
    })
}

fn rel_rms(a: &[f32], base: &[f32]) -> f64 {
    let (mut num, mut den) = (0.0f64, 0.0f64);
    for (&x, &y) in a.iter().zip(base) {
        num += (x as f64 - y as f64).powi(2);
        den += (y as f64).powi(2);
    }
    (num / den.max(f64::MIN_POSITIVE)).sqrt()
}

/// Largest absolute differences between two logit vectors (tokens, durations).
fn max_abs_delta(a: &[f64], b: &[f64], vocab: usize) -> (f64, f64) {
    let m = |x: &[f64], y: &[f64]| {
        x.iter()
            .zip(y)
            .map(|(p, q)| (p - q).abs())
            .fold(0.0, f64::max)
    };
    (m(&a[..vocab], &b[..vocab]), m(&a[vocab..], &b[vocab..]))
}

/// Per non-baseline precision: how far its logits move on decisions it
/// shares with the baseline, and how many of those decisions could flip.
#[derive(Default)]
struct Perturbation {
    /// Per shared decision, the largest token-logit difference.
    tok_deltas: Vec<f64>,
    /// Shared decisions whose baseline margin is below twice the largest difference.
    tok_at_risk: usize,
    dur_at_risk: usize,
    /// Utterances whose decisions diverge, by kind.
    diverged: BTreeMap<&'static str, usize>,
}

struct PrecisionRun {
    enc: Vec<f32>,
    logits: Vec<Vec<f64>>,
    steps: Vec<Step>,
    tokens: Vec<usize>,
    emitted_at: Vec<usize>,
    text: String,
    /// The fast decoder emitted exactly what the f64 reference did.
    fast_agrees: bool,
}

/// Margins near zero are what matters, so small ones keep their significant digits.
fn fmt_margin(m: f64) -> String {
    if !m.is_finite() {
        "-".into()
    } else if m.abs() < 0.01 {
        format!("{m:.1e}")
    } else {
        format!("{m:.3}")
    }
}

fn window_min(steps: &[Step], w: &std::ops::Range<usize>, f: impl Fn(&Step) -> f64) -> f64 {
    steps[w.clone()].iter().map(f).fold(f64::INFINITY, f64::min)
}

/// Thresholds for the margin histogram of the baseline's token decisions.
const MARGIN_BUCKETS: [f64; 8] = [0.001, 0.01, 0.1, 0.25, 0.5, 1.0, 2.0, 4.0];

fn analyze(
    args: &Args,
    model: &Model,
    params: &DecoderParams,
    cpus: &[usize],
    items: &[Item],
) -> Result<bool, String> {
    let pool = ThreadPool::new(cpus);
    let mut projs: Vec<Projector> = args
        .analyze
        .iter()
        .map(|&p| Projector::new(p, pool.threads()))
        .collect();
    let names: Vec<String> = args.analyze.iter().map(|&p| precision_name(p)).collect();
    let mut front = FrontendBuffers::default();
    let mut encbuf = EncoderBuffers::default();
    let vocab = params.vocab;
    println!(
        "Divergence analysis, baseline {}; margins are top-1 minus top-2 logits (= log-probability gap) from the f64 reference decoder",
        names[0]
    );
    println!(
        "| set | id | precision | audio s | decisions | same text as baseline | word edits vs baseline | first differing decision | kind | baseline margin there | this margin there | took baseline's runner-up | encoder rel. RMS vs baseline | max token-logit change on shared decisions | same text as M1 | word edits vs M1 | min token margin where text leaves M1 | min duration margin there | fast decoder = reference |"
    );
    println!(
        "| --- | --- | --- | ---: | ---: | --- | ---: | ---: | --- | ---: | ---: | --- | ---: | ---: | --- | ---: | ---: | ---: | --- |"
    );
    let mut perturbation: Vec<Perturbation> =
        names.iter().map(|_| Perturbation::default()).collect();
    let mut hist = [0usize; MARGIN_BUCKETS.len()];
    let mut total_decisions = 0usize;
    let mut disagreements = 0usize;
    let mut failures = 0usize;
    let mut analyzed = 0usize;
    for item in items {
        // The same input checks as `Transcriber::transcribe`; a failing item is
        // reported, counted and skipped.
        let result = item.samples().and_then(|samples| {
            check_length(&samples)?;
            let secs = samples.len() as f64 / SAMPLE_RATE as f64;
            let mel = frontend::features(&model.frontend, &pool, &samples, &mut front)
                .map_err(|e| e.to_string())?;
            let mut runs = Vec::new();
            for proj in projs.iter_mut() {
                let mut t = Timings::default();
                // Uncached positions: bit-identical to the cache, and no state
                // shared between the precisions being compared.
                let mut positions = encoder::PositionCache::new(0);
                let frames = encoder::encode(
                    model,
                    &pool,
                    proj,
                    &front.feat,
                    mel,
                    &mut encbuf,
                    &mut positions,
                    &mut t,
                )
                .map_err(|e| e.to_string())?;
                let enc = encbuf.x[..frames * D_MODEL].to_vec();
                check_finite(&enc)?;
                runs.push(precision_run(model, params, &pool, enc, frames)?);
            }
            Ok((secs, runs))
        });
        let (secs, runs) = match result {
            Ok(r) => r,
            Err(e) => {
                eprintln!("{} {}: {e}", item.set, item.id);
                failures += 1;
                continue;
            }
        };
        analyzed += 1;
        let base = &runs[0];
        for s in &base.steps {
            total_decisions += 1;
            for (b, &t) in MARGIN_BUCKETS.iter().enumerate() {
                if s.tok_margin < t {
                    hist[b] += 1;
                }
            }
        }
        for (ri, (name, r)) in names.iter().zip(&runs).enumerate() {
            disagreements += usize::from(!r.fast_agrees);
            let is_base = ri == 0;
            let div = if is_base {
                None
            } else {
                first_divergence(&base.steps, &r.steps)
            };
            let (kind, bm, tm, runner) = match div {
                Some(i) if i < base.steps.len() && i < r.steps.len() => {
                    let (b, t) = (&base.steps[i], &r.steps[i]);
                    if b.token != t.token {
                        (
                            "token",
                            b.tok_margin,
                            t.tok_margin,
                            if b.tok_second == Some(t.token) {
                                "yes"
                            } else {
                                "no"
                            },
                        )
                    } else {
                        let ti = DURATIONS.iter().position(|&d| d == t.duration);
                        (
                            "duration",
                            b.dur_margin,
                            t.dur_margin,
                            if b.dur_second.is_some() && b.dur_second == ti {
                                "yes"
                            } else {
                                "no"
                            },
                        )
                    }
                }
                Some(_) => ("length", f64::NAN, f64::NAN, "-"),
                None => ("-", f64::NAN, f64::NAN, "-"),
            };
            // Decisions taken in the same decoder state as the baseline: all up to and
            // including the first differing one.
            let shared = div
                .map_or(usize::MAX, |i| i + 1)
                .min(base.steps.len().min(r.steps.len()));
            let mut max_tok_delta = f64::NAN;
            if !is_base {
                let pt = &mut perturbation[ri];
                for k in 0..shared {
                    let (dt, dd) = max_abs_delta(&r.logits[k], &base.logits[k], vocab);
                    pt.tok_deltas.push(dt);
                    pt.tok_at_risk += usize::from(base.steps[k].tok_margin < 2.0 * dt);
                    pt.dur_at_risk += usize::from(base.steps[k].dur_margin < 2.0 * dd);
                    max_tok_delta = if max_tok_delta.is_nan() {
                        dt
                    } else {
                        max_tok_delta.max(dt)
                    };
                }
                if div.is_some() {
                    *pt.diverged.entry(kind).or_default() += 1;
                }
            }
            let (m1_same, m1_edits, wtok, wdur) = match &item.m1 {
                Some(m1) => {
                    let w = text_divergence_window(
                        &r.text,
                        m1,
                        r.tokens.len(),
                        &r.emitted_at,
                        r.steps.len(),
                        |k| model.tokenizer.decode(&r.tokens[..k]).unwrap_or_default(),
                    );
                    let (wt, wd) = w.map_or((f64::NAN, f64::NAN), |w| {
                        (
                            window_min(&r.steps, &w, |s| s.tok_margin),
                            window_min(&r.steps, &w, |s| s.dur_margin),
                        )
                    });
                    (
                        if r.text == *m1 { "yes" } else { "NO" },
                        text_edits(&r.text, m1).to_string(),
                        wt,
                        wd,
                    )
                }
                None => ("-", "-".into(), f64::NAN, f64::NAN),
            };
            println!(
                "| {} | {} | {name} | {secs:.1} | {} | {} | {} | {} | {kind} | {} | {} | {runner} | {} | {} | {m1_same} | {m1_edits} | {} | {} | {} |",
                item.set,
                item.id,
                r.steps.len(),
                if is_base {
                    "-"
                } else if r.text == base.text {
                    "yes"
                } else {
                    "NO"
                },
                if is_base {
                    "-".into()
                } else {
                    text_edits(&base.text, &r.text).to_string()
                },
                div.map_or("-".into(), |d| d.to_string()),
                fmt_margin(bm),
                fmt_margin(tm),
                if is_base {
                    "-".into()
                } else {
                    format!("{:.2e}", rel_rms(&r.enc, &base.enc))
                },
                if max_tok_delta.is_nan() {
                    "-".into()
                } else {
                    format!("{max_tok_delta:.2e}")
                },
                fmt_margin(wtok),
                fmt_margin(wdur),
                if r.fast_agrees { "yes" } else { "NO" },
            );
        }
    }
    println!(
        "\nBaseline ({}) token-decision margins over {} decisions in {} utterances:",
        names[0], total_decisions, analyzed
    );
    for (b, &t) in MARGIN_BUCKETS.iter().enumerate() {
        println!(
            "- below {t}: {} ({:.3}%)",
            hist[b],
            100.0 * hist[b] as f64 / total_decisions.max(1) as f64
        );
    }
    println!(
        "\nLogit changes against {} on decisions taken in the same decoder state (at risk: baseline margin below twice the largest change)",
        names[0]
    );
    println!(
        "| precision | shared decisions | token-logit change p50 | p99 | max | token decisions at risk | duration decisions at risk | utterances diverging (kind) |"
    );
    println!("| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |");
    for (name, pt) in names.iter().zip(&mut perturbation).skip(1) {
        pt.tok_deltas.sort_by(f64::total_cmp);
        let q = |p: f64| {
            if pt.tok_deltas.is_empty() {
                "-".to_owned()
            } else {
                format!("{:.2e}", percentile(&pt.tok_deltas, p))
            }
        };
        let kinds: Vec<String> = pt
            .diverged
            .iter()
            .map(|(k, n)| format!("{n} {k}"))
            .collect();
        println!(
            "| {name} | {} | {} | {} | {} | {} | {} | {} |",
            pt.tok_deltas.len(),
            q(0.5),
            q(0.99),
            q(1.0),
            pt.tok_at_risk,
            pt.dur_at_risk,
            if kinds.is_empty() {
                "0".into()
            } else {
                kinds.join(", ")
            }
        );
    }
    if disagreements > 0 {
        println!(
            "\nNOTE: the fast decoder and the f64 reference disagreed on {disagreements} precision runs"
        );
    }
    if failures > 0 {
        println!("\nFAILED: {failures} utterances could not be analyzed (see stderr)");
    }
    Ok(failures == 0)
}

/// The JSONL record of an utterance that could not be processed (no text, so
/// `lf-hypcompare` counts it as failed).
fn failure_record(item: &Item, precision: &str, error: &str) -> serde_json::Value {
    serde_json::json!({
        "id": item.id, "set": item.set, "precision": precision, "error": error,
    })
}

/// `Transcriber::transcribe`'s input limit, for the analysis path that bypasses it.
fn check_length(samples: &[f32]) -> Result<(), String> {
    if samples.len() > MAX_SECONDS * SAMPLE_RATE as usize {
        return Err(format!("audio longer than {MAX_SECONDS} s"));
    }
    Ok(())
}

/// `Transcriber::transcribe`'s encoder-output check.
fn check_finite(enc: &[f32]) -> Result<(), String> {
    if enc.iter().any(|v| !v.is_finite()) {
        return Err("encoder produced non-finite output".into());
    }
    Ok(())
}

/// Reference and fast decoding of one precision's encoder output.
fn precision_run(
    model: &Model,
    params: &DecoderParams,
    pool: &ThreadPool,
    enc: Vec<f32>,
    frames: usize,
) -> Result<PrecisionRun, String> {
    let (emitted, decisions) = reference::decode(params, &enc, frames);
    let projected = model.decoder.project_encoder(pool, &enc, frames);
    let fast = model.decoder.decode(pool, &projected, frames, None);
    let tokens: Vec<usize> = emitted.iter().map(|&(t, _)| t).collect();
    let text = model.tokenizer.decode(&tokens).map_err(|e| e.to_string())?;
    let blank = params.blank();
    let emitted_at = decisions
        .iter()
        .enumerate()
        .filter(|(_, d)| d.token != blank)
        .map(|(i, _)| i)
        .collect();
    Ok(PrecisionRun {
        enc,
        steps: steps(&decisions, params.vocab),
        logits: decisions.into_iter().map(|d| d.logits).collect(),
        tokens,
        emitted_at,
        text,
        fast_agrees: fast == emitted,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(s: &str) -> Vec<String> {
        s.split_whitespace().map(str::to_owned).collect()
    }

    fn item(id: &str) -> Item {
        Item {
            id: id.into(),
            set: "s".into(),
            audio: Audio::Memory(Vec::new()),
            reference: String::new(),
            m1: None,
            m1_joined: None,
        }
    }

    #[test]
    fn selection_filters_then_chunks_in_order() {
        let items: Vec<Item> = ["a", "b", "c", "d", "e"].iter().map(|s| item(s)).collect();
        let ids: Vec<String> = select(items, None, 1, Some(2))
            .into_iter()
            .map(|i| i.id)
            .collect();
        assert_eq!(ids, ["b", "c"]);
        let items: Vec<Item> = ["a", "b", "c", "d", "e"].iter().map(|s| item(s)).collect();
        let keep = parse_id_list("# comment\n e \n\nb\nzz\n");
        let ids: Vec<String> = select(items, Some(&keep), 0, None)
            .into_iter()
            .map(|i| i.id)
            .collect();
        assert_eq!(ids, ["b", "e"]);
        let items: Vec<Item> = ["a", "b"].iter().map(|s| item(s)).collect();
        assert!(select(items, None, 5, None).is_empty());
    }

    #[test]
    fn args_parse_and_validate() {
        let a = parse_args_from(argv(
            "--export x --precision i8x2 --offset 3 --limit 7 --quiet --min-seconds 0 --max-seconds 1e9",
        ))
        .unwrap();
        assert_eq!(a.precision, Precision::Int8(2));
        assert_eq!((a.offset, a.limit, a.quiet), (3, Some(7), true));
        assert_eq!(a.max_s, 1e9);
        let a = parse_args_from(argv("--export x --analyze f32,i8x3,i8x2")).unwrap();
        assert_eq!(
            a.analyze,
            [Precision::F32, Precision::Int8(3), Precision::Int8(2)]
        );
        assert!(parse_args_from(argv("--export x --analyze f32")).is_err());
        assert!(parse_args_from(argv("--export x --precision i8x4")).is_err());
        assert!(parse_args_from(argv("--export x --min-seconds 5 --max-seconds 1")).is_err());
        assert!(parse_args_from(argv("--export x --threads 0")).is_err());
    }

    #[test]
    fn save_path_must_be_outside_git() {
        let base = std::env::temp_dir().join(format!("lf-transcribe-test-{}", std::process::id()));
        let repo = base.join("repo");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        std::fs::create_dir_all(repo.join("sub")).unwrap();
        assert!(check_output_path(&repo.join("sub/h.jsonl")).is_err());
        assert!(check_output_path(&repo.join("h.jsonl")).is_err());
        // A worktree's `.git` is a file.
        let wt = base.join("wt");
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join(".git"), "gitdir: elsewhere\n").unwrap();
        assert!(check_output_path(&wt.join("h.jsonl")).is_err());
        let out = base.join("out");
        std::fs::create_dir_all(&out).unwrap();
        assert!(check_output_path(&out.join("h.jsonl")).is_ok());
        assert!(check_output_path(&base.join("missing/h.jsonl")).is_err());
        // Links out of the checked directory are refused, existing or dangling.
        std::fs::write(repo.join("tracked.jsonl"), "keep").unwrap();
        let link = out.join("link.jsonl");
        std::os::unix::fs::symlink(repo.join("tracked.jsonl"), &link).unwrap();
        assert!(check_output_path(&link).is_err());
        assert!(create_output(&link).is_err());
        let dangling = out.join("dangling.jsonl");
        std::os::unix::fs::symlink(repo.join("new.jsonl"), &dangling).unwrap();
        assert!(create_output(&dangling).is_err());
        assert!(!repo.join("new.jsonl").exists());
        assert_eq!(
            std::fs::read_to_string(repo.join("tracked.jsonl")).unwrap(),
            "keep"
        );
        // A hard link to a repository file is not truncated.
        let hard = out.join("hard.jsonl");
        std::fs::hard_link(repo.join("tracked.jsonl"), &hard).unwrap();
        assert!(create_output(&hard).is_err());
        assert_eq!(
            std::fs::read_to_string(repo.join("tracked.jsonl")).unwrap(),
            "keep"
        );
        // A plain file is created, then truncated on reuse.
        let plain = out.join("h.jsonl");
        std::fs::write(&plain, "old").unwrap();
        drop(create_output(&plain).unwrap());
        assert_eq!(std::fs::read_to_string(&plain).unwrap(), "");
        drop(create_output(&out.join("new.jsonl")).unwrap());
        assert!(out.join("new.jsonl").is_file());
        std::fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn failures_are_recorded_not_fatal() {
        // A missing FLAC fails at decode time, per item, not at selection.
        let mut it = item("u1");
        it.audio = Audio::Flac("/nonexistent/lf-transcribe-test.flac".into());
        let err = it.samples().unwrap_err();
        let rec = failure_record(&it, "i8x2", &err);
        assert_eq!(rec["id"], "u1");
        assert_eq!(rec["precision"], "i8x2");
        assert!(rec.get("text").is_none());
        assert!(
            rec["error"]
                .as_str()
                .unwrap()
                .contains("lf-transcribe-test.flac")
        );
        // Input checks the analysis path shares with `Transcriber::transcribe`.
        assert!(check_length(&vec![0.0; MAX_SECONDS * SAMPLE_RATE as usize]).is_ok());
        assert!(check_length(&vec![0.0; MAX_SECONDS * SAMPLE_RATE as usize + 1]).is_err());
        assert!(check_finite(&[0.0, 1.0]).is_ok());
        assert!(check_finite(&[0.0, f32::NAN]).is_err());
        assert!(check_finite(&[f32::INFINITY]).is_err());
    }

    #[test]
    fn margins_and_runner_up() {
        assert_eq!(fmt_margin(0.25), "0.250");
        assert_eq!(fmt_margin(0.00042), "4.2e-4");
        assert_eq!(fmt_margin(f64::NAN), "-");
        assert_eq!(top2_margin(&[1.0, 3.0, 2.5]), 0.5);
        assert_eq!(top2_margin(&[2.0, 2.0]), 0.0);
        assert!(top2_margin(&[1.0]).is_infinite());
        assert_eq!(runner_up(&[1.0, 3.0, 2.5]), Some(2));
        // First max wins, so the tie partner is the runner-up.
        assert_eq!(runner_up(&[2.0, 2.0, 1.0]), Some(1));
        assert_eq!(runner_up(&[1.0]), None);
    }

    fn step(frame: usize, token: usize, duration: usize) -> Step {
        Step {
            frame,
            token,
            duration,
            tok_margin: 1.0,
            dur_margin: 1.0,
            tok_second: None,
            dur_second: None,
        }
    }

    #[test]
    fn divergence_points() {
        let a = vec![step(0, 5, 1), step(1, 9, 2), step(3, 9, 1)];
        assert_eq!(first_divergence(&a, &a), None);
        let mut b = a.clone();
        b[1].duration = 1;
        assert_eq!(first_divergence(&a, &b), Some(1));
        assert_eq!(first_divergence(&a, &a[..2]), Some(2));
    }

    #[test]
    fn text_window() {
        // Tokens "Hel", "lo", " wor" emitted at decisions 1, 2 and 4 of 6.
        let toks = ["Hel", "lo", " wor"];
        let prefix = |k: usize| toks[..k].concat();
        let at = [1, 2, 4];
        assert_eq!(
            text_divergence_window("Hello wor", "Hello wor", 3, &at, 6, prefix),
            None
        );
        // Third token breaks the prefix: decisions after token 2 through token 3.
        assert_eq!(
            text_divergence_window("Hello wor", "Hello there", 3, &at, 6, prefix),
            Some(3..5)
        );
        // First token already wrong.
        assert_eq!(
            text_divergence_window("Hello wor", "Hi", 3, &at, 6, prefix),
            Some(0..2)
        );
        // Second token breaks it.
        assert_eq!(
            text_divergence_window("Hello wor", "Help", 3, &at, 6, prefix),
            Some(2..3)
        );
        // Ours is a strict prefix: the window runs to the end.
        assert_eq!(
            text_divergence_window("Hello wor", "Hello world", 3, &at, 6, prefix),
            Some(5..6)
        );
    }

    #[test]
    fn text_window_ignores_a_space_later_absorbed_by_punctuation() {
        // Tokens "cat", "▁", "?", "▁dog" at decisions 0..4. With NeMo's
        // stripping the prefixes are "cat", "cat ", "cat?", "cat? dog": the
        // space after "cat" disappears once "?" arrives.
        let prefixes = ["", "cat", "cat ", "cat?", "cat? dog"];
        let prefix = |k: usize| prefixes[k].to_string();
        let at = [0, 1, 2, 3];
        // The real divergence is "dog" vs "fog", at the fourth token.
        assert_eq!(
            text_divergence_window("cat? dog", "cat? fog", 4, &at, 4, prefix),
            Some(3..4)
        );
    }

    #[test]
    fn text_window_uses_the_tokenizers_whitespace() {
        // U+001C counts as whitespace for NeMo's `\s`, so it can be absorbed.
        let prefixes = ["", "cat", "cat\u{1c}", "cat?", "cat? dog"];
        let prefix = |k: usize| prefixes[k].to_string();
        assert_eq!(
            text_divergence_window("cat? dog", "cat? fog", 4, &[0, 1, 2, 3], 4, prefix),
            Some(3..4)
        );
    }

    #[test]
    fn text_window_keeps_a_final_trailing_space() {
        // Ours ends with a real space; the other text does not. The space is
        // final (nothing absorbs it), so the second token is the divergence.
        let prefixes = ["", "cat", "cat "];
        let prefix = |k: usize| prefixes[k].to_string();
        assert_eq!(
            text_divergence_window("cat ", "cat", 2, &[0, 1], 2, prefix),
            Some(1..2)
        );
        // Two spaces before "?": only one is absorbed, the other is final.
        let prefixes = ["", "cat", "cat  ", "cat ?"];
        let prefix = |k: usize| prefixes[k].to_string();
        assert_eq!(
            text_divergence_window("cat ?", "cat?", 3, &[0, 1, 2], 3, prefix),
            Some(1..2)
        );
    }

    #[test]
    fn relative_rms_and_logit_deltas() {
        assert_eq!(
            max_abs_delta(&[1.0, 2.0, 3.0, 0.5], &[1.5, 2.0, 2.0, 0.25], 3),
            (1.0, 0.25)
        );
        assert_eq!(rel_rms(&[1.0, 2.0], &[1.0, 2.0]), 0.0);
        let r = rel_rms(&[1.0, 0.0], &[0.0, 1.0]);
        assert!((r - 2f64.sqrt()).abs() < 1e-12);
    }
}

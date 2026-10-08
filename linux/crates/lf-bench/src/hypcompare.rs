//! Compares hypotheses saved by `lf-transcribe --save-hyps` with each other and
//! with the M1 GPU hypotheses of the same utterances.
//!
//! ```text
//! lf-hypcompare --m1 EVAL_JSON [--m1 EVAL_JSON]... \
//!     --hyps LABEL=PATH[,PATH...] [--hyps LABEL=PATH...]... [--diff-out PATH.tsv]
//! ```
//!
//! Sets are named by the evaluation file's stem, as `lf-transcribe` names
//! them. Several JSONL files per label (chunks of one run) are merged; an
//! utterance appearing twice for one label is an error. Prints, per set and
//! label, agreement with M1 and WER of both under the simple normalizer, then
//! pairwise agreement between labels. `--diff-out` lists the ids (never
//! texts) of utterances where anything differs, with word-edit counts.

mod wer;

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use wer::{Errors, align, normalize, text_edits};

struct M1Record {
    reference: String,
    hyp: String,
    /// False for references the official scoring excludes (empty after normalization).
    scored: bool,
}

struct M1Set {
    name: String,
    /// Corpus WER from the file (Whisper normalizer), if present.
    official_wer: Option<f64>,
    /// In file order.
    records: Vec<(String, M1Record)>,
}

struct Hyp {
    text: String,
    /// Token ids, when saved (two runs can produce the same text from different tokens).
    tokens: Option<Vec<u64>>,
}

/// `Ok(hypothesis)` or `Err(error message)` per `(set, id)`.
type Hyps = BTreeMap<(String, String), Result<Hyp, String>>;

/// One pairwise comparison of an utterance.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct PairCell {
    same_text: bool,
    /// `None` when either side has no tokens.
    same_tokens: Option<bool>,
    word_edits: usize,
}

impl PairCell {
    fn identical(&self) -> bool {
        self.same_text && self.same_tokens != Some(false)
    }
}

struct Args {
    m1: Vec<PathBuf>,
    hyps: Vec<(String, Vec<PathBuf>)>,
    diff_out: Option<PathBuf>,
}

fn parse_args_from(argv: impl IntoIterator<Item = String>) -> Result<Args, String> {
    let mut a = Args {
        m1: Vec::new(),
        hyps: Vec::new(),
        diff_out: None,
    };
    let mut it = argv.into_iter();
    while let Some(flag) = it.next() {
        let mut value = || it.next().ok_or(format!("{flag} needs a value"));
        match flag.as_str() {
            "--m1" => a.m1.push(value()?.into()),
            "--hyps" => {
                let v = value()?;
                let (label, paths) = v
                    .split_once('=')
                    .ok_or("--hyps takes LABEL=PATH[,PATH...]")?;
                if label.is_empty() || a.hyps.iter().any(|(l, _)| l == label) {
                    return Err(format!("empty or repeated label {label:?}"));
                }
                a.hyps.push((
                    label.to_owned(),
                    paths
                        .split(',')
                        .filter(|p| !p.is_empty())
                        .map(PathBuf::from)
                        .collect(),
                ));
            }
            "--diff-out" => a.diff_out = Some(value()?.into()),
            "-h" | "--help" => {
                return Err("usage: lf-hypcompare --m1 EVAL_JSON... --hyps LABEL=PATH[,PATH...]... [--diff-out PATH.tsv]".into());
            }
            _ => return Err(format!("unknown argument {flag}")),
        }
    }
    if a.m1.is_empty() || a.hyps.is_empty() {
        return Err("need at least one --m1 and one --hyps".into());
    }
    Ok(a)
}

fn read_json(path: &Path) -> Result<serde_json::Value, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    serde_json::from_slice(&bytes).map_err(|e| format!("{}: {e}", path.display()))
}

fn m1_set(path: &Path) -> Result<M1Set, String> {
    let v = read_json(path)?;
    parse_m1(
        &v,
        path.file_stem().and_then(|s| s.to_str()).unwrap_or("eval"),
    )
    .map_err(|e| format!("{}: {e}", path.display()))
}

fn parse_m1(v: &serde_json::Value, name: &str) -> Result<M1Set, String> {
    // Dev files store the WER as a number, test files as an object with a `wer` field.
    let official_wer = match v.get("wer") {
        Some(serde_json::Value::Number(n)) => n.as_f64(),
        Some(o) => o.get("wer").and_then(|w| w.as_f64()),
        None => None,
    };
    let mut records = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    for r in v
        .get("records")
        .and_then(|r| r.as_array())
        .ok_or("no records")?
    {
        let s = |k: &str| r.get(k).and_then(|v| v.as_str()).map(str::to_owned);
        let (Some(id), Some(reference), Some(hyp)) = (s("id"), s("ref"), s("hyp")) else {
            return Err("record without id, ref or hyp".into());
        };
        if !seen.insert(id.clone()) {
            return Err(format!("duplicate id {id}"));
        }
        let scored = r.get("scored").and_then(|v| v.as_bool()).unwrap_or(true);
        records.push((
            id,
            M1Record {
                reference,
                hyp,
                scored,
            },
        ));
    }
    Ok(M1Set {
        name: name.to_owned(),
        official_wer,
        records,
    })
}

/// Hypotheses are keyed by set name (the eval file's stem), so two `--m1`
/// files with the same stem would double-count or share hypotheses.
fn check_unique_sets(sets: &[M1Set]) -> Result<(), String> {
    let mut seen = std::collections::BTreeSet::new();
    for s in sets {
        if !seen.insert(s.name.as_str()) {
            return Err(format!("set {} given twice (by --m1 file stem)", s.name));
        }
    }
    Ok(())
}

fn read_hyps(paths: &[PathBuf]) -> Result<Hyps, String> {
    let mut out = Hyps::new();
    for p in paths {
        let text = std::fs::read_to_string(p).map_err(|e| format!("{}: {e}", p.display()))?;
        parse_hyps_into(&text, &mut out).map_err(|e| format!("{}: {e}", p.display()))?;
    }
    Ok(out)
}

fn parse_hyps_into(text: &str, out: &mut Hyps) -> Result<(), String> {
    for (n, line) in text.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let v: serde_json::Value =
            serde_json::from_str(line).map_err(|e| format!("line {}: {e}", n + 1))?;
        let s = |k: &str| v.get(k).and_then(|x| x.as_str()).map(str::to_owned);
        let (Some(id), Some(set)) = (s("id"), s("set")) else {
            return Err(format!("line {}: no id or set", n + 1));
        };
        let tokens = match v.get("tokens") {
            None => None,
            Some(t) => Some(
                t.as_array()
                    .and_then(|a| a.iter().map(|x| x.as_u64()).collect::<Option<Vec<_>>>())
                    .ok_or(format!(
                        "line {}: tokens must be non-negative integers",
                        n + 1
                    ))?,
            ),
        };
        let value = match (s("text"), s("error")) {
            (Some(text), None) => Ok(Hyp { text, tokens }),
            (None, Some(e)) => Err(e),
            _ => return Err(format!("line {}: need exactly one of text, error", n + 1)),
        };
        if out.insert((set.clone(), id.clone()), value).is_some() {
            return Err(format!("line {}: {set} {id} appears twice", n + 1));
        }
    }
    Ok(())
}

#[derive(Default, Clone, Copy)]
struct LabelStats {
    utts: usize,
    errors: usize,
    same_m1: usize,
    /// Utterances whose normalized words differ from M1's.
    word_diff_m1: usize,
    edits_m1: usize,
    words: usize,
    ours: Errors,
    m1: Errors,
}

impl LabelStats {
    fn add(&mut self, o: &LabelStats) {
        self.utts += o.utts;
        self.errors += o.errors;
        self.same_m1 += o.same_m1;
        self.word_diff_m1 += o.word_diff_m1;
        self.edits_m1 += o.edits_m1;
        self.words += o.words;
        self.ours.add(o.ours);
        self.m1.add(o.m1);
    }
}

#[derive(Default, Clone, Copy)]
struct PairStats {
    both: usize,
    same: usize,
    /// Utterances with tokens on both sides, and those whose tokens differ.
    tokens_compared: usize,
    token_diff: usize,
    word_diff: usize,
    edits: usize,
}

impl PairStats {
    fn add(&mut self, o: &PairStats) {
        self.both += o.both;
        self.same += o.same;
        self.tokens_compared += o.tokens_compared;
        self.token_diff += o.token_diff;
        self.word_diff += o.word_diff;
        self.edits += o.edits;
    }
}

struct Report {
    /// Per set, per label.
    labels: Vec<(String, Option<f64>, usize, Vec<LabelStats>)>,
    /// Per set, per pair `(i, j)` with `i < j`.
    pairs: Vec<Vec<PairStats>>,
    /// Utterances where any label differs from M1 or from another label.
    diffs: Vec<DiffRow>,
}

struct DiffRow {
    set: String,
    id: String,
    ref_words: usize,
    /// Per label: `None` = missing or failed, `Some((same text, word edits))`.
    vs_m1: Vec<Option<(bool, usize)>>,
    pairs: Vec<Option<PairCell>>,
}

fn pair_indices(n: usize) -> Vec<(usize, usize)> {
    (0..n)
        .flat_map(|i| (i + 1..n).map(move |j| (i, j)))
        .collect()
}

fn compare(sets: &[M1Set], hyps: &[(String, Hyps)]) -> Report {
    let pairs_ij = pair_indices(hyps.len());
    let mut report = Report {
        labels: Vec::new(),
        pairs: Vec::new(),
        diffs: Vec::new(),
    };
    for set in sets {
        let mut ls = vec![LabelStats::default(); hyps.len()];
        let mut ps = vec![PairStats::default(); pairs_ij.len()];
        for (id, rec) in &set.records {
            let key = (set.name.clone(), id.clone());
            let texts: Vec<Option<&Hyp>> = hyps
                .iter()
                .map(|(_, h)| h.get(&key).and_then(|r| r.as_ref().ok()))
                .collect();
            let reference = normalize(&rec.reference);
            let m1_words = normalize(&rec.hyp);
            let mut vs_m1 = Vec::new();
            for (l, (_, h)) in hyps.iter().enumerate() {
                let s = &mut ls[l];
                match (h.get(&key), texts[l]) {
                    (None, _) => {
                        vs_m1.push(None);
                        continue;
                    }
                    (Some(Err(_)), _) => {
                        s.errors += 1;
                        vs_m1.push(None);
                        continue;
                    }
                    _ => {}
                }
                let t = &texts[l].unwrap().text;
                s.utts += 1;
                let ours = normalize(t);
                let same = *t == rec.hyp;
                let e = wer::edits(&m1_words, &ours);
                s.same_m1 += usize::from(same);
                s.word_diff_m1 += usize::from(e > 0);
                s.edits_m1 += e;
                if rec.scored {
                    s.words += reference.len();
                    s.ours.add(align(&reference, &ours));
                    s.m1.add(align(&reference, &m1_words));
                }
                vs_m1.push(Some((same, e)));
            }
            let mut pair_row = Vec::new();
            for (p, &(i, j)) in pairs_ij.iter().enumerate() {
                match (texts[i], texts[j]) {
                    (Some(a), Some(b)) => {
                        let cell = PairCell {
                            same_text: a.text == b.text,
                            same_tokens: a
                                .tokens
                                .as_ref()
                                .zip(b.tokens.as_ref())
                                .map(|(x, y)| x == y),
                            word_edits: text_edits(&a.text, &b.text),
                        };
                        let s = &mut ps[p];
                        s.both += 1;
                        s.same += usize::from(cell.same_text);
                        s.tokens_compared += usize::from(cell.same_tokens.is_some());
                        s.token_diff += usize::from(cell.same_tokens == Some(false));
                        s.word_diff += usize::from(cell.word_edits > 0);
                        s.edits += cell.word_edits;
                        pair_row.push(Some(cell));
                    }
                    _ => pair_row.push(None),
                }
            }
            let differs = vs_m1.iter().flatten().any(|&(same, _)| !same)
                || pair_row.iter().flatten().any(|c| !c.identical());
            if differs {
                report.diffs.push(DiffRow {
                    set: set.name.clone(),
                    id: id.clone(),
                    ref_words: reference.len(),
                    vs_m1,
                    pairs: pair_row,
                });
            }
        }
        report
            .labels
            .push((set.name.clone(), set.official_wer, set.records.len(), ls));
        report.pairs.push(ps);
    }
    report
}

fn pct(e: Errors, words: usize) -> String {
    if words == 0 {
        "-".into()
    } else {
        format!("{:.3}%", 100.0 * e.total() as f64 / words as f64)
    }
}

fn print_report(report: &Report, labels: &[String]) {
    println!(
        "Agreement with M1 (exact text; word edits after the simple normalizer). WER columns use the simple normalizer over scored utterances that have a hypothesis; M1 official = the eval file's Whisper-normalized corpus WER over the whole set."
    );
    println!(
        "| set | label | utts / M1 records | failed | identical text to M1 | utts with word differences | word edits vs M1 | ref words | WER ours | WER M1 | M1 official WER |"
    );
    println!("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |");
    let mut totals = vec![LabelStats::default(); labels.len()];
    let mut total_records = 0;
    for (set, official, n, ls) in &report.labels {
        total_records += n;
        for (l, s) in ls.iter().enumerate() {
            totals[l].add(s);
            println!(
                "| {set} | {} | {}/{n} | {} | {} | {} | {} | {} | {} | {} | {} |",
                labels[l],
                s.utts,
                s.errors,
                s.same_m1,
                s.word_diff_m1,
                s.edits_m1,
                s.words,
                pct(s.ours, s.words),
                pct(s.m1, s.words),
                official.map_or("-".into(), |w| format!("{:.3}%", 100.0 * w)),
            );
        }
    }
    if report.labels.len() > 1 {
        for (l, s) in totals.iter().enumerate() {
            println!(
                "| all | {} | {}/{total_records} | {} | {} | {} | {} | {} | {} | {} | - |",
                labels[l],
                s.utts,
                s.errors,
                s.same_m1,
                s.word_diff_m1,
                s.edits_m1,
                s.words,
                pct(s.ours, s.words),
                pct(s.m1, s.words),
            );
        }
    }
    let pairs_ij = pair_indices(labels.len());
    if pairs_ij.is_empty() {
        return;
    }
    println!("\nPairwise agreement (utterances with both hypotheses)");
    println!(
        "| set | pair | utts | identical text | different text | different tokens (of utts with tokens) | utts with word differences | word edits |"
    );
    println!("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |");
    let row = |set: &str, (i, j): (usize, usize), s: &PairStats| {
        println!(
            "| {set} | {} vs {} | {} | {} | {} | {} ({}) | {} | {} |",
            labels[i],
            labels[j],
            s.both,
            s.same,
            s.both - s.same,
            s.token_diff,
            s.tokens_compared,
            s.word_diff,
            s.edits
        );
    };
    let mut totals = vec![PairStats::default(); pairs_ij.len()];
    for ((set, ..), ps) in report.labels.iter().zip(&report.pairs) {
        for (p, s) in ps.iter().enumerate() {
            totals[p].add(s);
            row(set, pairs_ij[p], s);
        }
    }
    if report.labels.len() > 1 {
        for (p, s) in totals.iter().enumerate() {
            row("all", pairs_ij[p], s);
        }
    }
}

fn write_diffs(path: &Path, report: &Report, labels: &[String]) -> Result<(), String> {
    let mut w = std::io::BufWriter::new(
        std::fs::File::create(path).map_err(|e| format!("{}: {e}", path.display()))?,
    );
    let pairs_ij = pair_indices(labels.len());
    let mut header = vec!["set".to_owned(), "id".into(), "ref_words".into()];
    header.extend(labels.iter().map(|l| format!("{l}_vs_m1")));
    header.extend(
        pairs_ij
            .iter()
            .map(|&(i, j)| format!("{}_vs_{}", labels[i], labels[j])),
    );
    let m1_cell = |c: &Option<(bool, usize)>| match c {
        None => "-".to_owned(),
        Some((true, _)) => "same".into(),
        Some((false, e)) => format!("text:{e}w"),
    };
    let pair_cell = |c: &Option<PairCell>| match c {
        None => "-".to_owned(),
        Some(c) if c.identical() => "same".into(),
        Some(c) if c.same_text => "tokens".into(),
        Some(c) => format!("text:{}w", c.word_edits),
    };
    let io = |e: std::io::Error| e.to_string();
    writeln!(w, "{}", header.join("\t")).map_err(io)?;
    for d in &report.diffs {
        let mut row = vec![d.set.clone(), d.id.clone(), d.ref_words.to_string()];
        row.extend(d.vs_m1.iter().map(m1_cell));
        row.extend(d.pairs.iter().map(pair_cell));
        writeln!(w, "{}", row.join("\t")).map_err(io)?;
    }
    w.flush().map_err(io)
}

fn run() -> Result<bool, String> {
    let args = parse_args_from(std::env::args().skip(1))?;
    let sets = args
        .m1
        .iter()
        .map(|p| m1_set(p))
        .collect::<Result<Vec<_>, _>>()?;
    check_unique_sets(&sets)?;
    let hyps = args
        .hyps
        .iter()
        .map(|(l, p)| read_hyps(p).map(|h| (l.clone(), h)))
        .collect::<Result<Vec<_>, _>>()?;
    let labels: Vec<String> = hyps.iter().map(|(l, _)| l.clone()).collect();
    // Hypotheses for sets not given with --m1 would silently drop out.
    for (l, h) in &hyps {
        let unknown = h
            .keys()
            .filter(|(s, _)| !sets.iter().any(|m| &m.name == s))
            .count();
        if unknown > 0 {
            eprintln!("{l}: {unknown} hypotheses belong to sets without an --m1 file (ignored)");
        }
    }
    let report = compare(&sets, &hyps);
    print_report(&report, &labels);
    if let Some(p) = &args.diff_out {
        write_diffs(p, &report, &labels)?;
        eprintln!(
            "{} differing utterances listed in {}",
            report.diffs.len(),
            p.display()
        );
    }
    Ok(true)
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

#[cfg(test)]
mod tests {
    use super::*;

    fn m1() -> M1Set {
        let v = serde_json::json!({
            "wer": {"wer": 0.25},
            "records": [
                {"id": "u1", "ref": "the cat sat", "hyp": "The cat sat."},
                {"id": "u2", "ref": "a dog", "hyp": "A dog."},
                {"id": "u3", "ref": "", "hyp": "Hmm.", "scored": false},
            ]
        });
        parse_m1(&v, "toy").unwrap()
    }

    fn hyps(lines: &str) -> Hyps {
        let mut h = Hyps::new();
        parse_hyps_into(lines, &mut h).unwrap();
        h
    }

    #[test]
    fn agreement_and_wer() {
        let set = m1();
        assert_eq!(set.official_wer, Some(0.25));
        let a = hyps(
            r#"{"id":"u1","set":"toy","text":"The cat sat."}
{"id":"u2","set":"toy","text":"A dog."}
{"id":"u3","set":"toy","text":"Hmm."}"#,
        );
        let b = hyps(
            r#"{"id":"u1","set":"toy","text":"The cat sat"}
{"id":"u2","set":"toy","text":"A frog."}
{"id":"u3","set":"toy","error":"too short"}
{"id":"zz","set":"other","text":"ignored"}"#,
        );
        let r = compare(&[m1()], &[("a".into(), a), ("b".into(), b)]);
        // Same text from different tokens is counted and listed, but not as a text difference.
        let c = hyps(
            r#"{"id":"u1","set":"toy","text":"The cat sat.","tokens":[1,2,3]}
{"id":"u2","set":"toy","text":"A dog.","tokens":[4]}"#,
        );
        let d = hyps(
            r#"{"id":"u1","set":"toy","text":"The cat sat.","tokens":[1,2,3]}
{"id":"u2","set":"toy","text":"A dog.","tokens":[5,6]}
{"id":"u3","set":"toy","text":"Hmm."}"#,
        );
        let rt = compare(&[m1()], &[("c".into(), c), ("d".into(), d)]);
        let p = rt.pairs[0][0];
        assert_eq!(
            (p.both, p.same, p.tokens_compared, p.token_diff, p.edits),
            (2, 2, 2, 1, 0)
        );
        assert_eq!(rt.diffs.len(), 1);
        assert_eq!(rt.diffs[0].id, "u2");
        assert_eq!(
            rt.diffs[0].pairs,
            [Some(PairCell {
                same_text: true,
                same_tokens: Some(false),
                word_edits: 0
            })]
        );
        let mut bad = Hyps::new();
        assert!(
            parse_hyps_into(r#"{"id":"u","set":"s","text":"x","tokens":[-1]}"#, &mut bad).is_err()
        );
        let (_, _, n, ls) = &r.labels[0];
        assert_eq!(*n, 3);
        let (sa, sb) = (ls[0], ls[1]);
        assert_eq!((sa.utts, sa.errors, sa.same_m1, sa.edits_m1), (3, 0, 3, 0));
        // Unscored u3 is excluded from WER: 5 reference words.
        assert_eq!((sa.words, sa.ours.total(), sa.m1.total()), (5, 0, 0));
        // b: punctuation-only difference on u1, one substitution on u2, u3 failed.
        assert_eq!((sb.utts, sb.errors, sb.same_m1), (2, 1, 0));
        assert_eq!((sb.word_diff_m1, sb.edits_m1), (1, 1));
        assert_eq!((sb.words, sb.ours.sub), (5, 1));
        let p = r.pairs[0][0];
        assert_eq!((p.both, p.same, p.word_diff, p.edits), (2, 0, 1, 1));
        // u1 and u2 differ somewhere (b vs M1); u3 differs in no comparable pair.
        let ids: Vec<&str> = r.diffs.iter().map(|d| d.id.as_str()).collect();
        assert_eq!(ids, ["u1", "u2"]);
        assert_eq!(r.diffs[1].vs_m1, [Some((true, 0)), Some((false, 1))]);
        assert_eq!(
            r.diffs[1].pairs,
            [Some(PairCell {
                same_text: false,
                same_tokens: None,
                word_edits: 1
            })]
        );
    }

    #[test]
    fn duplicates_and_bad_lines_are_rejected() {
        let mut h = Hyps::new();
        let dup = "{\"id\":\"u1\",\"set\":\"s\",\"text\":\"x\"}\n{\"id\":\"u1\",\"set\":\"s\",\"text\":\"y\"}";
        assert!(parse_hyps_into(dup, &mut h).is_err());
        let mut h = Hyps::new();
        assert!(parse_hyps_into("{\"id\":\"u1\",\"set\":\"s\"}", &mut h).is_err());
        // The same id in two sets is fine.
        let mut h = Hyps::new();
        let two = "{\"id\":\"u1\",\"set\":\"s\",\"text\":\"x\"}\n{\"id\":\"u1\",\"set\":\"t\",\"text\":\"x\"}";
        assert!(parse_hyps_into(two, &mut h).is_ok());
        let v = serde_json::json!({"wer": 0.1, "records": [
            {"id": "u1", "ref": "a", "hyp": "a"}, {"id": "u1", "ref": "a", "hyp": "a"}]});
        assert!(parse_m1(&v, "s").is_err());
        let v = serde_json::json!({"wer": 0.1, "records": [{"id": "u1", "ref": "a", "hyp": "a"}]});
        assert_eq!(parse_m1(&v, "s").unwrap().official_wer, Some(0.1));
        // The same set twice (same file, or different files with one stem) is refused.
        let one = || parse_m1(&v, "s").unwrap();
        assert!(check_unique_sets(&[one(), one()]).is_err());
        assert!(check_unique_sets(&[one(), parse_m1(&v, "t").unwrap()]).is_ok());
    }

    #[test]
    fn args() {
        let argv = |s: &str| s.split_whitespace().map(str::to_owned).collect::<Vec<_>>();
        let a = parse_args_from(argv(
            "--m1 e.json --hyps f32=a.jsonl,b.jsonl --hyps i8x2=c.jsonl",
        ))
        .unwrap();
        assert_eq!(a.hyps[0].1.len(), 2);
        assert!(parse_args_from(argv("--m1 e.json --hyps f32=a --hyps f32=b")).is_err());
        assert!(parse_args_from(argv("--m1 e.json")).is_err());
        assert!(parse_args_from(argv("--m1 e.json --hyps nolabel")).is_err());
    }
}

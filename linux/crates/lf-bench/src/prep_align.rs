//! Decode-consistent alignment of a target token sequence to TDT decisions
//! (experiment 2, DESIGN "Alignment of targets to decisions").
//!
//! The search state is `(t, u, r)`: frame `t`, target tokens emitted `u`
//! (the prediction network has consumed the start symbol and `T[..u]`, so
//! its output is row `u` of `PackedDecoder::predictor_outputs`), and `r`
//! tokens emitted on frame `t` so far. At each decision the only choices are
//! the next target token or blank, and everything else is what greedy
//! decoding (`PackedDecoder::decode`) does:
//!
//! - the duration is the joint's argmax duration at `(t, u)` (first maximum);
//! - blank advances by its duration, or by 1 when that is 0; it changes
//!   neither the prediction network nor the bias state;
//! - a token advances by its duration, except that the
//!   `MAX_SYMBOLS_PER_FRAME`-th token on one frame with duration 0 advances 1;
//! - decoding ends once the frame reaches the end, possibly overshooting.
//!
//! A path is complete when it ends with every target token emitted. The
//! alignment maximizes the summed token log-softmax (over the token and blank
//! rows, in f64) of the chosen labels. `None` when no complete path exists.

#![allow(dead_code)]

use lf_cpu::decoder::MAX_SYMBOLS_PER_FRAME;

/// One decision: frame, target tokens emitted before it, and its label (a
/// token id, or the blank id).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Decision {
    pub t: usize,
    pub u: usize,
    pub label: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Alignment {
    pub decisions: Vec<Decision>,
    /// Summed log-softmax of the labels.
    pub score: f64,
}

/// What a decision at `(t, u)` needs from one joint output row.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RowStats {
    pub lsm_blank: f64,
    /// Log-softmax of the next target token (NaN when none is left).
    pub lsm_target: f64,
    /// The argmax duration (a value of `durations`).
    pub duration: usize,
    /// The argmax token (first maximum, compared in f32 as decoding does).
    pub argmax: usize,
}

/// Statistics of one joint row (`vocab` token logits, blank last, then one
/// logit per duration).
pub fn row_stats(
    row: &[f32],
    vocab: usize,
    durations: &[usize],
    target: Option<usize>,
) -> RowStats {
    let tokens = &row[..vocab];
    let (mut argmax, mut best) = (0usize, f32::NEG_INFINITY);
    for (i, &v) in tokens.iter().enumerate() {
        if v > best {
            best = v;
            argmax = i;
        }
    }
    let m = best as f64;
    let lse = m + tokens
        .iter()
        .map(|&v| (v as f64 - m).exp())
        .sum::<f64>()
        .ln();
    let (mut d, mut dbest) = (0usize, f32::NEG_INFINITY);
    for (i, &v) in row[vocab..vocab + durations.len()].iter().enumerate() {
        if v > dbest {
            dbest = v;
            d = i;
        }
    }
    RowStats {
        lsm_blank: tokens[vocab - 1] as f64 - lse,
        lsm_target: target.map_or(f64::NAN, |y| tokens[y] as f64 - lse),
        duration: durations[d],
        argmax,
    }
}

/// The best decode-consistent path for `target` over `frames` frames.
/// `row(t, u, out)` writes the joint output row for frame `t` and
/// prediction-network row `u` (`vocab + durations.len()` values); it is
/// called at most once per reachable `(t, u)`.
pub fn align(
    frames: usize,
    target: &[usize],
    vocab: usize,
    durations: &[usize],
    row: &mut dyn FnMut(usize, usize, &mut [f32]),
) -> Option<Alignment> {
    const R: usize = MAX_SYMBOLS_PER_FRAME;
    let blank = vocab - 1;
    let big_u = target.len();
    if frames == 0 {
        return (big_u == 0).then(|| Alignment {
            decisions: Vec::new(),
            score: 0.0,
        });
    }
    let uu = big_u + 1;
    let idx = |t: usize, u: usize, r: usize| (t * uu + u) * R + r;
    let states = frames * uu * R;
    let mut score = vec![f64::NEG_INFINITY; states];
    let mut back = vec![u32::MAX; states];
    let mut cells: Vec<Option<RowStats>> = vec![None; frames * uu];
    let mut buf = vec![0.0f32; vocab + durations.len()];
    // Best complete path: (score, last state, its label).
    let mut fin: Option<(f64, usize, usize)> = None;
    score[0] = 0.0;
    for t in 0..frames {
        for u in 0..uu {
            for r in 0..R {
                let i = idx(t, u, r);
                let s = score[i];
                if s == f64::NEG_INFINITY {
                    continue;
                }
                let c = *cells[t * uu + u].get_or_insert_with(|| {
                    row(t, u, &mut buf);
                    row_stats(&buf, vocab, durations, target.get(u).copied())
                });
                let d = c.duration;
                let relax = |score: &mut [f64], back: &mut [u32], j: usize, v: f64| {
                    if v > score[j] {
                        score[j] = v;
                        back[j] = i as u32;
                    }
                };
                let mut finish = |v: f64, label: usize| {
                    if fin.is_none_or(|(b, _, _)| v > b) {
                        fin = Some((v, i, label));
                    }
                };
                // Blank.
                let nt = t + d.max(1);
                let v = s + c.lsm_blank;
                if nt >= frames {
                    if u == big_u {
                        finish(v, blank);
                    }
                } else {
                    relax(&mut score, &mut back, idx(nt, u, 0), v);
                }
                // The next target token.
                if u < big_u {
                    let nr = r + 1;
                    let a = if d == 0 && nr >= R { 1 } else { d };
                    let v = s + c.lsm_target;
                    if a == 0 {
                        relax(&mut score, &mut back, idx(t, u + 1, nr), v);
                    } else if t + a >= frames {
                        if u + 1 == big_u {
                            finish(v, target[u]);
                        }
                    } else {
                        relax(&mut score, &mut back, idx(t + a, u + 1, 0), v);
                    }
                }
            }
        }
    }
    let (total, last, last_label) = fin?;
    let mut path = vec![last];
    while back[*path.last().unwrap()] != u32::MAX {
        path.push(back[*path.last().unwrap()] as usize);
    }
    path.reverse();
    let decode = |i: usize| (i / R / uu, i / R % uu);
    let mut decisions = Vec::with_capacity(path.len());
    for (k, &i) in path.iter().enumerate() {
        let (t, u) = decode(i);
        let label = match path.get(k + 1) {
            Some(&j) if decode(j).1 == u => blank,
            Some(_) => target[u],
            None => last_label,
        };
        decisions.push(Decision { t, u, label });
    }
    Some(Alignment {
        decisions,
        score: total,
    })
}

/// Greedy decoding replayed through `row`, with the prediction network
/// following `target`: returns the `(token, frame)` emissions, or `Err` with
/// the emissions so far when the argmax token leaves `target`. With exact
/// joint rows and `target` = the greedy output, this is that output.
/// `(token, frame)` emissions.
pub type Emissions = Vec<(usize, usize)>;

pub fn greedy_replay(
    frames: usize,
    target: &[usize],
    vocab: usize,
    durations: &[usize],
    row: &mut dyn FnMut(usize, usize, &mut [f32]),
) -> Result<Emissions, Emissions> {
    let blank = vocab - 1;
    let mut buf = vec![0.0f32; vocab + durations.len()];
    let (mut frame, mut last_frame, mut symbols, mut u) = (0usize, usize::MAX, 0usize, 0usize);
    let mut emitted = Vec::new();
    while frame < frames {
        row(frame, u, &mut buf);
        let c = row_stats(&buf, vocab, durations, None);
        let (token, duration) = (c.argmax, c.duration);
        let mut advance = if token == blank && duration == 0 {
            1
        } else {
            duration
        };
        if token != blank {
            if target.get(u) != Some(&token) {
                return Err(emitted);
            }
            symbols = if last_frame == frame { symbols + 1 } else { 1 };
            last_frame = frame;
            emitted.push((token, frame));
            u += 1;
            if advance == 0 && symbols >= MAX_SYMBOLS_PER_FRAME {
                advance = 1;
            }
        }
        frame += advance;
    }
    Ok(emitted)
}

#[cfg(test)]
mod tests {
    use super::*;
    use lf_cpu::decoder::{DecoderParams, reference};
    use lf_model::rng::SplitMix64;

    const DUR: [usize; 5] = [0, 1, 2, 3, 4];

    /// A joint given as a table: `rows[(t, u)]`, `vocab + 5` values.
    struct Table {
        vocab: usize,
        frames: usize,
        uu: usize,
        rows: Vec<Vec<f32>>,
    }

    impl Table {
        fn random(vocab: usize, frames: usize, uu: usize, seed: u64, dur_bias: [f32; 5]) -> Self {
            let mut rng = SplitMix64::new(seed);
            let rows = (0..frames * uu)
                .map(|_| {
                    let mut r: Vec<f32> = (0..vocab).map(|_| 2.0 * rng.next_gaussian()).collect();
                    r.extend(dur_bias.iter().map(|&b| b + rng.next_gaussian()));
                    r
                })
                .collect();
            Table {
                vocab,
                frames,
                uu,
                rows,
            }
        }

        fn row(&self) -> impl FnMut(usize, usize, &mut [f32]) + '_ {
            move |t, u, out| out.copy_from_slice(&self.rows[t * self.uu + u])
        }

        /// Sets the argmax duration at `(t, u)` (by index into `DUR`).
        fn set_duration(&mut self, t: usize, u: usize, d: usize) {
            let r = &mut self.rows[t * self.uu + u];
            for k in 0..5 {
                r[self.vocab + k] = if k == d { 10.0 } else { -10.0 };
            }
        }
    }

    /// The greedy decoder's loop, copied literally (frame, last_frame,
    /// symbols, advance), with each token decision forced to `labels[k]`.
    /// Returns the decisions if `labels` is used up exactly when decoding ends.
    fn simulate(
        frames: usize,
        vocab: usize,
        labels: &[usize],
        row: &mut dyn FnMut(usize, usize, &mut [f32]),
    ) -> Option<Vec<Decision>> {
        let blank = vocab - 1;
        let mut buf = vec![0.0f32; vocab + 5];
        let (mut frame, mut last_frame, mut symbols, mut u) = (0usize, usize::MAX, 0usize, 0usize);
        let mut out = Vec::new();
        while frame < frames {
            let &token = labels.get(out.len())?;
            row(frame, u, &mut buf);
            let duration = row_stats(&buf, vocab, &DUR, None).duration;
            out.push(Decision {
                t: frame,
                u,
                label: token,
            });
            let mut advance = if token == blank && duration == 0 {
                1
            } else {
                duration
            };
            if token != blank {
                symbols = if last_frame == frame { symbols + 1 } else { 1 };
                last_frame = frame;
                u += 1;
                if advance == 0 && symbols >= MAX_SYMBOLS_PER_FRAME {
                    advance = 1;
                }
            }
            frame += advance;
        }
        (out.len() == labels.len()).then_some(out)
    }

    fn path_score(table: &Table, target: &[usize], d: &[Decision]) -> f64 {
        d.iter()
            .map(|x| {
                let s = row_stats(
                    &table.rows[x.t * table.uu + x.u],
                    table.vocab,
                    &DUR,
                    target.get(x.u).copied(),
                );
                if x.label == table.vocab - 1 {
                    s.lsm_blank
                } else {
                    s.lsm_target
                }
            })
            .sum()
    }

    /// Exhaustive search over every choice sequence (next token or blank)
    /// through the literal decoder loop: the best complete score, if any.
    fn brute_force(table: &Table, target: &[usize]) -> Option<f64> {
        fn go(table: &Table, target: &[usize], labels: &mut Vec<usize>, best: &mut Option<f64>) {
            let mut row = table.row();
            // Where does the forced decoder stand after `labels`?
            let blank = table.vocab - 1;
            let mut buf = vec![0.0f32; table.vocab + 5];
            let (mut frame, mut last_frame, mut symbols, mut u) =
                (0usize, usize::MAX, 0usize, 0usize);
            for &token in labels.iter() {
                row(frame, u, &mut buf);
                let duration = row_stats(&buf, table.vocab, &DUR, None).duration;
                let mut advance = if token == blank && duration == 0 {
                    1
                } else {
                    duration
                };
                if token != blank {
                    symbols = if last_frame == frame { symbols + 1 } else { 1 };
                    last_frame = frame;
                    u += 1;
                    if advance == 0 && symbols >= MAX_SYMBOLS_PER_FRAME {
                        advance = 1;
                    }
                }
                frame += advance;
            }
            if frame >= table.frames {
                if u == target.len() {
                    let d = simulate(table.frames, table.vocab, labels, &mut table.row()).unwrap();
                    let s = path_score(table, target, &d);
                    if best.is_none_or(|b| s > b) {
                        *best = Some(s);
                    }
                }
                return;
            }
            labels.push(blank);
            go(table, target, labels, best);
            labels.pop();
            if u < target.len() {
                labels.push(target[u]);
                go(table, target, labels, best);
                labels.pop();
            }
        }
        let mut best = None;
        go(table, target, &mut Vec::new(), &mut best);
        best
    }

    #[test]
    fn best_path_is_decode_consistent_and_optimal() {
        // Random small tables, with duration 0 frequent enough that
        // same-frame runs (and the forced advance) happen.
        let mut checked = 0;
        for seed in 0..60u64 {
            let frames = 2 + (seed % 5) as usize;
            let target: Vec<usize> = (0..(seed % 6) as usize)
                .map(|k| (k * 3 + seed as usize) % 6)
                .collect();
            let table = Table::random(
                7,
                frames,
                target.len() + 1,
                seed,
                [1.0, 0.8, 0.5, 0.0, -0.5],
            );
            let got = align(frames, &target, 7, &DUR, &mut table.row());
            let brute = brute_force(&table, &target);
            match (got, brute) {
                (Some(a), Some(b)) => {
                    // Replaying the labels through the decoder's own loop
                    // visits exactly the same decisions.
                    let labels: Vec<usize> = a.decisions.iter().map(|d| d.label).collect();
                    let sim = simulate(frames, 7, &labels, &mut table.row()).unwrap();
                    assert_eq!(sim, a.decisions, "seed {seed}");
                    assert!((a.score - path_score(&table, &target, &a.decisions)).abs() < 1e-9);
                    assert!(
                        (a.score - b).abs() < 1e-9,
                        "seed {seed}: {} vs {b}",
                        a.score
                    );
                    checked += 1;
                }
                (None, None) => {}
                (a, b) => panic!("seed {seed}: aligner {a:?}, brute force {b:?}"),
            }
        }
        assert!(checked > 30);
    }

    #[test]
    fn blank_with_duration_zero_advances_one_frame() {
        // Duration 0 everywhere. The single target token is likely only on
        // frame 2: the path must take blanks at frames 0 and 1, one frame each.
        let mut table = Table::random(5, 4, 2, 1, [0.0; 5]);
        for t in 0..4 {
            for u in 0..2 {
                table.set_duration(t, u, 0);
            }
        }
        for t in 0..4 {
            table.rows[t * 2][2] = if t == 2 { 20.0 } else { -20.0 };
        }
        let a = align(4, &[2], 5, &DUR, &mut table.row()).unwrap();
        let got: Vec<(usize, usize, usize)> =
            a.decisions.iter().map(|d| (d.t, d.u, d.label)).collect();
        assert_eq!(
            got,
            vec![(0, 0, 4), (1, 0, 4), (2, 0, 2), (2, 1, 4), (3, 1, 4)]
        );
    }

    #[test]
    fn tenth_token_on_a_frame_forces_an_advance() {
        // Twelve tokens, duration 0 everywhere, two frames, and blank very
        // unlikely on frame 0: ten tokens on frame 0 (the tenth advances),
        // two on frame 1, then a blank ends it.
        let target = vec![1usize; 12];
        let mut table = Table::random(4, 2, 13, 3, [0.0; 5]);
        for t in 0..2 {
            for u in 0..13 {
                table.set_duration(t, u, 0);
                table.rows[t * 13 + u][1] = 10.0;
                if t == 0 {
                    table.rows[u][3] = -30.0;
                }
            }
        }
        let a = align(2, &target, 4, &DUR, &mut table.row()).unwrap();
        let frames: Vec<usize> = a.decisions.iter().map(|d| d.t).collect();
        let mut expected = vec![0; 10];
        expected.extend([1, 1, 1]);
        assert_eq!(frames, expected);
        assert_eq!(a.decisions.last().unwrap().label, 3);
        // Eleven tokens cannot fit on frame 0, and with one frame there is no room.
        assert!(align(1, &target[..11], 4, &DUR, &mut table.row()).is_none());
        assert!(align(1, &target[..10], 4, &DUR, &mut table.row()).is_some());
    }

    #[test]
    fn final_advance_may_overshoot_and_every_token_must_be_emitted() {
        // Duration 4 everywhere on 3 frames: one decision ends decoding.
        let mut table = Table::random(5, 3, 3, 5, [0.0; 5]);
        for t in 0..3 {
            for u in 0..3 {
                table.set_duration(t, u, 4);
            }
        }
        let a = align(3, &[1], 5, &DUR, &mut table.row()).unwrap();
        assert_eq!(
            a.decisions,
            vec![Decision {
                t: 0,
                u: 0,
                label: 1
            }]
        );
        // Two tokens cannot both be emitted before the end.
        assert!(align(3, &[1, 2], 5, &DUR, &mut table.row()).is_none());
        // No target: a single blank.
        let a = align(3, &[], 5, &DUR, &mut table.row()).unwrap();
        assert_eq!(
            a.decisions,
            vec![Decision {
                t: 0,
                u: 0,
                label: 4
            }]
        );
        assert!(
            align(0, &[], 5, &DUR, &mut table.row())
                .unwrap()
                .decisions
                .is_empty()
        );
        assert!(align(0, &[1], 5, &DUR, &mut table.row()).is_none());
    }

    /// The f64 reference decoder's prediction network, from the public
    /// weights: g after the start symbol (a blank step, when `sos`) and after
    /// each token.
    fn predictor(p: &DecoderParams, tokens: &[usize], sos: bool) -> Vec<Vec<f64>> {
        let hd = p.hidden;
        let sig = |x: f64| 1.0 / (1.0 + (-x).exp());
        let mv = |w: &[f32], rows: usize, k: usize, x: &[f64], b: &[f32]| -> Vec<f64> {
            (0..rows)
                .map(|r| {
                    w[r * k..(r + 1) * k]
                        .iter()
                        .zip(x)
                        .map(|(&a, &b)| a as f64 * b)
                        .sum::<f64>()
                        + b[r] as f64
                })
                .collect()
        };
        let mut h = [vec![0.0; hd], vec![0.0; hd]];
        let mut c = [vec![0.0; hd], vec![0.0; hd]];
        let mut out = Vec::new();
        if !sos {
            out.push(mv(&p.w_pred, p.joint, hd, &h[1], &p.b_pred));
        }
        let start = if sos { vec![p.blank()] } else { Vec::new() };
        for &tok in start.iter().chain(tokens) {
            let mut x: Vec<f64> = p.embed[tok * hd..(tok + 1) * hd]
                .iter()
                .map(|&v| v as f64)
                .collect();
            for l in 0..2 {
                let a = mv(&p.w_ih[l], 4 * hd, hd, &x, &p.b_ih[l]);
                let b = mv(&p.w_hh[l], 4 * hd, hd, &h[l], &p.b_hh[l]);
                for k in 0..hd {
                    let g = |q: usize| a[q * hd + k] + b[q * hd + k];
                    c[l][k] = sig(g(1)) * c[l][k] + sig(g(0)) * g(2).tanh();
                    h[l][k] = sig(g(3)) * c[l][k].tanh();
                }
                x = h[l].clone();
            }
            out.push(mv(&p.w_pred, p.joint, hd, &x, &p.b_pred));
        }
        out
    }

    /// Joint rows of the f64 reference for projected frames `f` and
    /// predictor rows `g`.
    fn joint<'a>(
        p: &'a DecoderParams,
        f: &'a [Vec<f64>],
        g: &'a [Vec<f64>],
    ) -> impl FnMut(usize, usize, &mut [f32]) + 'a {
        move |t, u, out| {
            let z: Vec<f64> = f[t]
                .iter()
                .zip(&g[u])
                .map(|(a, b)| (a + b).max(0.0))
                .collect();
            for (r, o) in out.iter_mut().enumerate() {
                let w = &p.w_out[r * p.joint..(r + 1) * p.joint];
                *o = (w.iter().zip(&z).map(|(&a, &b)| a as f64 * b).sum::<f64>()
                    + p.b_out[r] as f64) as f32;
            }
        }
    }

    #[test]
    fn replay_and_alignment_follow_the_reference_decoder() {
        // The prediction network starts with one blank (start-symbol) step:
        // row u of the predictor is after the start symbol and u tokens. With
        // that joint, greedy replay reproduces the f64 reference decoder, and
        // the greedy output is aligned decode-consistently.
        for (vocab, seed) in [(33usize, 11u64), (71, 21)] {
            let p = DecoderParams::random(vocab, 32, 40, 48, seed);
            let frames = 40;
            let mut rng = SplitMix64::new(seed + 1);
            let enc: Vec<f32> = (0..frames * p.enc_dim)
                .map(|_| rng.next_gaussian())
                .collect();
            let (expected, decisions) = reference::decode(&p, &enc, frames, None);
            let h: Vec<usize> = expected.iter().map(|e| e.0).collect();
            assert!(h.len() > 5);
            let f: Vec<Vec<f64>> = (0..frames)
                .map(|t| {
                    (0..p.joint)
                        .map(|j| {
                            (0..p.enc_dim)
                                .map(|i| {
                                    p.w_enc[j * p.enc_dim + i] as f64
                                        * enc[t * p.enc_dim + i] as f64
                                })
                                .sum::<f64>()
                                + p.b_enc[j] as f64
                        })
                        .collect()
                })
                .collect();
            let g = predictor(&p, &h, true);
            let mut row = joint(&p, &f, &g);
            assert_eq!(
                greedy_replay(frames, &h, p.vocab, &DUR, &mut row),
                Ok(expected.clone())
            );
            // Every reference decision's logits are the joint row at its
            // frame and emitted-token count; without the start step they
            // are not.
            let g0 = predictor(&p, &h, false);
            let mut no_sos = joint(&p, &f, &g0);
            let mut buf = vec![0.0f32; p.vocab + 5];
            let (mut u, mut worst, mut worst_no_sos) = (0usize, 0f64, 0f64);
            for d in &decisions {
                row(d.frame, u, &mut buf);
                let diff = |b: &[f32]| {
                    b.iter()
                        .zip(&d.logits)
                        .map(|(&a, &b)| (a as f64 - b).abs())
                        .fold(0.0, f64::max)
                };
                worst = worst.max(diff(&buf));
                no_sos(d.frame, u, &mut buf);
                worst_no_sos = worst_no_sos.max(diff(&buf));
                u += usize::from(d.token != p.blank());
            }
            assert!(worst < 1e-5, "{worst} {worst_no_sos}");
            assert!(worst_no_sos > 1e-4, "{worst} {worst_no_sos}");
            // The reference's own decisions are one decode-consistent path for H.
            let greedy: Vec<usize> = decisions.iter().map(|d| d.token).collect();
            let gd = simulate(frames, p.vocab, &greedy, &mut row).unwrap();
            let decision_frames: Vec<usize> = decisions.iter().map(|d| d.frame).collect();
            assert_eq!(gd.iter().map(|d| d.t).collect::<Vec<_>>(), decision_frames);
            let mut buf = vec![0.0f32; p.vocab + 5];
            let mut greedy_score = 0.0;
            for d in &gd {
                row(d.t, d.u, &mut buf);
                let s = row_stats(&buf, p.vocab, &DUR, h.get(d.u).copied());
                greedy_score += if d.label == p.blank() {
                    s.lsm_blank
                } else {
                    s.lsm_target
                };
            }
            // The best path replays through the decoder's loop, emits H, and
            // scores at least as well as the greedy path.
            let a = align(frames, &h, p.vocab, &DUR, &mut row).unwrap();
            let labels: Vec<usize> = a.decisions.iter().map(|d| d.label).collect();
            assert_eq!(
                simulate(frames, p.vocab, &labels, &mut row).unwrap(),
                a.decisions
            );
            let emitted: Vec<usize> = labels.into_iter().filter(|&l| l != p.blank()).collect();
            assert_eq!(emitted, h);
            assert!(a.score >= greedy_score - 1e-9);
        }
    }
}

//! Training shards written by `lf-bias-prep` (CONTRACT-2 §4): one
//! safetensors file per dictionary sample of a call, holding the dictionary
//! trie with its candidate tables, the utterances' projected encoder frames
//! and prediction-network outputs, and the aligned decisions.
//!
//! Candidate tables: the candidates of state `s` (`BiasGraph::candidates`)
//! always include every token of the root's set, since a failure chain ends
//! at the root, so they are stored as the root's rows plus, per state, the
//! rows whose token is not in the root's set or whose destination differs.
//! [`reconstruct`] is the reader's rule: the root rows, replaced or extended
//! by the state's overrides, sorted by token.

#![allow(dead_code)]

use std::collections::BTreeMap;

use lf_cpu::bias::{BiasGraph, BiasState};
use lf_model::safetensors::{TensorData, serialize};

use crate::learned::{BLANK, TrieFeatures};

/// The format tag in every shard's metadata.
pub const SHARD_FORMAT: &str = "lf-bias-prep-v1";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CandTables {
    /// The root's `(token, dest)` rows, sorted by token.
    pub root: Vec<(u32, u32)>,
    /// `overrides[offset[s]..offset[s + 1]]` belong to state `s`, sorted by token.
    pub offset: Vec<i64>,
    pub overrides: Vec<(u32, u32)>,
}

/// The candidate tables of `states` states, from `cands(s)` (each sorted by
/// token and a superset of the root's tokens).
pub fn cand_tables(
    states: usize,
    cands: &dyn Fn(BiasState) -> Vec<(u32, BiasState)>,
) -> CandTables {
    let root = cands(BiasGraph::ROOT);
    let mut offset = Vec::with_capacity(states + 1);
    let mut overrides = Vec::new();
    offset.push(0);
    for s in 0..states as u32 {
        if s != BiasGraph::ROOT {
            let c = cands(s);
            let mut k = 0;
            for &(t, d) in &c {
                while k < root.len() && root[k].0 < t {
                    k += 1;
                }
                let same = k < root.len() && root[k] == (t, d);
                if !same {
                    overrides.push((t, d));
                }
            }
        }
        offset.push(overrides.len() as i64);
    }
    CandTables {
        root,
        offset,
        overrides,
    }
}

/// The candidates of state `s` from the tables: the root's rows, replaced
/// or extended by `s`'s overrides, sorted by token.
pub fn reconstruct(t: &CandTables, s: usize) -> Vec<(u32, u32)> {
    let ov = &t.overrides[t.offset[s] as usize..t.offset[s + 1] as usize];
    let mut out = Vec::with_capacity(t.root.len() + ov.len());
    let (mut i, mut j) = (0, 0);
    while i < t.root.len() || j < ov.len() {
        match (t.root.get(i), ov.get(j)) {
            (Some(&r), Some(&o)) if r.0 == o.0 => {
                out.push(o);
                i += 1;
                j += 1;
            }
            (Some(&r), Some(&o)) if r.0 < o.0 => {
                out.push(r);
                i += 1;
            }
            (Some(&r), None) => {
                out.push(r);
                i += 1;
            }
            (_, Some(&o)) => {
                out.push(o);
                j += 1;
            }
            (None, None) => unreachable!(),
        }
    }
    out
}

/// One utterance of a shard.
pub struct ShardUtt {
    pub id: String,
    /// `[frames][joint]` projected encoder frames.
    pub enc: Vec<f32>,
    /// `[target.len() + 1][joint]` prediction-network outputs.
    pub pred: Vec<f32>,
    pub target: Vec<usize>,
    pub decisions: Vec<ShardDecision>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ShardDecision {
    pub t: u32,
    pub u: u32,
    /// Bias state after `target[..u]`.
    pub state: u32,
    /// Token id, or `BLANK`.
    pub label: u32,
    /// 0 preservation, 1 correction.
    pub kind: u8,
}

fn pairs(v: &[(u32, u32)]) -> Vec<i32> {
    v.iter().flat_map(|&(a, b)| [a as i32, b as i32]).collect()
}

/// The shard file: trie, candidates, utterances and decisions (CONTRACT-2
/// §4), plus `target.offset`/`target` (the target tokens of each utterance)
/// and any `extra` tensors.
pub fn shard_bytes(
    metadata: &BTreeMap<String, String>,
    trie: &TrieFeatures,
    cands: &CandTables,
    g_size: f32,
    joint: usize,
    utts: &[ShardUtt],
    extra: Vec<TensorData>,
) -> Result<Vec<u8>, String> {
    let n = trie.nodes();
    let tokens: Vec<i32> = trie.token.iter().map(|&t| t as i32).collect();
    debug_assert_eq!(tokens[0], BLANK as i32);
    let depth: Vec<i32> = trie.depth.iter().map(|&d| d as i32).collect();
    let nf: Vec<f32> = trie.nf.iter().flatten().copied().collect();
    let mut frame_offset = vec![0i64];
    let mut pred_offset = vec![0i64];
    let mut target_offset = vec![0i64];
    let (mut enc, mut pred, mut target) = (Vec::new(), Vec::new(), Vec::new());
    let mut dec: [Vec<i32>; 5] = Default::default();
    let mut kind = Vec::new();
    for (i, u) in utts.iter().enumerate() {
        if u.enc.len() % joint != 0 || u.pred.len() != (u.target.len() + 1) * joint {
            return Err(format!("{}: enc/pred shapes", u.id));
        }
        enc.extend_from_slice(&u.enc);
        pred.extend_from_slice(&u.pred);
        target.extend(u.target.iter().map(|&t| t as i32));
        frame_offset.push((enc.len() / joint) as i64);
        pred_offset.push((pred.len() / joint) as i64);
        target_offset.push(target.len() as i64);
        for d in &u.decisions {
            for (k, v) in [i as u32, d.t, d.u, d.state, d.label]
                .into_iter()
                .enumerate()
            {
                dec[k].push(v as i32);
            }
            kind.push(d.kind);
        }
    }
    let nd = kind.len();
    let mut tensors = vec![
        TensorData::i32("trie.token", vec![n], &tokens),
        TensorData::i32("trie.depth", vec![n], &depth),
        TensorData::i32("trie.parent", vec![n], &trie.parent),
        TensorData::f32("trie.nf", vec![n, 5], &nf),
        TensorData::i32("cand.root", vec![cands.root.len(), 2], &pairs(&cands.root)),
        TensorData::i64("cand.override.offset", vec![n + 1], &cands.offset),
        TensorData::i32(
            "cand.override",
            vec![cands.overrides.len(), 2],
            &pairs(&cands.overrides),
        ),
        TensorData::f32("g_size", vec![], &[g_size]),
        TensorData::i64("utt.frame_offset", vec![utts.len() + 1], &frame_offset),
        TensorData::f32("enc", vec![enc.len() / joint, joint], &enc),
        TensorData::i64("utt.pred_offset", vec![utts.len() + 1], &pred_offset),
        TensorData::f32("pred", vec![pred.len() / joint, joint], &pred),
        TensorData::i64("target.offset", vec![utts.len() + 1], &target_offset),
        TensorData::i32("target", vec![target.len()], &target),
        TensorData::i32("dec.utt", vec![nd], &dec[0]),
        TensorData::i32("dec.t", vec![nd], &dec[1]),
        TensorData::i32("dec.u", vec![nd], &dec[2]),
        TensorData::i32("dec.state", vec![nd], &dec[3]),
        TensorData::i32("dec.label", vec![nd], &dec[4]),
        TensorData::u8("dec.kind", vec![nd], &kind),
    ];
    tensors.extend(extra);
    serialize(metadata, &tensors).map_err(|e| e.to_string())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use lf_cpu::bias::BiasConfig;
    use lf_model::rng::SplitMix64;

    /// Test-only reference: every token whose `step` leaves the root.
    pub(crate) fn candidates_by_step(g: &BiasGraph, s: BiasState) -> Vec<(u32, BiasState)> {
        (0..g.tokens())
            .filter_map(|t| {
                let (m, _) = g.step(s, t);
                (m != BiasGraph::ROOT).then_some((t as u32, m))
            })
            .collect()
    }

    pub(crate) fn random_graph(seed: u64, tokens: usize, phrases: usize) -> BiasGraph {
        let mut rng = SplitMix64::new(seed);
        let p: Vec<Vec<usize>> = (0..phrases)
            .map(|_| {
                let len = 1 + rng.below(5) as usize;
                (0..len)
                    .map(|_| rng.below(tokens as u64) as usize)
                    .collect()
            })
            .collect();
        let config = BiasConfig {
            alpha: 1.0,
            context_score: 1.0,
            depth_scaling: 0.0,
            cancel_unfinished: false,
        };
        BiasGraph::new(&p, tokens, config).unwrap()
    }

    #[test]
    fn candidate_tables_reconstruct_step_exactly() {
        let mut overridden = 0;
        for seed in 0..40 {
            let g = random_graph(seed, 3 + (seed % 10) as usize, 1 + (seed % 25) as usize);
            let tables = cand_tables(g.states(), &|s| g.candidates(s));
            assert_eq!(tables.offset.len(), g.states() + 1);
            assert_eq!(tables.offset[1], 0, "the root has no overrides");
            for s in 0..g.states() {
                let want = candidates_by_step(&g, s as BiasState);
                assert_eq!(g.candidates(s as BiasState), want, "seed {seed} state {s}");
                assert_eq!(reconstruct(&tables, s), want, "seed {seed} state {s}");
                // Overrides are exactly the rows that differ from the root's.
                let ov =
                    &tables.overrides[tables.offset[s] as usize..tables.offset[s + 1] as usize];
                assert!(ov.iter().all(|r| !tables.root.contains(r)));
                assert!(ov.windows(2).all(|w| w[0].0 < w[1].0));
                overridden += ov.len();
            }
        }
        assert!(overridden > 50, "tables should exercise overrides");
    }

    #[test]
    fn shard_tensors_have_the_contract_shapes() {
        let g = random_graph(3, 12, 6);
        let trie = TrieFeatures::new(&g);
        let tables = cand_tables(g.states(), &|s| g.candidates(s));
        let utts = vec![
            ShardUtt {
                id: "u0".into(),
                enc: vec![0.5; 3 * 4],
                pred: vec![0.25; 3 * 4],
                target: vec![1, 2],
                decisions: vec![
                    ShardDecision {
                        t: 0,
                        u: 0,
                        state: 0,
                        label: 1,
                        kind: 1,
                    },
                    ShardDecision {
                        t: 1,
                        u: 1,
                        state: 2,
                        label: BLANK as u32,
                        kind: 0,
                    },
                ],
            },
            ShardUtt {
                id: "u1".into(),
                enc: vec![1.0; 2 * 4],
                pred: vec![2.0; 4],
                target: vec![],
                decisions: vec![ShardDecision {
                    t: 0,
                    u: 0,
                    state: 0,
                    label: BLANK as u32,
                    kind: 0,
                }],
            },
        ];
        let meta = BTreeMap::from([("format".to_owned(), SHARD_FORMAT.to_owned())]);
        let bytes = shard_bytes(&meta, &trie, &tables, 0.5, 4, &utts, Vec::new()).unwrap();
        let st = lf_model::SafeTensors::parse(bytes).unwrap();
        let n = g.states();
        let shape = |k: &str| st.tensors[k].shape.clone();
        assert_eq!(shape("trie.nf"), vec![n, 5]);
        assert_eq!(shape("cand.override.offset"), vec![n + 1]);
        assert_eq!(shape("enc"), vec![5, 4]);
        assert_eq!(shape("pred"), vec![4, 4]);
        assert_eq!(shape("g_size"), Vec::<usize>::new());
        assert_eq!(st.i64_vec("utt.frame_offset").unwrap(), vec![0, 3, 5]);
        assert_eq!(st.i64_vec("utt.pred_offset").unwrap(), vec![0, 3, 4]);
        assert_eq!(st.i32_vec("dec.utt").unwrap(), vec![0, 0, 1]);
        assert_eq!(st.i32_vec("dec.label").unwrap(), vec![1, 1024, 1024]);
        assert_eq!(st.u8_vec("dec.kind").unwrap(), vec![1, 0, 0]);
        assert_eq!(st.i32_vec("trie.parent").unwrap()[0], -1);
        assert_eq!(st.i32_vec("trie.token").unwrap()[0], 1024);
    }
}

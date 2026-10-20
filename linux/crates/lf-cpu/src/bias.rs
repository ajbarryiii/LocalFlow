// DESIGN refers to docs/dictionary/DESIGN.md; pins to docs/dictionary/DESIGN-pins.md.
//! Word boosting (contextual biasing) for greedy TDT decoding.
//!
//! A [`BiasGraph`] is an Aho-Corasick automaton over token ids: a trie of
//! the boosted phrases plus failure links, so a match can start right after a
//! mismatch or overlap another phrase. Each phrase carries a strength.
//!
//! Scores (LocalFlow's shared dictionary contract, DESIGN §1.2):
//!
//! - `σ(n)`: the largest strength of the phrases whose path passes through
//!   or ends at trie state `n`.
//! - `own(n) = σ(n) · (CONTEXT_SCORE + DEPTH_SCALING · ln d(n))` at depth
//!   `d(n) ≥ 1`; `own(root) = 0`.
//! - `score(n) = max(own(n), score(fail(n)))`, so the best match on the
//!   suffix chain wins whatever order the phrases were given in.
//! - Non-blank token `t` taken from state `s` gets the bonus
//!   `ALPHA · score(goto(s, t))` (0 when `goto` returns to the root),
//!   computed in f64 and stored as f32. Blank gets no bonus and does not
//!   move the state.
//!
//! Strengths of entries that share a token prefix are coupled through `σ`.

use lf_model::{Error, Result};

/// Overall weight of every bonus.
pub const ALPHA: f64 = 1.414;
/// Score of a match at depth 1 (times its strength).
pub const CONTEXT_SCORE: f64 = 1.0;
/// Depth `d` scores `CONTEXT_SCORE + DEPTH_SCALING · ln d`.
pub const DEPTH_SCALING: f64 = 3.0;

/// A state of a [`BiasGraph`]; [`BiasGraph::ROOT`] before any match.
pub type BiasState = u32;

pub struct BiasGraph {
    tokens: usize,
    /// Trie children of state `s`: `children[child_start[s]..child_start[s + 1]]`,
    /// sorted by token.
    child_start: Vec<u32>,
    children: Vec<(u32, BiasState)>,
    fail: Vec<BiasState>,
    /// `ALPHA · score(n)` as f32: the bonus of a token that leads to `n`.
    bonus: Vec<f32>,
}

impl BiasGraph {
    pub const ROOT: BiasState = 0;

    /// `phrases`: token-id sequences (blank excluded) with their strengths.
    /// Each must be non-empty with every id below `tokens` (the vocabulary
    /// size without blank), and each strength finite and positive.
    /// Duplicate sequences keep their largest strength.
    pub fn new(phrases: &[(Vec<usize>, f32)], tokens: usize) -> Result<Self> {
        for (i, (p, strength)) in phrases.iter().enumerate() {
            if p.is_empty() {
                return Err(Error(format!("bias phrase {i} is empty")));
            }
            if let Some(&t) = p.iter().find(|&&t| t >= tokens) {
                return Err(Error(format!(
                    "bias phrase {i}: token {t} out of range ({tokens} tokens)"
                )));
            }
            if !(strength.is_finite() && *strength > 0.0) {
                return Err(Error(format!("bias phrase {i}: invalid strength")));
            }
        }
        // Trie with σ: every state on a phrase's path takes its strength.
        let mut kids: Vec<Vec<(u32, BiasState)>> = vec![Vec::new()];
        let mut sigma = vec![0.0f64];
        for (p, strength) in phrases {
            let strength = f64::from(*strength);
            let mut s = 0usize;
            for &t in p {
                let t = t as u32;
                s = match kids[s].iter().find(|&&(k, _)| k == t) {
                    Some(&(_, c)) => c as usize,
                    None => {
                        let c = kids.len();
                        let c32 =
                            u32::try_from(c).map_err(|_| Error("too many bias states".into()))?;
                        kids[s].push((t, c32));
                        kids.push(Vec::new());
                        sigma.push(0.0);
                        c
                    }
                };
                sigma[s] = sigma[s].max(strength);
            }
        }
        let states = kids.len();
        let mut child_start = Vec::with_capacity(states + 1);
        let mut children = Vec::new();
        for k in &mut kids {
            k.sort_unstable();
            child_start.push(children.len() as u32);
            children.extend_from_slice(k);
        }
        child_start.push(children.len() as u32);

        let mut graph = BiasGraph {
            tokens,
            child_start,
            children,
            fail: vec![Self::ROOT; states],
            bonus: vec![0.0; states],
        };
        // Breadth-first: a state's parent and failure target are shallower,
        // so their scores are final when it is reached.
        let mut score = vec![0.0f64; states];
        let mut depth = vec![0usize; states];
        let mut queue = std::collections::VecDeque::from([Self::ROOT]);
        while let Some(s) = queue.pop_front() {
            for i in graph.child_range(s) {
                let (t, c) = graph.children[i];
                let cu = c as usize;
                let d = depth[s as usize] + 1;
                depth[cu] = d;
                let f = if s == Self::ROOT {
                    Self::ROOT
                } else {
                    graph.next(graph.fail[s as usize], t)
                };
                graph.fail[cu] = f;
                let own = sigma[cu] * (CONTEXT_SCORE + DEPTH_SCALING * (d as f64).ln());
                score[cu] = own.max(score[f as usize]);
                graph.bonus[cu] = (ALPHA * score[cu]) as f32;
                queue.push_back(c);
            }
        }
        Ok(graph)
    }

    /// True when no token ever receives a bonus (no phrases).
    pub fn is_empty(&self) -> bool {
        self.children.is_empty()
    }

    /// Vocabulary size without blank; every phrase token is below it.
    pub fn tokens(&self) -> usize {
        self.tokens
    }

    /// The state after emitting non-blank `token` at `state`, and the bonus
    /// that token receives at `state`.
    pub fn step(&self, state: BiasState, token: usize) -> (BiasState, f32) {
        let Ok(t) = u32::try_from(token) else {
            return (Self::ROOT, 0.0);
        };
        let m = self.next(state, t);
        (m, self.bonus[m as usize])
    }

    /// Writes the bonus at `state` of tokens `start..start + out.len()` (all
    /// below [`Self::tokens`]) to `out`, as [`Self::step`] gives them. Needs
    /// no allocation or shared cache, so every decoder thread fills its own
    /// rows.
    pub fn bonuses(&self, state: BiasState, start: usize, out: &mut [f32]) {
        assert!(start + out.len() <= self.tokens, "bias token range");
        out.fill(0.0);
        self.fill_chain(state, start, out);
    }

    /// Children of `f` and of everything on its failure chain, the root
    /// first and `f` last, so the state [`Self::next`] picks for a token wins.
    fn fill_chain(&self, f: BiasState, start: usize, out: &mut [f32]) {
        if f != Self::ROOT {
            self.fill_chain(self.fail[f as usize], start, out);
        }
        let kids = &self.children[self.child_range(f)];
        let from = kids.partition_point(|&(t, _)| (t as usize) < start);
        for &(t, m) in &kids[from..] {
            let Some(slot) = out.get_mut(t as usize - start) else {
                break;
            };
            *slot = self.bonus[m as usize];
        }
    }

    fn child_range(&self, s: BiasState) -> std::ops::Range<usize> {
        self.child_start[s as usize] as usize..self.child_start[s as usize + 1] as usize
    }

    fn child(&self, s: BiasState, t: u32) -> Option<BiasState> {
        let kids = &self.children[self.child_range(s)];
        kids.binary_search_by_key(&t, |&(k, _)| k)
            .ok()
            .map(|i| kids[i].1)
    }

    /// `goto(s, t)`: the state token `t` leads to from `s`, following failure
    /// links (the root when nothing matches).
    fn next(&self, s: BiasState, t: u32) -> BiasState {
        let mut f = s;
        loop {
            if let Some(m) = self.child(f, t) {
                return m;
            }
            if f == Self::ROOT {
                return Self::ROOT;
            }
            f = self.fail[f as usize];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOKENS: usize = 12;

    fn graph(phrases: &[(&[usize], f32)]) -> BiasGraph {
        let phrases: Vec<(Vec<usize>, f32)> =
            phrases.iter().map(|(p, s)| (p.to_vec(), *s)).collect();
        BiasGraph::new(&phrases, TOKENS).unwrap()
    }

    /// Bonuses along `tokens` from the root (`None` is blank), and the final state.
    fn walk(g: &BiasGraph, tokens: &[Option<usize>]) -> (Vec<f32>, BiasState) {
        let mut s = BiasGraph::ROOT;
        let mut bonuses = Vec::new();
        for t in tokens {
            match t {
                Some(t) => {
                    let (n, b) = g.step(s, *t);
                    s = n;
                    bonuses.push(b);
                }
                None => bonuses.push(0.0),
            }
        }
        (bonuses, s)
    }

    /// Independent definition: the bonus of `t` after `history` is the best
    /// `own(u)` over every suffix `u` of `history + t` that is a phrase
    /// prefix (the Aho-Corasick state is the longest such suffix).
    fn oracle(phrases: &[(Vec<usize>, f32)], history: &[usize], t: usize) -> f32 {
        let mut seq = history.to_vec();
        seq.push(t);
        let mut best = 0.0f64;
        for start in 0..seq.len() {
            let u = &seq[start..];
            let sigma = phrases
                .iter()
                .filter(|(p, _)| p.len() >= u.len() && &p[..u.len()] == u)
                .map(|(_, s)| f64::from(*s))
                .fold(None, |m: Option<f64>, s| Some(m.map_or(s, |m| m.max(s))));
            if let Some(sigma) = sigma {
                let own = sigma * (CONTEXT_SCORE + DEPTH_SCALING * (u.len() as f64).ln());
                best = best.max(own);
            }
        }
        (ALPHA * best) as f32
    }

    #[test]
    fn matches_the_suffix_definition_on_random_phrases() {
        let mut rng = lf_model::rng::SplitMix64::new(7);
        for round in 0..20 {
            let phrases: Vec<(Vec<usize>, f32)> = (0..1 + round % 9)
                .map(|_| {
                    let len = 1 + rng.below(4) as usize;
                    let p = (0..len).map(|_| rng.below(5) as usize).collect();
                    let s = [0.25f32, 0.5, 1.0, 1.41, 2.0, 4.0][rng.below(6) as usize];
                    (p, s)
                })
                .collect();
            let g = BiasGraph::new(&phrases, TOKENS).unwrap();
            let mut reversed = phrases.clone();
            reversed.reverse();
            let r = BiasGraph::new(&reversed, TOKENS).unwrap();
            let mut history = Vec::new();
            let (mut s, mut sr) = (BiasGraph::ROOT, BiasGraph::ROOT);
            for _ in 0..200 {
                let t = rng.below(6) as usize;
                let mut row = vec![f32::NAN; TOKENS];
                g.bonuses(s, 0, &mut row);
                for (u, &b) in row.iter().enumerate() {
                    assert_eq!(b.to_bits(), g.step(s, u).1.to_bits());
                    assert_eq!(b.to_bits(), oracle(&phrases, &history, u).to_bits());
                }
                // Phrase order changes nothing.
                assert_eq!(r.step(sr, t).1.to_bits(), g.step(s, t).1.to_bits());
                s = g.step(s, t).0;
                sr = r.step(sr, t).0;
                history.push(t);
            }
        }
    }

    #[test]
    fn hand_computed_bonuses() {
        let a = ALPHA;
        let ln = |d: f64| d.ln();
        let g1 = graph(&[(&[1, 2, 3], 1.0)]);
        let (b, _) = walk(&g1, &[Some(1), Some(2), Some(3)]);
        assert_eq!(
            b,
            [
                a as f32,
                (a * (1.0 + 3.0 * ln(2.0))) as f32,
                (a * (1.0 + 3.0 * ln(3.0))) as f32
            ]
        );
        assert_eq!(walk(&g1, &[Some(9)]).0, [0.0]);
        // A strong suffix phrase beats a weak deeper match.
        let g2 = graph(&[(&[1, 2, 3], 0.25), (&[2, 3], 4.0)]);
        let (b, _) = walk(&g2, &[Some(1), Some(2), Some(3)]);
        let s2 = 1.0 + 3.0 * ln(2.0);
        let s3 = 1.0 + 3.0 * ln(3.0);
        assert_eq!(
            b,
            [
                (a * 0.25) as f32,
                (a * 4.0) as f32,
                (a * (4.0 * s2).max(0.25 * s3)) as f32
            ]
        );
        // Duplicate sequences keep the largest strength.
        let g3 = graph(&[(&[5, 6], 1.0), (&[5, 6], 2.0)]);
        assert_eq!(
            walk(&g3, &[Some(5), Some(6)]).0,
            [(a * 2.0) as f32, (a * 2.0 * s2) as f32]
        );
        // Blank keeps the state; another token resets it.
        let g4 = graph(&[(&[1, 2], 1.0)]);
        assert_eq!(walk(&g4, &[Some(1), None, Some(2)]).0[2], (a * s2) as f32);
        assert_eq!(walk(&g4, &[Some(1), Some(7), Some(2)]).0[2], 0.0);
    }

    #[test]
    fn empty_graph_gives_nothing() {
        let g = BiasGraph::new(&[], TOKENS).unwrap();
        assert!(g.is_empty());
        let (b, s) = walk(&g, &[Some(3), Some(1), None, Some(2)]);
        assert!(b.iter().all(|v| v.to_bits() == 0));
        assert_eq!(s, BiasGraph::ROOT);
        let mut row = vec![1.0f32; TOKENS];
        g.bonuses(BiasGraph::ROOT, 0, &mut row);
        assert!(row.iter().all(|v| v.to_bits() == 0));
        assert!(!graph(&[(&[1], 1.0)]).is_empty());
    }

    #[test]
    fn bonuses_fill_any_token_range() {
        let g = graph(&[(&[1, 2], 1.0), (&[2, 7, 11], 2.0), (&[7], 0.5)]);
        for history in [&[][..], &[1], &[1, 2], &[2, 7], &[9]] {
            let s = history.iter().fold(BiasGraph::ROOT, |s, &t| g.step(s, t).0);
            for (start, len) in [(0, TOKENS), (3, TOKENS - 3), (2, 3), (TOKENS, 0), (11, 1)] {
                let mut out = vec![f32::NAN; len];
                g.bonuses(s, start, &mut out);
                for (i, v) in out.iter().enumerate() {
                    assert_eq!(v.to_bits(), g.step(s, start + i).1.to_bits());
                }
            }
        }
    }

    #[test]
    fn rejects_invalid_phrases() {
        assert!(BiasGraph::new(&[(vec![], 1.0)], TOKENS).is_err());
        assert!(BiasGraph::new(&[(vec![1, TOKENS], 1.0)], TOKENS).is_err());
        for s in [0.0, -1.0, f32::NAN, f32::INFINITY] {
            assert!(BiasGraph::new(&[(vec![1], s)], TOKENS).is_err(), "{s}");
        }
    }
}

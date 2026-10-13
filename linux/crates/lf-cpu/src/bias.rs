//! Phrase boosting (contextual biasing) for greedy TDT decoding.
//!
//! A [`BiasGraph`] is an Aho-Corasick automaton over token ids, as in icefall's
//! `ContextGraph`: a trie of the phrases plus failure links, so a match can
//! start right after a mismatch or overlap another phrase. Every decision adds
//! the current state's bonus (in nats, times `alpha`) to each token logit
//! before the argmax; a non-blank emission then moves the state. Blank never
//! receives a bonus and never moves the state.
//!
//! A token that extends a match to depth `d` scores `s(d) = context_score +
//! depth_scaling * ln(d)` (NeMo GPU-PB); `A(n)` is the sum of `s` along state
//! `n`'s path. Token `t` at state `n` leads to `m`, the child on `t` of the
//! first state on `n`'s failure chain that has one (the root if none does).
//! Without cancel, the token scores `s(depth of m)` (0 when `m` is the root).
//!
//! With cancel, the score is banked per completed occurrence, as in icefall:
//! `O(m)`, the summed `A` of every phrase that ends at `m` (`m` itself and its
//! output links), is banked on entering `m`. `P(m)`, the pending score of the
//! current match, grows by `s(d)` per trie edge and drops by what that edge
//! banks, but never below 0: `P(m) = max(0, P(parent) + s(d) - O(m))`. The
//! token scores `O(m) + P(m) - P(n)`, so after any token sequence the bonuses
//! sum to the banked score of every completed occurrence plus the current
//! `P`. An abandoned partial match takes back exactly what was not banked, a
//! completed phrase keeps its full score for every occurrence, and while no
//! occurrences overlap each token scores just `s(d)`. (icefall instead adds
//! `O(m)` on top of `s(d)` and takes back all of `A` on leaving, which nets the
//! same but penalizes every token after a completed phrase.)

use std::sync::OnceLock;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BiasConfig {
    /// Overall weight; every bonus is multiplied by it. 0 disables boosting.
    pub alpha: f32,
    /// Score of a token at depth 1.
    pub context_score: f32,
    /// Depth d >= 2 scores context_score + depth_scaling * ln(d).
    pub depth_scaling: f32,
    /// icefall-style cancel: leaving an unfinished match subtracts the score
    /// accumulated since the last completed phrase (applied to non-blank tokens).
    pub cancel_unfinished: bool,
}

/// Tokens with their own bonus at a state, sorted by token.
type Arcs = Box<[(u32, f32)]>;

/// A state of a [`BiasGraph`]; [`BiasGraph::ROOT`] before any match.
pub type BiasState = u32;

pub struct BiasGraph {
    config: BiasConfig,
    tokens: usize,
    /// Trie children of state `s`: `children[child_start[s]..child_start[s + 1]]`,
    /// sorted by token.
    child_start: Vec<u32>,
    children: Vec<(u32, BiasState)>,
    fail: Vec<BiasState>,
    /// Trie parent and the token on the edge into each state (the root's
    /// entries are unused).
    parent: Vec<BiasState>,
    edge: Vec<u32>,
    /// Some phrase ends exactly at the state.
    end: Vec<bool>,
    depth: Vec<u32>,
    /// Unscaled `A` by depth (`path[0] == 0`).
    path: Vec<f64>,
    /// Unscaled `O` and `P` by state.
    output: Vec<f64>,
    pending: Vec<f64>,
    default: Vec<f32>,
    /// Built on first call, for inspection; decoding uses [`Self::bonuses`].
    arcs: Vec<OnceLock<Arcs>>,
}

impl BiasGraph {
    pub const ROOT: BiasState = 0;

    /// `phrases`: token-id sequences (blank excluded), each non-empty and every
    /// id < `tokens` (the vocabulary size without blank). Duplicates are fine.
    pub fn new(phrases: &[Vec<usize>], tokens: usize, config: BiasConfig) -> Result<Self, String> {
        let BiasConfig {
            alpha,
            context_score,
            depth_scaling,
            ..
        } = config;
        if !(alpha.is_finite() && context_score.is_finite() && depth_scaling.is_finite()) {
            return Err(format!("non-finite bias config: {config:?}"));
        }
        if alpha < 0.0 {
            return Err(format!("negative bias alpha {alpha}"));
        }
        for (i, p) in phrases.iter().enumerate() {
            if p.is_empty() {
                return Err(format!("bias phrase {i} is empty"));
            }
            if let Some(&t) = p.iter().find(|&&t| t >= tokens) {
                return Err(format!(
                    "bias phrase {i}: token {t} out of range ({tokens} tokens)"
                ));
            }
        }
        let max_depth = phrases.iter().map(Vec::len).max().unwrap_or(0);
        let mut path = vec![0.0f64];
        for d in 1..=max_depth {
            let score = context_score as f64 + depth_scaling as f64 * (d as f64).ln();
            if score < 0.0 {
                return Err(format!("bias score at depth {d} is negative ({score})"));
            }
            path.push(path[d - 1] + score);
        }
        // With alpha 0 every bonus is 0: keep only the root.
        let phrases = if alpha == 0.0 { &[][..] } else { phrases };

        // Trie, then failure links and scores in breadth-first order (a
        // state's parent and failure target are both shallower).
        let mut kids: Vec<Vec<(u32, BiasState)>> = vec![Vec::new()];
        let mut end = vec![false];
        for p in phrases {
            let mut s = 0usize;
            for &t in p {
                let t = t as u32;
                s = match kids[s].iter().find(|&&(k, _)| k == t) {
                    Some(&(_, c)) => c as usize,
                    None => {
                        let c = kids.len();
                        let c32 = u32::try_from(c).map_err(|_| "too many bias states")?;
                        kids[s].push((t, c32));
                        kids.push(Vec::new());
                        end.push(false);
                        c
                    }
                };
            }
            end[s] = true;
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
            config,
            tokens,
            child_start,
            children,
            fail: vec![Self::ROOT; states],
            parent: vec![Self::ROOT; states],
            edge: vec![0; states],
            end,
            depth: vec![0; states],
            path,
            output: vec![0.0; states],
            pending: vec![0.0; states],
            default: Vec::new(),
            arcs: (0..states).map(|_| OnceLock::new()).collect(),
        };
        let mut queue = std::collections::VecDeque::from([Self::ROOT]);
        while let Some(s) = queue.pop_front() {
            for i in graph.child_range(s) {
                let (t, c) = graph.children[i];
                let cu = c as usize;
                let d = graph.depth[s as usize] as usize + 1;
                graph.depth[cu] = d as u32;
                graph.parent[cu] = s;
                graph.edge[cu] = t;
                let f = if s == Self::ROOT {
                    Self::ROOT
                } else {
                    graph.next(graph.fail[s as usize], t)
                };
                graph.fail[cu] = f;
                let own = if graph.end[cu] { graph.path[d] } else { 0.0 };
                graph.output[cu] = own + graph.output[f as usize];
                let step = graph.path[d] - graph.path[d - 1];
                graph.pending[cu] = (graph.pending[s as usize] + step - graph.output[cu]).max(0.0);
                queue.push_back(c);
            }
        }
        graph.default = (0..states as u32)
            .map(|s| graph.bonus(s, Self::ROOT))
            .collect();
        Ok(graph)
    }

    /// True when no token ever receives a bonus (no phrases, or alpha 0).
    pub fn is_empty(&self) -> bool {
        self.children.is_empty()
    }

    pub fn config(&self) -> BiasConfig {
        self.config
    }

    /// Vocabulary size without blank; every phrase token is below it.
    pub fn tokens(&self) -> usize {
        self.tokens
    }

    /// State after emitting non-blank `token` at `state`, and the bonus (already
    /// multiplied by alpha) that token receives at `state`.
    pub fn step(&self, state: BiasState, token: usize) -> (BiasState, f32) {
        let Ok(t) = u32::try_from(token) else {
            return (Self::ROOT, self.default_bonus(state));
        };
        let m = self.next(state, t);
        (m, self.arc_bonus(state, m))
    }

    /// Tokens whose bonus at `state` differs from `default_bonus(state)`, with
    /// that bonus. Sorted by token id.
    pub fn arcs(&self, state: BiasState) -> &[(u32, f32)] {
        self.arcs[state as usize].get_or_init(|| {
            // Only tokens with a trie child somewhere on the failure chain can
            // leave the default (which is the bonus of returning to the root).
            let mut tokens = Vec::new();
            let mut s = state;
            loop {
                tokens.extend(self.child_range(s).map(|i| self.children[i].0));
                if s == Self::ROOT {
                    break;
                }
                s = self.fail[s as usize];
            }
            tokens.sort_unstable();
            tokens.dedup();
            let default = self.default_bonus(state);
            tokens
                .into_iter()
                .filter_map(|t| {
                    let b = self.step(state, t as usize).1;
                    (b != default).then_some((t, b))
                })
                .collect()
        })
    }

    /// Bonus of every other non-blank token at `state` (0 without cancel; <= 0 with it).
    pub fn default_bonus(&self, state: BiasState) -> f32 {
        self.default[state as usize]
    }

    /// Every token `t` with `step(state, t).0 != ROOT`, with that destination
    /// state (the deepest match, as [`Self::step`] takes it), sorted by token.
    /// Computed afresh on each call, with no shared cache; callers may cache
    /// it per state.
    pub fn candidates(&self, state: BiasState) -> Vec<(u32, BiasState)> {
        // Children along the failure chain, deepest state first; a stable
        // sort then keeps the deepest destination of each token first.
        let mut out = Vec::new();
        let mut s = state;
        loop {
            out.extend_from_slice(&self.children[self.child_range(s)]);
            if s == Self::ROOT {
                break;
            }
            s = self.fail[s as usize];
        }
        out.sort_by_key(|&(t, _)| t);
        out.dedup_by_key(|&mut (t, _)| t);
        out
    }

    /// Number of states (trie nodes, the root included); states are `0..states()`.
    pub fn states(&self) -> usize {
        self.depth.len()
    }

    /// Trie parent of `state` (`None` for the root). Failure links are not edges.
    pub fn parent(&self, state: BiasState) -> Option<BiasState> {
        (state != Self::ROOT).then(|| self.parent[state as usize])
    }

    /// The token on the trie edge into `state` (`None` for the root).
    pub fn edge_token(&self, state: BiasState) -> Option<u32> {
        (state != Self::ROOT).then(|| self.edge[state as usize])
    }

    /// Trie depth: tokens from the root to `state`.
    pub fn depth(&self, state: BiasState) -> u32 {
        self.depth[state as usize]
    }

    /// Whether some phrase ends exactly at `state`.
    pub fn is_end(&self, state: BiasState) -> bool {
        self.end[state as usize]
    }

    /// Trie children of `state` as `(token, child)`, sorted by token.
    pub fn children(&self, state: BiasState) -> &[(u32, BiasState)] {
        &self.children[self.child_range(state)]
    }

    /// Writes the bonus at `state` of tokens `start..start + out.len()` (all
    /// below [`Self::tokens`]) to `out`, as [`Self::step`] gives them. Costs
    /// the fill plus the trie children in range of the states on `state`'s
    /// failure chain; needs no allocation or shared cache, so every decoder
    /// thread fills its own rows.
    pub fn bonuses(&self, state: BiasState, start: usize, out: &mut [f32]) {
        assert!(start + out.len() <= self.tokens, "bias token range");
        out.fill(self.default_bonus(state));
        self.fill_chain(state, state, start, out);
    }

    /// Children of `f` and of everything on its failure chain, deepest last so
    /// the state [`Self::next`] picks for a token wins.
    fn fill_chain(&self, state: BiasState, f: BiasState, start: usize, out: &mut [f32]) {
        if f != Self::ROOT {
            self.fill_chain(state, self.fail[f as usize], start, out);
        }
        let kids = &self.children[self.child_range(f)];
        let from = kids.partition_point(|&(t, _)| (t as usize) < start);
        for &(t, m) in &kids[from..] {
            let Some(slot) = out.get_mut(t as usize - start) else {
                break;
            };
            *slot = self.arc_bonus(state, m);
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

    /// The state token `t` leads to from `s` (the root when nothing matches).
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

    /// [`Self::bonus`], with the default's exact bits when equal to it.
    fn arc_bonus(&self, s: BiasState, m: BiasState) -> f32 {
        let (b, default) = (self.bonus(s, m), self.default_bonus(s));
        if b == default { default } else { b }
    }

    /// Scaled bonus of moving from `s` to `m` (see the module docs).
    fn bonus(&self, s: BiasState, m: BiasState) -> f32 {
        let v = if self.config.cancel_unfinished {
            self.output[m as usize] + self.pending[m as usize] - self.pending[s as usize]
        } else if m == Self::ROOT {
            0.0
        } else {
            let d = self.depth[m as usize] as usize;
            self.path[d] - self.path[d - 1]
        };
        (self.config.alpha as f64 * v) as f32
    }
}

/// A learned-bias hook for [`crate::decoder::PackedDecoder::decode_scored`].
pub trait BiasScorer: Sync {
    /// Called once per decision when the graph state has candidates.
    /// `z` is the joint hidden relu(f_t + g_u) (length = joint dim);
    /// `logits` is the full row of 1025 token logits plus the durations,
    /// exactly as computed. Writes (token, bonus) for each candidate into
    /// `out` (cleared by the caller). Candidates are given by `cands`
    /// (token, destination state), sorted by token. A candidate left out gets
    /// no bonus; a token that is not a candidate is an error (the decoder
    /// panics).
    fn score(
        &self,
        state: BiasState,
        z: &[f32],
        logits: &[f32],
        cands: &[(u32, BiasState)],
        out: &mut Vec<(u32, f32)>,
    );
}

/// Scores every candidate with the graph's own bonus, `graph.step(s, y).1`:
/// with `cancel_unfinished` off, decoding with it equals decoding with the
/// graph itself.
pub struct GraphBonusScorer<'a>(pub &'a BiasGraph);

impl BiasScorer for GraphBonusScorer<'_> {
    fn score(
        &self,
        state: BiasState,
        _z: &[f32],
        _logits: &[f32],
        cands: &[(u32, BiasState)],
        out: &mut Vec<(u32, f32)>,
    ) {
        out.extend(
            cands
                .iter()
                .map(|&(t, _)| (t, self.0.step(state, t as usize).1)),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOKENS: usize = 12;

    fn config(alpha: f32, depth_scaling: f32, cancel: bool) -> BiasConfig {
        BiasConfig {
            alpha,
            context_score: 1.0,
            depth_scaling,
            cancel_unfinished: cancel,
        }
    }

    fn graph(phrases: &[&[usize]], c: BiasConfig) -> BiasGraph {
        let phrases: Vec<Vec<usize>> = phrases.iter().map(|p| p.to_vec()).collect();
        BiasGraph::new(&phrases, TOKENS, c).unwrap()
    }

    /// Bonuses along `tokens` from the root, and the final state.
    fn walk(g: &BiasGraph, tokens: &[usize]) -> (Vec<f32>, BiasState) {
        let mut s = BiasGraph::ROOT;
        let bonuses = tokens
            .iter()
            .map(|&t| {
                let (n, b) = g.step(s, t);
                s = n;
                b
            })
            .collect();
        (bonuses, s)
    }

    fn total(g: &BiasGraph, tokens: &[usize]) -> f64 {
        walk(g, tokens).0.iter().map(|&b| b as f64).sum()
    }

    fn score(d: usize) -> f64 {
        1.0 + (d as f64).ln()
    }

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-5
    }

    // h=1, e=2, s=3, i=4, r=5; 9 matches nothing.
    const HE: &[usize] = &[1, 2];
    const SHE: &[usize] = &[3, 1, 2];
    const HIS: &[usize] = &[1, 4, 3];
    const HERS: &[usize] = &[1, 2, 5, 3];

    #[test]
    fn follows_failure_links() {
        // Without cancel each token scores the depth of the match it extends,
        // which (with depth scaling) reveals the state.
        let g = graph(&[HE, SHE, HIS, HERS], config(2.0, 1.0, false));
        let (b, _) = walk(&g, &[3, 1, 2, 5, 3, 9, 1, 4, 3, 1]);
        let expected =
            [1, 2, 3, 3, 4, 0, 1, 2, 3, 2].map(|d| if d == 0 { 0.0 } else { 2.0 * score(d) });
        for (got, want) in b.iter().zip(expected) {
            assert!(close(*got as f64, want), "{b:?} vs {expected:?}");
        }
        // "s h" fails over to "h" when "i" follows: "h i" (depth 2) then "his".
        let (b, _) = walk(&g, &[3, 1, 4, 3]);
        assert!(close(b[2] as f64, 2.0 * score(2)) && close(b[3] as f64, 2.0 * score(3)));
        // The same state is reached whichever way the path "he" arises.
        assert_eq!(walk(&g, &[3, 9, 1, 2]).1, walk(&g, &[1, 2]).1);
        assert_eq!(walk(&g, &[3, 1, 2]).1, walk(&g, &[9, 3, 1, 2]).1);
        assert_ne!(walk(&g, &[3, 1, 2]).1, walk(&g, &[1, 2]).1);
        for s in [walk(&g, &[3, 1]).1, walk(&g, &[1, 2, 5]).1] {
            assert_eq!(g.default_bonus(s), 0.0);
        }
    }

    #[test]
    fn cancel_telescopes() {
        let new_york: &[usize] = &[6, 7];
        let new_york_city: &[usize] = &[6, 7, 8];
        let g = graph(
            &[new_york, new_york_city, HERS, HIS, &[4], SHE],
            config(1.5, 0.7, true),
        );
        let a = |d: usize| 1.5 * (1..=d).map(|k| 1.0 + 0.7 * (k as f64).ln()).sum::<f64>();
        // An abandoned partial match nets 0, also when it fails over.
        assert!(close(total(&g, &[1, 2, 5, 9]), 0.0));
        assert!(close(total(&g, &[1, 2, 5, 9, 9, 1]), a(1)));
        // A completed phrase nets its full score and keeps it; without
        // overlapping occurrences each token scores just its depth's score.
        let (b, _) = walk(&g, &[1, 2, 5, 3]);
        for (d, &v) in b.iter().enumerate() {
            assert!(close(v as f64, a(d + 1) - a(d)));
        }
        assert!(close(total(&g, &[1, 2, 5, 3]), a(4)));
        assert!(close(total(&g, &[1, 2, 5, 3, 9]), a(4)));
        // Both occurrences count when a completed phrase is extended to
        // another; abandoning the extension keeps the shorter one.
        assert!(close(total(&g, &[6, 7, 8]), a(2) + a(3)));
        assert!(close(total(&g, &[6, 7, 8, 9]), a(2) + a(3)));
        assert!(close(total(&g, &[6, 7, 9]), a(2)));
        assert!(close(total(&g, &[6, 7, 6, 9]), a(2)));
        // A phrase completed inside another partial match ("i" in "h i s") is banked.
        assert!(close(total(&g, &[1, 4, 9]), a(1)));
        // Overlapping phrases each keep their full score: "s h e", then "r s"
        // fails over into "h e r s".
        assert!(close(total(&g, &[3, 1, 2, 5, 3]), a(3) + a(4)));
        // The pending score is exactly what a mismatch takes back.
        for prefix in [&[1, 2, 5][..], &[3, 1], &[6, 7, 8], &[6]] {
            let (_, s) = walk(&g, prefix);
            let d = g.default_bonus(s);
            assert!(d <= 0.0);
            let mut abandoned = prefix.to_vec();
            abandoned.push(9);
            assert!(close(total(&g, prefix) + d as f64, total(&g, &abandoned)));
        }
        assert_eq!(g.default_bonus(BiasGraph::ROOT), 0.0);
        assert_eq!(g.default_bonus(walk(&g, &[6, 7]).1), 0.0);
    }

    #[test]
    fn every_completed_occurrence_is_banked() {
        // Unit scores. Regression: two "1"s inside a partial "2 1 1 3" used to
        // bank one "1" (the best single phrase), not both.
        let unit = config(1.0, 0.0, true);
        let g = graph(&[&[1], &[2, 1, 1, 3]], unit);
        assert_eq!(walk(&g, &[2, 1, 1, 9]).0, [1.0, 1.0, 1.0, -1.0]);
        // Completing the long phrase banks its 4 on top of the two "1"s.
        assert_eq!(walk(&g, &[2, 1, 1, 3, 9]).0, [1.0, 1.0, 1.0, 3.0, 0.0]);
        // Nested occurrences: after "1 1 1", "1" occurred three times, "1 1"
        // twice and "1 1 1" once (3 + 4 + 3); a fourth "1" adds 1 + 2 + 3.
        let g = graph(&[&[1], &[1, 1], &[1, 1, 1]], unit);
        assert_eq!(walk(&g, &[1, 1, 1, 9]).0, [1.0, 3.0, 6.0, 0.0]);
        assert_eq!(total(&g, &[1, 1, 1, 1]), 16.0);
        // Without cancel nothing is banked: each token scores its depth.
        let g = graph(&[&[1], &[2, 1, 1, 3]], config(1.0, 0.0, false));
        assert_eq!(walk(&g, &[2, 1, 1, 9]).0, [1.0, 1.0, 1.0, 0.0]);
    }

    #[test]
    fn step_agrees_with_arcs() {
        let mut rng = lf_model::rng::SplitMix64::new(7);
        let phrases: Vec<Vec<usize>> = (0..10)
            .map(|_| {
                let len = 1 + rng.below(4) as usize;
                (0..len).map(|_| rng.below(6) as usize).collect()
            })
            .collect();
        for cancel in [false, true] {
            let g = BiasGraph::new(&phrases, TOKENS, config(1.3, 0.5, cancel)).unwrap();
            let mut states = vec![BiasGraph::ROOT];
            let mut s = BiasGraph::ROOT;
            for _ in 0..400 {
                s = g.step(s, rng.below(7) as usize).0;
                states.push(s);
            }
            states.sort_unstable();
            states.dedup();
            assert!(states.len() > 8);
            for &s in &states {
                let arcs = g.arcs(s);
                assert!(arcs.windows(2).all(|w| w[0].0 < w[1].0));
                let d = g.default_bonus(s);
                if !cancel {
                    assert_eq!(d, 0.0);
                }
                for t in 0..TOKENS {
                    let b = g.step(s, t).1;
                    match arcs.binary_search_by_key(&(t as u32), |a| a.0) {
                        Ok(i) => assert!(arcs[i].1 == b && b != d),
                        Err(_) => assert_eq!(b.to_bits(), d.to_bits()),
                    }
                }
                // `bonuses` gives the same bits for any token range.
                for (start, len) in [(0, TOKENS), (3, TOKENS - 3), (2, 3), (TOKENS, 0)] {
                    let mut out = vec![f32::NAN; len];
                    g.bonuses(s, start, &mut out);
                    for (i, v) in out.iter().enumerate() {
                        assert_eq!(v.to_bits(), g.step(s, start + i).1.to_bits());
                    }
                }
            }
        }
    }

    #[test]
    fn candidates_are_the_non_root_steps() {
        let mut rng = lf_model::rng::SplitMix64::new(11);
        let phrases: Vec<Vec<usize>> = (0..14)
            .map(|_| {
                let len = 1 + rng.below(5) as usize;
                (0..len).map(|_| rng.below(8) as usize).collect()
            })
            .collect();
        for cancel in [false, true] {
            let g = BiasGraph::new(&phrases, TOKENS, config(1.0, 0.5, cancel)).unwrap();
            let mut checked = 0;
            for s in 0..g.states() as BiasState {
                let expected: Vec<(u32, BiasState)> = (0..TOKENS)
                    .filter_map(|t| {
                        let m = g.step(s, t).0;
                        (m != BiasGraph::ROOT).then_some((t as u32, m))
                    })
                    .collect();
                assert_eq!(g.candidates(s), expected, "state {s}");
                checked += usize::from(s != BiasGraph::ROOT && !expected.is_empty());
            }
            assert!(checked > 10);
            // A deeper failure-chain match overrides the root's child.
            let g = graph(&[HE, SHE], config(1.0, 0.0, cancel));
            let (_, sh) = walk(&g, &[3, 1]);
            let (_, h) = walk(&g, &[1]);
            let c = g.candidates(sh);
            assert_eq!(
                c,
                vec![(1, h), (2, walk(&g, &[3, 1, 2]).1), (3, walk(&g, &[3]).1)]
            );
            assert_ne!(c[1].1, walk(&g, &[1, 2]).1);
        }
        let none = BiasGraph::new(&[], TOKENS, config(1.0, 0.0, false)).unwrap();
        assert!(none.candidates(BiasGraph::ROOT).is_empty());
    }

    #[test]
    fn exposes_the_trie() {
        // "h e", "h i s", "s h e": the trie (not failure links) as written.
        let g = graph(&[HE, HIS, SHE], config(1.0, 0.0, false));
        assert_eq!(g.states(), 1 + 2 + 2 + 3);
        assert_eq!(g.parent(BiasGraph::ROOT), None);
        assert_eq!(g.edge_token(BiasGraph::ROOT), None);
        assert_eq!(g.depth(BiasGraph::ROOT), 0);
        let roots: Vec<u32> = g.children(BiasGraph::ROOT).iter().map(|c| c.0).collect();
        assert_eq!(roots, [1, 3]);
        let (_, he) = walk(&g, &[1, 2]);
        let (_, h) = walk(&g, &[1]);
        assert_eq!(
            (g.parent(he), g.edge_token(he), g.depth(he)),
            (Some(h), Some(2), 2)
        );
        assert!(g.is_end(he) && !g.is_end(h));
        let (_, she) = walk(&g, &[3, 1, 2]);
        assert!(g.is_end(she) && g.children(she).is_empty());
        let kids: Vec<u32> = g.children(h).iter().map(|c| c.0).collect();
        assert_eq!(kids, [2, 4]);
        // Every non-root state is its parent's child on its edge token.
        for s in 1..g.states() as BiasState {
            let p = g.parent(s).unwrap();
            assert!(g.children(p).contains(&(g.edge_token(s).unwrap(), s)));
            assert_eq!(g.depth(s), g.depth(p) + 1);
        }
    }

    #[test]
    fn disabled_bias_is_exactly_zero() {
        let none = BiasGraph::new(&[], TOKENS, config(4.0, 1.0, true)).unwrap();
        let off = graph(&[HE, SHE], config(0.0, 1.0, true));
        for g in [&none, &off] {
            assert!(g.is_empty());
            let (b, s) = walk(g, &[3, 1, 2, 9]);
            assert!(b.iter().all(|v| v.to_bits() == 0));
            assert_eq!(s, BiasGraph::ROOT);
            assert!(g.arcs(s).is_empty());
            assert_eq!(g.default_bonus(s).to_bits(), 0);
        }
        assert!(!graph(&[HE], config(1.0, 0.0, false)).is_empty());
        // Duplicates are fine.
        let dup = graph(&[HE, HE], config(1.0, 0.0, true));
        assert!(close(total(&dup, &[1, 2, 9]), 2.0));
    }

    #[test]
    fn rejects_invalid_phrases_and_configs() {
        let c = config(1.0, 1.0, true);
        assert!(BiasGraph::new(&[vec![]], TOKENS, c).is_err());
        assert!(BiasGraph::new(&[vec![1, TOKENS]], TOKENS, c).is_err());
        assert!(BiasGraph::new(&[vec![1]], TOKENS, config(-1.0, 1.0, true)).is_err());
        assert!(BiasGraph::new(&[vec![1]], TOKENS, config(f32::NAN, 1.0, true)).is_err());
        // Depth scaling may not make a deeper token score negative.
        assert!(BiasGraph::new(&[vec![1, 2, 3]], TOKENS, config(1.0, -2.0, true)).is_err());
        assert!(BiasGraph::new(&[vec![1, 2, 3]], TOKENS, config(1.0, -0.5, true)).is_ok());
    }
}

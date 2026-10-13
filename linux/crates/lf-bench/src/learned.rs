//! Learned biasing (experiment 2): the trie features of CONTRACT-2 §2 and the
//! L1/L2/L3 model forward of §3, as a [`BiasScorer`] for
//! `PackedDecoder::decode_scored`.
//!
//! Work is split as the contract asks:
//! - Once per dictionary ([`LearnedModel::prepare`]): the trie features, the
//!   node pass (embeddings, the self-MLP stack, for L3 the bottom-up subtree
//!   aggregation, then the keys) and each node's share of the scorer's first
//!   layer (`nf` and `g_size` columns plus the bias).
//! - Per decision ([`LearnedScorer`]): the query `q` (L2/L3), the logit
//!   statistics, then per candidate the 8 per-head dot products, the rest of
//!   the first layer, and the small MLP (batched over candidates).
//!
//! All arithmetic is f32 except the logit statistics (f64, then rounded).
//! GELU is the exact erf form, with a rational erf accurate to ~1e-7.

#![allow(dead_code)]

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use lf_cpu::ThreadPool;
use lf_cpu::bias::{BiasGraph, BiasScorer, BiasState};
use lf_cpu::dense::{self, Panels};
use lf_model::SafeTensors;

/// Model width, heads, head width, joint width, tokens with blank, blank id.
pub const D: usize = 512;
pub const HEADS: usize = 8;
pub const DH: usize = 64;
pub const J: usize = 640;
pub const V: usize = 1025;
pub const BLANK: usize = 1024;
/// Hidden width of the self and subtree MLPs, and of the small scorer MLPs.
pub const FF: usize = 1024;
pub const HID: usize = 64;
/// Node features, candidate features (`[nf, lf, g_size]`).
pub const NF: usize = 5;
pub const NX: usize = 10;
pub const DEPTH_EMB: usize = 16;
pub const DMAX_CAP: u32 = 32;
pub const FORMAT: &str = "lf-learned-bias-v1";
const LN_EPS: f32 = 1e-5;

// ---------------------------------------------------------------- features (§2)

/// Per-node trie features (CONTRACT-2 §2). Nodes are graph states, root 0;
/// every parent precedes its children.
#[derive(Clone, Debug, PartialEq)]
pub struct TrieFeatures {
    /// Token on the edge into the node; the root has [`BLANK`].
    pub token: Vec<u32>,
    pub depth: Vec<u32>,
    pub is_end: Vec<bool>,
    pub dmin: Vec<u32>,
    /// Capped at [`DMAX_CAP`].
    pub dmax: Vec<u32>,
    pub nends: Vec<u32>,
    /// −1 for the root.
    pub parent: Vec<i32>,
    /// `children[child_start[n]..child_start[n + 1]]`, ascending node ids.
    pub child_start: Vec<u32>,
    pub children: Vec<u32>,
    /// `[depth/8, is_end, dmin/8, dmax/8, ln(1+nends)/4]`.
    pub nf: Vec<[f32; NF]>,
}

impl TrieFeatures {
    /// The trie of a graph (tree edges only, not failure links).
    pub fn new(g: &BiasGraph) -> Self {
        let n = g.states();
        let mut token = vec![BLANK as u32; n];
        let mut parent = vec![-1i32; n];
        let mut is_end = vec![false; n];
        for s in 0..n as BiasState {
            if let (Some(p), Some(t)) = (g.parent(s), g.edge_token(s)) {
                parent[s as usize] = p as i32;
                token[s as usize] = t;
            }
            is_end[s as usize] = g.is_end(s);
        }
        Self::from_tree(token, parent, is_end).expect("a BiasGraph trie is a valid tree")
    }

    /// From explicit arrays: `parent[0] == -1` and `0 <= parent[n] < n`
    /// otherwise; `token[0]` is ignored (set to [`BLANK`]).
    pub fn from_tree(
        mut token: Vec<u32>,
        parent: Vec<i32>,
        is_end: Vec<bool>,
    ) -> Result<Self, String> {
        let n = parent.len();
        if n == 0 || token.len() != n || is_end.len() != n || parent[0] != -1 {
            return Err("trie: need a root and equal-length arrays".into());
        }
        token[0] = BLANK as u32;
        let mut depth = vec![0u32; n];
        let mut count = vec![0u32; n + 1];
        for i in 1..n {
            let p = parent[i];
            if p < 0 || p as usize >= i {
                return Err(format!("trie: node {i} has parent {p}"));
            }
            if token[i] as usize >= BLANK {
                return Err(format!("trie: node {i} has token {}", token[i]));
            }
            depth[i] = depth[p as usize] + 1;
            count[p as usize + 1] += 1;
        }
        let mut child_start = count;
        for i in 0..n {
            child_start[i + 1] += child_start[i];
        }
        let mut fill = child_start.clone();
        let mut children = vec![0u32; n.saturating_sub(1)];
        for (i, &p) in parent.iter().enumerate().skip(1) {
            let p = p as usize;
            children[fill[p] as usize] = i as u32;
            fill[p] += 1;
        }
        // Bottom-up (children have larger ids than their parents).
        let mut dmin = vec![u32::MAX; n];
        let mut dmax = vec![0u32; n];
        let mut nends = vec![0u32; n];
        let mut any = vec![false; n];
        for i in (0..n).rev() {
            if is_end[i] {
                dmin[i] = 0;
                nends[i] += 1;
                any[i] = true;
            }
            if i > 0 && any[i] {
                let p = parent[i] as usize;
                dmin[p] = dmin[p].min(dmin[i] + 1);
                dmax[p] = dmax[p].max((dmax[i] + 1).min(DMAX_CAP));
                nends[p] += nends[i];
                any[p] = true;
            }
        }
        for v in &mut dmin {
            if *v == u32::MAX {
                *v = 0;
            }
        }
        let nf = (0..n)
            .map(|i| {
                [
                    depth[i] as f32 / 8.0,
                    f32::from(u8::from(is_end[i])),
                    dmin[i] as f32 / 8.0,
                    dmax[i] as f32 / 8.0,
                    (1.0 + nends[i] as f32).ln() / 4.0,
                ]
            })
            .collect();
        Ok(TrieFeatures {
            token,
            depth,
            is_end,
            dmin,
            dmax,
            nends,
            parent,
            child_start,
            children,
            nf,
        })
    }

    pub fn nodes(&self) -> usize {
        self.parent.len()
    }

    pub fn children_of(&self, n: usize) -> &[u32] {
        &self.children[self.child_start[n] as usize..self.child_start[n + 1] as usize]
    }
}

/// The dictionary-size feature: `ln(1 + entries) / 7`, with `entries` the
/// deduplicated dictionary entries before case variants.
pub fn g_size(entries: usize) -> f32 {
    ((1.0 + entries as f64).ln() / 7.0) as f32
}

/// Statistics of one decision's 1025 token logits (blank included).
#[derive(Clone, Copy, Debug)]
pub struct LogitStats {
    pub max: f64,
    pub lse: f64,
    /// `logsoftmax(ℓ)_blank / 10`.
    pub blank_feature: f32,
}

impl LogitStats {
    /// `token_logits`: at least the 1025 token rows (durations ignored).
    /// The exponentials are f32 (relative error ~1e-7) summed in f64.
    #[inline(always)]
    pub fn new(token_logits: &[f32]) -> Self {
        let l = &token_logits[..V];
        let mut lanes = [f32::NEG_INFINITY; 16];
        for c in l.chunks(16) {
            for (m, &v) in lanes.iter_mut().zip(c) {
                *m = if v > *m { v } else { *m };
            }
        }
        let max32 = lanes.iter().fold(f32::NEG_INFINITY, |m, &v| m.max(v));
        let max = max32 as f64;
        let mut acc = [0.0f64; 16];
        for c in l.chunks(16) {
            for (a, &v) in acc.iter_mut().zip(c) {
                *a += exp_fast(v - max32) as f64;
            }
        }
        let lse = max + acc.iter().sum::<f64>().ln();
        LogitStats {
            max,
            lse,
            blank_feature: ((l[BLANK] as f64 - lse) / 10.0) as f32,
        }
    }

    /// `lf` of a candidate with logit `l_y`:
    /// `[ℓ_y/10, (ℓ_y − max ℓ)/10, logsoftmax_y/10, logsoftmax_blank/10]`.
    #[inline(always)]
    pub fn features(&self, l_y: f32) -> [f32; 4] {
        let l = l_y as f64;
        [
            (l / 10.0) as f32,
            ((l - self.max) / 10.0) as f32,
            ((l - self.lse) / 10.0) as f32,
            self.blank_feature,
        ]
    }
}

/// `lf` of token `y` given a decision's token logits.
pub fn logit_features(token_logits: &[f32], y: usize) -> [f32; 4] {
    LogitStats::new(token_logits).features(token_logits[y])
}

// ---------------------------------------------------------------- math

/// `exp(x)` for `x <= 0` (larger inputs are clamped at 88): Cody-Waite range
/// reduction and a degree-6 polynomial, branch-free so it vectorizes;
/// relative error ~2e-7, inputs below -87 give ~0.
#[inline(always)]
pub fn exp_fast(x: f32) -> f32 {
    let x = x.clamp(-87.0, 88.0);
    let k = (x * std::f32::consts::LOG2_E).round();
    // ln 2 = 0.693359375 (exact in a few bits) - 2.12194440e-4 (Cephes).
    let r = k.mul_add(-0.693_359_4, x);
    let r = k.mul_add(2.121_944_4e-4, r);
    let mut p = r.mul_add(1.0 / 720.0, 1.0 / 120.0);
    p = r.mul_add(p, 1.0 / 24.0);
    p = r.mul_add(p, 1.0 / 6.0);
    p = r.mul_add(p, 0.5);
    p = r.mul_add(p, 1.0);
    p = r.mul_add(p, 1.0);
    p * f32::from_bits(((k as i32 + 127) as u32) << 23)
}

/// erf, rational approximation (absolute error below ~1e-7 in f32).
#[inline(always)]
pub fn erf(x: f32) -> f32 {
    let x = x.clamp(-4.0, 4.0);
    let x2 = x * x;
    let mut p = x2.mul_add(-2.726_142_3e-10, 2.770_681_4e-8);
    p = x2.mul_add(p, -2.101_024e-6);
    p = x2.mul_add(p, -5.692_506_4e-5);
    p = x2.mul_add(p, -7.349_906_3e-4);
    p = x2.mul_add(p, -2.954_600_1e-3);
    p = x2.mul_add(p, -1.609_603_3e-2);
    let mut q = x2.mul_add(-1.456_607_2e-5, -2.133_740_6e-4);
    q = x2.mul_add(q, -1.682_827e-3);
    q = x2.mul_add(q, -7.373_329_2e-3);
    q = x2.mul_add(q, -1.426_474e-2);
    x * p / q
}

/// GELU, exact (erf) form.
#[inline(always)]
pub fn gelu(x: f32) -> f32 {
    0.5 * x * (1.0 + erf(x * std::f32::consts::FRAC_1_SQRT_2))
}

#[inline(always)]
fn gelu_slice(v: &mut [f32]) {
    for x in v {
        *x = gelu(*x);
    }
}

/// LayerNorm of each `w.len()`-wide row of `x`, in place.
#[inline(always)]
fn layer_norm_rows(x: &mut [f32], norm: &Norm) {
    let d = norm.w.len();
    for row in x.chunks_exact_mut(d) {
        let mean = row.iter().map(|&v| v as f64).sum::<f64>() / d as f64;
        let var = row
            .iter()
            .map(|&v| (v as f64 - mean) * (v as f64 - mean))
            .sum::<f64>()
            / d as f64;
        let inv = (1.0 / (var + LN_EPS as f64).sqrt()) as f32;
        let mean = mean as f32;
        for ((v, &w), &b) in row.iter_mut().zip(&norm.w).zip(&norm.b) {
            *v = (*v - mean) * inv * w + b;
        }
    }
}

#[inline(always)]
fn dot(a: &[f32], b: &[f32]) -> f32 {
    // Eight partial sums, so the compiler can vectorize.
    let mut acc = [0.0f32; 8];
    let (ac, ar) = a.as_chunks::<8>();
    let (bc, br) = b.as_chunks::<8>();
    for (x, y) in ac.iter().zip(bc) {
        for k in 0..8 {
            acc[k] = x[k].mul_add(y[k], acc[k]);
        }
    }
    let mut s = acc.iter().sum::<f32>();
    for (x, y) in ar.iter().zip(br) {
        s = x.mul_add(*y, s);
    }
    s
}

#[inline(always)]
fn axpy(y: &mut [f32], x: &[f32], a: f32) {
    for (y, &x) in y.iter_mut().zip(x) {
        *y = x.mul_add(a, *y);
    }
}

// ---------------------------------------------------------------- model (§3)

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Variant {
    L1,
    L2,
    L3,
    /// L3's tensors and math with `c(n)` always zero (no child messages):
    /// the capacity-matched control for L3.
    L3S,
}

impl Variant {
    pub const ALL: [Variant; 4] = [Variant::L1, Variant::L2, Variant::L3, Variant::L3S];

    pub fn parse(s: &str) -> Result<Self, String> {
        match s {
            "L1" => Ok(Variant::L1),
            "L2" => Ok(Variant::L2),
            "L3" => Ok(Variant::L3),
            "L3S" => Ok(Variant::L3S),
            _ => Err(format!("unknown learned-bias variant {s:?}")),
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Variant::L1 => "L1",
            Variant::L2 => "L2",
            Variant::L3 => "L3",
            Variant::L3S => "L3S",
        }
    }

    /// Has the `up.*` subtree layers and `gate` (L3 and L3S).
    pub fn has_up(self) -> bool {
        matches!(self, Variant::L3 | Variant::L3S)
    }
}

/// Every tensor of a variant with its shape (CONTRACT-2 §3 keys).
pub fn expected_tensors(variant: Variant) -> Vec<(String, Vec<usize>)> {
    let mut out: Vec<(String, Vec<usize>)> = Vec::new();
    let mut lin = |name: &str, i: usize, o: usize| {
        out.push((format!("{name}.weight"), vec![o, i]));
        out.push((format!("{name}.bias"), vec![o]));
    };
    if variant == Variant::L1 {
        lin("l1.0", NX, HID);
        lin("l1.1", HID, HID);
        lin("l1.2", HID, 1);
        return out;
    }
    lin("q.1", J, D);
    lin("q.2", D, D);
    lin("node.in", NF, D);
    for k in 0..2 {
        lin(&format!("self.{k}.0"), D, FF);
        lin(&format!("self.{k}.1"), FF, D);
    }
    lin("key", D, D);
    lin("sc.0", HEADS + NX, HID);
    lin("sc.1", HID, HID);
    lin("sc.2", HID, 1);
    if variant.has_up() {
        lin("up.0", 3 * D, FF);
        lin("up.1", FF, D);
    }
    let mut norm = |name: &str, d: usize| {
        out.push((format!("{name}.weight"), vec![d]));
        out.push((format!("{name}.bias"), vec![d]));
    };
    norm("q.ln", J);
    norm("self.0.ln", D);
    norm("self.1.ln", D);
    if variant.has_up() {
        norm("up.ln", D);
    }
    out.push(("emb.tok".into(), vec![V, D]));
    out.push(("emb.depth".into(), vec![DEPTH_EMB, D]));
    out.push(("emb.end".into(), vec![2, D]));
    if variant.has_up() {
        out.push(("gate".into(), vec![1]));
    }
    out
}

/// Named f32 tensors with shapes.
pub type Tensors = BTreeMap<String, (Vec<usize>, Vec<f32>)>;

struct Linear {
    /// `[out][in]`.
    w: Vec<f32>,
    b: Vec<f32>,
    inp: usize,
    out: usize,
    /// `w` packed for `x * w^T`.
    panels: Panels,
}

impl Linear {
    fn new(t: &mut Tensors, name: &str) -> Self {
        let (shape, w) = t.remove(&format!("{name}.weight")).expect("checked");
        let (_, b) = t.remove(&format!("{name}.bias")).expect("checked");
        let (out, inp) = (shape[0], shape[1]);
        let mut panels = Panels::default();
        panels.pack_rows(&w, out, inp, inp);
        Linear {
            w,
            b,
            inp,
            out,
            panels,
        }
    }

    /// `y[m][out] = x[m][inp] * w^T + b` on `pool`.
    fn forward(&self, pool: &ThreadPool, x: &[f32], m: usize) -> Vec<f32> {
        let mut y = vec![0.0f32; m * self.out];
        if m > 0 {
            dense::gemm(
                pool,
                x,
                m,
                self.inp,
                &self.panels,
                &mut y,
                self.out,
                Some(&self.b),
            );
        }
        y
    }

    /// Single-threaded `forward` into `y` (no allocation).
    fn forward_serial(&self, x: &[f32], m: usize, y: &mut [f32]) {
        if m == 0 {
            return;
        }
        dense::gemm_serial(
            x,
            m,
            self.inp,
            &self.panels,
            0..self.panels.panels(),
            y,
            self.out,
        );
        for row in y[..m * self.out].chunks_exact_mut(self.out) {
            for (v, &b) in row.iter_mut().zip(&self.b) {
                *v += b;
            }
        }
    }

    /// Column `c` of `w` (the weights of input `c`), length `out`.
    fn column(&self, c: usize) -> Vec<f32> {
        (0..self.out).map(|o| self.w[o * self.inp + c]).collect()
    }
}

struct Norm {
    w: Vec<f32>,
    b: Vec<f32>,
}

impl Norm {
    fn new(t: &mut Tensors, name: &str) -> Self {
        Norm {
            w: t.remove(&format!("{name}.weight")).expect("checked").1,
            b: t.remove(&format!("{name}.bias")).expect("checked").1,
        }
    }
}

/// The scorer's MLP: first layer split by input columns, then two layers.
struct Head {
    /// First layer (`HID` outputs): bias, and per input column its weights.
    b0: Vec<f32>,
    /// Columns of the per-head dot products (L2/L3; empty for L1).
    w_a: Vec<Vec<f32>>,
    w_nf: Vec<Vec<f32>>,
    w_lf: Vec<Vec<f32>>,
    w_g: Vec<f32>,
    l1: Linear,
    /// Last layer (`HID` -> 1).
    w2: Vec<f32>,
    b2: f32,
}

impl Head {
    fn new(l0: Linear, l1: Linear, l2: Linear, dots: usize) -> Self {
        let cols = |r: std::ops::Range<usize>| r.map(|c| l0.column(c)).collect::<Vec<_>>();
        Head {
            w_a: cols(0..dots),
            w_nf: cols(dots..dots + NF),
            w_lf: cols(dots + NF..dots + NF + 4),
            w_g: l0.column(dots + NF + 4),
            b0: l0.b.clone(),
            l1,
            w2: l2.w,
            b2: l2.b[0],
        }
    }

    /// A node's share of the first layer: bias + nf columns + g_size column.
    #[inline(always)]
    fn node_part(&self, nf: &[f32; NF], g: f32) -> Vec<f32> {
        let mut v = self.b0.clone();
        for (c, &x) in self.w_nf.iter().zip(nf) {
            axpy(&mut v, c, x);
        }
        axpy(&mut v, &self.w_g, g);
        v
    }
}

struct Query {
    ln: Norm,
    l1: Linear,
    l2: Linear,
}

struct NodeNet {
    tok: Vec<f32>,
    depth: Vec<f32>,
    end: Vec<f32>,
    input: Linear,
    selfs: [(Linear, Linear, Norm); 2],
    key: Linear,
    /// L3 and L3S only.
    up: Option<Up>,
}

/// The subtree layer: `t(n) = s(n) + gate * LN_up(up.1(gelu(up.0([s(n); c(n)]))))`,
/// with `c(n)` the children's max- and mean-pooled `t` (L3) or zero (L3S).
struct Up {
    l0: Linear,
    l1: Linear,
    ln: Norm,
    gate: f32,
    messages: bool,
}

pub struct LearnedModel {
    variant: Variant,
    lambda: f32,
    parameters: usize,
    head: Head,
    query: Option<Query>,
    nodes: Option<NodeNet>,
}

impl LearnedModel {
    /// Loads a model file (CONTRACT-2 §3): exactly the variant's tensors, all
    /// F32 with the expected shapes, and the metadata `format`, `variant`,
    /// `lambda` and `d`.
    pub fn load(path: &Path) -> Result<Self, String> {
        let st = SafeTensors::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
        Self::from_safetensors(&st).map_err(|e| format!("{}: {e}", path.display()))
    }

    pub fn from_safetensors(st: &SafeTensors) -> Result<Self, String> {
        let meta = |k: &str| {
            st.metadata
                .get(k)
                .ok_or(format!("metadata has no {k:?}"))
                .map(String::as_str)
        };
        if meta("format")? != FORMAT {
            return Err(format!("format {:?}, expected {FORMAT:?}", meta("format")?));
        }
        if meta("d")? != D.to_string() {
            return Err(format!("d {:?}, expected {D}", meta("d")?));
        }
        let variant = Variant::parse(meta("variant")?)?;
        let lambda: f32 = meta("lambda")?
            .parse()
            .map_err(|e| format!("lambda {:?}: {e}", meta("lambda")))?;
        let mut tensors = Tensors::new();
        for name in st.tensors.keys() {
            let (info, _) = st.get(name).map_err(|e| e.to_string())?;
            if info.dtype != lf_model::Dtype::F32 {
                return Err(format!("{name}: dtype {:?}, expected F32", info.dtype));
            }
            let v = st.f32_vec(name).map_err(|e| e.to_string())?;
            tensors.insert(name.clone(), (info.shape.clone(), v));
        }
        Self::from_tensors(variant, lambda, tensors)
    }

    /// From named tensors, which must be exactly the variant's set.
    pub fn from_tensors(variant: Variant, lambda: f32, mut t: Tensors) -> Result<Self, String> {
        if !lambda.is_finite() || lambda < 0.0 {
            return Err(format!("lambda {lambda} must be finite and non-negative"));
        }
        let expected = expected_tensors(variant);
        let mut missing = Vec::new();
        for (name, shape) in &expected {
            match t.get(name) {
                None => missing.push(name.clone()),
                Some((s, v)) => {
                    if s != shape || v.len() != shape.iter().product::<usize>() {
                        return Err(format!("{name}: shape {s:?}, expected {shape:?}"));
                    }
                    if v.iter().any(|x| !x.is_finite()) {
                        return Err(format!("{name}: non-finite values"));
                    }
                }
            }
        }
        let names: std::collections::BTreeSet<&String> = expected.iter().map(|(n, _)| n).collect();
        let extra: Vec<&String> = t.keys().filter(|k| !names.contains(k)).collect();
        if !missing.is_empty() || !extra.is_empty() {
            return Err(format!(
                "{} tensors: missing {missing:?}, unexpected {extra:?}",
                variant.name()
            ));
        }
        let parameters = expected
            .iter()
            .map(|(_, s)| s.iter().product::<usize>())
            .sum();
        let (head, query, nodes) = if variant == Variant::L1 {
            let l0 = Linear::new(&mut t, "l1.0");
            let l1 = Linear::new(&mut t, "l1.1");
            let l2 = Linear::new(&mut t, "l1.2");
            (Head::new(l0, l1, l2, 0), None, None)
        } else {
            let l0 = Linear::new(&mut t, "sc.0");
            let l1 = Linear::new(&mut t, "sc.1");
            let l2 = Linear::new(&mut t, "sc.2");
            let query = Query {
                ln: Norm::new(&mut t, "q.ln"),
                l1: Linear::new(&mut t, "q.1"),
                l2: Linear::new(&mut t, "q.2"),
            };
            let mut self_layer = |k: usize| {
                (
                    Linear::new(&mut t, &format!("self.{k}.0")),
                    Linear::new(&mut t, &format!("self.{k}.1")),
                    Norm::new(&mut t, &format!("self.{k}.ln")),
                )
            };
            let selfs = [self_layer(0), self_layer(1)];
            let up = variant.has_up().then(|| {
                let gate = t.remove("gate").expect("checked").1[0];
                Up {
                    l0: Linear::new(&mut t, "up.0"),
                    l1: Linear::new(&mut t, "up.1"),
                    ln: Norm::new(&mut t, "up.ln"),
                    gate,
                    messages: variant == Variant::L3,
                }
            });
            let nodes = NodeNet {
                tok: t.remove("emb.tok").expect("checked").1,
                depth: t.remove("emb.depth").expect("checked").1,
                end: t.remove("emb.end").expect("checked").1,
                input: Linear::new(&mut t, "node.in"),
                selfs,
                key: Linear::new(&mut t, "key"),
                up,
            };
            (Head::new(l0, l1, l2, HEADS), Some(query), Some(nodes))
        };
        Ok(LearnedModel {
            variant,
            lambda,
            parameters,
            head,
            query,
            nodes,
        })
    }

    pub fn variant(&self) -> Variant {
        self.variant
    }

    /// The λ stored in the model file.
    pub fn lambda(&self) -> f32 {
        self.lambda
    }

    pub fn parameters(&self) -> usize {
        self.parameters
    }

    /// The node pass for one dictionary: `entries` deduplicated entries
    /// (before case variants) whose phrases form `trie`. Uses `pool` for the
    /// matrix products.
    pub fn prepare(&self, pool: &ThreadPool, trie: &TrieFeatures, entries: usize) -> PreparedDict {
        let start = Instant::now();
        let n = trie.nodes();
        let g = g_size(entries);
        let pre = if simd() {
            // SAFETY: the CPU has the features (checked by `simd`).
            unsafe { node_parts_simd(&self.head, trie, g) }
        } else {
            node_parts(&self.head, trie, g)
        };
        let keys = self.nodes.as_ref().map(|net| {
            if simd() {
                // SAFETY: the CPU has the features (checked by `simd`).
                unsafe { node_keys_simd(net, pool, trie) }
            } else {
                node_keys(net, pool, trie)
            }
        });
        PreparedDict {
            nodes: n,
            g_size: g,
            pre,
            keys,
            node_pass_ns: start.elapsed().as_nanos() as u64,
        }
    }

    /// `b = 8 tanh(raw / 8)` (before λ) for each candidate of one decision.
    pub fn bonuses(
        &self,
        dict: &PreparedDict,
        z: &[f32],
        logits: &[f32],
        cands: &[(u32, BiasState)],
        scratch: &mut Scratch,
        out: &mut Vec<f32>,
    ) {
        if simd() {
            // SAFETY: the CPU has the features (checked by `simd`).
            unsafe { self.bonuses_simd(dict, z, logits, cands, scratch, out) }
        } else {
            self.bonuses_impl(dict, z, logits, cands, scratch, out)
        }
    }

    /// [`Self::bonuses_impl`] compiled for AVX-512 and FMA, so the inlined
    /// `mul_add`s and loops vectorize (without the features each `mul_add`
    /// is a libm call).
    #[target_feature(enable = "avx512f,avx512vl,avx2,fma")]
    unsafe fn bonuses_simd(
        &self,
        dict: &PreparedDict,
        z: &[f32],
        logits: &[f32],
        cands: &[(u32, BiasState)],
        scratch: &mut Scratch,
        out: &mut Vec<f32>,
    ) {
        self.bonuses_impl(dict, z, logits, cands, scratch, out)
    }

    #[inline(always)]
    fn bonuses_impl(
        &self,
        dict: &PreparedDict,
        z: &[f32],
        logits: &[f32],
        cands: &[(u32, BiasState)],
        scratch: &mut Scratch,
        out: &mut Vec<f32>,
    ) {
        out.clear();
        let c = cands.len();
        if c == 0 {
            return;
        }
        let stats = LogitStats::new(logits);
        if let Some(q) = &self.query {
            // q = q.2(gelu(q.1(LN(z)))).
            scratch.zn.clear();
            scratch.zn.extend_from_slice(&z[..J]);
            layer_norm_rows(&mut scratch.zn, &q.ln);
            scratch.qh.resize(D, 0.0);
            q.l1.forward_serial(&scratch.zn, 1, &mut scratch.qh);
            gelu_slice(&mut scratch.qh);
            scratch.q.resize(D, 0.0);
            q.l2.forward_serial(&scratch.qh, 1, &mut scratch.q);
        }
        scratch.h0.resize(c * HID, 0.0);
        scratch.h1.resize(c * HID, 0.0);
        for (i, &(y, node)) in cands.iter().enumerate() {
            let node = node as usize;
            let row = &mut scratch.h0[i * HID..(i + 1) * HID];
            row.copy_from_slice(&dict.pre[node * HID..(node + 1) * HID]);
            let lf = stats.features(logits[y as usize]);
            for (col, &x) in self.head.w_lf.iter().zip(&lf) {
                axpy(row, col, x);
            }
            if let Some(keys) = &dict.keys {
                let k = &keys[node * D..(node + 1) * D];
                for h in 0..HEADS {
                    let a = dot(&scratch.q[h * DH..(h + 1) * DH], &k[h * DH..(h + 1) * DH]) / 8.0;
                    axpy(row, &self.head.w_a[h], a);
                }
            }
            gelu_slice(row);
        }
        self.head.l1.forward_serial(&scratch.h0, c, &mut scratch.h1);
        gelu_slice(&mut scratch.h1[..c * HID]);
        for i in 0..c {
            let raw = dot(&scratch.h1[i * HID..(i + 1) * HID], &self.head.w2) + self.head.b2;
            out.push(8.0 * (raw / 8.0).tanh());
        }
    }
}

/// Whether the CPU runs the AVX-512/FMA builds of the hot loops.
fn simd() -> bool {
    static OK: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *OK.get_or_init(|| {
        #[cfg(target_arch = "x86_64")]
        {
            lf_cpu::cpu_supported()
                && std::arch::is_x86_feature_detected!("avx512vl")
                && std::arch::is_x86_feature_detected!("avx2")
                && std::arch::is_x86_feature_detected!("fma")
        }
        #[cfg(not(target_arch = "x86_64"))]
        {
            false
        }
    })
}

/// Every node's share of the scorer's first layer, `[nodes][HID]`.
#[inline(always)]
fn node_parts(head: &Head, trie: &TrieFeatures, g: f32) -> Vec<f32> {
    let mut pre = Vec::with_capacity(trie.nodes() * HID);
    for nf in &trie.nf {
        pre.extend(head.node_part(nf, g));
    }
    pre
}

#[target_feature(enable = "avx512f,avx512vl,avx2,fma")]
unsafe fn node_parts_simd(head: &Head, trie: &TrieFeatures, g: f32) -> Vec<f32> {
    node_parts(head, trie, g)
}

/// [`node_keys`] compiled for AVX-512 and FMA (see `bonuses_simd`).
#[target_feature(enable = "avx512f,avx512vl,avx2,fma")]
unsafe fn node_keys_simd(net: &NodeNet, pool: &ThreadPool, trie: &TrieFeatures) -> Vec<f32> {
    node_keys(net, pool, trie)
}

/// The node pass (L2/L3): `k(n)` for every node, `[nodes][D]`.
#[inline(always)]
fn node_keys(net: &NodeNet, pool: &ThreadPool, trie: &TrieFeatures) -> Vec<f32> {
    let n = trie.nodes();
    // e(n) = emb.tok[token] + emb.depth[min(depth, 15)] + emb.end[is_end] + node.in(nf).
    let nf: Vec<f32> = trie.nf.iter().flatten().copied().collect();
    let mut h = net.input.forward(pool, &nf, n);
    for i in 0..n {
        let row = &mut h[i * D..(i + 1) * D];
        let t = trie.token[i] as usize;
        let d = (trie.depth[i] as usize).min(DEPTH_EMB - 1);
        let e = usize::from(trie.is_end[i]);
        for (j, v) in row.iter_mut().enumerate() {
            *v += net.tok[t * D + j] + net.depth[d * D + j] + net.end[e * D + j];
        }
    }
    // Self stack: h <- LN(h + W1 gelu(W0 h)).
    for (l0, l1, ln) in &net.selfs {
        let mut a = l0.forward(pool, &h, n);
        gelu_slice(&mut a);
        let b = l1.forward(pool, &a, n);
        for (x, y) in h.iter_mut().zip(&b) {
            *x += y;
        }
        layer_norm_rows(&mut h, ln);
    }
    // L3: t(n) = s(n) + gate * LN_up(up.1(gelu(up.0([s(n); max_c t; mean_c t])))),
    // deepest nodes first, one level at a time. L3S: the same with c(n) = 0.
    let t = match &net.up {
        None => h,
        Some(Up {
            l0: u0,
            l1: u1,
            ln,
            gate,
            messages,
        }) => {
            let s = h;
            let mut t = s.clone();
            let max_depth = trie.depth.iter().copied().max().unwrap_or(0);
            let mut by_depth: Vec<Vec<usize>> = vec![Vec::new(); max_depth as usize + 1];
            for i in 1..n {
                by_depth[trie.depth[i] as usize].push(i);
            }
            for level in by_depth.iter().rev() {
                if level.is_empty() {
                    continue;
                }
                let m = level.len();
                let mut x = vec![0.0f32; m * 3 * D];
                for (r, &i) in level.iter().enumerate() {
                    let row = &mut x[r * 3 * D..(r + 1) * 3 * D];
                    row[..D].copy_from_slice(&s[i * D..(i + 1) * D]);
                    let kids = trie.children_of(i);
                    if kids.is_empty() || !messages {
                        continue;
                    }
                    let (mx, mean) = row[D..].split_at_mut(D);
                    mx.fill(f32::NEG_INFINITY);
                    for &k in kids {
                        let tk = &t[k as usize * D..(k as usize + 1) * D];
                        for j in 0..D {
                            mx[j] = mx[j].max(tk[j]);
                            mean[j] += tk[j];
                        }
                    }
                    let inv = 1.0 / kids.len() as f32;
                    for v in mean.iter_mut() {
                        *v *= inv;
                    }
                }
                let mut a = u0.forward(pool, &x, m);
                gelu_slice(&mut a);
                let mut b = u1.forward(pool, &a, m);
                layer_norm_rows(&mut b, ln);
                for (r, &i) in level.iter().enumerate() {
                    for j in 0..D {
                        t[i * D + j] = s[i * D + j] + gate * b[r * D + j];
                    }
                }
            }
            t
        }
    };
    net.key.forward(pool, &t, n)
}

/// A dictionary after the node pass.
pub struct PreparedDict {
    pub nodes: usize,
    pub g_size: f32,
    /// Per node, its share of the scorer's first layer (`[nodes][HID]`).
    pre: Vec<f32>,
    /// `k(n)` per node (`[nodes][D]`), L2/L3 only.
    keys: Option<Vec<f32>>,
    pub node_pass_ns: u64,
}

/// Per-decision buffers.
#[derive(Default)]
pub struct Scratch {
    zn: Vec<f32>,
    qh: Vec<f32>,
    q: Vec<f32>,
    h0: Vec<f32>,
    h1: Vec<f32>,
    b: Vec<f32>,
}

/// Per-decision cost counters of a [`LearnedScorer`].
#[derive(Default)]
pub struct ScorerStats {
    pub calls: AtomicU64,
    pub candidates: AtomicU64,
    pub ns: AtomicU64,
}

/// The [`BiasScorer`] of a prepared dictionary: bonus `λ·b` per candidate.
pub struct LearnedScorer<'a> {
    pub model: &'a LearnedModel,
    pub dict: &'a PreparedDict,
    pub lambda: f32,
    pub stats: Option<&'a ScorerStats>,
    scratch: Mutex<Scratch>,
}

impl<'a> LearnedScorer<'a> {
    pub fn new(
        model: &'a LearnedModel,
        dict: &'a PreparedDict,
        lambda: f32,
        stats: Option<&'a ScorerStats>,
    ) -> Self {
        LearnedScorer {
            model,
            dict,
            lambda,
            stats,
            scratch: Mutex::new(Scratch::default()),
        }
    }
}

impl BiasScorer for LearnedScorer<'_> {
    fn score(
        &self,
        _state: BiasState,
        z: &[f32],
        logits: &[f32],
        cands: &[(u32, BiasState)],
        out: &mut Vec<(u32, f32)>,
    ) {
        let start = self.stats.map(|_| Instant::now());
        let mut guard = self.scratch.lock().unwrap();
        let s = &mut *guard;
        let mut b = std::mem::take(&mut s.b);
        self.model.bonuses(self.dict, z, logits, cands, s, &mut b);
        out.extend(
            cands
                .iter()
                .zip(&b)
                .map(|(&(t, _), &v)| (t, self.lambda * v)),
        );
        s.b = b;
        if let (Some(st), Some(t0)) = (self.stats, start) {
            st.calls.fetch_add(1, Ordering::Relaxed);
            st.candidates
                .fetch_add(cands.len() as u64, Ordering::Relaxed);
            st.ns
                .fetch_add(t0.elapsed().as_nanos() as u64, Ordering::Relaxed);
        }
    }
}

// ---------------------------------------------------------------- synthetic models

/// Random weights with PyTorch's default initialization (Linear and its bias
/// uniform in ±1/sqrt(fan_in), embeddings standard normal, LayerNorm 1 and
/// 0), `gate` as given, and, with `zero_final`, `l1.2`/`sc.2` zero (the
/// contract's initialization). For tests and timing only.
pub fn random_tensors(variant: Variant, seed: u64, gate: f32, zero_final: bool) -> Tensors {
    let mut rng = lf_model::rng::SplitMix64::new(seed);
    let mut out = Tensors::new();
    for (name, shape) in expected_tensors(variant) {
        let n: usize = shape.iter().product();
        let v: Vec<f32> = if name == "gate" {
            vec![gate]
        } else if name.starts_with("emb.") {
            (0..n).map(|_| rng.next_gaussian()).collect()
        } else if name.ends_with("ln.weight") {
            vec![1.0; n]
        } else if name.ends_with("ln.bias")
            || (zero_final && (name.starts_with("l1.2.") || name.starts_with("sc.2.")))
        {
            vec![0.0; n]
        } else {
            let base = name.rsplit_once('.').unwrap().0;
            let fan_in = expected_tensors(variant)
                .into_iter()
                .find(|(k, _)| *k == format!("{base}.weight"))
                .map(|(_, s)| s[1])
                .unwrap();
            let bound = 1.0 / (fan_in as f32).sqrt();
            (0..n)
                .map(|_| (2.0 * rng.next_f32() - 1.0) * bound)
                .collect()
        };
        out.insert(name, (shape, v));
    }
    out
}

/// Serializes tensors as a model file (CONTRACT-2 §3 metadata).
pub fn model_file_bytes(variant: Variant, lambda: f32, t: &Tensors) -> Vec<u8> {
    let meta: BTreeMap<String, String> = [
        ("variant".to_owned(), variant.name().to_owned()),
        ("lambda".to_owned(), lambda.to_string()),
        ("d".to_owned(), D.to_string()),
        ("format".to_owned(), FORMAT.to_owned()),
    ]
    .into();
    let data: Vec<lf_model::TensorData> = t
        .iter()
        .map(|(k, (s, v))| lf_model::TensorData::f32(k, s.clone(), v))
        .collect();
    lf_model::safetensors::serialize(&meta, &data).expect("valid tensors")
}

#[cfg(test)]
mod tests {
    use super::*;
    use lf_cpu::bias::BiasConfig;

    fn graph(phrases: &[&[usize]]) -> BiasGraph {
        let p: Vec<Vec<usize>> = phrases.iter().map(|p| p.to_vec()).collect();
        let c = BiasConfig {
            alpha: 1.0,
            context_score: 1.0,
            depth_scaling: 0.0,
            cancel_unfinished: false,
        };
        BiasGraph::new(&p, BLANK, c).unwrap()
    }

    #[test]
    fn trie_features_follow_the_contract() {
        // "new york" (1 2), "new york city" (1 2 3), "newt" (1 4 5 6), "x" (7).
        let g = graph(&[&[1, 2], &[1, 2, 3], &[1, 4, 5, 6], &[7]]);
        let f = TrieFeatures::new(&g);
        assert_eq!(f.nodes(), g.states());
        let at = |path: &[u32]| {
            let mut s = 0usize;
            for &t in path {
                s = f
                    .children_of(s)
                    .iter()
                    .copied()
                    .find(|&c| f.token[c as usize] == t)
                    .unwrap() as usize;
            }
            s
        };
        assert_eq!(f.token[0], BLANK as u32);
        assert_eq!(f.parent[0], -1);
        let (new, ny, nyc, x) = (at(&[1]), at(&[1, 2]), at(&[1, 2, 3]), at(&[7]));
        assert_eq!(
            (
                f.depth[ny],
                f.is_end[ny],
                f.dmin[ny],
                f.dmax[ny],
                f.nends[ny]
            ),
            (2, true, 0, 1, 2)
        );
        assert_eq!((f.dmin[new], f.dmax[new], f.nends[new]), (1, 3, 3));
        assert_eq!((f.dmin[nyc], f.dmax[nyc], f.nends[nyc]), (0, 0, 1));
        assert_eq!((f.dmin[x], f.dmax[x]), (0, 0));
        assert_eq!((f.dmin[0], f.dmax[0], f.nends[0]), (1, 4, 4));
        assert_eq!(f.parent[nyc], ny as i32);
        let nf = f.nf[new];
        assert_eq!(
            nf,
            [1.0 / 8.0, 0.0, 1.0 / 8.0, 3.0 / 8.0, (4.0f32).ln() / 4.0]
        );
        assert_eq!(f.nf[ny][1], 1.0);
        // dmax is capped.
        let long: Vec<usize> = (0..40).map(|i| i % 9 + 1).collect();
        let f = TrieFeatures::new(&graph(&[&long]));
        assert_eq!(f.dmax[0], DMAX_CAP);
        assert_eq!(f.dmin[0], 40);
        // Explicit arrays are validated.
        assert!(TrieFeatures::from_tree(vec![0, 1], vec![-1, 1], vec![false, true]).is_err());
        assert!(TrieFeatures::from_tree(vec![0, 1], vec![0, 0], vec![false, true]).is_err());
        assert!(TrieFeatures::from_tree(vec![0, 1024], vec![-1, 0], vec![false, true]).is_err());
    }

    #[test]
    fn size_and_logit_features() {
        assert_eq!(g_size(0), 0.0);
        assert!((g_size(1000) - (1001f32).ln() / 7.0).abs() < 1e-7);
        let mut l = vec![0.0f32; V + 5];
        l[3] = 2.0;
        l[BLANK] = 1.0;
        l[V] = 100.0; // a duration: ignored
        let lse = ((V as f64 - 2.0) + 2f64.exp() + 1f64.exp()).ln();
        let f = logit_features(&l, 3);
        let want = [
            0.2,
            0.0,
            ((2.0 - lse) / 10.0) as f32,
            ((1.0 - lse) / 10.0) as f32,
        ];
        for (a, b) in f.iter().zip(want) {
            assert!((a - b).abs() < 1e-7, "{f:?} vs {want:?}");
        }
        assert!((logit_features(&l, 0)[1] + 0.2).abs() < 1e-7);
    }

    /// erf to f64 accuracy by its Taylor series (|x| <= 3.5).
    fn erf_ref(x: f64) -> f64 {
        let (mut term, mut sum) = (x, x);
        for n in 1..200 {
            term *= -x * x / n as f64;
            sum += term / (2 * n + 1) as f64;
        }
        sum * 2.0 / std::f64::consts::PI.sqrt()
    }

    #[test]
    fn erf_is_accurate() {
        let mut worst = 0.0f64;
        for i in -3500..=3500 {
            let x = i as f64 / 1000.0;
            worst = worst.max((erf(x as f32) as f64 - erf_ref(x)).abs());
        }
        assert!(worst < 3e-7, "max erf error {worst}");
        for x in [3.6f32, 5.0, 40.0, f32::MAX] {
            assert!((erf(x) - 1.0).abs() < 1e-6 && (erf(-x) + 1.0).abs() < 1e-6);
        }
        assert_eq!(gelu(0.0), 0.0);
        assert!((gelu(1.0) - 0.841_344_7).abs() < 1e-6);
    }

    fn model(variant: Variant, seed: u64, gate: f32, zero_final: bool) -> LearnedModel {
        LearnedModel::from_tensors(
            variant,
            1.0,
            random_tensors(variant, seed, gate, zero_final),
        )
        .unwrap()
    }

    /// A naive f64 implementation of CONTRACT-2 §3 for one candidate.
    struct Naive<'a>(&'a Tensors);

    impl Naive<'_> {
        fn t(&self, k: &str) -> &[f32] {
            &self.0[k].1
        }
        fn lin(&self, name: &str, x: &[f64]) -> Vec<f64> {
            let (s, w) = &self.0[&format!("{name}.weight")];
            let b = self.t(&format!("{name}.bias"));
            (0..s[0])
                .map(|o| {
                    (0..s[1])
                        .map(|i| w[o * s[1] + i] as f64 * x[i])
                        .sum::<f64>()
                        + b[o] as f64
                })
                .collect()
        }
        fn ln(&self, name: &str, x: &[f64]) -> Vec<f64> {
            let n = x.len() as f64;
            let m = x.iter().sum::<f64>() / n;
            let v = x.iter().map(|a| (a - m) * (a - m)).sum::<f64>() / n;
            let (w, b) = (
                self.t(&format!("{name}.weight")),
                self.t(&format!("{name}.bias")),
            );
            x.iter()
                .enumerate()
                .map(|(i, a)| (a - m) / (v + 1e-5).sqrt() * w[i] as f64 + b[i] as f64)
                .collect()
        }
        fn gelu(x: Vec<f64>) -> Vec<f64> {
            x.into_iter()
                .map(|a| 0.5 * a * (1.0 + erf_ref((a / 2f64.sqrt()).clamp(-3.5, 3.5))))
                .collect()
        }
        fn s(&self, f: &TrieFeatures, n: usize) -> Vec<f64> {
            let row = |k: &str, i: usize| self.t(k)[i * D..(i + 1) * D].to_vec();
            let nf: Vec<f64> = f.nf[n].iter().map(|&v| v as f64).collect();
            let inp = self.lin("node.in", &nf);
            let (tok, dep, end) = (
                row("emb.tok", f.token[n] as usize),
                row("emb.depth", (f.depth[n] as usize).min(15)),
                row("emb.end", usize::from(f.is_end[n])),
            );
            let mut h: Vec<f64> = (0..D)
                .map(|j| tok[j] as f64 + dep[j] as f64 + end[j] as f64 + inp[j])
                .collect();
            for k in 0..2 {
                let a = Self::gelu(self.lin(&format!("self.{k}.0"), &h));
                let b = self.lin(&format!("self.{k}.1"), &a);
                let sum: Vec<f64> = h.iter().zip(&b).map(|(x, y)| x + y).collect();
                h = self.ln(&format!("self.{k}.ln"), &sum);
            }
            h
        }
        fn t_node(&self, f: &TrieFeatures, n: usize, variant: Variant) -> Vec<f64> {
            let s = self.s(f, n);
            if !variant.has_up() {
                return s;
            }
            let kids = f.children_of(n);
            let mut c = vec![0.0; 2 * D];
            if !kids.is_empty() && variant == Variant::L3 {
                let ts: Vec<Vec<f64>> = kids
                    .iter()
                    .map(|&k| self.t_node(f, k as usize, variant))
                    .collect();
                for j in 0..D {
                    c[j] = ts.iter().map(|t| t[j]).fold(f64::NEG_INFINITY, f64::max);
                    c[D + j] = ts.iter().map(|t| t[j]).sum::<f64>() / ts.len() as f64;
                }
            }
            let x: Vec<f64> = s.iter().chain(&c).copied().collect();
            let u = self.ln(
                "up.ln",
                &self.lin("up.1", &Self::gelu(self.lin("up.0", &x))),
            );
            let gate = self.t("gate")[0] as f64;
            s.iter().zip(&u).map(|(a, b)| a + gate * b).collect()
        }
        #[allow(clippy::too_many_arguments)]
        fn bonus(
            &self,
            variant: Variant,
            f: &TrieFeatures,
            entries: usize,
            z: &[f32],
            logits: &[f32],
            y: usize,
            n: usize,
        ) -> f64 {
            let lf = logit_features(logits, y);
            let mut x: Vec<f64> = f.nf[n].iter().chain(&lf).map(|&v| v as f64).collect();
            x.push(g_size(entries) as f64);
            let raw = if variant == Variant::L1 {
                let h = Self::gelu(self.lin("l1.0", &x));
                self.lin("l1.2", &Self::gelu(self.lin("l1.1", &h)))[0]
            } else {
                let zf: Vec<f64> = z.iter().map(|&v| v as f64).collect();
                let q = self.lin("q.2", &Self::gelu(self.lin("q.1", &self.ln("q.ln", &zf))));
                let k = self.lin("key", &self.t_node(f, n, variant));
                let mut inp: Vec<f64> = (0..HEADS)
                    .map(|h| (0..DH).map(|j| q[h * DH + j] * k[h * DH + j]).sum::<f64>() / 8.0)
                    .collect();
                inp.extend(x);
                let h = Self::gelu(self.lin("sc.0", &inp));
                self.lin("sc.2", &Self::gelu(self.lin("sc.1", &h)))[0]
            };
            8.0 * (raw / 8.0).tanh()
        }
    }

    fn decision(seed: u64) -> (Vec<f32>, Vec<f32>) {
        let mut rng = lf_model::rng::SplitMix64::new(seed);
        let z: Vec<f32> = (0..J).map(|_| rng.next_gaussian().max(0.0)).collect();
        let l: Vec<f32> = (0..V + 5).map(|_| 3.0 * rng.next_gaussian()).collect();
        (z, l)
    }

    fn small_graph() -> BiasGraph {
        graph(&[
            &[10, 20],
            &[10, 20, 30],
            &[10, 40, 50, 60],
            &[70],
            &[20, 30, 80],
            &[900, 901],
        ])
    }

    #[test]
    fn forward_matches_a_naive_implementation() {
        if !lf_cpu::cpu_supported() {
            return;
        }
        let pool = ThreadPool::new(&[0]);
        let g = small_graph();
        let f = TrieFeatures::new(&g);
        for (variant, gate) in [
            (Variant::L1, 0.0),
            (Variant::L2, 0.0),
            (Variant::L3, 0.7),
            (Variant::L3S, 0.7),
        ] {
            let tensors = random_tensors(variant, 5, gate, false);
            let m = LearnedModel::from_tensors(variant, 1.0, tensors.clone()).unwrap();
            let dict = m.prepare(&pool, &f, 6);
            let naive = Naive(&tensors);
            for (seed, state) in [
                (1, BiasGraph::ROOT),
                (2, g.step(0, 10).0),
                (3, g.step(g.step(0, 20).0, 30).0),
            ] {
                let (z, l) = decision(seed);
                let cands = g.candidates(state);
                assert!(!cands.is_empty());
                let mut b = Vec::new();
                m.bonuses(&dict, &z, &l, &cands, &mut Scratch::default(), &mut b);
                for (&(y, n), &got) in cands.iter().zip(&b) {
                    let want = naive.bonus(variant, &f, 6, &z, &l, y as usize, n as usize);
                    assert!(
                        (got as f64 - want).abs() <= 1e-4 * (1.0 + want.abs()),
                        "{variant:?} state {state} token {y}: {got} vs {want}"
                    );
                    assert!(want.abs() > 1e-3, "bonuses should be non-trivial");
                }
            }
        }
    }

    #[test]
    fn l3_with_a_zero_gate_equals_l2() {
        if !lf_cpu::cpu_supported() {
            return;
        }
        let pool = ThreadPool::new(&[0]);
        let g = small_graph();
        let f = TrieFeatures::new(&g);
        let t3 = random_tensors(Variant::L3, 9, 0.0, false);
        let mut t2 = t3.clone();
        t2.retain(|k, _| !k.starts_with("up.") && k != "gate");
        let m3 = LearnedModel::from_tensors(Variant::L3, 1.0, t3).unwrap();
        let m2 = LearnedModel::from_tensors(Variant::L2, 1.0, t2).unwrap();
        let (d3, d2) = (m3.prepare(&pool, &f, 6), m2.prepare(&pool, &f, 6));
        let (z, l) = decision(4);
        for s in 0..g.states() as BiasState {
            let cands = g.candidates(s);
            let (mut b3, mut b2) = (Vec::new(), Vec::new());
            m3.bonuses(&d3, &z, &l, &cands, &mut Scratch::default(), &mut b3);
            m2.bonuses(&d2, &z, &l, &cands, &mut Scratch::default(), &mut b2);
            assert_eq!(b3, b2, "state {s}");
        }
        // A non-zero gate changes the bonuses of nodes with children.
        let mut t3 = random_tensors(Variant::L3, 9, 0.0, false);
        t3.get_mut("gate").unwrap().1[0] = 1.0;
        let m3 = LearnedModel::from_tensors(Variant::L3, 1.0, t3).unwrap();
        let d3 = m3.prepare(&pool, &f, 6);
        let cands = g.candidates(BiasGraph::ROOT);
        let (mut b3, mut b2) = (Vec::new(), Vec::new());
        m3.bonuses(&d3, &z, &l, &cands, &mut Scratch::default(), &mut b3);
        m2.bonuses(&d2, &z, &l, &cands, &mut Scratch::default(), &mut b2);
        assert_ne!(b3, b2);
    }

    #[test]
    fn l3s_equals_l3_without_children() {
        if !lf_cpu::cpu_supported() {
            return;
        }
        let pool = ThreadPool::new(&[0]);
        let t = random_tensors(Variant::L3, 12, 0.8, false);
        let m3 = LearnedModel::from_tensors(Variant::L3, 1.0, t.clone()).unwrap();
        let m3s = LearnedModel::from_tensors(Variant::L3S, 1.0, t).unwrap();
        let (z, l) = decision(5);
        let bonuses = |m: &LearnedModel, g: &BiasGraph, s: BiasState| {
            let d = m.prepare(&pool, &TrieFeatures::new(g), 4);
            let mut b = Vec::new();
            m.bonuses(
                &d,
                &z,
                &l,
                &g.candidates(s),
                &mut Scratch::default(),
                &mut b,
            );
            b
        };
        // One-token phrases: every scored node is a leaf.
        let leaves = graph(&[&[3], &[17], &[500], &[1023]]);
        assert_eq!(
            bonuses(&m3, &leaves, BiasGraph::ROOT),
            bonuses(&m3s, &leaves, BiasGraph::ROOT)
        );
        // With children the messages matter.
        let deep = small_graph();
        assert_ne!(
            bonuses(&m3, &deep, BiasGraph::ROOT),
            bonuses(&m3s, &deep, BiasGraph::ROOT)
        );
    }

    #[test]
    fn zero_final_layers_give_zero_bonus() {
        if !lf_cpu::cpu_supported() {
            return;
        }
        let pool = ThreadPool::new(&[0]);
        let g = small_graph();
        let f = TrieFeatures::new(&g);
        for variant in Variant::ALL {
            let m = model(variant, 3, 0.0, true);
            let dict = m.prepare(&pool, &f, 6);
            let (z, l) = decision(8);
            let cands = g.candidates(BiasGraph::ROOT);
            let scorer = LearnedScorer::new(&m, &dict, 2.0, None);
            let mut out = Vec::new();
            scorer.score(BiasGraph::ROOT, &z, &l, &cands, &mut out);
            assert_eq!(out.len(), cands.len());
            assert!(
                out.iter()
                    .zip(&cands)
                    .all(|(o, c)| o.0 == c.0 && o.1 == 0.0)
            );
        }
    }

    #[test]
    fn scorer_scales_by_lambda_and_counts() {
        if !lf_cpu::cpu_supported() {
            return;
        }
        let pool = ThreadPool::new(&[0]);
        let g = small_graph();
        let f = TrieFeatures::new(&g);
        let m = model(Variant::L3, 2, 0.3, false);
        let dict = m.prepare(&pool, &f, 6);
        let (z, l) = decision(6);
        let cands = g.candidates(g.step(0, 10).0);
        let mut b = Vec::new();
        m.bonuses(&dict, &z, &l, &cands, &mut Scratch::default(), &mut b);
        let stats = ScorerStats::default();
        let scorer = LearnedScorer::new(&m, &dict, 1.41, Some(&stats));
        let mut out = Vec::new();
        scorer.score(0, &z, &l, &cands, &mut out);
        scorer.score(0, &z, &l, &cands, &mut Vec::new());
        for ((t, v), (&(ct, _), &bv)) in out.iter().zip(cands.iter().zip(&b)) {
            assert_eq!((*t, *v), (ct, 1.41 * bv));
            assert!(bv.abs() <= 8.0);
        }
        assert_eq!(stats.calls.load(Ordering::Relaxed), 2);
        assert_eq!(
            stats.candidates.load(Ordering::Relaxed),
            2 * cands.len() as u64
        );
    }

    /// Checks one of P's parity fixtures (CONTRACT-2 NOTES, "P (Python
    /// side)"): trie features, candidates, b within 1e-4·(1+|b|) and the
    /// fused argmax at λ = 1. Returns the worst |Δb| / (1+|b|).
    fn check_parity_fixture(path: &Path) -> f64 {
        let st = SafeTensors::open(path).unwrap();
        let fx = |k: &str| format!("fx.{k}");
        let i32s = |k: &str| st.i32_vec(&fx(k)).unwrap();
        let f32s = |k: &str| st.f32_vec(&fx(k)).unwrap();
        // The model: every tensor outside `fx.`, through the strict loader.
        let mut tensors = Tensors::new();
        for (name, info) in &st.tensors {
            if !name.starts_with("fx.") {
                tensors.insert(
                    name.clone(),
                    (info.shape.clone(), st.f32_vec(name).unwrap()),
                );
            }
        }
        assert_eq!(st.metadata["format"], FORMAT);
        assert_eq!(st.metadata["d"], "512");
        let variant = Variant::parse(&st.metadata["variant"]).unwrap();
        let lambda: f32 = st.metadata["lambda"].parse().unwrap();
        let model = LearnedModel::from_tensors(variant, lambda, tensors).unwrap();
        // The dictionary.
        let (toks, offs) = (i32s("phrase.tokens"), i32s("phrase.offset"));
        let phrases: Vec<Vec<usize>> = offs
            .windows(2)
            .map(|w| {
                toks[w[0] as usize..w[1] as usize]
                    .iter()
                    .map(|&t| t as usize)
                    .collect()
            })
            .collect();
        let g = graph(&phrases.iter().map(Vec::as_slice).collect::<Vec<_>>());
        let f = TrieFeatures::new(&g);
        let u32s = |k: &str| i32s(k).into_iter().map(|v| v as u32).collect::<Vec<_>>();
        assert_eq!(f.token, u32s("trie.token"), "{variant:?} trie tokens");
        assert_eq!(f.parent, i32s("trie.parent"));
        assert_eq!(f.depth, u32s("trie.depth"));
        assert_eq!(
            f.is_end,
            i32s("trie.is_end")
                .iter()
                .map(|&v| v != 0)
                .collect::<Vec<_>>()
        );
        assert_eq!(f.dmin, u32s("trie.dmin"));
        assert_eq!(f.dmax, u32s("trie.dmax"));
        assert_eq!(f.nends, u32s("trie.nends"));
        let nf: Vec<f32> = f.nf.iter().flatten().copied().collect();
        for (a, b) in nf.iter().zip(f32s("trie.nf")) {
            assert!((a - b).abs() <= 1e-6, "nf {a} vs {b}");
        }
        let entries = i32s("entries")[0] as usize;
        assert!((g_size(entries) - f32s("g_size")[0]).abs() <= 1e-7);
        // The decisions.
        let pool = ThreadPool::new(&[0]);
        let dict = model.prepare(&pool, &f, entries);
        let (states, z, logits) = (i32s("dec.state"), f32s("dec.z"), f32s("dec.logits"));
        let (coff, ctok, cdest) = (i32s("cand.offset"), i32s("cand.token"), i32s("cand.dest"));
        let (cx, want, argmax) = (
            f32s("cand.x"),
            f32s("expected_bonus"),
            i32s("expected_argmax"),
        );
        let rows = logits.len() / states.len();
        let mut worst = 0.0f64;
        for (i, &s) in states.iter().enumerate() {
            let cands = g.candidates(s as BiasState);
            let r = coff[i] as usize..coff[i + 1] as usize;
            let expected: Vec<(u32, BiasState)> = r
                .clone()
                .map(|k| (ctok[k] as u32, cdest[k] as BiasState))
                .collect();
            assert_eq!(cands, expected, "{variant:?} decision {i}: candidates");
            let (zi, li) = (&z[i * J..(i + 1) * J], &logits[i * rows..(i + 1) * rows]);
            let stats = LogitStats::new(li);
            for (k, &(y, n)) in r.clone().zip(&cands) {
                let lf = stats.features(li[y as usize]);
                let x: Vec<f32> = f.nf[n as usize]
                    .iter()
                    .chain(&lf)
                    .copied()
                    .chain([dict.g_size])
                    .collect();
                for (a, b) in x.iter().zip(&cx[k * NX..(k + 1) * NX]) {
                    assert!(
                        (a - b).abs() <= 1e-5 * (1.0 + b.abs()),
                        "{variant:?} x {a} vs {b}"
                    );
                }
            }
            let mut b = Vec::new();
            model.bonuses(&dict, zi, li, &cands, &mut Scratch::default(), &mut b);
            let mut fused: Vec<f64> = li[..V].iter().map(|&v| v as f64).collect();
            for (k, (&(y, _), &got)) in r.zip(cands.iter().zip(&b)) {
                let w = want[k] as f64;
                let err = (got as f64 - w).abs() / (1.0 + w.abs());
                worst = worst.max(err);
                assert!(
                    err <= 1e-4,
                    "{variant:?} decision {i} token {y}: b {got} vs {w}"
                );
                fused[y as usize] += got as f64;
            }
            let best = (0..V).fold(0, |m, t| if fused[t] > fused[m] { t } else { m });
            assert_eq!(
                best as i32, argmax[i],
                "{variant:?} decision {i}: fused argmax"
            );
        }
        worst
    }

    /// P's parity fixtures: the committed L1 copy always; every variant from
    /// `$LF_PARITY_FIXTURES`, else `$LF_EXP2_ROOT/fixtures`, when one is set
    /// (skipped otherwise).
    #[test]
    fn matches_the_python_parity_fixtures() {
        if !lf_cpu::cpu_supported() {
            return;
        }
        let committed =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/parity-L1.safetensors");
        let worst = check_parity_fixture(&committed);
        eprintln!("committed L1 fixture: worst |Δb|/(1+|b|) = {worst:.2e}");
        let dir = match (
            std::env::var_os("LF_PARITY_FIXTURES"),
            std::env::var_os("LF_EXP2_ROOT"),
        ) {
            (Some(d), _) => std::path::PathBuf::from(d),
            (None, Some(r)) => std::path::PathBuf::from(r).join("fixtures"),
            (None, None) => {
                eprintln!("SKIPPED the L2/L3/L3S fixtures: set LF_PARITY_FIXTURES or LF_EXP2_ROOT");
                return;
            }
        };
        for v in Variant::ALL {
            let p = Path::new(&dir).join(format!("parity-{}.safetensors", v.name()));
            if p.exists() {
                let worst = check_parity_fixture(&p);
                eprintln!("{}: worst |Δb|/(1+|b|) = {worst:.2e}", p.display());
            } else {
                eprintln!(
                    "SKIPPED {}: not present (set LF_PARITY_FIXTURES)",
                    p.display()
                );
            }
        }
    }

    #[test]
    fn exp_fast_is_accurate() {
        let mut worst = 0.0f64;
        for i in 0..=87_000 {
            let x = -(i as f32) / 1000.0;
            let want = (x as f64).exp();
            worst = worst.max((exp_fast(x) as f64 - want).abs() / want);
        }
        assert!(worst < 4e-7, "max relative exp error {worst}");
        assert_eq!(exp_fast(0.0), 1.0);
        assert!(exp_fast(-200.0) < 1e-37);
    }

    #[test]
    fn model_files_are_strict() {
        for variant in Variant::ALL {
            let t = random_tensors(variant, 1, 0.0, true);
            let bytes = model_file_bytes(variant, 0.71, &t);
            let st = SafeTensors::parse(bytes).unwrap();
            let m = LearnedModel::from_safetensors(&st).unwrap();
            assert_eq!((m.variant(), m.lambda()), (variant, 0.71));
            let count: usize = t.values().map(|(s, _)| s.iter().product::<usize>()).sum();
            assert_eq!(m.parameters(), count);
            // Missing, extra and misshapen tensors are refused.
            let mut missing = t.clone();
            missing.pop_last();
            assert!(LearnedModel::from_tensors(variant, 1.0, missing).is_err());
            let mut extra = t.clone();
            extra.insert("extra.weight".into(), (vec![1], vec![0.0]));
            assert!(LearnedModel::from_tensors(variant, 1.0, extra).is_err());
            let mut bad = t.clone();
            let (name, (shape, v)) = bad.pop_first().unwrap();
            let mut shape = shape;
            shape.reverse();
            shape.push(1);
            bad.insert(name, (shape, v));
            assert!(LearnedModel::from_tensors(variant, 1.0, bad).is_err());
        }
        // A model file of another variant or format is refused.
        let t = random_tensors(Variant::L2, 1, 0.0, true);
        let wrong = model_file_bytes(Variant::L3, 1.0, &t);
        assert!(LearnedModel::from_safetensors(&SafeTensors::parse(wrong).unwrap()).is_err());
        let l3 = random_tensors(Variant::L3, 1, 0.0, true);
        let n3 = LearnedModel::from_tensors(Variant::L3, 1.0, l3)
            .unwrap()
            .parameters();
        let n2 = LearnedModel::from_tensors(Variant::L2, 1.0, t)
            .unwrap()
            .parameters();
        // L3 is about 5-6M parameters; L2 differs by the subtree layers only.
        assert!((5_000_000..6_500_000).contains(&n3), "{n3}");
        assert_eq!(n3 - n2, 3 * D * FF + FF + FF * D + D + 2 * D + 1);
    }
}

//! Ternary GEMM on exact FP32 activations through lookup tables (variant D,
//! experimental).
//!
//! Inputs are taken in groups of three. For a frame `x` and group `g` the 27
//! sums `a * x0 + b * x1 + c * x2` with `a, b, c` in {-1, 0, +1} come in
//! sign pairs, so a 16-float table holds 14 of them, indexed by the
//! non-negative balanced-ternary patterns: entry `j` (a value of either sign)
//! is the sum whose balanced-ternary digits spell `j`
//! (`j = a + 3 * b + 9 * c`). A weight row's three codes form the signed
//! pattern `v = a + 3 * b + 9 * c` in -13..=13, and its contribution is
//! `sign(v) * table[|v|]`. For 16 outputs that is one non-destructive
//! `vpermps` (index `|v|`) and one FMA by a ±1 sign vector, which replaces
//! three FMAs against a {-1, 0, +1} tile. Every sum is FP32: no activation is
//! quantized, and the rounding count per three inputs matches the FMA kernel.
//! The order of additions differs (three inputs are pre-summed), so results
//! are not bit-identical to `gemm_f32`, and finite inputs within a factor of
//! three of `f32::MAX` may overflow where a sequential sum would not. NaN and
//! infinite inputs make every output of their frame non-finite, as in
//! `gemm_f32`.
//!
//! Work layout:
//! - Threads form frame groups (by default `threads / 2`, at most 4; with CPUs
//!   `0..16` that is two groups per CCD). Each group owns a contiguous frame
//!   range and its own tables; its threads split the output panels
//!   (`panel_vectors * 16` rows).
//! - A group walks its frames in chunks ([`Plan`]): one chunk if its tables
//!   fit `table_budget`, otherwise smaller double-buffered chunks, so one
//!   spin barrier per chunk suffices. Its threads first build the chunk's
//!   tables together, then each thread runs its panels against them.
//! - Per panel and per `kc_groups` input groups, the 2-bit codes of
//!   [`PackedTernary`] are expanded into a per-thread tile of sign-extended
//!   `vpermps` indices (4 bytes per weight group and output) that every frame
//!   of the chunk reuses. The microkernel turns bit 31 into the ±1.0 sign
//!   with one `vpternlogd`.
//! - Weights stay in the shared [`PackedTernary`] layout (2 bits per weight);
//!   tables and tiles are transient workspace.
//!
//! Status: exact and tested, but on the 9950X3D it is only about 1.1x faster
//! than the i8x3 kernel on long inputs (from 10 s at 8 threads, from 30 s at
//! 16), slower on short ones, and well behind i8x2; see `linux/PLAN.md`.

use crate::barrier::SpinBarrier;
use crate::pack::{NR, PackedTernary};
use crate::{AlignedBuf, SendPtr, ThreadPool, split_range};

/// Blocking parameters. All are validated by [`LutWorkspace::new`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LutConfig {
    /// Output vectors (16 rows each) per microkernel: 4 or 8.
    pub panel_vectors: usize,
    /// Frames per microkernel call: 1..=6 with 4 vectors, 1..=3 with 8.
    pub micro_frames: usize,
    /// Most frames whose tables are built and consumed together.
    pub chunk_frames: usize,
    /// Table bytes a frame group may keep live. A group whose frames all fit
    /// uses one chunk; otherwise chunks shrink so both buffers fit. The one
    /// exception: a buffer always holds at least one `micro_frames` block, so
    /// a budget below two blocks is exceeded.
    pub table_budget: usize,
    /// Input groups (of three) per expanded tile; a multiple of 4.
    pub kc_groups: usize,
    /// Thread groups that split the frames, each with its own tables; 0 picks
    /// `threads / 2` groups, at most 4. Falls back to 1 if it does not divide the
    /// thread count.
    pub frame_groups: usize,
}

impl Default for LutConfig {
    /// Tuned on the 9950X3D (see `linux/PLAN.md`, "Lookup-table kernel").
    fn default() -> Self {
        LutConfig {
            panel_vectors: 8,
            micro_frames: 3,
            chunk_frames: 256,
            table_budget: 9 << 20,
            kc_groups: 128,
            frame_groups: 0,
        }
    }
}

impl LutConfig {
    pub fn validate(&self) -> Result<(), String> {
        let max_frames = match self.panel_vectors {
            4 => 6,
            8 => 3,
            v => return Err(format!("panel_vectors must be 4 or 8, not {v}")),
        };
        if !(1..=max_frames).contains(&self.micro_frames) {
            return Err(format!(
                "micro_frames must be 1..={max_frames} with {} panel vectors",
                self.panel_vectors
            ));
        }
        if self.chunk_frames == 0 || self.chunk_frames > 4096 {
            return Err("chunk_frames must be 1..=4096".into());
        }
        if self.table_budget > 1 << 32 {
            return Err("table_budget must be at most 4 GiB".into());
        }
        if self.kc_groups == 0 || !self.kc_groups.is_multiple_of(4) || self.kc_groups > 4096 {
            return Err("kc_groups must be a positive multiple of 4, at most 4096".into());
        }
        if self.frame_groups > 64 {
            return Err("frame_groups must be 0 (auto) or 1..=64".into());
        }
        Ok(())
    }

    /// Frame groups actually used with `threads` threads.
    pub fn groups_for(&self, threads: usize) -> usize {
        let fg = match self.frame_groups {
            0 => (threads / 2).clamp(1, 4),
            n => n,
        };
        if threads.is_multiple_of(fg) { fg } else { 1 }
    }
}

/// How one call splits its frames.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Plan {
    /// Frame groups (each with its own tables).
    pub groups: usize,
    /// Frames per chunk.
    pub chunk: usize,
    /// Table buffers per group: 1 if a group's frames fit one chunk, else 2.
    pub buffers: usize,
    /// Floats per table buffer.
    pub buffer_floats: usize,
}

impl Plan {
    pub fn new(cfg: &LutConfig, threads: usize, t: usize, cols: usize) -> Plan {
        let groups = cfg.groups_for(threads);
        let per_frame = table_bytes_per_frame(cols);
        let mf = cfg.micro_frames;
        // Buffers hold whole `mf`-frame blocks.
        let rounded = |frames: usize| frames.div_ceil(mf) * mf;
        let group_frames = t.div_ceil(groups).max(1);
        let (chunk, buffers) = if group_frames <= cfg.chunk_frames
            && crate::size(rounded(group_frames), per_frame) <= cfg.table_budget
        {
            (group_frames, 1)
        } else {
            let fit = cfg.table_budget / crate::size(2, per_frame);
            let chunk = cfg.chunk_frames.min(fit).min(group_frames);
            // Whole blocks where possible, so rounding stays within the budget.
            let chunk = if chunk >= mf { chunk / mf * mf } else { chunk };
            (chunk.max(1), 2)
        };
        let buffer_floats = crate::size(
            crate::size(chunk.div_ceil(mf) * mf, padded_groups(cols)),
            16,
        );
        Plan {
            groups,
            chunk,
            buffers,
            buffer_floats,
        }
    }

    /// Table bytes per frame group.
    pub fn table_bytes(&self) -> usize {
        crate::size(crate::size(self.buffers, self.buffer_floats), 4)
    }
}

/// Input groups of three for `cols` inputs, padded to a multiple of 4 so the
/// expansion always handles whole 12-input (3-byte) steps.
pub fn padded_groups(cols: usize) -> usize {
    cols.div_ceil(3).next_multiple_of(4)
}

/// Bytes of one frame's tables for `cols` inputs.
pub fn table_bytes_per_frame(cols: usize) -> usize {
    crate::size(padded_groups(cols), 64)
}

/// Reusable buffers for [`gemm`]: per-thread tiles and per-group tables. They
/// grow on demand to the largest call seen. [`gemm`] takes `&mut`, so no two
/// calls can ever share them.
pub struct LutWorkspace {
    cfg: LutConfig,
    tiles: Vec<AlignedBuf>,
    tables: Vec<AlignedBuf>,
}

impl LutWorkspace {
    pub fn new(cfg: LutConfig) -> Result<Self, String> {
        cfg.validate()?;
        Ok(LutWorkspace {
            cfg,
            tiles: Vec::new(),
            tables: Vec::new(),
        })
    }

    pub fn config(&self) -> LutConfig {
        self.cfg
    }

    /// Bytes currently allocated.
    pub fn bytes(&self) -> usize {
        self.tiles
            .iter()
            .chain(&self.tables)
            .map(AlignedBuf::len)
            .sum()
    }

    fn tile_bytes(&self) -> usize {
        crate::size(
            crate::size(self.cfg.kc_groups, self.cfg.panel_vectors),
            TILE_VEC,
        )
    }

    /// Grows the buffers for `threads` threads in `groups` frame groups, with
    /// `table_bytes` bytes of tables per group.
    fn ensure(&mut self, threads: usize, groups: usize, table_bytes: usize) {
        let tile = self.tile_bytes();
        if self.tiles.len() < threads {
            self.tiles.resize_with(threads, || AlignedBuf::new(tile));
        }
        if self.tables.len() < groups {
            self.tables.resize_with(groups, || AlignedBuf::new(0));
        }
        for t in &mut self.tables[..groups] {
            if t.len() < table_bytes {
                *t = AlignedBuf::new(table_bytes);
            }
        }
    }
}

/// `y[t][o] = scale[o] * sum_i code(o, i) * x[t][i]` for `t` frames of `x`
/// (`[t][w.cols()]`) into `y` (`[t][w.rows()]`).
pub fn gemm(
    pool: &ThreadPool,
    ws: &mut LutWorkspace,
    w: &PackedTernary,
    x: &[f32],
    t: usize,
    y: &mut [f32],
) {
    assert!(crate::cpu_supported(), "AVX-512 F/BW/VBMI required");
    let (k, o) = (w.cols(), w.rows());
    assert!(x.len() >= crate::size(t, k) && y.len() >= crate::size(t, o));
    if t == 0 {
        return;
    }
    let cfg = ws.cfg;
    let threads = pool.threads();
    let plan = Plan::new(&cfg, threads, t, k);
    let (fg, fc, nbuf, half) = (plan.groups, plan.chunk, plan.buffers, plan.buffer_floats);
    let tg = threads / fg;
    let gp = padded_groups(k);
    let mf = cfg.micro_frames;
    // Tables are laid out `[frame block][group][frame in block][16]` with
    // `mf`-frame blocks, so each microkernel call reads one contiguous stream.
    ws.ensure(threads, fg, plan.table_bytes());
    let tile_bytes = ws.tile_bytes();

    let blocks = w.blocks();
    let bpp = cfg.panel_vectors / 4;
    let panels = blocks.div_ceil(bpp);
    let quads = w.quads();
    let tiles: Vec<SendPtr<u8>> = ws
        .tiles
        .iter_mut()
        .map(|b| SendPtr(b.as_mut_ptr()))
        .collect();
    let tables: Vec<SendPtr<f32>> = ws.tables[..fg]
        .iter_mut()
        .map(|b| SendPtr(b.as_mut_ptr().cast::<f32>()))
        .collect();
    let barriers: Vec<SpinBarrier> = (0..fg).map(|_| SpinBarrier::new(tg)).collect();
    let yp = SendPtr(y.as_mut_ptr());
    let xp = SendPtr(x.as_ptr().cast_mut());
    let kcg = cfg.kc_groups;
    debug_assert!(tile_bytes >= kcg * bpp * 4 * TILE_VEC);

    pool.run(&|idx| {
        let (gi, ti) = (idx / tg, idx % tg);
        let frames = split_range(t, fg, gi);
        let tile = tiles[idx].get();
        let x = xp.get().cast_const();
        let mut chunk = 0;
        let mut f0 = frames.start;
        while f0 < frames.end {
            let nf = fc.min(frames.end - f0);
            // With one buffer the group has exactly one chunk. With two, the
            // buffer written here was last read for chunk `chunk - 2`, and
            // every thread of the group finished that before it reached the
            // barrier of chunk `chunk - 1`, which this thread has passed.
            debug_assert!(nbuf == 2 || chunk == 0);
            let tab = unsafe { tables[gi].get().add((chunk % nbuf) * half) };
            // Each thread writes only its own input groups' tables.
            unsafe {
                x86::build_tables(x.add(f0 * k), k, nf, split_range(gp, tg, ti), gp, mf, tab)
            };
            barriers[gi].wait();
            let mut g0 = 0;
            while g0 < gp {
                let ng = kcg.min(gp - g0);
                let last = g0 + ng == gp;
                for p in split_range(panels, tg, ti) {
                    let b0 = p * bpp;
                    let nb = bpp.min(blocks - b0);
                    let nv = nb * 4;
                    for pb in 0..nb {
                        unsafe {
                            x86::expand_block(
                                w.block(b0 + pb),
                                quads,
                                g0,
                                ng,
                                nv * TILE_VEC,
                                pb * 4,
                                tile,
                            )
                        };
                    }
                    let mut fl = 0;
                    while fl < nf {
                        let rows = mf.min(nf - fl);
                        unsafe {
                            x86::kernel_for(nv, rows)(
                                tile,
                                tab.add(((fl / mf) * gp + g0) * mf * 16),
                                mf * 16,
                                ng,
                                yp.get().add((f0 + fl) * o + b0 * NR),
                                o,
                                g0 > 0,
                                if last {
                                    w.scale().as_ptr().add(b0 * NR)
                                } else {
                                    std::ptr::null()
                                },
                            )
                        };
                        fl += rows;
                    }
                }
                g0 += ng;
            }
            f0 += nf;
            chunk += 1;
        }
    });
}

/// Tile bytes per (group, 16 outputs): 16 sign-extended i32 indices. Storing
/// a separate ±1.0 sign vector instead doubled the tile and measured 4-19%
/// slower at 16 threads, depending on `kc_groups`.
const TILE_VEC: usize = 64;

/// Byte per 6-bit code pattern (three 2-bit codes, first input lowest):
/// `|v|` in the low bits and the sign of `v` in bit 7.
const PATTERN: [u8; 64] = {
    let mut out = [0u8; 64];
    let mut p = 0;
    while p < 64 {
        let mut v: i32 = 0;
        let mut place = 1;
        let mut i = 0;
        while i < 3 {
            v += place
                * match (p >> (2 * i)) & 3 {
                    1 => 1,
                    2 => -1,
                    _ => 0,
                };
            place *= 3;
            i += 1;
        }
        out[p] = if v < 0 { 0x80 | (-v) as u8 } else { v as u8 };
        p += 1;
    }
    out
};

/// `DIGITS[i][j]`: balanced-ternary digit `i` of table entry `j` (0 for the
/// unused entries 14 and 15).
const DIGITS: [[f32; 16]; 3] = {
    let mut out = [[0.0f32; 16]; 3];
    let mut j = 0;
    while j < 14 {
        let mut r = j as i32;
        let mut i = 0;
        while i < 3 {
            let d = (r + 1).rem_euclid(3) - 1;
            out[i][j] = d as f32;
            r = (r - d) / 3;
            i += 1;
        }
        j += 1;
    }
    out
};

// Explicit index loops over const-sized accumulator arrays unroll into registers.
#[cfg(target_arch = "x86_64")]
#[allow(clippy::needless_range_loop, clippy::too_many_arguments)]
mod x86 {
    use super::{DIGITS, PATTERN, TILE_VEC};
    use std::arch::x86_64::*;

    type Kernel = unsafe fn(*const u8, *const f32, usize, usize, *mut f32, usize, bool, *const f32);

    pub fn kernel_for(vectors: usize, frames: usize) -> Kernel {
        match (vectors, frames) {
            (4, 1) => kernel::<4, 1>,
            (4, 2) => kernel::<4, 2>,
            (4, 3) => kernel::<4, 3>,
            (4, 4) => kernel::<4, 4>,
            (4, 5) => kernel::<4, 5>,
            (4, 6) => kernel::<4, 6>,
            (8, 1) => kernel::<8, 1>,
            (8, 2) => kernel::<8, 2>,
            (8, 3) => kernel::<8, 3>,
            _ => unreachable!("no kernel for {vectors} vectors x {frames} frames"),
        }
    }

    /// Tables for `nf` frames (`x` at the chunk's first frame, `k` per row)
    /// and the input groups in `groups`, stored at
    /// `tab[((f / mf * gp + g) * mf + f % mf) * 16]`. Inputs past `k` count as zero.
    #[target_feature(enable = "avx512f")]
    pub unsafe fn build_tables(
        x: *const f32,
        k: usize,
        nf: usize,
        groups: std::ops::Range<usize>,
        gp: usize,
        mf: usize,
        tab: *mut f32,
    ) {
        let d: [__m512; 3] =
            std::array::from_fn(|i| unsafe { _mm512_loadu_ps(DIGITS[i].as_ptr()) });
        // Groups wholly inside `k` need no bounds checks.
        let full = groups.start.max(groups.end.min(k / 3));
        for f0 in (0..nf).step_by(mf) {
            let fb = f0 / mf;
            let n = mf.min(nf - f0);
            for g in groups.start..full {
                let out = unsafe { tab.add((fb * gp + g) * mf * 16) };
                for fi in 0..n {
                    let p = unsafe { x.add((f0 + fi) * k + 3 * g) };
                    let s = _mm512_mul_ps(_mm512_set1_ps(unsafe { *p }), d[0]);
                    let s = _mm512_fmadd_ps(_mm512_set1_ps(unsafe { *p.add(1) }), d[1], s);
                    let s = _mm512_fmadd_ps(_mm512_set1_ps(unsafe { *p.add(2) }), d[2], s);
                    unsafe { _mm512_store_ps(out.add(fi * 16), s) };
                }
            }
            for g in full..groups.end {
                let out = unsafe { tab.add((fb * gp + g) * mf * 16) };
                for fi in 0..n {
                    let row = unsafe { x.add((f0 + fi) * k) };
                    let v = |i: usize| {
                        if 3 * g + i < k {
                            _mm512_set1_ps(unsafe { *row.add(3 * g + i) })
                        } else {
                            _mm512_setzero_ps()
                        }
                    };
                    let s = _mm512_mul_ps(v(0), d[0]);
                    let s = _mm512_fmadd_ps(v(1), d[1], s);
                    let s = _mm512_fmadd_ps(v(2), d[2], s);
                    unsafe { _mm512_store_ps(out.add(fi * 16), s) };
                }
            }
        }
    }

    /// Expands groups `g0..g0 + ng` (`g0` and `ng` multiples of 4) of one
    /// 64-row block into the tile: group `gl = g - g0`, vector `v` (16 rows)
    /// goes to `dst[gl * stride + (vbase + v) * TILE_VEC]` as 16 i32: `|v|` in
    /// bits 0..4 (all `vpermps` reads) and the sign of `v` in bits 7..32.
    /// Quads past `quads` count as zero.
    #[target_feature(enable = "avx512f,avx512bw,avx512vbmi")]
    pub unsafe fn expand_block(
        src: &[u8],
        quads: usize,
        g0: usize,
        ng: usize,
        stride: usize,
        vbase: usize,
        dst: *mut u8,
    ) {
        debug_assert!(g0.is_multiple_of(4) && ng.is_multiple_of(4));
        let lut = unsafe { _mm512_loadu_si512(PATTERN.as_ptr().cast()) };
        let low2 = _mm512_set1_epi8(0x03);
        let low4 = _mm512_set1_epi8(0x0f);
        let load = |q: usize| {
            if q < quads {
                unsafe { _mm512_loadu_si512(src.as_ptr().add(q * 64).cast()) }
            } else {
                _mm512_setzero_si512()
            }
        };
        for m in 0..ng / 4 {
            // 12 inputs = 3 code bytes per row; groups sit at bits 0, 6, 12, 18.
            // `vpermb` reads only the low 6 bits of each index byte, so bits
            // shifted in from the neighbouring byte of a 16-bit lane are harmless.
            let q = 3 * (g0 / 4 + m);
            let (b0, b1, b2) = (load(q), load(q + 1), load(q + 2));
            // 0xE4: c ? a : b.
            let pats = [
                b0,
                _mm512_ternarylogic_epi32::<0xE4>(
                    _mm512_srli_epi16::<6>(b0),
                    _mm512_slli_epi16::<2>(b1),
                    low2,
                ),
                _mm512_ternarylogic_epi32::<0xE4>(
                    _mm512_srli_epi16::<4>(b1),
                    _mm512_slli_epi16::<4>(b2),
                    low4,
                ),
                _mm512_srli_epi16::<2>(b2),
            ];
            for (j, &p) in pats.iter().enumerate() {
                let bytes = _mm512_permutexvar_epi8(p, lut);
                let lanes = [
                    _mm512_extracti32x4_epi32::<0>(bytes),
                    _mm512_extracti32x4_epi32::<1>(bytes),
                    _mm512_extracti32x4_epi32::<2>(bytes),
                    _mm512_extracti32x4_epi32::<3>(bytes),
                ];
                let base = unsafe { dst.add((4 * m + j) * stride) };
                for (v, &lane) in lanes.iter().enumerate() {
                    // Sign extension keeps |v| in bits 0..4 and smears the sign
                    // from bit 7 to bit 31.
                    let index = _mm512_cvtepi8_epi32(lane);
                    unsafe { _mm512_store_si512(base.add((vbase + v) * TILE_VEC).cast(), index) };
                }
            }
        }
    }

    /// `F` frames x `V` vectors of accumulators over `ng` groups.
    #[target_feature(enable = "avx512f")]
    unsafe fn kernel<const V: usize, const F: usize>(
        tile: *const u8,
        tab: *const f32,
        tab_stride: usize,
        ng: usize,
        y: *mut f32,
        ldy: usize,
        accumulate: bool,
        scale: *const f32,
    ) {
        let sign_bit = _mm512_set1_epi32(i32::MIN);
        let one = _mm512_set1_epi32(1.0f32.to_bits() as i32);
        let mut acc = [[_mm512_setzero_ps(); V]; F];
        for g in 0..ng {
            let tb = unsafe { tab.add(g * tab_stride) };
            let tables: [__m512; F] =
                std::array::from_fn(|f| unsafe { _mm512_load_ps(tb.add(f * 16)) });
            let tp = unsafe { tile.add(g * V * TILE_VEC) };
            for v in 0..V {
                let index = unsafe { _mm512_load_si512(tp.add(v * TILE_VEC).cast()) };
                // 0xEA: (a & b) | c, i.e. the sign bit of the index on 1.0.
                let sign =
                    _mm512_castsi512_ps(_mm512_ternarylogic_epi32::<0xEA>(index, sign_bit, one));
                for f in 0..F {
                    let t = _mm512_permutexvar_ps(index, tables[f]);
                    acc[f][v] = _mm512_fmadd_ps(t, sign, acc[f][v]);
                }
            }
        }
        for f in 0..F {
            for v in 0..V {
                let p = unsafe { y.add(f * ldy + v * 16) };
                let mut out = acc[f][v];
                if accumulate {
                    out = _mm512_add_ps(out, unsafe { _mm512_loadu_ps(p) });
                }
                if !scale.is_null() {
                    out = _mm512_mul_ps(out, unsafe { _mm512_loadu_ps(scale.add(v * 16)) });
                }
                unsafe { _mm512_storeu_ps(p, out) };
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gemm_ref::{compare, reference};
    use lf_model::TernaryMatrix;
    use lf_model::rng::SplitMix64;
    use lf_model::ternary::code_value;

    #[test]
    fn pattern_and_digit_tables_agree() {
        for (p, &b) in PATTERN.iter().enumerate() {
            let codes: [u8; 3] = std::array::from_fn(|i| ((p >> (2 * i)) & 3) as u8);
            if codes.contains(&3) {
                continue;
            }
            let j = (b & 0x0f) as usize;
            let sign = if b & 0x80 != 0 { -1.0 } else { 1.0 };
            assert_eq!(b & 0x70, 0, "pattern {p}");
            assert!(j < 14);
            for (i, &c) in codes.iter().enumerate() {
                assert_eq!(sign * DIGITS[i][j], code_value(c) as f32, "pattern {p}");
            }
        }
        for row in &DIGITS {
            assert_eq!(row[14], 0.0);
            assert_eq!(row[15], 0.0);
        }
    }

    #[test]
    fn config_validation() {
        assert!(LutConfig::default().validate().is_ok());
        let bad = [
            LutConfig {
                panel_vectors: 6,
                ..Default::default()
            },
            LutConfig {
                panel_vectors: 8,
                micro_frames: 4,
                ..Default::default()
            },
            LutConfig {
                micro_frames: 0,
                ..Default::default()
            },
            LutConfig {
                kc_groups: 6,
                ..Default::default()
            },
            LutConfig {
                chunk_frames: 0,
                ..Default::default()
            },
            LutConfig {
                frame_groups: 65,
                ..Default::default()
            },
            LutConfig {
                table_budget: (1 << 32) + 1,
                ..Default::default()
            },
        ];
        for cfg in bad {
            assert!(LutWorkspace::new(cfg).is_err(), "{cfg:?}");
        }
    }

    #[test]
    fn plan_picks_groups_and_chunks() {
        let cfg = LutConfig::default();
        assert_eq!(cfg.groups_for(16), 4);
        assert_eq!(cfg.groups_for(8), 4);
        assert_eq!(cfg.groups_for(1), 1);
        assert_eq!(cfg.groups_for(6), 3);
        assert_eq!(cfg.groups_for(5), 1);
        let explicit = LutConfig {
            frame_groups: 3,
            ..cfg
        };
        assert_eq!(explicit.groups_for(6), 3);
        assert_eq!(explicit.groups_for(8), 1);
        // A group's frames fit the budget: one chunk, one buffer.
        let p = Plan::new(&cfg, 16, 375, 4096);
        assert_eq!((p.groups, p.chunk, p.buffers), (4, 94, 1));
        assert!(p.table_bytes() <= cfg.table_budget);
        // Too many frames: chunks shrink so two buffers fit the budget.
        let p = Plan::new(&cfg, 16, 750, 4096);
        assert_eq!(p.buffers, 2);
        assert!(p.chunk >= cfg.micro_frames && p.table_bytes() <= cfg.table_budget);
        // The budget holds for every shape once it covers two blocks,
        // including the padding to whole `micro_frames` blocks.
        for mf in 1..=6 {
            let c = LutConfig {
                panel_vectors: 4,
                micro_frames: mf,
                table_budget: 1 << 20,
                ..cfg
            };
            for t in 1..300 {
                for cols in [24, 1024, 4096] {
                    let p = Plan::new(&c, 1, t, cols);
                    let block = 2 * mf * table_bytes_per_frame(cols);
                    if block <= c.table_budget {
                        assert!(p.table_bytes() <= c.table_budget, "mf={mf} t={t} {cols}");
                    }
                    assert!(p.chunk >= 1 && p.chunk <= t);
                }
            }
        }
        // A zero budget still makes progress, one frame at a time.
        let tiny = LutConfig {
            table_budget: 0,
            ..cfg
        };
        let p = Plan::new(&tiny, 1, 10, 24);
        assert_eq!((p.chunk, p.buffers), (1, 2));
    }

    /// Non-finite activations poison every output of their frames, as in
    /// `gemm_f32` (`0 * inf` and `0 * NaN` are NaN in both), and other frames
    /// stay exact. Finite inputs near `f32::MAX` are outside the supported
    /// range: pre-summing three inputs can overflow where a sequential sum
    /// would not.
    #[test]
    fn non_finite_inputs_stay_in_their_frames() {
        if !crate::cpu_supported() {
            return;
        }
        // 32 inputs: the last group (30, 31 and padding) is partial.
        let k = 32;
        let m = TernaryMatrix::random(64, k, 4);
        let w = PackedTernary::new(&m).unwrap();
        let pool = ThreadPool::new(&[0, 1]);
        let mut ws = LutWorkspace::new(LutConfig {
            chunk_frames: 2,
            table_budget: 0,
            ..Default::default()
        })
        .unwrap();
        let mut rng = SplitMix64::new(3);
        let t = 5;
        let mut x: Vec<f32> = (0..t * k).map(|_| rng.next_gaussian()).collect();
        // One-frame chunks alternate between the two buffers, so frames 3
        // and 4 reuse the buffers that frames 1 (NaN) and 2 (+Inf) poisoned.
        x[k + 7] = f32::NAN;
        x[2 * k + 31] = f32::INFINITY;
        let mut y = vec![0.0; t * 64];
        gemm(&pool, &mut ws, &w, &x, t, &mut y);
        assert_eq!(
            Plan::new(&ws.config(), 2, t, k).chunk,
            1,
            "test relies on one-frame chunks"
        );
        for f in 0..t {
            let row = &y[f * 64..(f + 1) * 64];
            if f == 1 || f == 2 {
                assert!(row.iter().all(|v| !v.is_finite()), "frame {f}");
            } else {
                let xf = &x[f * k..(f + 1) * k];
                let (rel, _) = compare(row, &reference(&m, xf, 1));
                assert!(rel < 1e-6, "frame {f}: {rel}");
            }
        }
    }

    fn check(m: &TernaryMatrix, cfg: LutConfig, threads: usize, frames: &[usize], seed: u64) {
        let w = PackedTernary::new(m).unwrap();
        let pool = ThreadPool::new(&(0..threads).collect::<Vec<_>>());
        let mut ws = LutWorkspace::new(cfg).unwrap();
        let mut rng = SplitMix64::new(seed);
        for &t in frames {
            let x: Vec<f32> = (0..t * m.cols)
                .map(|i| rng.next_gaussian() * if i % 97 == 0 { 12.0 } else { 1.0 })
                .collect();
            // Stale values in y must not leak into the result.
            let mut y = vec![f32::NAN; t * m.rows];
            gemm(&pool, &mut ws, &w, &x, t, &mut y);
            let (rel, worst) = compare(&y, &reference(m, &x, t));
            assert!(
                rel < 1e-6 && worst < 1e-5,
                "{}x{} t={t} threads={threads} {cfg:?}: rel={rel} worst={worst}",
                m.rows,
                m.cols
            );
        }
    }

    #[test]
    fn matches_reference_on_odd_shapes() {
        if !crate::cpu_supported() {
            return;
        }
        // Columns: 4 (one partial group), 8, 12 (one exact expansion step),
        // 100 and 1100 (not multiples of 3 or 12), 1024.
        let shapes = [
            (64, 4),
            (64, 8),
            (128, 12),
            (192, 100),
            (64, 1100),
            (320, 1024),
        ];
        for (si, &(rows, cols)) in shapes.iter().enumerate() {
            let m = TernaryMatrix::random(rows, cols, 10 + si as u64);
            check(&m, LutConfig::default(), 1, &[1, 6, 11], si as u64);
        }
    }

    #[test]
    fn matches_reference_across_configs_and_threads() {
        if !crate::cpu_supported() {
            return;
        }
        let m = TernaryMatrix::random(192, 196, 21);
        let mut seed = 0;
        for panel_vectors in [4, 8] {
            let max = if panel_vectors == 4 { 6 } else { 3 };
            for micro_frames in 1..=max {
                // Budgets: unlimited (one chunk per group), and zero (one-frame
                // chunks, double buffered).
                for (chunk_frames, table_budget, kc_groups) in
                    [(3, usize::MAX >> 32, 4), (7, 0, 8), (64, 1 << 20, 64)]
                {
                    for (threads, frame_groups) in [(1, 1), (2, 2), (3, 1), (4, 2), (3, 2), (4, 0)]
                    {
                        let cfg = LutConfig {
                            panel_vectors,
                            micro_frames,
                            chunk_frames,
                            table_budget,
                            kc_groups,
                            frame_groups,
                        };
                        seed += 1;
                        check(&m, cfg, threads, &[1, 2, 13], seed);
                    }
                }
            }
        }
    }

    #[test]
    fn workspace_is_reused_across_shapes() {
        if !crate::cpu_supported() {
            return;
        }
        let pool = ThreadPool::new(&[0, 1]);
        let mut ws = LutWorkspace::new(LutConfig {
            chunk_frames: 5,
            frame_groups: 2,
            ..Default::default()
        })
        .unwrap();
        let mut rng = SplitMix64::new(9);
        for (rows, cols, t) in [(64, 24, 3), (128, 400, 17), (64, 24, 30), (192, 400, 1)] {
            let m = TernaryMatrix::random(rows, cols, rows as u64 + cols as u64);
            let w = PackedTernary::new(&m).unwrap();
            let x: Vec<f32> = (0..t * cols).map(|_| rng.next_gaussian()).collect();
            let mut y = vec![0.0; t * rows];
            gemm(&pool, &mut ws, &w, &x, t, &mut y);
            let (rel, _) = compare(&y, &reference(&m, &x, t));
            assert!(rel < 1e-6, "{rows}x{cols} t={t}: {rel}");
        }
        assert!(ws.bytes() > 0);
    }

    #[test]
    fn zero_frames_is_a_no_op() {
        if !crate::cpu_supported() {
            return;
        }
        let m = TernaryMatrix::random(64, 12, 1);
        let w = PackedTernary::new(&m).unwrap();
        let pool = ThreadPool::new(&[0]);
        let mut ws = LutWorkspace::new(LutConfig::default()).unwrap();
        let mut y: Vec<f32> = Vec::new();
        gemm(&pool, &mut ws, &w, &[], 0, &mut y);
    }

    #[test]
    #[should_panic]
    fn short_input_is_rejected() {
        let m = TernaryMatrix::random(64, 12, 1);
        let w = PackedTernary::new(&m).unwrap();
        let pool = ThreadPool::new(&[0]);
        let mut ws = LutWorkspace::new(LutConfig::default()).unwrap();
        let mut y = vec![0.0; 2 * 64];
        gemm(&pool, &mut ws, &w, &[0.0; 12], 2, &mut y);
    }
}

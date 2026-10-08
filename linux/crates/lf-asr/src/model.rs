//! Weights from a verified export, converted once into kernel layouts.

use lf_cpu::PackedTernary;
use lf_cpu::decoder::{DecoderParams, PackedDecoder, Storage};
use lf_cpu::dense::Panels;
use lf_model::{Error, Export, Result, SafeTensors, TernaryMatrix};

use crate::config::*;
use crate::tokenizer::Tokenizer;

pub struct Norm {
    pub gamma: Vec<f32>,
    pub beta: Vec<f32>,
}

pub struct Layer {
    pub norm_ff1: Norm,
    pub norm_att: Norm,
    pub norm_conv: Norm,
    pub norm_ff2: Norm,
    pub norm_out: Norm,
    pub ff1: [PackedTernary; 2],
    pub ff2: [PackedTernary; 2],
    pub q: PackedTernary,
    pub k: PackedTernary,
    pub v: PackedTernary,
    pub pos: PackedTernary,
    pub out: PackedTernary,
    pub pw1: PackedTernary,
    pub pw2: PackedTernary,
    /// `[heads][d_head]`.
    pub bias_u: Vec<f32>,
    pub bias_v: Vec<f32>,
    /// Depthwise time convolution with batch norm folded in: `[k][d]` and `[d]`.
    pub dw_w: Vec<f32>,
    pub dw_b: Vec<f32>,
}

pub struct Subsampling {
    /// conv0 (1 -> 256) and the two depthwise convs, tap-major `[9][256]`.
    pub w0: Vec<f32>,
    pub b0: Vec<f32>,
    pub w2: Vec<f32>,
    pub b2: Vec<f32>,
    pub w5: Vec<f32>,
    pub b5: Vec<f32>,
    /// Pointwise convs as `[256 out][256 in]` panels.
    pub p3: Panels,
    pub b3: Vec<f32>,
    pub p6: Panels,
    pub b6: Vec<f32>,
    /// Output projection with input columns reordered from NeMo's
    /// `channel * 16 + freq` to our channel-last `freq * 256 + channel`.
    pub out: Panels,
    pub out_b: Vec<f32>,
}

pub struct Frontend {
    /// Real DFT of a 400-sample window: columns `0..257` cos, `257..514` sin.
    pub dft: Panels,
    /// Mel filterbank `[128][257]` as panels.
    pub mel: Panels,
    pub window: Vec<f32>,
}

pub struct Model {
    pub frontend: Frontend,
    pub sub: Subsampling,
    pub layers: Vec<Layer>,
    pub decoder: PackedDecoder,
    pub tokenizer: Tokenizer,
}

fn tensor(st: &SafeTensors, name: &str, shape: &[usize]) -> Result<Vec<f32>> {
    let (s, v) = st.float_vec(name)?;
    if s != shape {
        return Err(Error(format!("{name}: shape {s:?}, expected {shape:?}")));
    }
    Ok(v)
}

fn ternary(st: &SafeTensors, name: &str, rows: usize, cols: usize) -> Result<PackedTernary> {
    let m = TernaryMatrix::from_export(st, name)?;
    if m.rows != rows || m.cols != cols {
        return Err(Error(format!(
            "{name}: {}x{}, expected {rows}x{cols}",
            m.rows, m.cols
        )));
    }
    PackedTernary::new(&m)
}

/// `[256][1][3][3]` (out, in, dt, df) to tap-major `[9][256]`.
fn taps(w: &[f32]) -> Vec<f32> {
    let mut out = vec![0.0; 9 * SUB_CHANNELS];
    for c in 0..SUB_CHANNELS {
        for tap in 0..9 {
            out[tap * SUB_CHANNELS + c] = w[c * 9 + tap];
        }
    }
    out
}

impl Model {
    pub fn load(export: &Export, decoder_storage: Storage) -> Result<Self> {
        crate::config::validate(&export.manifest.config)?;
        let st = &export.tensors;
        let tokenizer = Tokenizer::from_vocab_file(
            &export.read_verified("tokenizer/tokenizer.vocab")?,
            export
                .manifest
                .config
                .pointer("/joint/vocabulary")
                .and_then(|v| v.as_array())
                .map(Vec::as_slice),
        )?;
        let frontend = load_frontend(st)?;
        let sub = load_subsampling(st)?;
        let layers = (0..LAYERS)
            .map(|l| load_layer(st, l))
            .collect::<Result<Vec<_>>>()?;
        let params = DecoderParams::from_export(st, DURATIONS.to_vec())?;
        if params.vocab != VOCAB + 1 || params.enc_dim != D_MODEL {
            return Err(Error("decoder shapes disagree with the encoder".into()));
        }
        let decoder = PackedDecoder::new(&params, decoder_storage);
        Ok(Model {
            frontend,
            sub,
            layers,
            decoder,
            tokenizer,
        })
    }
}

fn load_frontend(st: &SafeTensors) -> Result<Frontend> {
    let bins = N_FFT / 2 + 1;
    let fb = tensor(st, "preprocessor.featurizer.fb", &[1, FEATURES, bins])?;
    let window = tensor(st, "preprocessor.featurizer.window", &[WIN_LENGTH])?;
    // DFT basis B[m][j]: torch centres the 400-sample window in the 512-point
    // frame (offset 56); that circular shift only changes phase, not power.
    let mut basis = vec![0.0f32; WIN_LENGTH * 2 * bins];
    for m in 0..WIN_LENGTH {
        for j in 0..bins {
            let angle = 2.0 * std::f64::consts::PI * ((j * m) % N_FFT) as f64 / N_FFT as f64;
            basis[m * 2 * bins + j] = angle.cos() as f32;
            basis[m * 2 * bins + bins + j] = angle.sin() as f32;
        }
    }
    let mut dft = Panels::default();
    dft.pack_cols(&basis, WIN_LENGTH, 2 * bins, 2 * bins);
    let mut mel = Panels::default();
    mel.pack_rows(&fb, FEATURES, bins, bins);
    Ok(Frontend { dft, mel, window })
}

fn load_subsampling(st: &SafeTensors) -> Result<Subsampling> {
    let c = SUB_CHANNELS;
    let get = |i: usize, shape: &[usize]| {
        tensor(st, &format!("encoder.pre_encode.conv.{i}.weight"), shape)
    };
    let bias = |i: usize| tensor(st, &format!("encoder.pre_encode.conv.{i}.bias"), &[c]);
    let pointwise = |i: usize| -> Result<Panels> {
        let w = get(i, &[c, c, 1, 1])?;
        let mut p = Panels::default();
        p.pack_rows(&w, c, c, c);
        Ok(p)
    };
    let freq = 16; // 128 -> 64 -> 32 -> 16
    let w_out = tensor(st, "encoder.pre_encode.out.weight", &[D_MODEL, c * freq])?;
    let mut permuted = vec![0.0f32; D_MODEL * c * freq];
    for o in 0..D_MODEL {
        for ch in 0..c {
            for f in 0..freq {
                permuted[o * c * freq + f * c + ch] = w_out[o * c * freq + ch * freq + f];
            }
        }
    }
    let mut out = Panels::default();
    out.pack_rows(&permuted, D_MODEL, c * freq, c * freq);
    Ok(Subsampling {
        w0: taps(&get(0, &[c, 1, 3, 3])?),
        b0: bias(0)?,
        w2: taps(&get(2, &[c, 1, 3, 3])?),
        b2: bias(2)?,
        w5: taps(&get(5, &[c, 1, 3, 3])?),
        b5: bias(5)?,
        p3: pointwise(3)?,
        b3: bias(3)?,
        p6: pointwise(6)?,
        b6: bias(6)?,
        out,
        out_b: tensor(st, "encoder.pre_encode.out.bias", &[D_MODEL])?,
    })
}

fn load_layer(st: &SafeTensors, l: usize) -> Result<Layer> {
    let p = format!("encoder.layers.{l}");
    let norm = |name: &str| -> Result<Norm> {
        Ok(Norm {
            gamma: tensor(st, &format!("{p}.{name}.weight"), &[D_MODEL])?,
            beta: tensor(st, &format!("{p}.{name}.bias"), &[D_MODEL])?,
        })
    };
    let t = |name: &str, rows: usize, cols: usize| ternary(st, &format!("{p}.{name}"), rows, cols);
    // Fold eval-mode batch norm into the depthwise convolution (no conv bias).
    let dw = tensor(
        st,
        &format!("{p}.conv.depthwise_conv.weight"),
        &[D_MODEL, 1, CONV_KERNEL],
    )?;
    let bn = |name: &str| tensor(st, &format!("{p}.conv.batch_norm.{name}"), &[D_MODEL]);
    let (gamma, beta, mean, var) = (
        bn("weight")?,
        bn("bias")?,
        bn("running_mean")?,
        bn("running_var")?,
    );
    let mut dw_w = vec![0.0f32; CONV_KERNEL * D_MODEL];
    let mut dw_b = vec![0.0f32; D_MODEL];
    for c in 0..D_MODEL {
        let s = gamma[c] as f64 / (var[c] as f64 + BN_EPS).sqrt();
        for j in 0..CONV_KERNEL {
            dw_w[j * D_MODEL + c] = (dw[c * CONV_KERNEL + j] as f64 * s) as f32;
        }
        dw_b[c] = (beta[c] as f64 - mean[c] as f64 * s) as f32;
    }
    Ok(Layer {
        norm_ff1: norm("norm_feed_forward1")?,
        norm_att: norm("norm_self_att")?,
        norm_conv: norm("norm_conv")?,
        norm_ff2: norm("norm_feed_forward2")?,
        norm_out: norm("norm_out")?,
        ff1: [
            t("feed_forward1.linear1", D_FF, D_MODEL)?,
            t("feed_forward1.linear2", D_MODEL, D_FF)?,
        ],
        ff2: [
            t("feed_forward2.linear1", D_FF, D_MODEL)?,
            t("feed_forward2.linear2", D_MODEL, D_FF)?,
        ],
        q: t("self_attn.linear_q", D_MODEL, D_MODEL)?,
        k: t("self_attn.linear_k", D_MODEL, D_MODEL)?,
        v: t("self_attn.linear_v", D_MODEL, D_MODEL)?,
        pos: t("self_attn.linear_pos", D_MODEL, D_MODEL)?,
        out: t("self_attn.linear_out", D_MODEL, D_MODEL)?,
        pw1: t("conv.pointwise_conv1", 2 * D_MODEL, D_MODEL)?,
        pw2: t("conv.pointwise_conv2", D_MODEL, D_MODEL)?,
        bias_u: tensor(st, &format!("{p}.self_attn.pos_bias_u"), &[HEADS, D_HEAD])?,
        bias_v: tensor(st, &format!("{p}.self_attn.pos_bias_v"), &[HEADS, D_HEAD])?,
        dw_w,
        dw_b,
    })
}

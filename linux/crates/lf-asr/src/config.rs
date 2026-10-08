//! The architecture this crate implements, checked against the export's NeMo
//! config so a different model fails loudly instead of decoding garbage.

use serde_json::Value;

use lf_model::{Error, Result};

pub const SAMPLE_RATE: usize = 16_000;
pub const WIN_LENGTH: usize = 400;
pub const HOP_LENGTH: usize = 160;
pub const N_FFT: usize = 512;
pub const FEATURES: usize = 128;
pub const PREEMPH: f32 = 0.97;
pub const LOG_GUARD: f32 = 5.960_464_5e-8; // 2^-24
pub const NORM_EPS: f32 = 1e-5;

pub const LAYERS: usize = 24;
pub const D_MODEL: usize = 1024;
pub const HEADS: usize = 8;
pub const D_HEAD: usize = D_MODEL / HEADS;
pub const D_FF: usize = 4 * D_MODEL;
pub const CONV_KERNEL: usize = 9;
pub const SUB_CHANNELS: usize = 256;
pub const BN_EPS: f64 = 1e-5;

pub const VOCAB: usize = 1024;
pub const DURATIONS: [usize; 5] = [0, 1, 2, 3, 4];

/// Checks every config value the implementation hard-codes.
pub fn validate(cfg: &Value) -> Result<()> {
    let checks: &[(&str, Value)] = &[
        ("/preprocessor/sample_rate", SAMPLE_RATE.into()),
        ("/preprocessor/normalize", "per_feature".into()),
        ("/preprocessor/window_size", 0.025.into()),
        ("/preprocessor/window_stride", 0.01.into()),
        ("/preprocessor/window", "hann".into()),
        ("/preprocessor/features", FEATURES.into()),
        ("/preprocessor/n_fft", N_FFT.into()),
        ("/preprocessor/log", true.into()),
        ("/preprocessor/frame_splicing", 1.into()),
        ("/preprocessor/pad_to", 0.into()),
        ("/encoder/feat_in", FEATURES.into()),
        ("/encoder/n_layers", LAYERS.into()),
        ("/encoder/d_model", D_MODEL.into()),
        ("/encoder/use_bias", false.into()),
        ("/encoder/subsampling", "dw_striding".into()),
        ("/encoder/subsampling_factor", 8.into()),
        ("/encoder/subsampling_conv_channels", SUB_CHANNELS.into()),
        ("/encoder/causal_downsampling", false.into()),
        ("/encoder/ff_expansion_factor", 4.into()),
        ("/encoder/self_attention_model", "rel_pos".into()),
        ("/encoder/n_heads", HEADS.into()),
        ("/encoder/att_context_size", serde_json::json!([-1, -1])),
        ("/encoder/xscaling", false.into()),
        ("/encoder/untie_biases", true.into()),
        ("/encoder/conv_kernel_size", CONV_KERNEL.into()),
        ("/encoder/conv_norm_type", "batch_norm".into()),
        ("/decoder/blank_as_pad", true.into()),
        ("/decoder/vocab_size", VOCAB.into()),
        ("/decoder/prednet/pred_hidden", 640.into()),
        ("/decoder/prednet/pred_rnn_layers", 2.into()),
        ("/joint/jointnet/joint_hidden", 640.into()),
        ("/joint/jointnet/activation", "relu".into()),
        ("/joint/num_extra_outputs", DURATIONS.len().into()),
        ("/joint/num_classes", VOCAB.into()),
        ("/decoding/durations", serde_json::json!(DURATIONS)),
        ("/decoding/model_type", "tdt".into()),
        (
            "/decoding/greedy/max_symbols",
            lf_cpu::decoder::MAX_SYMBOLS_PER_FRAME.into(),
        ),
        ("/encoder/conv_context_size", Value::Null),
    ];
    // Greedy decoding only (NeMo's batched and single greedy agree for one utterance).
    match cfg.pointer("/decoding/strategy").and_then(Value::as_str) {
        Some("greedy" | "greedy_batch") => {}
        other => {
            return Err(Error(format!(
                "model config /decoding/strategy is {other:?}, expected greedy"
            )));
        }
    }
    for (path, want) in checks {
        let got = cfg.pointer(path);
        let same = match (got, want) {
            (Some(Value::Number(a)), Value::Number(b)) => a.as_f64() == b.as_f64(),
            (Some(g), w) => g == w,
            (None, _) => false,
        };
        if !same {
            return Err(Error(format!(
                "model config {path} is {got:?}, expected {want}"
            )));
        }
    }
    // Optional keys that must keep their defaults if present.
    let defaults: &[(&str, Value)] = &[
        ("/preprocessor/exact_pad", false.into()),
        ("/preprocessor/mel_norm", "slaney".into()),
        ("/preprocessor/mag_power", 2.0.into()),
        ("/preprocessor/log_zero_guard_type", "add".into()),
        (
            "/preprocessor/log_zero_guard_value",
            (LOG_GUARD as f64).into(),
        ),
        ("/preprocessor/preemph", 0.97.into()),
        ("/preprocessor/lowfreq", 0.into()),
        ("/preprocessor/highfreq", Value::Null),
        ("/preprocessor/nb_augmentation_prob", 0.0.into()),
        ("/encoder/reduction", Value::Null),
    ];
    for (path, want) in defaults {
        if let Some(got) = cfg.pointer(path) {
            let same = match (got, want) {
                (Value::Number(a), Value::Number(b)) => a.as_f64() == b.as_f64(),
                (g, w) => g == w,
            };
            if !same {
                return Err(Error(format!(
                    "model config {path} is {got}, expected {want}"
                )));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn valid() -> Value {
        json!({
            "preprocessor": {"sample_rate": 16000, "normalize": "per_feature", "window_size": 0.025,
                "window_stride": 0.01, "window": "hann", "features": 128, "n_fft": 512, "log": true,
                "frame_splicing": 1, "pad_to": 0, "dither": 1e-5},
            "encoder": {"feat_in": 128, "n_layers": 24, "d_model": 1024, "use_bias": false,
                "subsampling": "dw_striding", "subsampling_factor": 8, "subsampling_conv_channels": 256,
                "causal_downsampling": false, "ff_expansion_factor": 4, "self_attention_model": "rel_pos",
                "n_heads": 8, "att_context_size": [-1, -1], "xscaling": false, "untie_biases": true,
                "conv_kernel_size": 9, "conv_norm_type": "batch_norm", "conv_context_size": null,
                "reduction": null},
            "decoder": {"blank_as_pad": true, "vocab_size": 1024,
                "prednet": {"pred_hidden": 640, "pred_rnn_layers": 2}},
            "joint": {"jointnet": {"joint_hidden": 640, "activation": "relu"},
                "num_extra_outputs": 5, "num_classes": 1024},
            "decoding": {"strategy": "greedy_batch", "model_type": "tdt", "durations": [0, 1, 2, 3, 4],
                "greedy": {"max_symbols": 10}}
        })
    }

    #[test]
    fn accepts_the_supported_architecture_and_rejects_changes() {
        validate(&valid()).unwrap();
        for (path, bad) in [
            ("/preprocessor/preemph", json!(0.9)),
            ("/preprocessor/log_zero_guard_value", json!(1e-6)),
            ("/encoder/conv_context_size", json!([4, 4])),
            ("/decoding/strategy", json!("beam")),
            ("/decoding/greedy/max_symbols", json!(5)),
            ("/encoder/n_heads", json!(4)),
        ] {
            let mut cfg = valid();
            let (parent, key) = path.rsplit_once('/').unwrap();
            cfg.pointer_mut(parent)
                .unwrap()
                .as_object_mut()
                .unwrap()
                .insert(key.into(), bad);
            assert!(validate(&cfg).is_err(), "{path} should be rejected");
        }
        // Explicit defaults are fine.
        let mut cfg = valid();
        let pre = cfg
            .pointer_mut("/preprocessor")
            .unwrap()
            .as_object_mut()
            .unwrap();
        pre.insert("preemph".into(), json!(0.97));
        pre.insert("log_zero_guard_value".into(), json!(2f64.powi(-24)));
        validate(&cfg).unwrap();
    }
}

"""Benchmark-only graph adapted from wilderness-labs-stt ios/mlxarm/encoder.py.

MIT-licensed upstream inference code; see Resources/Parakeet/Software-LICENSE.
Uses the same masking/FP16 graph, with linear biases read from the shipped MIL.
No export loader, tokenizer, provider, or model download is included.
"""
import math

GROUP, BITS = 64, 2
D_MODEL, HEADS, D_K, SUB_CH, KERNEL = 1024, 8, 128, 256, 9
LN_EPS, NEG = 1e-5, -10000.0

def _qlinear(x, w):
    import mlx.core as mx

    wq, scales, biases, linear_bias = w
    return mx.quantized_matmul(x, wq, scales, biases, transpose=True, group_size=GROUP, bits=BITS) + linear_bias


def _halve(L):
    return (L - 1) // 2 + 1


def _rel_shift(x, t: int):
    """x [H, T, 2T - 1] -> [H, T, T] (reference rel_shift followed by [..., :T])."""
    import mlx.core as mx

    h = x.shape[0]
    x = mx.pad(x, [(0, 0), (0, 0), (1, 0)])
    x = x.reshape(h, 2 * t, t)[:, 1:, :]
    return x.reshape(h, t, 2 * t - 1)[:, :, :t]


def _layer(W, L: dict, x, att_bad, pad_bad, pos, t: int):
    import mlx.core as mx

    dt = W.dt

    def ln(v, norm):
        g, b = L[norm]
        return mx.fast.layer_norm(v, g, b, LN_EPS)

    def ff(v, which):
        h = _qlinear(v, L[f"feed_forward{which}.linear1"])
        h = h * mx.sigmoid(h)
        h = _qlinear(h, L[f"feed_forward{which}.linear2"])
        return h * mx.array(0.5, dtype=dt)

    res = x + ff(ln(x, "norm_feed_forward1"), 1)
    xa = ln(res, "norm_self_att")
    q = _qlinear(xa, L["self_attn.linear_q"]).reshape(t, HEADS, D_K)
    k = _qlinear(xa, L["self_attn.linear_k"]).reshape(t, HEADS, D_K).transpose(1, 0, 2)
    v = _qlinear(xa, L["self_attn.linear_v"]).reshape(t, HEADS, D_K).transpose(1, 0, 2)
    qu = (q + L["pos_bias_u"]).transpose(1, 0, 2)
    qv = (q + L["pos_bias_v"]).transpose(1, 0, 2)
    ac = qu @ k.transpose(0, 2, 1)
    bd = _rel_shift(qv @ pos, t)
    scores = (ac + bd) * mx.array(1.0 / math.sqrt(D_K), dtype=dt)
    scores = mx.where(att_bad, mx.array(NEG, dtype=dt), scores)
    attn = mx.where(att_bad, mx.array(0, dtype=dt), mx.softmax(scores, axis=-1, precise=True))
    out = (attn @ v).transpose(1, 0, 2).reshape(t, D_MODEL)
    res = res + _qlinear(out, L["self_attn.linear_out"])
    h = _qlinear(ln(res, "norm_conv"), L["conv.pointwise_conv1"])            # [T, 2048]
    h = h[:, :D_MODEL] * mx.sigmoid(h[:, D_MODEL:])                          # GLU
    h = mx.where(pad_bad[:, None], mx.array(0, dtype=dt), h)
    h = mx.conv1d(h[None], L["dw_w"], stride=1, padding=(KERNEL - 1) // 2, groups=D_MODEL)[0] + L["dw_b"]
    h = h * mx.sigmoid(h)
    res = res + _qlinear(h, L["conv.pointwise_conv2"])
    res = res + ff(ln(res, "norm_feed_forward2"), 2)
    return ln(res, "norm_out")


def forward(W, mel, mel_length, bucket: int):
    """mel [128, F_b] (compute dtype), mel_length int32 [] -> (encoder float32 [1024, T_b], encoder_length int32 [])."""
    import mlx.core as mx

    dt = W.dt
    f = mel.shape[1]
    x = mel.T[None, :, :, None]                                              # NHWC [1, F, 128, 1]
    L = mel_length
    x = x * (mx.arange(f) < L).astype(dt)[None, :, None, None]
    x = mx.conv2d(x, W.sub["w0"], stride=2, padding=1) + W.sub["b0"]
    x = mx.maximum(x, mx.array(0, dtype=dt))
    L = _halve(L)
    for stage in (1, 2):
        x = x * (mx.arange(x.shape[1]) < L).astype(dt)[None, :, None, None]
        x = mx.conv2d(x, W.sub[f"dw{stage}"], stride=2, padding=1, groups=SUB_CH) + W.sub[f"dwb{stage}"]
        x = mx.conv2d(x, W.sub[f"pw{stage}"]) + W.sub[f"pwb{stage}"]
        x = mx.maximum(x, mx.array(0, dtype=dt))
        L = _halve(L)
    t = x.shape[1]
    x = x * (mx.arange(t) < L).astype(dt)[None, :, None, None]
    x = x.transpose(0, 1, 3, 2).reshape(t, SUB_CH * x.shape[2])               # [T, 256 x 16] channel-major
    x = x @ W.sub["out_w"].T + W.sub["out_b"]
    valid = mx.arange(t) < L
    att_bad = mx.logical_not(valid[:, None] & valid[None, :])[None]           # [1, T, T]
    pad_bad = mx.logical_not(valid)
    for i in range(W.n_layers):
        x = _layer(W, W.layers[i], x, att_bad, pad_bad, W.pos[bucket][i], t)
    return x.T.astype(mx.float32), L

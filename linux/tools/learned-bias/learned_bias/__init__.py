"""Training-only tooling for LocalFlow word-boosting experiment 2.

A learned biasing module (L1/L2/L3) over the dictionary prefix tree; see
CONTRACT-2.md for the binding interfaces. Nothing here runs in the app: the
Rust side (lf-bench `learned.rs`) implements the forward pass for decoding.
"""

# Contract constants (CONTRACT-2 §2, §3).
D = 512
HEADS = 8
J = 640
V = 1025
BLANK = 1024
FF = 1024
HID = 64
NF = 5
NX = 10
DEPTH_EMB = 16
DMAX_CAP = 32
FORMAT = "lf-learned-bias-v1"
LN_EPS = 1e-5
SEED = 20261011

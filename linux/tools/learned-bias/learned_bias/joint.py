"""Base logits ℓ = W_out·relu(f+g) + b_out (CONTRACT-2 §4), with the joint
output weight rounded to f16 exactly as `Storage::F16` stores it (round to
nearest even) and f32 accumulation. The bias stays f32, as in Rust."""

import torch
from safetensors import safe_open

from . import V

W_KEY = "joint.joint_net.2.weight"  # [1025 + 5 durations, 640], F16 in the export
B_KEY = "joint.joint_net.2.bias"  # [1030]


def f16_round(w):
    """f32 -> nearest f16 (ties to even) -> f32."""
    return w.to(torch.float32).to(torch.float16).to(torch.float32)


class JointOutput:
    def __init__(self, weight, bias, device="cpu"):
        self.weight = f16_round(torch.as_tensor(weight)).to(device)
        self.bias = torch.as_tensor(bias).to(device=device, dtype=torch.float32)
        if self.weight.shape[0] != self.bias.shape[0] or self.weight.shape[0] < V:
            raise ValueError(f"joint output shapes {tuple(self.weight.shape)} {tuple(self.bias.shape)}")

    @staticmethod
    def from_export(path, device="cpu"):
        """`path`: the export's weights file or its directory."""
        from .provenance import export_paths

        _, weights = export_paths(path)
        with safe_open(str(weights), framework="pt", device="cpu") as f:
            return JointOutput(f.get_tensor(W_KEY), f.get_tensor(B_KEY), device)

    def rows(self, z):
        """All output rows (tokens and durations) for z [B, J]."""
        return torch.addmm(self.bias, z, self.weight.t())

    def token_logits(self, z):
        """The 1025 token rows (blank last)."""
        return torch.addmm(self.bias[:V], z, self.weight[:V].t())

"""Harness factory for W1 scorers (W0 convention `MODULE:CALLABLE`, string args).

    ./python -m lfspk.harness.evaluate run --set dev-v1 --scorer lfspk.embed.factory:make \
        --arg embedder=titanet-s --arg window=1.5 --arg hop=0.25 --arg norm=asnorm \
        --arg rule=robust --arg head=score [--arg C=1.0] [--arg device=cpu]

`head` is "score" (score-only logistic head) or "all" (full feature head);
the head file and the gates are read from W1's run directories
(`head.py` output, `adapt` gates) and must exist: a factory never fits
anything on the data it is about to be evaluated on. The scorer's name
encodes every choice, so result directories are unambiguous.
"""

from __future__ import annotations

from pathlib import Path

from .. import paths
from .scorer import Cohort, EmbeddingScorer, Head, ScorerConfig, UpdateConfig, WindowConfig


def scorer_name(embedder: str, window: float, hop: float, norm: str, rule: str, head: str, C: float) -> str:
    return f"w1-{embedder}-L{window}-H{hop}-{norm}-{rule}-{head}-C{C}"


def make(embedder: str, window: str = "1.5", hop: str = "0.25", norm: str = "asnorm", rule: str = "robust",
         head: str = "score", C: str = "1.0", device: str = "cpu", runs: str = "", smoke: str = "0",
         cache: str = "0") -> EmbeddingScorer:
    """Everything (head, gates, cohort) is resolved beneath ONE run root
    (`runs`, default RUNS/W1): head/<tag>/..., adapt/train/<embedder>/gates_<norm>.json
    and survey/emb/<embedder>/. Unless smoke=1, the head's provenance sidecar
    and the gates must come from real committed runs. cache=N keeps the
    scoring-window embeddings of N recordings (identical scores; use 0 for
    latency measurements)."""
    import json

    from .adapt import check_upstream, load_gates
    from .head import _tag

    L, H, c = float(window), float(hop), float(C)
    is_smoke = smoke not in ("0", "", "false", "False")
    root = Path(runs) if runs else paths.RUNS / "W1"
    head_file = root / "head" / _tag(embedder, L, H) / f"head_{norm}_{rule}_{head}_C{c}.json"
    if not head_file.is_file():
        raise FileNotFoundError(f"no fitted head {head_file}; run `lfspk.embed.head fit` first")
    sidecar = head_file.with_suffix(".meta.json")
    prov = json.loads(sidecar.read_text()) if sidecar.is_file() else {}
    check_upstream({"git": prov.get("git", "unknown"), "smoke": prov.get("smoke", True)}, is_smoke, str(head_file))
    upd = UpdateConfig(rule=rule)
    if rule != "naive":
        g = load_gates(embedder, norm, is_smoke, root=root / "adapt")
        upd = UpdateConfig(rule=rule, window_gate=g["window_gate"], dictation_gate=g["dictation_gate"],
                           anchor_gate=g["anchor_gate"], drift_floor=g["drift_floor"])
    cfg = ScorerConfig(embedder, WindowConfig(L, H), norm=norm, update=upd,
                       head=Head.from_json(head_file.read_text()),
                       name=scorer_name(embedder, L, H, norm, rule, head, c))
    cohort = (Cohort.from_survey(embedder, L, root / "survey", update_s=cfg.update_window.window_s)
              if norm == "asnorm" else None)
    return EmbeddingScorer(cfg, cohort=cohort, device=device, cache_windows=int(cache))

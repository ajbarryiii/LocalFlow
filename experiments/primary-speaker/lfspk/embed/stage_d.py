"""Stage D: the pre-registered configuration grid and selection rule
(DESIGN.md, Stage D), on W0 harness outputs.

  ./python -m lfspk.embed.stage_d plan [--half A]          # one evaluator command per configuration
  ./python -m lfspk.embed.stage_d select --set dev-v1      # the selection rule on half A
  ./python -m lfspk.embed.stage_d report --set dev-v1 --half B|all --names S C50 C15

Paired statistics come from W3's reviewed `lfspk.pvad.compare` (imported
read-only: `system_points`, `paired`, `s0_versus_oracle`), which recalibrates
each system's tau in every joint-speaker resample with W0's weights and seed.
Primary metric m = pooled S1-S4 interferer words kept at the calibrated 0.5 %
budget in the headline condition (builtin, clean, k = 10); S0 has no
interferer words, so this equals the pooled interferer-kept fraction. Cost c =
CostReport.macs_per_audio_second of the configuration.

Rule: B0 = argmin m. Order all configurations by (c, m, name) ascending and
take the first whose paired difference m(config) - m(B0) has a CI lower
bound <= 0 (not significantly worse): that is S. Cheaper configurations:
argmin m (ties to lower c, then name) among c <= 0.5 c(S), and among
c <= 0.15 c(S); empty sets are reported empty.
"""

from __future__ import annotations

import argparse
import itertools
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .. import paths

EMBEDDERS = ("redimnet2-b2", "wespeaker-r34lm", "redimnet2-b0")
WINDOWS = ((1.0, 0.25), (1.0, 0.5), (1.5, 0.25), (1.5, 0.5))
NORMS = ("raw", "asnorm")
HEADS = ("score", "all")
RULE = "robust"
C = 1.0
HEADLINE = ("builtin", False, 10)
METRIC = ("pooled_S1-S4", "interferer_kept/all")
CHEAPER = (0.5, 0.15)
OUT = paths.RUNS / "W1" / "eval"
CACHE = 128  # scoring-window cache size: covers one speaker's mixture traversal (about 70), no thrashing


@dataclass(frozen=True)
class Config:
    embedder: str
    window: float
    hop: float
    norm: str
    head: str

    @property
    def name(self) -> str:
        from .factory import scorer_name

        return scorer_name(self.embedder, self.window, self.hop, self.norm, RULE, self.head, C)

    def kwargs(self, cache: int) -> dict[str, str]:
        return {"embedder": self.embedder, "window": str(self.window), "hop": str(self.hop), "norm": self.norm,
                "rule": RULE, "head": self.head, "C": str(C), "cache": str(cache)}


def grid() -> list[Config]:
    """The 48 pre-stated configurations, in a fixed order."""
    return [Config(e, L, H, n, h) for e, (L, H), n, h in itertools.product(EMBEDDERS, WINDOWS, NORMS, HEADS)]


def result_dir(cfg: Config, set_id: str, half: str) -> Path:
    return OUT / cfg.name / f"{set_id}-{half}"


def select_rule(points: dict[str, float], costs: dict[str, float],
                paired_fn: Callable[[str, str], dict]) -> dict:
    """The pre-registered rule on given half-A points m and costs c.
    `paired_fn(a, b)` returns {"point", "lo", "hi"} for m(a) - m(b)."""
    import math

    names = sorted(points)
    if set(names) != set(costs):
        raise ValueError("points and costs must cover the same configurations")
    bad = [n for n in names if not (math.isfinite(costs[n]) and costs[n] > 0 and math.isfinite(points[n]))]
    if bad:
        raise ValueError(f"non-finite or non-positive cost, or non-finite point, for {bad}")
    b0 = min(names, key=lambda n: (points[n], costs[n], n))
    order = sorted(names, key=lambda n: (costs[n], points[n], n))
    trail = []
    selected = None
    for n in order:
        if n == b0:
            selected = n
            trail.append({"name": n, "vs_b0": None})
            break
        p = paired_fn(n, b0)
        trail.append({"name": n, "vs_b0": p})
        if p["lo"] <= 0:
            selected = n
            break
    out = {"b0": b0, "selected": selected, "comparisons": trail, "cheaper": {}}
    for frac in CHEAPER:
        pool = [n for n in names if costs[n] <= frac * costs[selected]]
        out["cheaper"][str(frac)] = min(pool, key=lambda n: (points[n], costs[n], n)) if pool else None
    return out


def _cost(cfg: Config) -> float:
    from .factory import make

    return float(make(**cfg.kwargs(0)).cost().macs_per_audio_second)


def s0_flag(entry: dict) -> bool:
    """DESIGN Stage D step 5: flagged if the S0 WER increase exceeds the
    oracle's by more than the half-width of the paired CI (reported, not a gate)."""
    lo, hi = entry["relative_ci"]
    return bool(entry["relative"] > (hi - lo) / 2)


def cmd_plan(args) -> None:
    """Scoring runs use the window cache (cache=64). The evaluator's own
    latency in those results.json files is therefore not valid; latency is
    measured by separate `latency` commands with cache=0, printed after."""
    for cfg in grid():
        argv = " ".join(f"--arg {k}={v}" for k, v in cfg.kwargs(CACHE).items())
        print(f"./python -m lfspk.harness.evaluate run --set {args.set} --half {args.half} --workers {args.workers} "
              f"--scorer lfspk.embed.factory:make {argv} --name {cfg.name} --out {result_dir(cfg, args.set, args.half)}")
    from ..harness.evaluate import CPU_ENV

    env = " ".join(f"{k}={v}" for k, v in CPU_ENV.items())  # the evaluator refuses latency without it
    for cfg in grid():
        argv = " ".join(f"--arg {k}={v}" for k, v in cfg.kwargs(0).items())
        print(f"env {env} ./python -m lfspk.harness.evaluate latency --set {args.set} --scorer lfspk.embed.factory:make "
              f"{argv} > {result_dir(cfg, args.set, args.half).parent / 'latency_cache0.json'}")


def cmd_select(args) -> None:
    from ..pvad.compare import paired, system_points
    from .survey import require_clean

    commit = require_clean(args.smoke)
    cfgs = grid()
    dirs = [result_dir(c, args.set, "A") for c in cfgs]
    pts = system_points(args.set, "A", dirs, cond=HEADLINE)
    group, metric = METRIC
    points = {c.name: float(p[group][metric]) for c, p in zip(cfgs, pts)}
    costs = {c.name: _cost(c) for c in cfgs}
    by_name = {c.name: d for c, d in zip(cfgs, dirs)}
    cache: dict = {}

    def paired_fn(a: str, b: str) -> dict:
        if (a, b) not in cache:
            cache[(a, b)] = paired(args.set, "A", by_name[a], by_name[b], cond=HEADLINE, group=group, metric=metric)
        return cache[(a, b)]

    res = select_rule(points, costs, paired_fn)
    res.update({"git": commit, "smoke": args.smoke, "set": args.set, "half": "A", "metric": list(METRIC),
                "points": points, "costs": costs})
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"selection_{args.set}.json").write_text(json.dumps(res, indent=1))
    print(json.dumps({k: res[k] for k in ("b0", "selected", "cheaper")}, indent=1))


def cmd_report(args) -> None:
    """Points, paired differences of the cheaper ones against the selected,
    and S0 against the oracle, for the selected configurations on half B or all."""
    from ..pvad.compare import paired, s0_versus_oracle, system_points
    from .survey import require_clean

    commit = require_clean(args.smoke)
    sel = json.loads((OUT / f"selection_{args.set}.json").read_text())
    names = [n for n in [sel["selected"], *sel["cheaper"].values()] if n]
    if sel["b0"] not in names:  # what choosing a cheaper S cost: S vs B0 on this half
        names.append(sel["b0"])
    by_name = {c.name: result_dir(c, args.set, args.half) for c in grid()}
    dirs = [by_name[n] for n in names]
    pts = system_points(args.set, args.half, dirs, cond=HEADLINE)
    s0 = s0_versus_oracle(args.set, args.half, dirs, cond=HEADLINE)
    pairs = {n: paired(args.set, args.half, by_name[n], by_name[names[0]], cond=HEADLINE, group=METRIC[0],
                       metric=METRIC[1]) for n in names[1:]}
    if sel["b0"] != names[0]:
        pairs["selected_minus_b0"] = paired(args.set, args.half, by_name[names[0]], by_name[sel["b0"]], cond=HEADLINE,
                                            group=METRIC[0], metric=METRIC[1])
    for e in s0:
        e["flagged"] = s0_flag(e)
    res = {"git": commit, "smoke": args.smoke, "set": args.set, "half": args.half, "names": names,
           "label": "selection-free (half B)" if args.half == "B" else "exploratory (full dev includes the selection half A)",
           "latency_note": "use latency_cache0.json; the evaluator's latency in results.json ran with the cache on",
           "points": dict(zip(names, pts)), "s0_vs_oracle": dict(zip(names, s0)), "vs_selected": pairs}
    (OUT / f"report_{args.set}_{args.half}.json").write_text(json.dumps(res, indent=1, default=float))
    print(json.dumps({"names": names, "pairs": pairs}, indent=1, default=float))


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(prog="lfspk.embed.stage_d")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--set", default="dev-v1")
    p.add_argument("--half", default="A")
    p.add_argument("--workers", type=int, default=8)
    for name in ("select", "report"):
        q = sub.add_parser(name)
        q.add_argument("--set", default="dev-v1")
        q.add_argument("--smoke", action="store_true")
        if name == "report":
            q.add_argument("--half", choices=("B", "all"), required=True)
    args = ap.parse_args(argv)
    {"plan": cmd_plan, "select": cmd_select, "report": cmd_report}[args.cmd](args)


if __name__ == "__main__":
    main()

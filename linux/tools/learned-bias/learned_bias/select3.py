"""Experiment 3 selection (DESIGN-3 "Training runs", "Seed replicates").

Three modes, all over runs written by `train.py --checkpoint-steps` and
dev-checked with the mandatory dev command (devcheck.py):

- global (default): the minimum dev objective over every (run, step, λ) of
  the selectable runs, plus the λ = 0 baseline fallback. Every planned
  check of every run must be present and valid under the given dev command,
  with one dev coverage across all runs. Subset controls (runs trained with
  --calls-file, i.e. C) and toy runs are refused: C is never a candidate.
- --within-run RUN: the same rule within one run (reports control C's best).
- --fixed-lambda λ: replicate mode. Reports each run's checkpoints at the
  frozen λ, not a minimum; the output is marked fixed.

Ties go to the baseline, then fewer steps, then the lower lr, then the
--runs order, then λ in grid order.

    python -m learned_bias.select3 --runs A1,A2,A3,B --cmd-file "$LF_EXP2_ROOT/train/devcheck.cmd" \\
        --out "$LF_EXP2_ROOT/train/selection3.json"
    python -m learned_bias.select3 --within-run C --cmd-file ... --out .../selection3-C.json
    python -m learned_bias.select3 --runs R1,R2 --fixed-lambda 1 --cmd-file ... --out .../replicates.json
"""

import argparse
import json
import sys
from pathlib import Path

from .devcheck import LAMBDA_LITERALS, LAMBDAS, DevCheckError, cmd_sha256, revalidate

FROZEN_PLAN = (250, 500, 1000, 1500, 2000, 3000, 4000, 6000)
# The registered search (DESIGN-3 "Training runs"): exactly these arms, L2,
# the full-data pool, training seed 20261011, each with its (lr, horizon).
FROZEN_SEARCH = {
    "A1": {"lr": 1e-3, "horizon_steps": 6000},
    "A2": {"lr": 3e-4, "horizon_steps": 6000},
    "A3": {"lr": 1e-4, "horizon_steps": 6000},
    "B": {"lr": 1e-3, "horizon_steps": 44228},
}
FROZEN_VARIANT = "L2"
FROZEN_TRAIN_SEED = 20261011
BASELINE_RUN = "baseline"


def subset_of(info):
    """How a run's calls were restricted ("calls-file", "call-fraction") or
    None for the full-data pool."""
    if info.get("calls_file"):
        return "calls-file"
    try:
        frac = float((info.get("args") or {}).get("call_fraction", "1.0"))
    except ValueError:
        return "call-fraction"
    return None if frac == 1.0 else "call-fraction"


class SelectionError(RuntimeError):
    def __init__(self, problems):
        self.problems = list(problems)
        super().__init__("refusing to select:\n  " + "\n  ".join(self.problems))


def candidate_key(c, run_order):
    """Total order of candidates: objective, then baseline first, fewer steps,
    lower lr, the --runs order, λ in grid order. Shared with analysis3's
    selection-stability bootstrap."""
    if c["run"] == BASELINE_RUN:
        return (c["objective"], 0, 0, 0.0, -1, -1)
    return (c["objective"], 1, c["step"], c["lr"], run_order.index(c["run"]), LAMBDAS.index(c["lambda"]))


def _load_run(run_dir, cmd, plan, problems, allow_control=False):
    """Validated records of one run: {"name", "info", "records": {step: rec}}
    or None (problems appended)."""
    run_dir = Path(run_dir)
    name = run_dir.name
    path = run_dir / "run.json"
    if not path.exists():
        problems.append(f"{name}: no run.json in {run_dir}")
        return None
    info = json.loads(path.read_text())
    bad = len(problems)
    if info.get("toy"):
        problems.append(f"{name}: a toy run cannot be selected from")
    subset = subset_of(info)
    if subset and not allow_control:
        problems.append(f"{name}: a subset control (--{subset}) is never a selection candidate")
    run_plan = info.get("step_plan")
    if not isinstance(run_plan, list) or not run_plan:
        problems.append(f"{name}: not an experiment-3 run (no step_plan)")
        return None
    plan = list(run_plan) if plan is None else list(plan)
    if run_plan != plan:
        problems.append(f"{name}: step plan {run_plan} != {plan}")
    tags = [f"s{s}" for s in plan]
    if info.get("checkpoints") != tags or info.get("checkpoints_planned") != tags:
        problems.append(f"{name}: checkpoints {info.get('checkpoints')} are not the plan {tags}")
    for k in ("lr", "horizon_steps", "train_seed"):
        if not isinstance(info.get(k), (int, float)) or isinstance(info.get(k), bool):
            problems.append(f"{name}: run.json {k} {info.get(k)!r}")
    if len(problems) > bad:
        return None
    db_path = run_dir / "devcheck.json"
    db = json.loads(db_path.read_text()) if db_path.exists() else {}
    records = {}
    for step, tag in zip(plan, tags):
        rec = db.get(tag)
        if rec is None:
            problems.append(f"{name}: {tag} has no dev check")
            continue
        try:
            records[step] = revalidate(rec, run_dir / f"model-{tag}.safetensors", cmd, info.get("train_df"))
        except DevCheckError as e:
            problems.append(f"{name}: {tag}: {str(e).splitlines()[0]}")
    cov_path = run_dir / "dev_coverage.json"
    cov = json.loads(cov_path.read_text())["coverage"] if cov_path.exists() else None
    if cov is None:
        problems.append(f"{name}: no dev_coverage.json")
    for step, rec in records.items():
        if rec.get("coverage") != cov:
            problems.append(f"{name}: s{step} coverage differs from the run's dev_coverage.json")
    return {"name": name, "dir": str(run_dir.resolve()), "info": info, "records": records, "coverage": cov}


def _load_all(run_dirs, cmd, plan, allow_control=False):
    problems = []
    names = [Path(d).name for d in run_dirs]
    dupes = sorted({n for n in names if names.count(n) > 1})
    if dupes:
        problems.append(f"runs given twice: {dupes}")
    runs = [_load_run(d, cmd, plan, problems, allow_control) for d in run_dirs]
    if problems:
        raise SelectionError(problems)
    covs = {json.dumps(r["coverage"], sort_keys=True) for r in runs}
    if len(covs) != 1:
        problems.append(f"dev coverage differs across runs {names}")
    dfs = {json.dumps(r["info"].get("train_df"), sort_keys=True) for r in runs}
    if len(dfs) != 1:
        problems.append("runs were trained on different DF tables (train_df)")
    variants = {r["info"].get("variant") for r in runs}
    if len(variants) != 1:
        problems.append(f"runs mix variants {sorted(map(str, variants))}")
    if problems:
        raise SelectionError(problems)
    return runs


def _candidates(runs):
    """The baseline, then every (run, step, λ) in run, step, grid order."""
    cands = [{"run": BASELINE_RUN, "step": 0, "lambda": 0.0, "objective": 1.0, "lr": 0.0}]
    for r in runs:
        info = r["info"]
        for step in info["step_plan"]:
            rec = r["records"][step]
            for lam in LAMBDAS:
                cands.append({
                    "run": r["name"], "step": step, "lambda": lam,
                    "objective": rec["objectives"][repr(lam)],
                    "lr": info["lr"], "horizon_steps": info["horizon_steps"], "train_seed": info["train_seed"],
                    "model_id": rec["model_id"], "row": f"{rec['model_id']}@{LAMBDA_LITERALS[lam]}",
                    "model": rec["model"], "model_sha256": rec["model_sha256"],
                })
    return cands


def _select(runs, cmd, mode):
    order = [r["name"] for r in runs]
    cands = _candidates(runs)
    best = min(cands, key=lambda c: candidate_key(c, order))
    return {
        "mode": mode,
        "runs": order,
        "plan": runs[0]["info"]["step_plan"],
        "cmd_sha256": cmd_sha256(cmd),
        "coverage": runs[0]["coverage"],
        "tie_order": "objective, baseline, fewer steps, lower lr, --runs order, λ grid order",
        "selected": best,
        "baseline_fallback": best["run"] == BASELINE_RUN,
        "candidates": cands,
    }


def search_problems(run_dirs, search, variant=FROZEN_VARIANT, train_seed=FROZEN_TRAIN_SEED):
    """The registered search: exactly the arms of `search`, each L2 on the
    full-data pool with the frozen training seed and its (lr, horizon)."""
    names = [Path(d).name for d in run_dirs]
    p = []
    missing = sorted(set(search) - set(names))
    extra = sorted(set(names) - set(search))
    if missing:
        p.append(f"the registered search needs arms {missing} (got {names})")
    if extra:
        p.append(f"runs {extra} are not arms of the registered search {sorted(search)}")
    for d in run_dirs:
        name, path = Path(d).name, Path(d) / "run.json"
        if name not in search or not path.exists():
            continue
        info = json.loads(path.read_text())
        if info.get("variant") != variant:
            p.append(f"{name}: variant {info.get('variant')!r}, the search is {variant}")
        for k, want in search[name].items():
            if info.get(k) != want:
                p.append(f"{name}: {k} {info.get(k)!r}, registered {want!r}")
        if info.get("train_seed") != train_seed:
            p.append(f"{name}: train_seed {info.get('train_seed')!r}, registered {train_seed}")
        sub = subset_of(info)
        if sub:
            p.append(f"{name}: trained on a subset (--{sub}); the search uses the full-data pool")
    return p


def select_global(run_dirs, cmd, plan=None, search=None):
    """Global selection over the registered search (A1-A3 and B, all
    8 checkpoints each). `plan`/`search` default to the frozen ones; tests
    pass smaller ones."""
    plan = FROZEN_PLAN if plan is None else plan
    search = FROZEN_SEARCH if search is None else search
    problems = search_problems(run_dirs, search)
    if problems:
        raise SelectionError(problems)
    return _select(_load_all(run_dirs, cmd, plan), cmd, "global")


def select_within(run_dir, cmd, plan=None):
    """The same rule within one run; controls allowed (reports C's best)."""
    runs = _load_all([run_dir], cmd, FROZEN_PLAN if plan is None else plan, allow_control=True)
    sel = _select(runs, cmd, "within_run")
    sub = subset_of(runs[0]["info"])
    sel["control"] = bool(sub)
    sel["subset"] = sub
    return sel


def fixed_lambda(run_dirs, cmd, lam, plan=None):
    """Replicate mode: each run's checkpoints at the frozen λ (not a
    minimum). `plan` None: each run's own plan."""
    if lam not in LAMBDAS:
        raise SelectionError([f"λ {lam} is not in the grid {list(LAMBDAS)}"])
    runs = _load_all(run_dirs, cmd, plan, allow_control=False)
    rows = []
    for r in runs:
        for step in r["info"]["step_plan"]:
            rec = r["records"][step]
            rows.append({"run": r["name"], "step": step, "lambda": lam, "objective": rec["objectives"][repr(lam)],
                         "train_seed": r["info"]["train_seed"], "lr": r["info"]["lr"],
                         "horizon_steps": r["info"]["horizon_steps"], "model_id": rec["model_id"],
                         "model_sha256": rec["model_sha256"]})
    objs = [x["objective"] for x in rows]
    return {
        "mode": "fixed_lambda",
        "fixed": True,
        "lambda": lam,
        "runs": [r["name"] for r in runs],
        "cmd_sha256": cmd_sha256(cmd),
        "coverage": runs[0]["coverage"],
        "rows": rows,
        "summary": {"n": len(objs), "mean": sum(objs) / len(objs), "min": min(objs), "max": max(objs)},
    }


def main(argv=None):
    from .env import ConfigError, exp2_root

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", help="comma-separated run names (directories under --root)")
    ap.add_argument("--within-run", help="select within this one run (a control allowed)")
    ap.add_argument("--fixed-lambda", type=float, default=None, help="replicate mode: report this frozen λ")
    ap.add_argument("--root", type=Path, default=None, help="runs root (default $LF_EXP2_ROOT/train)")
    ap.add_argument("--cmd", default=None, help="the frozen dev-check command template")
    ap.add_argument("--cmd-file", type=Path, default=None, help="file holding the dev-check command template")
    ap.add_argument("--out", required=True, type=Path)
    a = ap.parse_args(argv)
    try:
        root = a.root or exp2_root() / "train"
        if bool(a.cmd) == bool(a.cmd_file):
            raise SelectionError(["give exactly one of --cmd and --cmd-file"])
        cmd = a.cmd if a.cmd else a.cmd_file.read_text().strip()
        if a.within_run:
            if a.runs or a.fixed_lambda is not None:
                raise SelectionError(["--within-run takes no --runs or --fixed-lambda"])
            sel = select_within(root / a.within_run, cmd)
        else:
            if not a.runs:
                raise SelectionError(["--runs is required"])
            dirs = [root / n for n in a.runs.split(",")]
            if a.fixed_lambda is not None:
                sel = fixed_lambda(dirs, cmd, a.fixed_lambda)
            else:
                # Frozen: exactly A1, A2, A3 and B on the full plan.
                sel = select_global(dirs, cmd)
    except (SelectionError, ConfigError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(sel, indent=2))
    if "selected" in sel:
        s = sel["selected"]
        print(f"selected {s['run']} s{s['step']} λ {s['lambda']}: {s['objective']:.6f}")
    else:
        print(f"fixed λ {sel['lambda']}: mean {sel['summary']['mean']:.6f} over {sel['summary']['n']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

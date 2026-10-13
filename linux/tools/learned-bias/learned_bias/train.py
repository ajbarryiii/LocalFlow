"""Train L1/L2/L3/L3S on the prep shards (DESIGN.md "Training").

Frozen choices: seed 20261011, AdamW (lr 1e-3, weight decay 0.01 on every
parameter, default betas), cosine decay to 0 over all steps without warmup,
at most 4 epochs, batches of up to 1024 decisions from one shard (one
dictionary) with the node pass once per batch, CE over the 1025 fused token
logits at λ = 1 with correction and preservation weighted 1.0 each,
checkpoints every half epoch. Shards (of every dataset) are visited in a
seeded order per epoch; the batches of `--window` consecutive shards are
interleaved at random. Losses are reported per kind and per dataset.

Experiment runs (the default) refuse to start unless every shard passes the
provenance checks (provenance.py) and a valid dev-check command is given;
every half-epoch checkpoint is then dev-checked and the run ends by writing
selection.json (devcheck.py). `--toy` exempts synthetic runs from both and
marks the run so it can never be selected from.

Experiment 3 (DESIGN-3) adds step plans, all optional; without them the
behaviour above is unchanged byte for byte:
- `--checkpoint-steps LIST` checkpoints (`model-s{step}`) at those optimizer
  steps only, across epochs, and stops after the last; it requires
  `--horizon-steps H`, the cosine horizon, independent of the stop. A run
  stopped at S reproduces the checkpoint at S of a longer run with the same
  H and training seed (bit-exact on CPU).
- `--train-seed` seeds initialization and data order; `--seed` (20261011)
  keeps its meaning for the call subset and is never changed.
- `--calls-file FILE` trains on exactly the listed calls (`dataset/session`).
- `--fixed-lambda λ` (replicates) writes selection.json for that λ only.
- Every checkpoint records the cumulative calls, decisions and correction
  decisions seen, per dataset (run.json `checkpoint_stats`).

    python -m learned_bias.train --variant L3 --run L3 --dev-check-cmd "$(cat W/train/devcheck.cmd)"
    python -m learned_bias.train --variant L3 --run L3-c25 --call-fraction 0.25 --dev-check-cmd ...
    python -m learned_bias.train --variant L2 --run A2 --lr 3e-4 --horizon-steps 6000 \\
        --checkpoint-steps 250,500,1000,1500,2000,3000,4000,6000 --dev-check-cmd ...
"""

import argparse
import hashlib
import itertools
import json
import math
import os
import platform
import random
import sys
import time
from collections import defaultdict
from pathlib import Path

import numpy as np

VARIANT_CHOICES = ["L1", "L2", "L3", "L3S"]


def parse_args(argv):
    from . import SEED

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--variant", required=True, choices=VARIANT_CHOICES)
    ap.add_argument("--run", required=True, help="run name; outputs go to --out-root/RUN")
    ap.add_argument("--prep", type=Path, default=None, help="prep root (default $LF_EXP2_ROOT/prep)")
    ap.add_argument("--split", default="train")
    ap.add_argument("--out-root", type=Path, default=None, help="runs root (default $LF_EXP2_ROOT/train)")
    ap.add_argument("--export", default=None,
                    help="Parakeet export directory or its export.safetensors (default $LF_EXPORT)")
    ap.add_argument("--epochs", type=float, default=None, help="epochs (default 4; not with --checkpoint-steps)")
    ap.add_argument("--batch", type=int, default=1024, help="decisions per batch")
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--weight-decay", type=float, default=0.01)
    ap.add_argument("--w-correction", type=float, default=1.0)
    ap.add_argument("--w-preservation", type=float, default=1.0)
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--call-fraction", type=float, default=1.0,
                    help="learning curve: train on this nested fraction of train calls")
    ap.add_argument("--window", type=int, default=16, help="shards whose batches are interleaved")
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--gpu-lock", default=None, help="GPU lock file (default $LF_GPU_LOCK)")
    ap.add_argument("--wait-gpu-lock", action="store_true", help="wait for the lock instead of failing")
    ap.add_argument("--log-every", type=int, default=50)
    ap.add_argument("--overwrite", action="store_true", help="reuse an existing run directory")
    ap.add_argument("--dev-check-cmd", default=None,
                    help="lf-bias-eval template run on every half-epoch checkpoint (required unless --toy)")
    ap.add_argument("--dev-check-results", default=None,
                    help="results.json path template (default $LF_EXP2_ROOT/eval/{run}/results.json)")
    ap.add_argument("--toy", action="store_true",
                    help="synthetic/toy run: no provenance checks, dev checks optional, never selectable")
    ap.add_argument("--max-steps", type=int, default=0, help="stop after this many steps (--toy only)")
    # Experiment 3 (all optional; absent, experiment 2's behaviour is unchanged).
    ap.add_argument("--horizon-steps", type=int, default=None,
                    help="cosine horizon in optimizer steps, independent of when training stops")
    ap.add_argument("--checkpoint-steps", default=None,
                    help="comma-separated optimizer steps to checkpoint at; training stops after the last")
    ap.add_argument("--train-seed", type=int, default=None,
                    help="seed of initialization and data order (default --seed); --seed keeps the subset")
    ap.add_argument("--calls-file", type=Path, default=None, help="train on exactly these calls (dataset/session)")
    ap.add_argument("--fixed-lambda", type=float, default=None,
                    help="replicate mode: selection.json reports this frozen λ, not a minimum")
    a = ap.parse_args(argv)
    if a.max_steps and not a.toy:
        ap.error("--max-steps is only for --toy runs")
    if a.split != "train" and not a.toy:
        ap.error("experiment runs train on the train split only")
    a.step_plan = None
    if a.checkpoint_steps is not None:
        try:
            plan = [int(x) for x in a.checkpoint_steps.split(",")]
        except ValueError:
            ap.error(f"--checkpoint-steps {a.checkpoint_steps!r} is not a list of integers")
        if not plan or plan[0] < 1 or any(b <= p for p, b in zip(plan, plan[1:])):
            ap.error("--checkpoint-steps must be positive and strictly increasing")
        if a.horizon_steps is None:
            ap.error("--checkpoint-steps needs --horizon-steps (the cosine horizon)")
        if a.epochs is not None or a.max_steps:
            ap.error("--checkpoint-steps sets the stop; --epochs and --max-steps do not apply")
        a.step_plan = plan
    elif a.epochs is None:
        a.epochs = 4.0
    if a.horizon_steps is not None and a.horizon_steps < 1:
        ap.error("--horizon-steps must be positive")
    if a.fixed_lambda is not None:
        from .devcheck import LAMBDAS

        if a.fixed_lambda not in LAMBDAS:
            ap.error(f"--fixed-lambda must be one of {list(LAMBDAS)}")
    if a.calls_file is not None and a.call_fraction < 1.0:
        ap.error("--calls-file and --call-fraction are exclusive")
    return a


EXP3_ARGS = ("horizon_steps", "checkpoint_steps", "train_seed", "calls_file", "fixed_lambda")


def run_identity(args, shards, weights):
    """What an experiment-3 run trained on and is evaluated with, so seed
    replicates can be checked against the selected run: the prep index's
    sha256, each dataset's policy_sha256, a digest of the shard pool
    (file, call, sample, decisions, policy), the export weights' sha256, and
    the dev-check command's sha256."""
    from .devcheck import cmd_sha256
    from .provenance import sha256_file

    index = Path(args.prep) / "index.json"
    policies = {}
    pool = hashlib.sha256()
    for s in sorted(shards, key=lambda s: s.path.name):
        pol = s.meta.get("policy_sha256")
        policies.setdefault(str(s.dataset), set()).add(pol)
        pool.update(json.dumps([s.path.name, s.call, s.sample, s.decisions, pol]).encode() + b"\n")
    return {
        "prep_index_sha256": sha256_file(index) if index.exists() else None,
        "policy_sha256": {ds: sorted(map(str, v)) for ds, v in sorted(policies.items())},
        "shard_pool_sha256": pool.hexdigest(),
        "export_weights_sha256": sha256_file(weights),
        "dev_cmd_sha256": cmd_sha256(args.dev_check_cmd) if args.dev_check_cmd else None,
    }


def read_calls_file(path, call_ids):
    """The calls listed in `path`, one per line, each a call of the shards;
    refuses an empty file, duplicates and unknown calls."""
    calls = [x.strip() for x in Path(path).read_text().splitlines() if x.strip()]
    problems = []
    if not calls:
        problems.append("it lists no calls")
    dupes = sorted({c for c in calls if calls.count(c) > 1})
    if dupes:
        problems.append(f"duplicates {dupes[:5]}")
    unknown = sorted(set(calls) - set(call_ids))
    if unknown:
        problems.append(f"{len(unknown)} calls not in the shards, e.g. {unknown[:5]}")
    if problems:
        raise SystemExit(f"refusing to train: --calls-file {path}: " + "; ".join(problems))
    return set(calls)


def cosine(step, total):
    return 0.5 * (1.0 + math.cos(math.pi * min(step, total) / max(total, 1)))


class Meter:
    """Summed CE per (dataset, kind), with the base (b = 0) CE alongside."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.steps = 0
        self.loss = 0.0
        self.cands = 0
        self.sums = defaultdict(lambda: [0.0, 0.0, 0])  # (ds, kind) -> ce, base, n

    def add(self, dataset, loss, ce, base, corr, cands):
        self.steps += 1
        self.loss += loss
        self.cands += cands
        for kind, m in (("correction", corr), ("preservation", ~corr)):
            s = self.sums[(dataset, kind)]
            s[0] += float(ce[m].sum())
            s[1] += float(base[m].sum())
            s[2] += int(m.sum())

    def record(self):
        tot = defaultdict(lambda: [0.0, 0.0, 0])
        per = {}
        for (ds, kind), (ce, base, n) in sorted(self.sums.items()):
            per.setdefault(ds, {})[kind] = {"ce": ce / max(n, 1), "base_ce": base / max(n, 1), "n": n}
            t = tot[kind]
            t[0] += ce
            t[1] += base
            t[2] += n
        rec = {"loss": self.loss / max(self.steps, 1)}
        decisions = 0
        for kind in ("correction", "preservation"):
            ce, base, n = tot[kind]
            rec[f"ce_{kind}"] = ce / max(n, 1)
            rec[f"base_ce_{kind}"] = base / max(n, 1)
            rec[f"n_{kind}"] = n
            decisions += n
        rec["cands_per_decision"] = self.cands / max(decisions, 1)
        rec["per_dataset"] = per
        return rec


def planned_checkpoints(epochs, steps_per_epoch, total_steps):
    """Tags of the half-epoch checkpoints a run writes, in order."""
    half = math.ceil(steps_per_epoch / 2)
    tags = []
    for e in range(math.ceil(epochs)):
        start = e * steps_per_epoch
        if half < steps_per_epoch and start + half <= total_steps:
            tags.append(f"e{e}.5")
        if start + steps_per_epoch <= total_steps:
            tags.append(f"e{e + 1}.0")
    return tags


def main(argv=None):
    args = parse_args(argv)
    from .devcheck import DevCheckError, check_checkpoint, check_run, validate_command
    from .provenance import ProvenanceError, export_paths, validate_training_shards
    from .shards import Shard, list_shards
    from .splits import subset_calls

    # Locations come from flags or the environment (env.py), never the repo.
    from .devcheck import default_results
    from .env import ConfigError, exp2_root, export_path, gpu_lock

    try:
        args.export = export_path(args.export)
        if args.device.startswith("cuda"):
            args.gpu_lock = gpu_lock(args.gpu_lock)
        args.prep = args.prep or exp2_root() / "prep"
        args.out_root = args.out_root or exp2_root() / "train"
        if args.dev_check_cmd and not args.dev_check_results:
            args.dev_check_results = default_results()
    except ConfigError as e:
        raise SystemExit(f"refusing to train: {e}") from None

    run_dir = args.out_root / args.run
    if (run_dir / "run.json").exists() and not args.overwrite:
        raise SystemExit(f"{run_dir} already has a run; pass --overwrite or choose another --run")

    # Everything that can refuse the run happens before the GPU is touched.
    if args.dev_check_cmd or not args.toy:
        try:
            validate_command(args.dev_check_cmd)
        except DevCheckError as e:
            raise SystemExit(f"refusing to train: {e}") from None
    _, weights = export_paths(args.export)
    if args.toy:
        shards = [Shard(p) for p in list_shards(args.prep, args.split)]
    else:
        try:
            shards = validate_training_shards(args.prep, args.export, args.split)
        except ProvenanceError as e:
            raise SystemExit(str(e)) from None
    if not shards:
        raise SystemExit(f"no shards for split {args.split!r} under {args.prep}")
    if args.call_fraction < 1.0:
        keep = subset_calls([s.call_id for s in shards], args.call_fraction, args.seed)
        shards = [s for s in shards if s.call_id in keep]
    if args.calls_file is not None:
        keep = read_calls_file(args.calls_file, {s.call_id for s in shards})
        shards = [s for s in shards if s.call_id in keep]
    calls = sorted({s.call_id for s in shards})
    exp3 = any(getattr(args, k) is not None for k in EXP3_ARGS)
    plan_mode = args.step_plan is not None
    train_seed = args.seed if args.train_seed is None else args.train_seed
    run_dir.mkdir(parents=True, exist_ok=True)
    # An overwritten run starts without the previous run's dev-check state.
    for stale in ("devcheck.json", "dev_coverage.json", "selection.json"):
        (run_dir / stale).unlink(missing_ok=True)

    lock = None
    if args.device.startswith("cuda"):
        from .gpu import acquire

        lock = acquire(args.gpu_lock, wait=args.wait_gpu_lock)  # before CUDA initializes
    os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")

    import torch
    import torch.nn.functional as F

    from .features import candidate_features
    from .joint import JointOutput
    from .model import BiasModel, export_model, fused_logits, param_count

    random.seed(train_seed)
    np.random.seed(train_seed)
    torch.manual_seed(train_seed)
    torch.use_deterministic_algorithms(True, warn_only=True)
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
    dev = torch.device(args.device)

    steps_per_epoch = sum(math.ceil(s.decisions / args.batch) for s in shards)
    if plan_mode:
        total_steps = args.step_plan[-1]
        planned = [f"s{n}" for n in args.step_plan]
    else:
        total_steps = math.ceil(steps_per_epoch * args.epochs)
        if args.max_steps:
            total_steps = min(total_steps, args.max_steps)
        planned = planned_checkpoints(args.epochs, steps_per_epoch, total_steps)
    half = math.ceil(steps_per_epoch / 2)
    horizon = args.horizon_steps if args.horizon_steps is not None else total_steps

    model = BiasModel(args.variant).to(dev)
    joint = JointOutput.from_export(weights, dev)
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=args.weight_decay)
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: cosine(s, horizon))

    datasets = defaultdict(lambda: [0, 0])
    for s in shards:
        datasets[str(s.dataset)][0] += 1
        datasets[str(s.dataset)][1] += s.decisions
    # The new flags appear in the record only when given (experiment 2's
    # run.json is unchanged).
    recorded = {k: v for k, v in vars(args).items()
                if k != "step_plan" and not (k in EXP3_ARGS and v is None)}
    info = {
        "args": {k: str(v) for k, v in recorded.items()},
        "toy": bool(args.toy),
        # Each dataset's frozen DF table (one per dataset, by provenance);
        # dev checks require evaluation to use the same tables.
        "train_df": {str(s.dataset): s.meta.get("df_source_sha256") for s in shards
                     if s.meta.get("df_source_sha256")},
        "variant": args.variant,
        "params": param_count(model),
        "shards": len(shards),
        "calls": len(calls),
        "decisions": sum(s.decisions for s in shards),
        "datasets": {k: {"shards": v[0], "decisions": v[1]} for k, v in sorted(datasets.items())},
        "steps_per_epoch": steps_per_epoch,
        "total_steps": total_steps,
        "checkpoints_planned": planned,
        "checkpoints": [],
        "torch": torch.__version__,
        "device": torch.cuda.get_device_name(dev) if dev.type == "cuda" else platform.processor(),
    }
    if exp3:
        info.update({
            "lr": args.lr,
            "horizon_steps": horizon,
            "train_seed": train_seed,
            "step_plan": args.step_plan,
            "calls_file": None if args.calls_file is None else {
                "path": str(args.calls_file.resolve()),
                "sha256": hashlib.sha256(args.calls_file.read_bytes()).hexdigest(),
                "calls": len(calls),
            },
            "checkpoint_stats": {},
            "identity": run_identity(args, shards, weights),
        })

    def write_info():
        (run_dir / "run.json").write_text(json.dumps(info, indent=2))

    write_info()
    (run_dir / "calls.txt").write_text("".join(c + "\n" for c in calls))
    print(json.dumps({k: v for k, v in info.items() if k != "args"}), flush=True)
    metrics = open(run_dir / "metrics.jsonl", "a")

    def emit(rec):
        metrics.write(json.dumps(rec) + "\n")
        metrics.flush()
        print(json.dumps(rec), flush=True)

    t0 = time.time()
    step = 0
    last_ckpt = None

    def checkpoint(tag):
        nonlocal last_ckpt
        state = {"model": model.state_dict(), "opt": opt.state_dict(), "sched": sched.state_dict(),
                 "step": step, "variant": args.variant}
        torch.save(state, run_dir / f"ckpt-{tag}.pt")
        path = run_dir / f"model-{tag}.safetensors"
        export_model(model, path, lam=1.0)
        last_ckpt = step
        info["checkpoints"].append(tag)
        rec = {"checkpoint": tag, "step": step, "elapsed_s": time.time() - t0}
        if exp3:
            snap = {ds: {"calls": len(v["calls"]), "decisions": v["decisions"], "corrections": v["corrections"]}
                    for ds, v in sorted(seen.items())}
            info["checkpoint_stats"][tag] = {"step": step, "seen": snap}
            rec["seen"] = snap
        write_info()
        if args.dev_check_cmd:
            # A failure is recorded and retried by the final selection,
            # which refuses to select while any checkpoint lacks a valid check.
            try:
                r = check_checkpoint(run_dir, tag, args.dev_check_cmd, args.dev_check_results,
                                     force=True, log=lambda *_: None)
                rec["dev_objectives"] = r["objectives"]
            except DevCheckError as e:
                rec["dev_check_error"] = str(e)
        emit(rec)

    rng = np.random.default_rng(train_seed)
    # Cumulative training data seen, per dataset (logged at checkpoints in
    # experiment-3 runs).
    seen = defaultdict(lambda: {"calls": set(), "decisions": 0, "corrections": 0})

    def epoch_batches():
        """(ShardData, decision positions) for one epoch."""
        order = rng.permutation(len(shards))
        for w0 in range(0, len(order), args.window):
            window = [shards[i].load(dev) for i in order[w0 : w0 + args.window]]
            batches = []
            for sd in window:
                perm = rng.permutation(sd.decisions())
                batches += [(sd, perm[k : k + args.batch]) for k in range(0, len(perm), args.batch)]
            for bi in rng.permutation(len(batches)):
                yield batches[bi]

    meter = Meter()
    plan_set = set(args.step_plan or ())
    for epoch in itertools.count() if plan_mode else range(math.ceil(args.epochs)):
        in_epoch = 0
        for sd, idx_np in epoch_batches():
            if step >= total_steps:
                break
            idx = torch.as_tensor(idx_np, device=dev)
            z = sd.z(idx)
            with torch.no_grad():
                logits = joint.token_logits(z)
            cd, ct, cdst = sd.batch_candidates(idx_np)
            x = candidate_features(sd.trie.nf, logits, cd, ct, cdst, sd.g_size)
            keys = model.node_pass(sd.trie)
            b = model.bonus(keys, z, x, cd, cdst)
            fused = fused_logits(logits, cd, ct, b, 1.0)
            label = sd.dec_label[idx]
            corr = sd.dec_kind[idx] == 1
            ce = F.cross_entropy(fused, label, reduction="none")
            w = torch.where(corr, args.w_correction, args.w_preservation)
            loss = (w * ce).sum() / idx.shape[0]
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step()
            sched.step()
            step += 1
            in_epoch += 1
            with torch.no_grad():
                base = F.cross_entropy(logits, label, reduction="none")
                meter.add(str(sd.shard.dataset), float(loss), ce.detach(), base, corr, int(cd.shape[0]))
                if exp3:
                    s = seen[str(sd.shard.dataset)]
                    s["calls"].add(sd.shard.call_id)
                    s["decisions"] += int(idx.shape[0])
                    s["corrections"] += int(corr.sum())
            if step % args.log_every == 0 or step == total_steps:
                rec = {"step": step, "epoch": step / steps_per_epoch, "lr": sched.get_last_lr()[0]}
                rec.update(meter.record())
                if args.variant in ("L3", "L3S"):
                    rec["gate"] = model.gate.item()
                rec["elapsed_s"] = time.time() - t0
                emit(rec)
                meter.reset()
            if plan_mode:
                if step in plan_set:
                    checkpoint(f"s{step}")
            elif in_epoch == half and half < steps_per_epoch:
                checkpoint(f"e{epoch}.5")
        if not plan_mode and in_epoch == steps_per_epoch:
            checkpoint(f"e{epoch + 1}.0")
        if step >= total_steps:
            break
    if last_ckpt != step:
        checkpoint(f"step{step}")
    metrics.close()
    if lock is not None:
        lock.close()

    if args.toy:
        return 0
    # Selection over every half-epoch checkpoint (retrying failed checks).
    info["checkpoints"] = [c for c in info["checkpoints"] if c in planned]
    write_info()
    try:
        check_run(run_dir, args.dev_check_cmd, args.dev_check_results, fixed_lambda=args.fixed_lambda)
    except DevCheckError as e:
        print(f"error: no selection: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

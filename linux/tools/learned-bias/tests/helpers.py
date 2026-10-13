"""Synthetic prep trees, exports and a fake lf-bias-eval for the tests."""

import glob
import json
import os
import shlex
import sys
from pathlib import Path

from learned_bias.devcheck import DEV_DOMAINS, DOMAIN_SIZES, LAMBDA_LITERALS, LAMBDAS, RESULTS_FORMAT
from learned_bias.fixtures import synthetic_export, synthetic_shard, write_index
from learned_bias.joint import JointOutput
from learned_bias.provenance import TRAIN_MIX, ExportIdentity
from learned_bias.splits import spgi_is_dev

ROOT = Path(__file__).resolve().parents[1]  # linux/tools/learned-bias
# Rust-written fixtures committed with lf-bench (synthetic, in the repo).
REPO_FIXTURES = Path(__file__).resolve().parents[3] / "crates" / "lf-bench" / "tests" / "fixtures"


def real_root():
    """W from LF_EXP2_ROOT, or None: tests on real data skip without it."""
    v = os.environ.get("LF_EXP2_ROOT")
    return Path(v) if v else None


def real_export():
    """The export from LF_EXPORT, or None: tests needing it skip without it."""
    return os.environ.get("LF_EXPORT") or None


def prep_fixtures():
    """Rust prep fixtures: $LF_PREP_FIXTURE (a path or glob) if set; else the
    repo's synthetic fixture plus W/fixtures/prep*.safetensors when
    LF_EXP2_ROOT is set."""
    pat = os.environ.get("LF_PREP_FIXTURE")
    if pat:
        return sorted(glob.glob(pat))
    out = sorted(str(p) for p in REPO_FIXTURES.glob("prep*.safetensors"))
    if real_root():
        out += sorted(glob.glob(str(real_root() / "fixtures" / "prep*.safetensors")))
    return out
SPGI_TRAIN = [f"{i:032x}" for i in range(64) if not spgi_is_dev(f"{i:032x}")]
SPGI_DEV = [f"{i:032x}" for i in range(64) if spgi_is_dev(f"{i:032x}")]


def make_prep(root, sessions=2, utterances=3, joint=False, datasets=TRAIN_MIX):
    """root/export (synthetic export) and root/prep: `sessions` train
    sessions × 2 samples for every dataset of the training mix, one dev
    session of spgispeech, all with matching identities and policies, plus a
    complete v2 index.json. Returns (export_dir, prep_dir, identity)."""
    root = Path(root)
    export = synthetic_export(root / "export")
    ident = ExportIdentity(export)
    jo = JointOutput.from_export(ident.weights) if joint else None
    prep = root / "prep"
    k = 0
    for ds in datasets:
        names = SPGI_TRAIN[:sessions] if ds == "spgispeech" else [f"S{i:03d}" for i in range(sessions)]
        for sess in names:
            for s in (0, 1):
                synthetic_shard(prep / "train" / f"{ds}.{sess}.{s}.safetensors", seed=k, utterances=utterances,
                                dataset=ds, session=sess, sample=s, split_session_ids=names,
                                identity=ident, joint=jo)
                k += 1
    synthetic_shard(prep / "dev" / f"spgispeech.{SPGI_DEV[0]}.0.safetensors", seed=999, utterances=utterances,
                    session=SPGI_DEV[0], split="dev", samples=1, identity=ident)
    write_index(prep)
    return export, prep, ident


# R1's eligible results.json, written by the production serializer
# (learned_eval::tests::rust_results_fixture_is_current). Everything below
# is derived from it, so Python is tested against what Rust really writes.
RESULTS_FIXTURE = REPO_FIXTURES / "results-eligible.json"
TRAIN_SPLIT_DATASETS = ("spgispeech", "slidespeech", "icsi")


def rust_results():
    """A fresh copy of R1's fixture."""
    return json.loads(RESULTS_FIXTURE.read_text())


def fixture_train_df():
    """{dataset: table} of the fixture's train-split DF tables (what a run
    must have trained on for the fixture to be selectable)."""
    return {e["dataset"]: e["table_sha256"] for e in rust_results()["df_source"].values()
            if e["dataset"] in TRAIN_SPLIT_DATASETS}


TRAIN_DF = "d" * 64  # the synthetic shards' df_source_sha256 (fixtures.synthetic_shard)
TRAIN_DF_MAP = {"spgispeech": TRAIN_DF, "slidespeech": TRAIN_DF, "icsi": TRAIN_DF}


def coverage_for(utterances=None, groups=None):
    """The fixture's spec.domains, optionally with other utterance/group
    counts for every domain but the frozen dev-other."""
    out = []
    for d in rust_results()["spec"]["domains"]:
        d = dict(d)
        if d["name"] != "librispeech_dev_other_600":
            if utterances is not None:
                d["utterances"] = utterances
            if groups is not None:
                d["groups"] = groups
        out.append(d)
    return out


def _replace_strings(obj, old, new):
    if isinstance(obj, str):
        return obj.replace(old, new)
    if isinstance(obj, list):
        return [_replace_strings(x, old, new) for x in obj]
    if isinstance(obj, dict):
        return {k: _replace_strings(v, old, new) for k, v in obj.items()}
    return obj


def results_for(model, mid, objectives=(0.99, 0.98, 0.97, 0.985, 0.995), domains=None, df_table=None,
                **override):
    """R1's fixture re-targeted to model file `model` with id `mid`: its id,
    path and variant replaced, its λ rows given `objectives` (the objective
    map and the selected row follow, ties to the baseline), optionally other
    `domains` coverage, and with `df_table` every train-split DF table (and
    its prep-index hashes) set to that table. `override` sets top-level
    fields last."""
    r = rust_results()
    old = r["learned"][0]
    r = _replace_strings(r, old["model"], str(model))
    r = _replace_strings(r, old["id"], mid)
    variant = mid.split("/")[0]
    r["learned"][0]["variant"] = variant
    r["spec"]["models"][0]["variant"] = variant
    rows = r["learned"][0]["by_lambda"]
    assert [x["lambda"] for x in rows] == [0.0] + list(LAMBDAS), "fixture rows changed"
    trimmed = rows[: 1 + len(objectives)]
    for row, o in zip(trimmed[1:], objectives):
        row["dev_objective"] = o
    r["learned"][0]["by_lambda"] = trimmed
    rid = lambda l: f"{mid}@{LAMBDA_LITERALS[l]}"  # noqa: E731
    omap = {rid(l): o for l, o in zip(LAMBDAS, objectives)}
    omap["baseline@0"] = r["baseline_dev_objective"]
    r["dev_objectives_learned"] = omap
    finite = [(o, l) for l, o in zip(LAMBDAS, objectives) if isinstance(o, float) and o == o]
    best = min([(r["baseline_dev_objective"], 0.0)] + finite, key=lambda t: t[0])
    r["dev_objective"] = best[0]
    r["dev_objective_row"] = ({"row": "baseline@0", "model": "baseline", "lambda": 0.0, "fallback": True}
                              if best[1] == 0.0 else
                              {"row": rid(best[1]), "model": mid, "lambda": best[1], "fallback": False})
    if domains is not None:
        r["spec"]["domains"] = domains
    if df_table is not None:
        for e in r["df_source"].values():
            if e["dataset"] in TRAIN_SPLIT_DATASETS:
                e["table_sha256"] = df_table
                e["prep_index"].update(df_source_sha256=df_table, eval_table_sha256=df_table)
    r.update(override)
    return r


FAKE_EVAL = r'''
import json, os, sys
sys.path.insert(0, %(root)r)
from safetensors import safe_open
from tests.helpers import coverage_for, results_for
a = sys.argv[1:]
val = lambda f: a[a.index(f) + 1]
model, out = val("--learned"), val("--out")
os.makedirs(out, exist_ok=True)
count = os.environ.get("FAKE_EVAL_COUNT")
if count:
    open(count, "a").write(model + "\n")
with safe_open(model, framework="np") as f:
    variant = f.metadata()["variant"]
mid = "%%s/%%s/%%s" %% (variant, os.path.basename(os.path.dirname(model)), os.path.basename(model)[:-len(".safetensors")])
objs = json.loads(os.environ.get("FAKE_EVAL_OBJS", "[0.99, 0.98, 0.97, 0.985, 0.995]"))
utts = os.environ.get("FAKE_EVAL_UTTS")
doms = coverage_for(utterances=int(utts)) if utts else None
table = os.environ.get("FAKE_EVAL_DF") or None  # None: the fixture's own tables
json.dump(results_for(model, mid, tuple(objs), domains=doms, df_table=table),
          open(os.path.join(out, "results.json"), "w"))
'''


def fake_eval(root):
    """(command template, results template) of a fake lf-bias-eval that
    accepts the real flags and writes a valid v2 results.json."""
    root = Path(root)
    script = root / "fake_eval.py"
    script.write_text(FAKE_EVAL % {"root": str(ROOT)})
    cmd = (f"{shlex.quote(sys.executable)} {shlex.quote(str(script))} --sets dev --no-l0 {DEV_SET_FLAGS} "
           f"--learned {{model}} --out {shlex.quote(str(root / 'eval'))}/{{run}} --lambdas 0.5,0.71,1,1.41,2")
    return cmd, str(root / "eval" / "{run}" / "results.json")


# The six dev domains as R1's final template loads them (synthetic paths).
DEV_SET_FLAGS = (
    "--session /e22.json:/test_earnings22.jsonl --libri-dev /ldo.jsonl --spgi-dev /spgi.jsonl "
    "--set dev:slidespeech_dev:/s/dev.jsonl:dataset=slidespeech,cased=true,df=/s/train.jsonl "
    "--set dev:icsi_dev:/i/dev.jsonl:dataset=icsi,cased=false,df=/i/train.jsonl "
    "--set dev:acl6060_dev:/a/dev.jsonl:dataset=acl6060,cased=true,df=scored"
)


def write_json(path, obj):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(obj))


# ---------------------------------------------------------------- experiment 3

def make_exp3_run(root, name, objectives, lr=1e-3, horizon=6000, plan=(250, 500), cmd="CMD", variant="L2",
                  train_seed=20261011, calls_file=None, coverage=None, toy=False, cmd_for=None, extra_info=None):
    """A finished experiment-3 run directory under `root`, as train.py and
    devcheck.py leave it: run.json, a model file per planned step, a valid
    results.json and a bound devcheck.json record per checkpoint, and
    dev_coverage.json. `objectives(step) -> 5 objectives` (grid order).
    `cmd_for(step)` may give a step's record another command (for refusal
    tests). Returns the run directory."""
    import hashlib

    from learned_bias.devcheck import cmd_sha256
    from learned_bias.model import BiasModel, export_model

    run = Path(root) / name
    run.mkdir(parents=True, exist_ok=True)
    cov = sorted(coverage if coverage is not None else coverage_for(), key=lambda c: c["name"])
    tags = [f"s{s}" for s in plan]
    db = {}
    for k, step in enumerate(plan):
        tag = f"s{step}"
        model = run / f"model-{tag}.safetensors"
        m = BiasModel(variant)
        import torch

        with torch.no_grad():  # distinct bytes per checkpoint
            (m.l1[2] if variant == "L1" else m.sc[2]).bias.fill_(0.001 * (k + 1) + 0.0001 * len(name))
        export_model(m, model)
        mid = f"{variant}/{name}/model-{tag}"
        objs = tuple(objectives(step))
        res = run / "results" / tag / "results.json"
        res.parent.mkdir(parents=True, exist_ok=True)
        res.write_text(json.dumps(results_for(str(model.resolve()), mid, objs, domains=coverage)))
        db[tag] = {
            "model": str(model.resolve()),
            "model_sha256": hashlib.sha256(model.read_bytes()).hexdigest(),
            "model_id": mid,
            "cmd_sha256": cmd_sha256(cmd_for(step) if cmd_for else cmd),
            "run": f"{name}-{tag}",
            "results": str(res),
            "objectives": {repr(l): o for l, o in zip(LAMBDAS, objs)},
            "coverage": cov,
        }
    (run / "devcheck.json").write_text(json.dumps(db, indent=2, sort_keys=True))
    (run / "dev_coverage.json").write_text(json.dumps({"first_checkpoint": tags[0], "coverage": cov}))
    info = {
        "toy": toy, "variant": variant, "train_df": fixture_train_df(),
        "lr": lr, "horizon_steps": horizon, "train_seed": train_seed, "step_plan": list(plan),
        "calls_file": calls_file, "checkpoints_planned": tags, "checkpoints": tags,
    }
    info.update(extra_info or {})
    (run / "run.json").write_text(json.dumps(info, indent=2))
    return run


def per_session_record(row, set_, size, session, ref_words, errors, baseline_errors, role="held-out", **extra):
    """One per_session.jsonl object in R1's schema, with consistent counts."""
    sub = errors // 2
    dele = errors // 4
    ins = errors - sub - dele
    b_err = errors // 3
    rec = {
        "row": row, "set": set_, "role": role, "size": size, "session": session,
        "utterances": 3, "ref_words": ref_words,
        "sub": sub, "del": dele, "ins": ins, "errors": errors,
        "b_ref_words": ref_words // 5, "b_errors": b_err, "u_ref_words": ref_words - ref_words // 5,
        "u_errors": errors - b_err, "b_matched": 1, "false_alarms": 0, "fixed": 0, "broken": 0,
        "baseline_errors": baseline_errors, "net_errors": errors - baseline_errors,
    }
    rec.update(extra)
    return rec

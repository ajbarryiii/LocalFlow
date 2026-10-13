"""Greedy dev checks and checkpoint selection (DESIGN.md "Training";
review findings B7, B8, A1, A2).

Every half-epoch checkpoint of an experiment run is evaluated by Rust
`lf-bias-eval` on the dev sets. A result counts only if it validates against
CONTRACT-2 NOTES "results.json validation fields (R1), authoritative for P":
format v2, eligible for selection, the full frozen spec (six dev domains
with their sizes, seed, λ grid, no smoke flags), exactly this checkpoint
(source and id `VARIANT/RUN/FILE_STEM`), the λ = 0 baseline fallback first,
and finite objectives at every λ of the frozen grid. Selection is over
(checkpoint, λ) plus the λ = 0 baseline fallback (objective 1.0, which wins
ties); it is written to `selection.json`.

The command is a template, validated before use, with placeholders {model}
(the model file), {run} (a run name unique to the checkpoint) and {out} (the
results.json path). It is split with shlex and run without a shell, from the
worktree root.

    python -m learned_bias.devcheck --run-dir W/train/L3 --cmd "$(cat W/train/devcheck.cmd)"
"""

import argparse
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

from safetensors import safe_open

from . import SEED
from .env import ConfigError, exp2_root

WORKTREE = Path(__file__).resolve().parents[4]


def default_results():
    """The results.json template under LF_EXP2_ROOT (R1's --out W/eval/{run})."""
    return str(exp2_root() / "eval" / "{run}" / "results.json")

# ---- Field-name table (R1, authoritative for P) ---------------------------
RESULTS_FORMAT = "lf-bias-eval experiment 2 v2"
# lf_bench::learned_eval::DEV_DOMAINS and their list sizes, frozen.
DEV_DOMAINS = (
    "spgispeech_dev",
    "earnings22_tune",
    "librispeech_dev_other_600",
    "slidespeech_dev",
    "icsi_dev",
    "acl6060_dev",
)
DOMAIN_SIZES = {d: [500] if d == "librispeech_dev_other_600" else [100, 500, 1000] for d in DEV_DOMAINS}
DEV_SUBSET = 600
LAMBDAS = (0.5, 0.71, 1.0, 1.41, 2.0)
LAMBDA_LITERALS = {0.5: "0.5", 0.71: "0.71", 1.0: "1", 1.41: "1.41", 2.0: "2"}
BASELINE_MODEL = "baseline"  # dev_objective_row.model when nothing beats it
BASELINE_KEY = "baseline@0"  # the baseline row id everywhere
# learned_eval::DATASETS: name -> has a train split (its DF must be the
# train table, compared with the prep index); others use df=scored.
DATASETS = {"spgispeech": True, "slidespeech": True, "icsi": True, "acl6060": False, "gigaspeech": False}
# Dev domains given by shorthand flags instead of --set.
SHORTHAND_DOMAINS = {"--spgi-dev": "spgispeech_dev", "--libri-dev": "librispeech_dev_other_600",
                     "--session": "earnings22_tune"}
# Frozen coverage known in advance (re-review #5). Every other domain's
# counts are bound per run: the first eligible check writes them to
# `dev_coverage.json` and every later check must match exactly.
FROZEN_UTTERANCES = {"librispeech_dev_other_600": 600}
# The frozen dev-other identity (learned_eval::DEV_OTHER_*; second
# re-review #2): `spec.dev_other` must be exactly this, so a different
# manifest (e.g. test-other) or another 600-utterance selection is refused.
DEV_OTHER_MANIFEST_SHA256 = "d66037522094c8c3f30e5c8f3c0b1fbc8ae66a848693a9557992ca867396a740"
DEV_OTHER_IDS_SHA256 = "58040fb1a0076429a61145f676729e6bbdc685978a40a22f3f73700abbd4be95"
FROZEN_DEV_OTHER = {
    "manifest": "librispeech_dev_other.jsonl",
    "manifest_sha256": DEV_OTHER_MANIFEST_SHA256,
    "frozen_manifest_sha256": DEV_OTHER_MANIFEST_SHA256,
    "ids_sha256": DEV_OTHER_IDS_SHA256,
    "frozen_ids_sha256": DEV_OTHER_IDS_SHA256,
    "selected": 600,
}
# ---- end of table ----------------------------------------------------------

BASELINE = {"checkpoint": "baseline", "lambda": 0.0, "objective": 1.0}
# Flags that make a run ineligible (R1's complete list); `--seed`,
# `--lambdas` and `--l0` are allowed only at their frozen values.
FORBIDDEN_FLAGS = ("--limit", "--sizes", "--dev-subset", "--allow-partial-dev")
FROZEN_VALUES = {"--seed": str(SEED), "--l0": "1.414,3,off,on"}
DEFAULT_RESULTS = None  # $LF_EXP2_ROOT/eval/{run}/results.json (default_results)
# Unreplaced tokens of R1's template (e.g. SLIDESPEECH_DEV_MANIFEST, ICSI_CASED).
PLACEHOLDER = re.compile(r"\b[A-Z0-9]+(?:_[A-Z0-9]+)*_(?:MANIFEST|CASED)\b")


class DevCheckError(RuntimeError):
    pass


# ------------------------------------------------------------ the command


def validate_command(cmd):
    """Reject a dev-check template that is not a full greedy dev evaluation
    of exactly {model} on the frozen λ grid. Returns the argv template."""
    if not cmd or not cmd.strip():
        raise DevCheckError("a dev-check command is required (--dev-check-cmd); only --toy runs may omit it")
    argv = shlex.split(cmd)
    problems = []
    exe = argv[0]
    if not (os.path.isfile(exe) and os.access(exe, os.X_OK)) and shutil.which(exe) is None:
        problems.append(f"executable {exe!r} not found")

    def values(flag):
        out = []
        for i, a in enumerate(argv):
            if a == flag:
                out.append(argv[i + 1] if i + 1 < len(argv) else None)
            elif a.startswith(flag + "="):
                out.append(a.split("=", 1)[1])
        return out

    if values("--sets") != ["dev"]:
        problems.append(f"--sets must appear once with value 'dev' (got {values('--sets')})")
    if values("--learned") != ["{model}"]:
        problems.append(f"--learned must appear once with value '{{model}}' (got {values('--learned')})")
    outs = values("--out")
    if len(outs) != 1 or outs[0] is None or "{run}" not in outs[0]:
        problems.append(f"--out must appear once and contain {{run}} (got {outs})")
    lam = values("--lambdas")
    if lam:
        try:
            got = tuple(float(x) for x in lam[0].split(","))
        except (AttributeError, ValueError):
            got = None
        if len(lam) != 1 or got != LAMBDAS:
            problems.append(f"--lambdas must be the frozen grid {','.join(map(str, LAMBDAS))} (got {lam})")
    for flag, want in FROZEN_VALUES.items():
        v = values(flag)
        if v and v != [want]:
            problems.append(f"{flag} must be {want} if given (got {v})")
    for a in argv:
        if a.split("=", 1)[0] in FORBIDDEN_FLAGS:
            problems.append(f"smoke flag {a!r} is not allowed in a dev check")
        if "random:" in a:
            problems.append(f"random models are not allowed ({a!r})")
        if a in ("heldout", "both"):
            problems.append(f"held-out sets are not allowed in a dev check ({a!r})")
        if PLACEHOLDER.search(a):
            problems.append(f"unreplaced template token in {a!r}")
    problems += set_problems(values("--set"), {d for f, d in SHORTHAND_DOMAINS.items() if values(f)})
    if problems:
        raise DevCheckError("invalid dev-check command:\n  " + "\n  ".join(problems))
    return argv


def set_problems(sets, shorthand):
    """`--set dev:NAME:MANIFEST:k=v,...` entries: dev role only, a frozen
    domain named `<dataset>_dev`, `dataset=` one of the frozen datasets, the
    train manifest as `df=` for datasets with a train split and `scored`
    otherwise; together with the shorthand flags, every frozen dev domain
    exactly once."""
    p, names = [], list(shorthand)
    for s in sets:
        if s is None:
            p.append("--set without a value")
            continue
        parts = s.split(":", 2)
        if len(parts) != 3 or ":" not in parts[2]:
            p.append(f"--set {s!r} is not ROLE:NAME:MANIFEST:OPTIONS")
            continue
        role, name, rest = parts
        _, opts_s = rest.rsplit(":", 1)
        opts = dict(o.split("=", 1) for o in opts_s.split(",") if "=" in o)
        ds = opts.get("dataset")
        names.append(name)
        if role != "dev":
            p.append(f"--set {name}: role {role!r}, a dev check loads dev sets only")
        if ds not in DATASETS:
            p.append(f"--set {name}: dataset={ds!r} is not one of {sorted(DATASETS)}")
            continue
        if name != f"{ds}_dev" or name not in DEV_DOMAINS:
            p.append(f"--set {name}: not the frozen dev domain of dataset {ds!r}")
        df = opts.get("df")
        if DATASETS[ds] and (not df or df == "scored"):
            p.append(f"--set {name}: {ds} has a train split, so df= must name its train manifest (got {df!r})")
        if not DATASETS[ds] and df != "scored":
            p.append(f"--set {name}: {ds} has no train split, so df= must be 'scored' (got {df!r})")
        if ds == "spgispeech" and opts.get("keep") != "spgi-dev":
            p.append(f"--set {name}: spgispeech needs keep=spgi-dev")
    if sorted(names) != sorted(DEV_DOMAINS):
        p.append(f"dev domains from --set and shorthand flags {sorted(names)} are not each of "
                 f"{sorted(DEV_DOMAINS)} exactly once")
    return p


# ------------------------------------------------------------ results


def _finite(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)


def _int(x):
    return isinstance(x, int) and not isinstance(x, bool)


def _grid(lam):
    """The frozen grid λ that `lam` is exactly (R1 writes the literals'
    values, never f32 expansions), or None."""
    if not _finite(lam):
        return None
    return next((x for x in LAMBDAS if x == lam), None)


def model_id(model_path):
    """R1's id of a model file: VARIANT/RUN/FILE_STEM (the file's metadata
    variant, its directory name and its stem)."""
    p = Path(model_path)
    with safe_open(str(p), framework="np") as f:
        variant = (f.metadata() or {}).get("variant")
    if not variant:
        raise DevCheckError(f"{p}: no variant in its metadata")
    return f"{variant}/{p.parent.name}/{p.stem}"


def df_source_problems(dfs, train_df=None):
    """`df_source.{set}` (re-review #1): one entry per `--set`, the three
    DF-using dev datasets. A dataset with a train split uses its train
    table (`split` "train"), whose prep-index comparison must be `match`
    with `df_source_sha256` = `eval_table_sha256` = `table_sha256`; with
    `train_df` ({dataset: df_source_sha256} of the shards the run trained
    on) it must also be that table. Datasets without one use "scored"."""
    if not isinstance(dfs, dict):
        return [f"df_source {dfs!r} is not an object"]
    p = []
    seen = set()
    for name, e in sorted(dfs.items()):
        if not isinstance(e, dict) or e.get("dataset") not in DATASETS:
            p.append(f"df_source.{name}: dataset {e.get('dataset') if isinstance(e, dict) else e!r} unknown")
            continue
        ds = e["dataset"]
        seen.add(ds)
        tab = e.get("table_sha256")
        if not is_sha256(tab):
            p.append(f"df_source.{name}: table_sha256 {tab!r} is not a sha256")
        if DATASETS[ds]:
            pi = e.get("prep_index") if isinstance(e.get("prep_index"), dict) else {}
            if e.get("split") != "train":
                p.append(f"df_source.{name}: {ds} DF split {e.get('split')!r}, not its train table")
            if pi.get("status") != "match":
                p.append(f"df_source.{name}: prep_index status {pi.get('status')!r}, not 'match' "
                         f"({pi.get('detail')!r})")
            elif not (pi.get("df_source_sha256") == pi.get("eval_table_sha256") == tab):
                p.append(f"df_source.{name}: prep_index {pi!r} does not equal table_sha256 {tab!r}")
            if train_df is not None and tab != train_df.get(ds):
                p.append(f"df_source.{name}: {ds} DF table {tab!r} is not the one the run trained on "
                         f"({train_df.get(ds)!r})")
        elif e.get("split") != "scored":
            p.append(f"df_source.{name}: {ds} has no train split, DF split {e.get('split')!r} != 'scored'")
    for ds in ("spgispeech", "slidespeech", "icsi", "acl6060"):
        if ds not in seen:
            p.append(f"df_source has no entry for {ds}")
    return p


def is_sha256(v):
    return isinstance(v, str) and len(v) == 64 and all(c in "0123456789abcdef" for c in v)


def validate_results(data, model_path, expected_id, train_df=None):
    """Objectives {λ: x} of one checkpoint from a results.json dict, or
    raise DevCheckError naming every problem. `train_df`: the run's
    {dataset: df_source_sha256} from run.json, to bind evaluation's DF tables
    to the training shards'."""
    problems = []
    bad = problems.append
    if data.get("format") != RESULTS_FORMAT:
        bad(f"format {data.get('format')!r} != {RESULTS_FORMAT!r}")
    if data.get("eligible_for_selection") is not True:
        bad(f"eligible_for_selection is {data.get('eligible_for_selection')!r} "
            f"(reasons {data.get('ineligible_reasons')!r})")
    if data.get("ineligible_reasons") != []:
        bad(f"ineligible_reasons {data.get('ineligible_reasons')!r} is not empty")
    if data.get("partial") is not False:
        bad(f"partial is {data.get('partial')!r}, not false")
    if data.get("limit") is not None:
        bad(f"limit is {data.get('limit')!r}, not null")
    if data.get("parity_failures") != []:
        bad(f"parity_failures {data.get('parity_failures')!r} is not empty")
    doms = data.get("dev_domains_present")
    if not isinstance(doms, list) or sorted(doms) != sorted(DEV_DOMAINS):
        bad(f"dev_domains_present {doms!r} is not exactly {list(DEV_DOMAINS)}")

    spec = data.get("spec")
    if not isinstance(spec, dict):
        bad("no spec")
        spec = {}
    want = {"sets": "dev", "limit": None, "sizes_flag": None, "dev_subset": DEV_SUBSET,
            "dev_subset_flag": None, "allow_partial_dev": False, "seed": SEED}
    for k, v in want.items():
        if k not in spec or spec[k] != v or isinstance(spec[k], bool) != isinstance(v, bool):
            bad(f"spec.{k} is {spec.get(k, '<missing>')!r}, not {v!r}")
    dev_other = spec.get("dev_other")
    if dev_other != FROZEN_DEV_OTHER or not _int((dev_other or {}).get("selected")):
        bad(f"spec.dev_other {dev_other!r} is not the frozen dev-other identity {FROZEN_DEV_OTHER!r}")
    if sorted(spec.get("frozen_domains") or []) != sorted(DEV_DOMAINS):
        bad(f"spec.frozen_domains {spec.get('frozen_domains')!r}")
    lams = spec.get("lambdas")
    if not isinstance(lams, list) or [_grid(x) for x in lams] != list(LAMBDAS):
        bad(f"spec.lambdas {lams!r} is not {list(LAMBDAS)}")
    sd = spec.get("domains")
    names = [d.get("name") if isinstance(d, dict) else None for d in sd] if isinstance(sd, list) else None
    coverage = None
    if names is None or sorted(map(str, names)) != sorted(DEV_DOMAINS):
        bad(f"spec.domains {names!r} is not the six frozen domains once each")
    else:
        coverage = []
        for d in sd:
            n = d["name"]
            if d.get("sizes") != DOMAIN_SIZES[n]:
                bad(f"spec.domains {n} sizes {d.get('sizes')!r} != {DOMAIN_SIZES[n]}")
            for k in ("utterances", "groups"):
                if not _int(d.get(k)) or d[k] < 1:
                    bad(f"spec.domains {n} {k} {d.get(k)!r} is not a positive integer")
            want_u = FROZEN_UTTERANCES.get(n)
            if want_u is not None and d.get("utterances") != want_u:
                bad(f"spec.domains {n} covers {d.get('utterances')!r} utterances, not {want_u}")
            coverage.append({"name": n, "sizes": d.get("sizes"), "utterances": d.get("utterances"),
                             "groups": d.get("groups")})
        coverage.sort(key=lambda c: c["name"])
        # The loaded-set summary, when present, must say the same.
        tune = [s for s in data.get("sets") or [] if isinstance(s, dict) and s.get("role") in ("tune", "dev")]
        if tune:
            got = sorted(({"name": s.get("name"), "sizes": s.get("sizes"), "utterances": s.get("utterances"),
                           "groups": s.get("groups")} for s in tune), key=lambda c: str(c["name"]))
            if got != coverage:
                bad(f"sets coverage {got!r} != spec.domains {coverage!r}")
    variant = expected_id.split("/", 1)[0]
    models = spec.get("models")
    if not isinstance(models, list) or len(models) != 1 or not isinstance(models[0], dict):
        bad(f"spec.models must hold exactly one model (got {models!r})")
    else:
        sm = models[0]
        src = sm.get("source")
        if not src or os.path.realpath(src) != os.path.realpath(model_path):
            bad(f"spec.models source {src!r} is not {str(model_path)!r}")
        if sm.get("id") != expected_id:
            bad(f"spec.models id {sm.get('id')!r} != {expected_id!r}")
        if sm.get("variant") != variant:
            bad(f"spec.models variant {sm.get('variant')!r} != {variant!r}")
        ml = sm.get("lambdas")
        if not isinstance(ml, list) or [_grid(x) for x in ml] != list(LAMBDAS):
            bad(f"spec.models lambdas {ml!r} is not the grid {list(LAMBDAS)}")
        want_rows = [row_id(expected_id, k) for k in LAMBDAS]
        if sm.get("rows") != want_rows:
            bad(f"spec.models rows {sm.get('rows')!r} != {want_rows!r}")

    learned = data.get("learned")
    objectives, baseline = {}, None
    if not isinstance(learned, list) or len(learned) != 1:
        bad(f"learned must hold exactly one model (got {len(learned) if isinstance(learned, list) else learned!r})")
    else:
        e = learned[0]
        if e.get("id") != expected_id or e.get("label", expected_id) != expected_id:
            bad(f"learned id/label {e.get('id')!r}/{e.get('label')!r} != {expected_id!r}")
        if e.get("variant") != variant:
            bad(f"learned variant {e.get('variant')!r} != {variant!r}")
        if not e.get("model") or os.path.realpath(e["model"]) != os.path.realpath(model_path):
            bad(f"learned model {e.get('model')!r} is not {str(model_path)!r}")
        rows = e.get("by_lambda")
        if not isinstance(rows, list) or not rows:
            bad("learned by_lambda is empty")
            rows = []
        if rows:
            b = rows[0]
            if not (b.get("fallback") is True and b.get("row") == BASELINE_KEY and b.get("lambda") == 0
                    and _finite(b.get("dev_objective"))):
                bad(f"by_lambda[0] is not the λ = 0 baseline fallback: {b!r}")
            else:
                baseline = float(b["dev_objective"])
        # One row per grid λ, in grid order, with row id `<id>@<literal>`.
        if [_grid(r.get("lambda")) for r in rows[1:]] != list(LAMBDAS):
            bad(f"by_lambda λs {[r.get('lambda') for r in rows[1:]]!r} are not the grid {list(LAMBDAS)} in order")
        for r in rows[1:]:
            k = _grid(r.get("lambda"))
            if k is None or r.get("fallback") is not False:
                bad(f"by_lambda row {r!r} is not a grid λ")
            elif k in objectives:
                bad(f"λ {r.get('lambda')} appears twice")
            elif r.get("row") != row_id(expected_id, k):
                bad(f"row id {r.get('row')!r} != {row_id(expected_id, k)!r}")
            elif not _finite(r.get("dev_objective")):
                bad(f"objective at λ {r.get('lambda')} is {r.get('dev_objective')!r} ({r.get('dev_objective_error')!r})")
            else:
                objectives[k] = float(r["dev_objective"])
        missing = [x for x in LAMBDAS if x not in objectives]
        if missing:
            bad(f"no finite objective at λ {missing}")
        # The objective map: exactly the rows' ids plus baseline@0, same values.
        omap = data.get("dev_objectives_learned")
        want_map = {row_id(expected_id, k): v for k, v in objectives.items()}
        if baseline is not None:
            want_map[BASELINE_KEY] = baseline
        if not missing and baseline is not None and omap != want_map:
            bad(f"dev_objectives_learned {omap!r} != the rows {want_map!r}")
    base_top = data.get("baseline_dev_objective")
    if not _finite(base_top) or abs(base_top - 1.0) > 1e-9:
        bad(f"baseline_dev_objective {base_top!r} != 1")
    if baseline is not None and _finite(base_top) and baseline != base_top:
        bad(f"by_lambda baseline {baseline} != baseline_dev_objective {base_top}")
    # The selected row agrees with the rows (ties go to the baseline).
    if not problems:
        best_lam, best = 0.0, baseline
        for lam in LAMBDAS:
            if objectives[lam] < best:
                best_lam, best = lam, objectives[lam]
        row = data.get("dev_objective_row") or {}
        if best_lam == 0.0:
            want = {"row": BASELINE_KEY, "model": BASELINE_MODEL, "lambda": 0.0, "fallback": True}
        else:
            want = {"row": row_id(expected_id, best_lam), "model": expected_id, "lambda": best_lam,
                    "fallback": False}
        row_ok = (row.get("row") == want["row"] and row.get("model") == want["model"]
                  and _finite(row.get("lambda")) and row.get("lambda") == want["lambda"]
                  and row.get("fallback") is want["fallback"])
        if not row_ok or data.get("dev_objective") != best:
            bad(f"dev_objective {data.get('dev_objective')!r} / row {row!r} disagree with the rows "
                f"(best {want['row']} = {best})")
    problems += df_source_problems(data.get("df_source"), train_df)
    if problems:
        raise DevCheckError("invalid dev-check result:\n  " + "\n  ".join(problems))
    return {"objectives": objectives, "baseline": baseline, "model_id": expected_id, "coverage": coverage}


def row_id(mid, lam):
    """R1's row id: `<model id>@<grid literal>` (0.5, 0.71, 1, 1.41, 2)."""
    return f"{mid}@{LAMBDA_LITERALS[lam]}"


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 22), b""):
            h.update(b)
    return h.hexdigest()


def cmd_sha256(cmd):
    """Identity of the evaluation spec a record was produced under."""
    return hashlib.sha256(cmd.encode()).hexdigest()


def run_dev_check(model, run, cmd, results=DEFAULT_RESULTS, cwd=WORKTREE, log=None, train_df=None):
    """Run the validated command for one model file and validate its result.
    Returns the record stored in devcheck.json."""
    argv = validate_command(cmd)
    fmt = {"model": str(Path(model).resolve()), "run": run}
    fmt["out"] = (results or default_results()).format(**fmt)
    expected_id = model_id(fmt["model"])
    sha_before = sha256_file(fmt["model"])
    out = Path(fmt["out"])
    if out.exists():
        out.unlink()  # never read a stale result
    argv = [a.format(**fmt) for a in argv]
    proc = subprocess.run(argv, cwd=str(cwd), stdout=log, stderr=subprocess.STDOUT if log else None)
    if proc.returncode != 0:
        raise DevCheckError(f"lf-bias-eval exited with {proc.returncode}")
    if not out.exists():
        raise DevCheckError(f"lf-bias-eval wrote no {out}")
    v = validate_results(json.loads(out.read_text()), fmt["model"], expected_id, train_df)
    if sha256_file(fmt["model"]) != sha_before:
        raise DevCheckError(f"{fmt['model']} changed during its dev check")
    return {
        "model": fmt["model"],
        "model_sha256": sha_before,
        "model_id": expected_id,
        "cmd_sha256": cmd_sha256(cmd),
        "run": run,
        "results": str(out),
        "objectives": {repr(k): x for k, x in v["objectives"].items()},
        "coverage": v["coverage"],
    }


def revalidate(rec, model, cmd, train_df=None):
    """A cached devcheck.json record counts for checkpoint file `model` only
    if it is bound to it (same resolved path, current sha256 and id), was
    produced under the same command template, and its results.json still
    validates for it with the coverage it recorded (re-review #3)."""
    model = str(Path(model).resolve())
    if not Path(model).exists():
        raise DevCheckError(f"{model} does not exist")
    if rec.get("model") != model:
        raise DevCheckError(f"cached record is for {rec.get('model')!r}, not {model!r}")
    sha, mid = sha256_file(model), model_id(model)
    if rec.get("model_sha256") != sha:
        raise DevCheckError(f"{model} changed since its dev check (or the record names other bytes)")
    if rec.get("model_id") != mid:
        raise DevCheckError(f"cached record id {rec.get('model_id')!r} != {mid!r}")
    if rec.get("cmd_sha256") != cmd_sha256(cmd):
        raise DevCheckError("cached record was produced under a different dev-check command")
    r = rec.get("results")
    if not r or not Path(r).exists():
        raise DevCheckError("cached record lacks its results file")
    v = validate_results(json.loads(Path(r).read_text()), model, mid, train_df)
    objectives = {repr(k): x for k, x in v["objectives"].items()}
    if objectives != rec.get("objectives") or v["coverage"] != rec.get("coverage"):
        raise DevCheckError("cached record disagrees with its results.json")
    return rec


def bind_coverage(run_dir, ck, coverage):
    """The first eligible check of a run writes its dev coverage to
    `dev_coverage.json`; every later check must match it exactly."""
    path = Path(run_dir) / "dev_coverage.json"
    if not path.exists():
        path.write_text(json.dumps({"first_checkpoint": ck, "coverage": coverage}, indent=2))
        return
    want = json.loads(path.read_text())["coverage"]
    if coverage != want:
        raise DevCheckError(f"{ck}: dev coverage {coverage!r} differs from the run's {want!r} ({path})")


def check_checkpoint(run_dir, ck, cmd, results=DEFAULT_RESULTS, force=False, log=print):
    """A valid record for checkpoint `ck` of `run_dir` (its file is
    `model-{ck}.safetensors`): the cached one if it is bound to that file and
    command and still validates, else a fresh dev check. The record is saved
    in devcheck.json and its coverage bound to the run. Evaluation's train DF
    tables must be the ones in run.json's `train_df`."""
    run_dir = Path(run_dir)
    train_df = json.loads((run_dir / "run.json").read_text()).get("train_df")
    if not isinstance(train_df, dict) or not train_df:
        raise DevCheckError(f"{run_dir}/run.json has no train_df (the training shards' DF tables)")
    model = run_dir / f"model-{ck}.safetensors"
    db_path = run_dir / "devcheck.json"
    db = json.loads(db_path.read_text()) if db_path.exists() else {}
    rec = db.get(ck)
    if rec is not None and not force:
        try:
            rec = revalidate(rec, model, cmd, train_df)
            bind_coverage(run_dir, ck, rec["coverage"])
            return rec
        except DevCheckError as e:
            log(f"{ck}: cached dev check rejected ({e}); re-running")
    with open(run_dir / f"devcheck-{ck}.log", "w") as lf:
        rec = run_dev_check(model, f"{run_dir.name}-{ck}", cmd, results, log=lf, train_df=train_df)
    bind_coverage(run_dir, ck, rec["coverage"])
    db = json.loads(db_path.read_text()) if db_path.exists() else {}
    db[ck] = rec
    db_path.write_text(json.dumps(db, indent=2, sort_keys=True))
    log(f"{ck}: dev objective min over λ {min(rec['objectives'].values()):.6f}")
    return rec


# ------------------------------------------------------------ selection


def select(records, expected):
    """Best (checkpoint, λ) over validated records, or the baseline. Every
    checkpoint in `expected` must have a record, and all records must share
    one coverage. Ties keep the earlier candidate; the baseline comes first,
    so it wins ties."""
    missing = [c for c in expected if c not in records]
    if missing:
        raise DevCheckError(f"checkpoints without a valid dev check: {missing}")
    covs = {json.dumps(records[c].get("coverage"), sort_keys=True) for c in expected}
    if len(covs) != 1:
        raise DevCheckError("checkpoints were dev-checked on different coverage")
    cands = [dict(BASELINE)]
    for ck in expected:
        rec = records[ck]
        for lam in LAMBDAS:
            cands.append({"checkpoint": ck, "lambda": lam, "objective": rec["objectives"][repr(lam)],
                          "model": rec["model"], "model_sha256": rec["model_sha256"],
                          "model_id": rec.get("model_id")})
    best = cands[0]
    for c in cands[1:]:
        if c["objective"] < best["objective"]:
            best = c
    return {"selected": best, "baseline_fallback": best["checkpoint"] == "baseline", "candidates": cands}


def check_run(run_dir, cmd, results=DEFAULT_RESULTS, force=False, log=print, fixed_lambda=None):
    """Dev-check every expected checkpoint of a run (reusing bound, valid
    cached records), then write selection.json. Returns the selection.
    With `fixed_lambda` (experiment 3's replicate mode) selection.json
    reports that λ's objective per checkpoint, marked fixed, not a minimum."""
    if fixed_lambda is not None and fixed_lambda not in LAMBDAS:
        raise DevCheckError(f"fixed λ {fixed_lambda} is not in the grid {list(LAMBDAS)}")
    run_dir = Path(run_dir)
    info = json.loads((run_dir / "run.json").read_text())
    if info.get("toy"):
        raise DevCheckError(f"{run_dir} is a toy run; it cannot be selected from")
    expected = list(info.get("checkpoints") or [])
    if not expected:
        raise DevCheckError(f"{run_dir}/run.json lists no checkpoints")
    validate_command(cmd)
    records = {ck: check_checkpoint(run_dir, ck, cmd, results, force, log) for ck in expected}
    if fixed_lambda is not None:
        sel = {"mode": "fixed_lambda", "fixed": True, "lambda": fixed_lambda, "cmd_sha256": cmd_sha256(cmd),
               "objectives": {ck: records[ck]["objectives"][repr(fixed_lambda)] for ck in expected},
               "models": {ck: {"model_id": records[ck]["model_id"], "model_sha256": records[ck]["model_sha256"]}
                          for ck in expected}}
        (run_dir / "selection.json").write_text(json.dumps(sel, indent=2))
        log(f"fixed λ {fixed_lambda}: {sel['objectives']}")
        return sel
    sel = select(records, expected)
    sel["cmd_sha256"] = cmd_sha256(cmd)
    (run_dir / "selection.json").write_text(json.dumps(sel, indent=2))
    s = sel["selected"]
    log(f"selected {s['checkpoint']} at λ {s['lambda']}: {s['objective']:.6f}")
    return sel


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run-dir", required=True, type=Path, help="training run directory")
    ap.add_argument("--cmd", required=True, help="lf-bias-eval command template")
    ap.add_argument("--results", default=None, help="results.json path template (default $LF_EXP2_ROOT/eval/{run}/results.json)")
    ap.add_argument("--force", action="store_true", help="re-run checkpoints already checked")
    a = ap.parse_args(argv)
    try:
        check_run(a.run_dir, a.cmd, a.results, a.force)
    except (DevCheckError, ConfigError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

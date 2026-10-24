"""The Mac CPU measurement (DESIGN 7): a self-verifying bundle built on nixos, and the measured run on the Mac.

    ./python -m lfspk.personal.macbench bundle                     # nixos: runs/W6/macbundle/ (public data only)
    python -m lfspk.personal.macbench verify --bundle DIR          # Mac: every file against bundle.json
    python -m lfspk.personal.macbench measure --bundle DIR --arm A-VB --subject 2775 --config P --rep 1 \
        --threads 2 --qos background --out DIR                     # Mac: one measured fine-tune

The bundle holds:
- the code (lfspk/{__init__,api,paths,splits}.py, lfspk/extract, lfspk/personal, lfspk/pvad);
- art/: the pinned Parakeet mel constants, the two base checkpoints and the
  packed bank, at the paths lfspk.paths resolves with LFSPK_ART=<bundle>/art;
- subjects/<spk>/: the verbatim dictation render files (tuning dictations only)
  and p0.npy, for the two measured subjects (first F and first M in pilot order).

bundle.json records the sha256 of every file, the nixos-side provenance of each
subject's inputs (dictation digests, profile digest, profile build identity,
bank pack), and the code hashes. `bundle-run` (lfspk.personal.tune) verifies
all of it before training; the running code's hashes must equal the bundle's.

`measure` runs the child fine-tune as
    [taskpolicy -c <qos>] /usr/bin/time -l <python> -m lfspk.personal.tune bundle-run ...
with OMP_NUM_THREADS = MKL_NUM_THREADS = threads, and records wall/user/sys
time, maximum RSS, peak memory footprint (the G5 metric) and load averages at
start and end into measure.json. Copied back to nixos: the readouts, logs and
measure.json only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from lfspk import paths

from . import subjects as S

OUT = paths.RUNS / "W6" / "macbundle"
MAC_SUBJECTS = (S.PILOT["F"][0], S.PILOT["M"][0])
MAC_ARMS = ("A-V0", "A-VB")
CODE_GLOBS = ("lfspk/__init__.py", "lfspk/api.py", "lfspk/paths.py", "lfspk/splits.py", "lfspk/extract/*.py",
              "lfspk/personal/*.py", "lfspk/pvad/*.py")
CONSTANTS_REL = Path("runs/W5/constants/parakeet-tdt-0.6b-v2-frontend.npz")
BUDGET = {"wall_s": 20 * 60, "peak_footprint_bytes": int(1.5 * 2**30)}  # G5 (DESIGN 7)


def _sha(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --- nixos: build ------------------------------------------------------------------------------

def bundle(out: Path = OUT) -> dict:
    from lfspk.extract.constants import OUT as CONST

    from .profiles import load as load_profiles
    from .tune import TuneConfig, base_name, code_sha256, nixos_inputs, w5_code_sha256

    if out.exists():
        raise FileExistsError(f"{out} exists; bundles are built once")
    repo = Path(__file__).resolve().parents[2]
    tmp = out.with_name(out.name + ".partial")
    if tmp.exists():
        shutil.rmtree(tmp)
    for g in CODE_GLOBS:
        for src in sorted(repo.glob(g)):
            dst = tmp / "code" / src.relative_to(repo)
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
    art = tmp / "art"
    (art / CONSTANTS_REL).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(CONST, art / CONSTANTS_REL)
    for arm in MAC_ARMS:
        name = base_name(arm)
        d = art / "runs" / "W5" / "train" / name
        d.mkdir(parents=True, exist_ok=True)
        shutil.copy2(paths.RUNS / "W5" / "train" / name / "final.pt", d / "final.pt")
    pack = art / "runs" / "W6" / "render" / "bank_pack"
    pack.mkdir(parents=True, exist_ok=True)
    for f in ("bank16.npy", "frames.npy", "index.json", "pack.json"):
        shutil.copy2(paths.RUNS / "W6" / "render" / "bank_pack" / f, pack / f)
    import numpy as np

    profs = load_profiles()
    prov = {}
    for spk in MAC_SUBJECTS:
        cfg = TuneConfig(arm=MAC_ARMS[0], subject=spk, device="cpu")
        inp = nixos_inputs(cfg)  # validates the render sets, the pack and the profiles
        sd = tmp / "subjects" / spk
        sd.mkdir(parents=True)
        for j in range(S.N_TUNE):
            key = f"{spk}-{j:02d}"
            shutil.copy2(paths.RUNS / "W6" / "render" / "dict" / "mix" / f"{key}.npz", sd / f"{key}.npz")
        np.save(sd / "p0.npy", profs[spk]["p0"])
        prov[spk] = inp.provenance
    files = {str(p.relative_to(tmp)): _sha(p) for p in sorted(tmp.rglob("*")) if p.is_file()}
    meta = {"kind": "w6-macbundle", "subjects": list(MAC_SUBJECTS), "arms": list(MAC_ARMS), "files": files,
            "provenance": prov, "code": {"w6_tune_code_sha256": code_sha256(), "w5_code_sha256": w5_code_sha256()},
            "bases": {base_name(a): S.BASES[base_name(a)] for a in MAC_ARMS},
            "bank_pack_sha256": _sha(pack / "pack.json"), "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    (tmp / "bundle.json").write_text(json.dumps(meta, indent=1))
    os.replace(tmp, out)
    return {"bundle": str(out), "bundle_json_sha256": _sha(out / "bundle.json"), "n_files": len(files),
            "bytes": sum((out / f).stat().st_size for f in files)}


def make_tar(src: Path = OUT, dst: Path | None = None) -> dict:
    """One tar of the verified bundle (top-level directory 'bundle/', sorted entries) for Taildrop, with its sha256
    and bundle.json's sha256 (the pins the Mac checks)."""
    import tarfile

    meta = verify(src)
    dst = dst or src.with_name("w6-macbundle.tar")
    if dst.exists():
        raise FileExistsError(dst)
    with tarfile.open(dst, "w") as tf:
        for rel in sorted([*meta["files"], "bundle.json"]):
            tf.add(src / rel, arcname=f"bundle/{rel}", recursive=False)
    res = {"tar": str(dst), "tar_sha256": _sha(dst), "bundle_json_sha256": _sha(src / "bundle.json"),
           "bytes": dst.stat().st_size}
    dst.with_suffix(".tar.json").write_text(json.dumps(res, indent=1))
    return res


def mac_receive_command(tar_name: str, tar_sha256: str, bundle_sha256: str,
                        python: str = "$HOME/miniforge3/envs/orthonet/bin/python") -> list[str]:
    """The jobs-mac argv that accepts a Taildropped tar: move it from Tailscale's inbox into ~/Downloads (`tailscale
    file get`; tolerated to find nothing, e.g. if already moved, since the sha256 check below fails closed), check its
    sha256, extract into ~/localflow-speaker-w6/bundle (which must not exist), verify every file against the pinned
    bundle.json with the bundle's own code (no extra files allowed), then delete the tar from ~/Downloads. Any failure
    stops before deletion."""
    dest = "$HOME/localflow-speaker-w6"
    script = " && ".join([
        "set -eu", "{ /usr/local/bin/tailscale file get --wait=false --conflict=skip \"$HOME/Downloads/\" || true; }",
        f"T=\"$HOME/Downloads/{tar_name}\"", f"test ! -e {dest}/bundle",
        f"echo \"{tar_sha256}  $T\" | shasum -a 256 -c -", f"mkdir -p {dest}", f"tar -xf \"$T\" -C {dest}",
        f"cd {dest}/bundle", "PFX=$(mktemp -d)",
        f"LC_ALL=C PYTHONPATH={dest}/bundle/code LFSPK_ART={dest}/bundle/art "
        f"{python} -B -X pycache_prefix=\"$PFX\" -m lfspk.personal.macbench verify --bundle {dest}/bundle "
        f"--bundle-sha256 {bundle_sha256}",
        "rm -f \"$T\""])
    return ["sh", "-c", script]


def mac_measure_command(arm: str, subject: str, rep: int, out: str, config: str = "P", threads: int = 2,
                        qos: str = "background", bundle_sha256: str | None = None,
                        python: str = "$HOME/miniforge3/envs/orthonet/bin/python") -> list[str]:
    """The jobs-mac argv of one measured run: the parent itself runs bundle code with -B and a fresh empty pycache
    prefix (macbench refuses otherwise), and the child gets its own fresh prefix (`measure`)."""
    dest = "$HOME/localflow-speaker-w6/bundle"
    pin = f" --bundle-sha256 {bundle_sha256}" if bundle_sha256 else ""
    script = " && ".join([
        "set -eu", "PFX=$(mktemp -d)",
        f"LC_ALL=C PYTHONPATH={dest}/code LFSPK_ART={dest}/art {python} -B -X pycache_prefix=\"$PFX\" "
        f"-m lfspk.personal.macbench measure --bundle {dest} --arm {arm} --subject {subject} --config {config} "
        f"--rep {rep} --threads {threads} --qos {qos} --out {out}{pin}"])
    return ["sh", "-c", script]


# --- any host: verify and load ---------------------------------------------------------------

def verify(root: Path, bundle_sha256: str | None = None) -> dict:
    root = Path(root)
    if bundle_sha256 is not None and _sha(root / "bundle.json") != bundle_sha256:
        raise RuntimeError("bundle.json differs from the pinned sha256")
    meta = json.loads((root / "bundle.json").read_text())
    for rel, h in meta["files"].items():
        if _sha(root / rel) != h:
            raise RuntimeError(f"{rel} differs from bundle.json")
    cached = sorted(str(p.relative_to(root)) for p in root.rglob("*")
                    if p.name == "__pycache__" or p.suffix in (".pyc", ".pyo"))
    if cached:  # code2-r2: bytecode in the bundle could execute instead of the pinned sources
        raise RuntimeError(f"bytecode caches in the bundle: {cached[:3]}")
    extra = sorted(str(p.relative_to(root)) for p in root.rglob("*")
                   if p.is_file() and str(p.relative_to(root)) not in meta["files"] and p.name != "bundle.json")
    if extra:
        raise RuntimeError(f"unexpected files in the bundle: {extra[:3]}")
    return meta


def python_argv(prefix: Path, python: str = sys.executable) -> list[str]:
    """How every bundle Python is launched (code2-r2): -B (never write bytecode) and a pycache prefix in a fresh,
    empty directory outside the bundle, so Python never reads in-tree __pycache__ and finds nothing to read."""
    return [python, "-B", "-X", f"pycache_prefix={prefix}"]


def fresh_prefix() -> Path:
    import tempfile

    p = Path(tempfile.mkdtemp(prefix="w6-pycache-"))
    if any(p.iterdir()):
        raise RuntimeError(f"pycache prefix {p} is not empty")
    return p


def require_isolated_bytecode(root: Path) -> None:
    """This interpreter writes no bytecode and reads caches only from an empty prefix directory outside the bundle."""
    root = Path(root).resolve()
    if not sys.flags.dont_write_bytecode:
        raise RuntimeError("bundle Python must run with -B")
    if not sys.pycache_prefix:
        raise RuntimeError("bundle Python must run with -X pycache_prefix=<fresh empty directory>")
    pre = Path(sys.pycache_prefix).resolve()
    if pre == root or root in pre.parents:
        raise RuntimeError("the pycache prefix lies inside the bundle")
    if pre.exists() and any(q.is_file() for q in pre.rglob("*")):
        raise RuntimeError(f"the pycache prefix {pre} is not empty")


# Every lfspk module a bundle-run imports, loaded up front so that `verify_modules` sees the whole active set.
PRELOAD = ("lfspk", "lfspk.api", "lfspk.paths", "lfspk.extract.api", "lfspk.extract.model", "lfspk.extract.losses",
           "lfspk.extract.frontend", "lfspk.extract.constants", "lfspk.extract.data", "lfspk.extract.harness_frontend",
           "lfspk.extract.identities", "lfspk.pvad.features", "lfspk.pvad.enrollment", "lfspk.pvad.w0_source",
           "lfspk.pvad.data", "lfspk.pvad.losses", "lfspk.personal", "lfspk.personal.subjects", "lfspk.personal.signals",
           "lfspk.personal.stream", "lfspk.personal.tune", "lfspk.personal.render", "lfspk.personal.profiles",
           "lfspk.personal.macbench")


def preload() -> None:
    import importlib

    for name in PRELOAD:
        importlib.import_module(name)


def verify_modules(root: Path, meta: dict | None = None) -> int:
    """Every loaded lfspk.* module must come from <root>/code and match bundle.json's sha256 (code2-r1 M2).
    Returns the number of modules checked."""
    root = Path(root).resolve()
    meta = meta or json.loads((root / "bundle.json").read_text())
    code = (root / "code").resolve()
    n = 0
    for name, mod in sorted(sys.modules.items()):
        if not (name == "lfspk" or name.startswith("lfspk.")) or mod is None:
            continue
        f = getattr(mod, "__file__", None)
        if f is None:
            raise RuntimeError(f"{name} has no source file")
        p = Path(f).resolve()
        if code not in p.parents:
            raise RuntimeError(f"{name} is loaded from {p}, outside the verified bundle code {code}")
        rel = str(p.relative_to(root))
        if meta["files"].get(rel) != _sha(p):
            raise RuntimeError(f"{name}: {rel} differs from bundle.json")
        n += 1
    return n


def bundle_inputs(root: Path, cfg, _verify_modules: bool = True):
    """(Inputs, code identity) for a bundle-run, after verifying every file, the pins and the running code
    (every loaded lfspk module from the bundle's code tree, by origin and sha256). `_verify_modules=False` is a
    test hook for in-tree unit tests; the origin check itself is tested in a subprocess."""
    import numpy as np

    from .profiles import vec_sha256
    from .render import decode
    from .signals import arrays_digest
    from .stream import Bank, Dictation
    from .tune import Inputs, base_name, code_sha256, w5_code_sha256

    root = Path(root).resolve()
    meta = verify(root)
    if _verify_modules:
        require_isolated_bytecode(root)
        preload()
        verify_modules(root, meta)
        require_isolated_bytecode(root)
    if paths.ART.resolve() != (root / "art").resolve():
        raise RuntimeError("LFSPK_ART must point at the bundle's art/ directory")
    code = {"w6_tune_code_sha256": code_sha256(), "w5_code_sha256": w5_code_sha256()}
    if code != meta["code"]:
        raise RuntimeError("the running code differs from the bundle's code")
    if cfg.subject not in meta["provenance"]:
        raise RuntimeError(f"{cfg.subject} is not in the bundle")
    prov = meta["provenance"][cfg.subject]
    sd = root / "subjects" / cfg.subject
    dicts = []
    for j in range(S.N_TUNE):
        key = f"{cfg.subject}-{j:02d}"
        z = np.load(sd / f"{key}.npz", allow_pickle=False)
        arrs = {k: z[k] for k in z.files}
        if arrays_digest(arrs) != prov["dict_digests"][key]:
            raise RuntimeError(f"{key}: arrays differ from the nixos manifest")
        d = decode(arrs)
        dicts.append(Dictation(d["audio"], d["target"], d["target_active"]))
    p0 = np.load(sd / "p0.npy").astype(np.float32)
    if vec_sha256(p0) != prov["profile_sha256"]:
        raise RuntimeError("p0 differs from the nixos profile digest")
    bank = Bank(root / "art" / "runs" / "W6" / "render" / "bank_pack", verify_current=False,
                pack_sha256=meta["bank_pack_sha256"])
    if bank.pack_sha256 != prov["bank_pack_sha256"]:
        raise RuntimeError("bank pack differs from the one the subject's provenance names")
    base = root / "art" / "runs" / "W5" / "train" / base_name(cfg.arm) / "final.pt"
    provenance = dict(prov, bundle_json_sha256=_sha(root / "bundle.json"))
    return Inputs(dicts, bank, p0, base, provenance), code


# --- Mac: measure -----------------------------------------------------------------------------

_TIMES = re.compile(r"^\s*(\d+\.\d+)\s+real\s+(\d+\.\d+)\s+user\s+(\d+\.\d+)\s+sys\s*$")
_COUNTS = {"max_rss_bytes": re.compile(r"^\s*(\d+)\s+maximum resident set size\s*$"),
           "peak_footprint_bytes": re.compile(r"^\s*(\d+)\s+peak memory footprint\s*$")}


def parse_time_l(text: str) -> dict:
    """macOS `/usr/bin/time -l` output (C locale) -> wall/user/sys seconds, max RSS and peak memory footprint (bytes).

    Each field must match one complete line exactly once (code2-r1 M1): a locale decimal comma, a truncated number
    or a repeated field fails closed with ValueError, so a malformed report can never pass the budget."""
    lines = text.splitlines()
    t = [m for m in (_TIMES.match(x) for x in lines) if m]
    if len(t) != 1:
        raise ValueError(f"expected exactly one 'real/user/sys' line in C-locale format, found {len(t)}")
    out = {"wall_s": float(t[0].group(1)), "user_s": float(t[0].group(2)), "sys_s": float(t[0].group(3))}
    for k, pat in _COUNTS.items():
        m = [x for x in (pat.match(x) for x in lines) if x]
        if len(m) != 1:
            raise ValueError(f"expected exactly one line for {k}, found {len(m)}")
        out[k] = int(m[0].group(1))
    return out


def power_snapshot() -> dict:
    """Report-only measurement conditions (orchestrator, 2026-10-24): `pmset -g batt` (AC or battery and the charge),
    `pmset -g therm` where available, and the load averages. Never gates anything."""
    out = {"load": list(os.getloadavg())}
    for k, args in (("pmset_batt", ["pmset", "-g", "batt"]), ("pmset_therm", ["pmset", "-g", "therm"])):
        try:
            r = subprocess.run(args, capture_output=True, text=True, timeout=10)
            out[k] = r.stdout.strip() if r.returncode == 0 else f"exit {r.returncode}: {r.stderr.strip()}"
        except (OSError, subprocess.SubprocessError) as e:
            out[k] = f"unavailable: {type(e).__name__}"
    b = out["pmset_batt"]
    out["on_ac"] = None if b.startswith(("unavailable", "exit")) else ("AC Power" in b)
    return out


def within_budget(m: dict) -> bool:
    return m["wall_s"] <= BUDGET["wall_s"] and m["peak_footprint_bytes"] <= BUDGET["peak_footprint_bytes"]


def measure(root: Path, arm: str, subject: str, config: str, rep: int, threads: int, qos: str, out: Path) -> dict:
    root = Path(root).resolve()
    tag = f"mac-{qos}-t{threads}-r{rep}"
    run = Path(out) / arm / config / f"{subject}-{tag}"
    if run.exists() or run.with_name(run.name + ".partial").exists():
        raise FileExistsError(f"{run} exists")
    run.parent.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, LC_ALL="C", LANG="C", PYTHONPATH=str(root / "code"), LFSPK_ART=str(root / "art"),
               OMP_NUM_THREADS=str(threads),
               MKL_NUM_THREADS=str(threads), PYTHONDONTWRITEBYTECODE="1")
    require_isolated_bytecode(root)  # this parent imported the bundle's code too
    prefix = fresh_prefix()
    child = [*python_argv(prefix), "-m", "lfspk.personal.tune", "bundle-run", "--bundle", str(root), "--arm", arm, "--subject",
             subject, "--config", config, "--threads", str(threads), "--tag", tag, "--out", str(run)]
    cmd = ["/usr/bin/time", "-l", *child]
    if qos != "default":
        cmd = ["taskpolicy", "-c", qos, *cmd]
    power0 = power_snapshot()
    load0 = os.getloadavg()
    t0 = time.time()
    p = subprocess.run(cmd, env=env, capture_output=True, text=True, cwd=str(root))
    load1 = os.getloadavg()
    power1 = power_snapshot()
    log_dir = run if run.exists() else run.with_name(run.name + ".failed")
    log_dir.mkdir(parents=True, exist_ok=True)
    (log_dir / "child.stdout").write_text(p.stdout)
    (log_dir / "child.stderr").write_text(p.stderr)
    res = {"arm": arm, "subject": subject, "config": config, "rep": rep, "threads": threads, "qos": qos,
           "exit_code": p.returncode, "outer_wall_s": round(time.time() - t0, 2), "load_start": list(load0),
           "load_end": list(load1), "power_start": power0, "power_end": power1, "cmd": cmd}
    try:
        res.update(parse_time_l(p.stderr))
        res["within_budget"] = p.returncode == 0 and within_budget(res)
    except ValueError as e:
        res["parse_error"] = str(e)
        res["within_budget"] = False
    (log_dir / "measure.json").write_text(json.dumps(res, indent=1))
    return res


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("bundle", "tar", "verify", "measure"))
    ap.add_argument("--bundle", default="")
    ap.add_argument("--bundle-sha256", default=None)
    ap.add_argument("--arm", choices=MAC_ARMS)
    ap.add_argument("--subject", choices=MAC_SUBJECTS)
    ap.add_argument("--config", default="P", choices=("P", "F"))
    ap.add_argument("--rep", type=int, default=1)
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--qos", default="background", choices=("background", "utility", "default"))
    ap.add_argument("--out", default="")
    a = ap.parse_args(argv)
    if a.cmd == "bundle":
        print(json.dumps(bundle(), indent=1))
    elif a.cmd == "tar":
        res = make_tar()
        res["mac_receive_argv"] = mac_receive_command(Path(res["tar"]).name, res["tar_sha256"], res["bundle_json_sha256"])
        print(json.dumps(res, indent=1))
    elif a.cmd == "verify":
        meta = verify(Path(a.bundle), a.bundle_sha256)
        print(json.dumps({"ok": True, "files": len(meta["files"])}))
    else:
        if a.bundle_sha256:
            verify(Path(a.bundle), a.bundle_sha256)
        print(json.dumps(measure(Path(a.bundle), a.arm, a.subject, a.config, a.rep, a.threads, a.qos, Path(a.out)), indent=1))


if __name__ == "__main__":
    main()

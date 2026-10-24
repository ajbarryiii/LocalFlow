"""Synthetic fixtures for the front-end evaluator tests (no real audio, no
models): a tiny frozen set on /tmp, a deterministic fake FeatureFrontEnd, and
a throwaway git repository holding a W5-style registration file."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path

import numpy as np
import soundfile as sf

from lfspk.extract.api import LOG_G_MIN, N_MELS, MaskOutput, feature_frames

FS = 16000
TARGET_TEXT = "alpha beta gamma"
SPEAKERS = ("11", "12")
N_ENROLL = 10
N_SHORT = 7  # speaker 12's headset stream: no k = 10 there


def _noise(seed: int, seconds: float) -> np.ndarray:
    rng = np.random.default_rng(seed)
    return (rng.standard_normal(int(seconds * FS)) * 0.05).astype(np.float32)


def build_set(root: Path, split: str = "dev", extra_short: bool = False) -> Path:
    """Two speakers x (S0, S1) mixtures of 1.5 s, 10 enrollment dictations per
    device (one contaminated twin at index 2), HASH and CONTENT.sha256. With
    `extra_short`, a third speaker (13, half B) whose built-in stream has only
    7 dictations, so the headline condition (k = 10) does not reach it."""
    speakers = SPEAKERS + (("13",) if extra_short else ())
    for d in ("mix", "labels", "dry", "enroll"):
        (root / d).mkdir(parents=True, exist_ok=True)
    rows, enr = [], []
    for si, spk in enumerate(speakers):
        other = SPEAKERS[1 - si] if si < 2 else "11"
        for scen in ("S0", "S1"):
            mid = f"{scen}-{spk}-00"
            audio = _noise(100 * si + (scen == "S1"), 1.5)
            sf.write(root / "mix" / f"{mid}.flac", audio, FS, subtype="PCM_24")
            F = audio.size // 160
            lab = np.zeros(F, np.uint8)
            lab[10:120] = 1  # target 0.1-1.2 s
            if scen == "S1":
                lab[100:120] = 3  # interferer 1.0-1.35 s
                lab[120:135] = 2
            np.savez_compressed(root / "labels" / f"{mid}.npz", labels=lab, target_active=(lab == 1) | (lab == 3),
                                interferer_actives=np.array([(lab == 2) | (lab == 3)]) if scen == "S1" else np.zeros((0, F), bool))
            ints = [{"kind": "office", "speaker": other}] if scen == "S1" else []
            rows.append({"id": mid, "scenario": scen, "rir_mode": "coherent", "speaker": spk, "half": "A" if si == 0 else "B",
                         "target_index": 0, "seed": 1, "relation_at": {"3": "cross_project", "10": None if spk == "13" else "cross_project", "30": None},
                         "enroll_len": N_ENROLL, "files": {"mix": f"mix/{mid}.flac", "labels": f"labels/{mid}.npz",
                                                           "target_dry": f"dry/{mid}.target.flac",
                                                           "interferers_dry": [f"dry/{mid}.int0.flac"] if ints else []},
                         "meta": {"split": split, "frames": F, "interferers": ints, "target": {"text": TARGET_TEXT}}})
        (root / "enroll" / spk).mkdir(exist_ok=True)
        for d, device in enumerate(("builtin", "headset")):
            for j in range(N_SHORT if (spk, device) in (("12", "headset"), ("13", "builtin")) else N_ENROLL):
                for tag in ("clean", "contam") if j == 2 else ("clean",):
                    f = f"enroll/{spk}/{device}-{j:02d}-{tag}.flac"
                    sf.write(root / f, _noise(1000 + 100 * si + 10 * d + j + (tag == "contam") * 7, 1.0), FS, subtype="PCM_24")
                    enr.append({"speaker": spk, "device": device, "index": j, "contaminated": tag == "contam",
                                "relation": "cross_project", "file": f})
    (root / "manifest.jsonl").write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
    (root / "enrollment.jsonl").write_text("".join(json.dumps(e, sort_keys=True) + "\n" for e in enr))
    (root / "plans.json").write_text(json.dumps({"plans": [{"speaker": s, "test_project_in_train": True} for s in speakers]}))
    files = sorted(p for p in root.rglob("*") if p.is_file() and p.name not in ("CONTENT.sha256", "HASH"))
    listing = "".join(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(root)}\n" for p in files)
    (root / "CONTENT.sha256").write_text(listing)
    (root / "HASH").write_text(hashlib.sha256(listing.encode()).hexdigest() + "\n")
    return root


class FakeFrontEnd:
    """Deterministic FeatureFrontEnd. The profile counts the dictations it has
    seen and sums their first samples, and the mask encodes both, so a test can
    check the exact enroll/update protocol from the stored arrays."""

    def __init__(self, gain: str = "1.0", run: str = "R1", seed: str = "0", sha: str = "ab" * 32, threads: str = "1",
                 set_threads: str = "0", declare_threads: str = "1"):
        self.gain = float(gain)
        self.run, self.seed, self.sha, self.threads = run, int(seed), sha, int(threads)
        self.set_threads, self.declare_threads = int(set_threads), declare_threads == "1"
        self.name = f"fake-{gain}"

    def enroll(self, utterances):
        return ("fake", len(utterances), float(sum(float(u[:16].sum()) for u in utterances)))

    def update(self, profile, utterance):
        return ("fake", profile[1] + 1, profile[2] + float(utterance[:16].sum()))

    def analyse(self, profile, audio) -> MaskOutput:
        t = feature_frames(audio.size)
        lm = np.full((N_MELS, t), -0.01 * profile[1] * self.gain, np.float32)
        lm[1, :] = np.float32(-(abs(profile[2]) % 1.0) - 0.01)
        lm[2, : min(t, 50)] = np.float32(-(abs(float(audio[:50].sum())) % 2.0) - 0.01)
        if self.set_threads:
            import torch

            torch.set_num_threads(self.set_threads)
        lm = np.clip(lm, LOG_G_MIN, 0.0)
        u = np.full(t, min(1.0, 0.05 * profile[1] + (0.4 if float(audio[0]) > 0 else 0.0)), np.float32)
        return MaskOutput(lm, u)

    def cost(self):
        from lfspk.api import CostReport

        return CostReport(params=1, macs_per_audio_second=1.0, update_macs=0.0, profile_bytes=0, reads_parakeet_layers=(), notes="fake")

    def identity(self) -> dict:
        ident = {"kind": "fake-frontend", "checkpoint_sha256": self.sha, "run": self.run, "seed": self.seed,
                 "gain": self.gain, "theta_b": 0.5}
        if self.declare_threads:
            ident["analyse_threads"] = self.threads
        return ident

    def config(self, name: str):
        from lfspk.extract.api import InferenceConfig

        return InferenceConfig(name, 0.5 if name in ("C3", "C4") else None)


def make(**kwargs) -> FakeFrontEnd:
    return FakeFrontEnd(**kwargs)


# --- a throwaway git repository with W5's registration file --------------------------------

RESULTS = "lfspk/extract/RESULTS.md"
PLACEHOLDER = "    confirmatory-checkpoint: R1-s0 sha256=<to be recorded after training>"


def git(repo: Path, *args: str) -> str:
    """git in the throwaway repository: the evaluator's sanitised environment,
    no hooks, no signing."""
    from lfspk.harness.fe_registry import git_env

    env = {**git_env(), "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
    cmd = ["git", "-c", "core.hooksPath=" + os.devnull, "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", *args]
    return subprocess.run(cmd, cwd=repo, env=env, check=True, capture_output=True, text=True).stdout


def init_repo(repo: Path) -> Path:
    (repo / "lfspk" / "extract").mkdir(parents=True)
    git(repo, "init", "-q", "-b", "main")
    (repo / RESULTS).write_text(f"# W5 results\n\n## Pre-registered confirmatory checkpoint\n\n{PLACEHOLDER}\n\nmore text\n")
    git(repo, "add", RESULTS)
    git(repo, "commit", "-q", "-m", "W5 RESULTS with the placeholder")
    return repo


def register(repo: Path, sha: str, message: str | None = None, extra_line: str | None = None) -> str:
    """The anchor commit: the placeholder line becomes the valid line."""
    p = repo / RESULTS
    s = p.read_text().replace(PLACEHOLDER, f"    confirmatory-checkpoint: R1-s0 sha256={sha}")
    if extra_line:
        s += extra_line + "\n"
    p.write_text(s)
    git(repo, "add", RESULTS)
    git(repo, "commit", "-q", "-m", message or f"W5: REGISTER confirmatory-checkpoint R1-s0 {sha}")
    return git(repo, "rev-parse", "HEAD").strip()


# --- B cache and a NeMo-free stand-in for nemo_hook.transcribe_masked ------------------------

B_IDENTITY = {"model": "/fake/parakeet.nemo", "model_sha256": "d9" * 32, "decoding": "greedy TDT, fp32, timestamps, length-sorted batches",
              "nemo": "3.0.0"}


def frozen_mix_hashes(root: Path) -> dict[str, str]:
    out = {}
    for line in (root / "CONTENT.sha256").read_text().splitlines():
        sha, rel = line.split("  ", 1)
        if rel.startswith("mix/") and rel.endswith(".flac"):
            out["mix:" + rel[4:-5]] = sha
    return out


def write_b_cache(b_dir: Path, set_root: Path) -> dict[str, dict]:
    """B's cache for the fixture set: asr.jsonl ({key, audio_sha256, text,
    words}) and asr.meta.json, as lfspk.harness.asr writes them."""
    b_dir.mkdir(parents=True, exist_ok=True)
    recs = {}
    tgt = [["alpha", 0.1, 0.3], ["beta", 0.4, 0.6], ["gamma", 0.9, 1.1]]
    for k, sha in sorted(frozen_mix_hashes(set_root).items()):
        # B: S0 perfect; S1 loses "gamma" and transcribes the interferer's "delta"
        w = tgt if k.startswith("mix:S0") else tgt[:2] + [["delta", 1.15, 1.3]]
        recs[k] = {"key": k, "audio_sha256": sha, "text": " ".join(x[0] for x in w), "words": w}
        mid = k[4:]
        recs[f"tdry:{mid}"] = {"key": f"tdry:{mid}", "audio_sha256": "0" * 64, "text": TARGET_TEXT, "words": tgt}
        if k.startswith("mix:S1"):
            recs[f"idry:{mid}:0"] = {"key": f"idry:{mid}:0", "audio_sha256": "0" * 64, "text": "delta", "words": [["delta", 1.15, 1.3]]}
    (b_dir / "asr.jsonl").write_text("".join(json.dumps(r) + "\n" for r in recs.values()))
    (b_dir / "asr.meta.json").write_text(json.dumps(B_IDENTITY, indent=1))
    return recs


def write_words(b_dir: Path, set_root: Path, b_recs: dict[str, dict]) -> dict[str, dict]:
    """words.jsonl as refs.build writes it (mixture_record's pseudo-reference
    branch: no forced alignments in the fixture)."""
    from lfspk.harness.frozen import FrozenSet
    from lfspk.harness.refs import mixture_record

    fs = FrozenSet("fixture", root=set_root)
    out = {}
    for row in fs.manifest:
        lab = fs.labels(row)
        out[row["id"]] = json.loads(json.dumps(mixture_record(row, lab["labels"], lab["target_active"], b_recs, None)))
    (b_dir / "words.jsonl").write_text("".join(json.dumps(r) + "\n" for r in out.values()))
    return out


class FakeASR:
    """Records every call of the stand-in transcriber (the batches it saw).
    `script` maps a recording's sample hash to the words to return."""

    def __init__(self, script: dict | None = None):
        self.calls: list[list[str]] = []
        self.script = dict(script or {})


def fake_transcribe_masked(model: FakeASR, audios, mask_outputs, config, batch_size: int = 16):
    """nemo_hook.transcribe_masked's contract without NeMo: None for a bypassed
    recording, otherwise a record that depends on the audio and on the applied
    mask, positional."""
    from lfspk.extract.frontend import weights

    out, seen = [], []
    for a, mo in zip(audios, mask_outputs):
        w = weights(mo.u, a.size, config)
        if w is None:
            out.append(None)
            continue
        v = float(np.asarray(a, np.float64)[:100].sum()) + float((w[None, :] * np.asarray(mo.log_mask, np.float64)).sum())
        seen.append(f"{v:.6f}")
        from lfspk.extract.nemo_hook import audio_sha256

        words = model.script.get(audio_sha256(a), [["f", 0.1, 0.3], ["x", 0.4, 0.6]])
        out.append({"text": " ".join(x[0] for x in words), "words": words})
    model.calls.append(seen)
    return out


# --- recording stubs: the exact inputs of stage A and of the scorer loop ------------------------


def digest(a) -> str:
    return hashlib.sha256(np.ascontiguousarray(a, dtype=np.float32).tobytes()).hexdigest()[:16]


class RecordingFrontEnd(FakeFrontEnd):
    """Logs, for every analyse call, the ordered digests of the dictations the
    profile was built from and the digest of the mixture audio."""

    def __init__(self, log: str, **kw):
        super().__init__(**kw)
        self.log = log

    def enroll(self, utterances):
        return ("rec", [digest(u) for u in utterances])

    def update(self, profile, utterance):
        return ("rec", profile[1] + [digest(utterance)])

    def analyse(self, profile, audio):
        with open(self.log, "a") as f:
            f.write(json.dumps({"profile": profile[1], "mix": digest(audio)}) + "\n")
        return super().analyse(("fake", len(profile[1]), 0.0), audio)

    def identity(self):
        return {**super().identity(), "log": self.log}


def make_recording(log: str, **kw) -> RecordingFrontEnd:
    return RecordingFrontEnd(log, **kw)


class RecordingScorer:
    """The same log for evaluate._score_speaker's scorer protocol."""

    name = "recording-scorer"

    def __init__(self, log: str):
        self.log = log

    def enroll(self, utterances):
        return _Prof([digest(u) for u in utterances])

    def update(self, profile, utterance):
        return _Prof(profile.d + [digest(utterance)])

    def score(self, profile, audio):
        with open(self.log, "a") as f:
            f.write(json.dumps({"profile": profile.d, "mix": digest(audio)}) + "\n")
        return np.ones(audio.size // 160, np.float32)


class _Prof:
    def __init__(self, d):
        self.d = d

    def to_bytes(self) -> bytes:
        return json.dumps(self.d).encode()


def supersede(repo: Path, old: str, message: str | None = None, extra_line: str | None = None, keep_line: bool = False) -> str:
    """The SUPERSEDE commit: the valid line for `old` becomes the placeholder
    again, plus one `superseded-checkpoint` line."""
    p = repo / RESULTS
    valid = f"    confirmatory-checkpoint: R1-s0 sha256={old}"
    repl = f"{PLACEHOLDER}\n    superseded-checkpoint: R1-s0 sha256={old}"
    s = p.read_text().replace(valid, (valid + "\n" if keep_line else "") + repl)
    if extra_line:
        s += extra_line + "\n"
    p.write_text(s)
    git(repo, "add", RESULTS)
    git(repo, "commit", "-q", "-m", message or f"W5: SUPERSEDE confirmatory-checkpoint R1-s0 {old}")
    return git(repo, "rev-parse", "HEAD").strip()

#!/usr/bin/env python3
"""Run synthetic startup comparisons without changing the app or its caches.

Use the upstream pinned Mac Python and macguard. All generated model copies,
synthetic fixtures, binary outputs and timings stay outside the repository.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time

from parakeet_weight_index import verify_bundle


REPO = Path(__file__).resolve().parents[1]
ARMS = ("all", "fifteen-first", "mlx", "mlx-with-ane")


class GuardFailure(Exception):
    """Only content-free guard status/reasons may be displayed."""


def outside_repo(path):
    path = Path(path).resolve()
    if path.is_relative_to(REPO):
        raise ValueError("Benchmark output must be outside the repository")
    return path


def copy_bundle(source, destination, manifest):
    destination.mkdir()
    for name in manifest["files"]:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, target)
    shutil.copy2(source / "bundle.json", destination / "bundle.json")
    spec = importlib.util.spec_from_file_location("branding", REPO / "scripts/label-localflow-model.py")
    branding = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(branding)
    branding.label_bundle(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="new experiment directory outside Git")
    parser.add_argument("--guard", type=Path, required=True, help="upstream ios/macguard")
    parser.add_argument("--python", type=Path, default=Path(sys.executable), help="upstream pinned Mac Python with MLX")
    parser.add_argument("--arms", nargs="+", choices=ARMS, default=list(ARMS))
    parser.add_argument("--repeats", type=int, default=1)
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64" or args.repeats < 1:
        raise ValueError("This experiment requires Apple Silicon and positive repeats")
    if int(platform.mac_ver()[0].split(".")[0]) < 26:
        raise ValueError("This model requires macOS 26 or later")
    output = outside_repo(args.output)
    if output.exists():
        raise ValueError("Use a new experiment directory; existing results are preserved")
    source = args.bundle.resolve()
    manifest = verify_bundle(source)
    output.mkdir(parents=True)
    executable = output / "parakeet-startup-benchmark"
    def run(command, timeout=900):
        completed = subprocess.run([str(args.guard), "--rss-cap", "4G", "--timeout", str(timeout), "--", *map(str, command)],
                                   capture_output=True, text=True)
        if completed.returncode:
            memory = re.search(r"refused: free memory (\d+)% < (\d+)%", completed.stderr)
            reason = f"free memory {memory[1]}% below {memory[2]}% minimum" if memory else "guarded step failed"
            if "refused: lock held" in completed.stderr:
                reason = "another guarded job holds the lock"
            raise GuardFailure(f"macguard exit {completed.returncode}: {reason}. Partial outputs are preserved outside Git.")
        peak = re.search(r"peak group RSS (\d+)KB, swap growth (-?\d+)KB", completed.stderr)
        metrics = {"guard_peak_group_rss_kib": int(peak[1]), "guard_swap_growth_kib": int(peak[2])} if peak else {}
        return completed.stdout, metrics

    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    sources = sorted((REPO / "Sources/Parakeet").glob("*.swift"))
    run(["swiftc", "-parse-as-library", "-O", "-warnings-as-errors", "-sdk", sdk,
         "-target", "arm64-apple-macosx13.0", *sources, REPO / "scripts/parakeet-startup-benchmark.swift", "-o", executable], 180)
    speech = output / "invented-speech.aiff"
    run(["say", "-v", "Samantha", "-r", "260", "-o", speech,
         "The blue lantern is beside the green notebook."], 60)
    fixtures = output / "fixtures"
    run([executable, "fixtures", speech, fixtures], 60)
    report = {"schema": 1, "export_sha256": manifest["export_sha256"], "encoder": "C6s8 plain",
              "hardware": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
              "macOS": platform.mac_ver()[0], "repeats": args.repeats,
              "cache_evidence": "new copied bundle path then same-path fresh process; no cache deletion or Instruments cache events",
              "limitations": ["Synthetic smoke on a shared Mac; no accuracy or controlled performance claim.",
                              "Python MLX feasibility prototype; Swift packaging size and production handoff not measured.",
                              "MLX bridge includes file IPC overhead; memory reported by MLX excludes system services.",
                              "First-path loads are not proven uncached specialization."], "runs": []}
    def save():
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    save()
    for repeat in range(args.repeats):
        arms = args.arms if repeat % 2 == 0 else list(reversed(args.arms))
        for arm in arms:
            work = output / f"repeat-{repeat + 1}-{arm}"
            work.mkdir()
            bundle = work / "bundle"
            copy_bundle(source, bundle, manifest)
            for phase in ("new-path", "same-path-fresh-process"):
                print(f"Starting {arm}: {phase}, repeat {repeat + 1}", flush=True)
                if arm.startswith("mlx"):
                    command = [args.python, REPO / "scripts/parakeet-mlx-benchmark.py", "--bundle", bundle,
                               "--fixtures", fixtures, "--scratch", work / "scratch", "--native", executable]
                    if arm == "mlx-with-ane":
                        command.append("--background-ane")
                else:
                    command = [executable, arm, bundle, fixtures]
                start = time.perf_counter()
                stdout, metrics = run(command)
                records = [json.loads(line) for line in stdout.splitlines() if line.startswith("{")]
                result = records[-1]
                result.update(phase=phase, repeat=repeat + 1, process_wall_seconds=time.perf_counter() - start)
                result.update(metrics)
                report["runs"].append(result)
                save()
                print(json.dumps({"arm": arm, "phase": phase, "first_transcript_ready_seconds":
                                  result["first_transcript_ready_seconds"]}), flush=True)
    print("Synthetic startup comparison complete; results.json saved outside Git.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except GuardFailure as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except Exception:
        print("Startup comparison failed; partial results are preserved outside Git.", file=sys.stderr)
        sys.exit(1)

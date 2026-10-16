#!/usr/bin/env python3
"""Compare LocalFlow's model with Apple's on-device speech recognizers on LibriSpeech.

Use Python 3.9 or later on Apple Silicon with macOS 26 or later. Audio comes
from the public LibriSpeech test sets only; hypotheses, binaries and the model
copy stay in the output directory outside Git. Apple's recognizers may ask for
Speech Recognition permission and may download Apple's English speech assets.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import random
import re
import shutil
import statistics
import subprocess
import sys
import time
import urllib.request


REPO = Path(__file__).resolve().parents[1]
ENGINES = ("localflow", "speech-transcriber", "sf-speech-recognizer")
SPLITS = ("test-clean", "test-other")
BOOTSTRAP_SAMPLES = 1000

ONES = ("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
        "fifteen sixteen seventeen eighteen nineteen").split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
SCALES = ((10 ** 9, "billion"), (10 ** 6, "million"), (1000, "thousand"))
ORDINALS = {"one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
            "nine": "ninth", "twelve": "twelfth"}
ABBREVIATIONS = {"mr": "mister", "mrs": "missus", "dr": "doctor"}
# LibriSpeech references use British spellings and the en-US recognizers write
# American ones. Whisper's spelling map (MIT), as used by the Open ASR Leaderboard.
SPELLING_URL = ("https://raw.githubusercontent.com/openai/whisper/"
                "c0d2f624c09dc18e709e37c2ad90c039a4eb72a2/whisper/normalizers/english.json")
SPELLING_SHA256 = "6607f948be9824d2e1b2fa2223cd94c06c45afa4e05ea0e3d5e1f2bdffde2465"


def outside_repo(path):
    path = Path(path).resolve()
    if path.is_relative_to(REPO):
        raise ValueError("Benchmark output must be outside the repository")
    return path


def cardinal(number):
    if number < 20:
        return ONES[number]
    if number < 100:
        return TENS[number // 10] + ("" if number % 10 == 0 else " " + ONES[number % 10])
    if number < 1000:
        rest = number % 100
        return ONES[number // 100] + " hundred" + ("" if rest == 0 else " " + cardinal(rest))
    for scale, name in SCALES:
        if number >= scale:
            rest = number % scale
            return cardinal(number // scale) + " " + name + ("" if rest == 0 else " " + cardinal(rest))
    raise ValueError("Unsupported number")


def ordinal(number):
    words = cardinal(number).split()
    last = words[-1]
    if last in ORDINALS:
        words[-1] = ORDINALS[last]
    elif last.endswith("y"):
        words[-1] = last[:-1] + "ieth"
    else:
        words[-1] = last + "th"
    return " ".join(words)


def year(number):
    """LibriSpeech books read four-digit years as pairs: 1850, 1905, 1900."""
    high, low = divmod(number, 100)
    if low == 0:
        return cardinal(high) + " hundred"
    return cardinal(high) + " " + ("o " + ONES[low] if low < 10 else cardinal(low))


def spoken_number(token):
    match = re.fullmatch(r"(\$?)(\d[\d,]*)(st|nd|rd|th|%)?", token)
    if not match or (len(match[2]) > 1 and match[2].startswith("0")):
        return token
    digits = match[2].replace(",", "")
    if not digits or len(digits) > 12:
        return token
    number, suffix = int(digits), match[3]
    if suffix in ("st", "nd", "rd", "th"):
        words = ordinal(number)
    elif not match[1] and not suffix and "," not in match[2] and 1100 <= number <= 1999:
        words = year(number)
    else:
        words = cardinal(number)
    if match[1]:
        words += " dollars"
    if suffix == "%":
        words += " percent"
    return words


def plain_normalize(text):
    """The word-boosting experiments' normalizer: case and punctuation only."""
    cleaned = "".join(c if c.isalnum() or c == "'" else " " for c in text.lower())
    return [word for word in (w.strip("'") for w in cleaned.split()) if word]


def load_spelling_map(path, sha256=SPELLING_SHA256):
    data = Path(path).read_bytes()
    if hashlib.sha256(data).hexdigest() != sha256:
        raise ValueError("Spelling map does not match the pinned SHA-256")
    return json.loads(data)


def fetch_spelling_map(output):
    path = output / "whisper-english-spelling.json"
    if not path.exists():
        with urllib.request.urlopen(SPELLING_URL, timeout=60) as response:
            path.write_bytes(response.read())
    return load_spelling_map(path)


def normalize(text, spelling=None):
    """Reference-style words: digits, currency, percentages and titles spelled
    out, and optionally British spellings mapped to American ones."""
    spelling = spelling or {}
    words = []
    for token in text.lower().replace("’", "'").split():
        token = token.strip(".,;:!?\"()[]{}“”'")
        if re.fullmatch(r"\$?\d[\d,]*(st|nd|rd|th|%)?", token):
            token = spoken_number(token)
        for word in plain_normalize(token):
            word = ABBREVIATIONS.get(word, word)
            words.append(spelling.get(word, word))
    return words


def align(reference, hypothesis):
    """Minimum word edits as (substitutions, deletions, insertions)."""
    previous = [(j, 0, 0, j) for j in range(len(hypothesis) + 1)]
    for i, word in enumerate(reference, 1):
        current = [(i, 0, i, 0)]
        for j, candidate in enumerate(hypothesis, 1):
            cost, sub, dele, ins = previous[j - 1]
            options = [(cost + (word != candidate), sub + (word != candidate), dele, ins)]
            cost, sub, dele, ins = previous[j]
            options.append((cost + 1, sub, dele + 1, ins))
            cost, sub, dele, ins = current[j - 1]
            options.append((cost + 1, sub, dele, ins + 1))
            current.append(min(options))
        previous = current
    return previous[-1][1:]


def load_librispeech(root, split):
    directory = Path(root) / "LibriSpeech" / split
    items = []
    for transcript in sorted(directory.glob("*/*/*.trans.txt")):
        for line in transcript.read_text().splitlines():
            identifier, _, reference = line.partition(" ")
            path = transcript.parent / f"{identifier}.flac"
            if not path.is_file():
                raise ValueError(f"Missing LibriSpeech audio for {identifier}")
            items.append({"id": identifier, "path": path, "reference": reference})
    if not items:
        raise ValueError(f"No LibriSpeech transcripts found for {split}")
    return sorted(items, key=lambda item: item["id"])


def errors(item, normalizer=normalize):
    reference = normalizer(item["reference"])
    return len(reference), align(reference, normalizer(item["hypothesis"]))


def spelled(spelling):
    return lambda text: normalize(text, spelling)


def bootstrap(rows, statistic, seed):
    generator = random.Random(seed)
    values = sorted(statistic([generator.choice(rows) for _ in rows]) for _ in range(BOOTSTRAP_SAMPLES))
    return [values[int(0.025 * BOOTSTRAP_SAMPLES)], values[int(0.975 * BOOTSTRAP_SAMPLES) - 1]]


def ratio(rows):
    words = sum(row[0] for row in rows)
    return sum(row[1] for row in rows) / words if words else 0.0


def summarize(items, seed, spelling=None):
    counted = [errors(item, spelled(spelling)) for item in items]
    unmapped = [errors(item) for item in items]
    plain = [errors(item, plain_normalize) for item in items]
    rows = [(words, sum(edits)) for words, edits in counted]
    seconds = sorted(item["seconds"] for item in items)
    return {
        "utterances": len(items),
        "reference_words": sum(words for words, _ in counted),
        "substitutions": sum(edits[0] for _, edits in counted),
        "deletions": sum(edits[1] for _, edits in counted),
        "insertions": sum(edits[2] for _, edits in counted),
        "wer": ratio(rows),
        "wer_95ci": bootstrap(rows, ratio, seed),
        "wer_without_spelling_map": ratio([(words, sum(edits)) for words, edits in unmapped]),
        "plain_wer": ratio([(words, sum(edits)) for words, edits in plain]),
        "empty_hypotheses": sum(not normalize(item["hypothesis"]) for item in items),
        "real_time_factor": sum(seconds) / sum(item["duration"] for item in items),
        "median_seconds": statistics.median(seconds),
        "p95_seconds": seconds[min(len(seconds) - 1, int(0.95 * len(seconds)))],
    }


def paired_difference(baseline, candidate, seed, spelling=None):
    """Candidate WER minus baseline WER, resampling the same utterances."""
    if set(baseline) != set(candidate):
        raise ValueError("Paired comparison needs the same utterances")
    rows = []
    for identifier in sorted(baseline):
        words, base = errors(baseline[identifier], spelled(spelling))
        _, other = errors(candidate[identifier], spelled(spelling))
        rows.append((words, sum(base), sum(other)))
    def delta(sample):
        words = sum(row[0] for row in sample)
        return (sum(row[2] for row in sample) - sum(row[1] for row in sample)) / words if words else 0.0
    return {"wer_delta": delta(rows), "wer_delta_95ci": bootstrap(rows, delta, seed)}


def read_jsonl(path):
    if not path.exists():
        return {}
    return {record["id"]: record for record in map(json.loads, path.read_text().splitlines())}


def run_engine(app, engine, bundle, items, hypotheses):
    """Append new hypotheses; an interrupted run resumes where it stopped.

    LaunchServices starts the app bundle so macOS attributes the Speech
    Recognition permission to it rather than to the terminal.
    """
    done = read_jsonl(hypotheses)
    pending = [item for item in items if item["id"] not in done]
    if pending:
        manifest, stdout, stderr = (hypotheses.with_suffix(suffix) for suffix in (".tsv", ".out", ".err"))
        manifest.write_text("".join(f"{item['id']}\t{item['path']}\n" for item in pending))
        for log in (stdout, stderr):
            log.unlink(missing_ok=True)
        # A short run can exit before `open -W` attaches and make it fail, so
        # completeness of the results, not its status, decides success.
        launch = subprocess.run(["open", "-W", "-n", "-g", "--stdout", str(stdout), "--stderr", str(stderr), str(app()),
                                 "--args", engine, str(bundle), str(manifest)], capture_output=True, text=True)
        with hypotheses.open("a") as output:
            output.write(stdout.read_text())
        done = read_jsonl(hypotheses)
        missing = [item["id"] for item in items if item["id"] not in done]
        if missing:
            raise RuntimeError(f"{engine} produced no result for {len(missing)} utterances: "
                               f"{launch.stderr.strip()} {stderr.read_text().strip()[-500:] if stderr.exists() else ''}")
    return {item["id"]: {**done[item["id"]], "reference": item["reference"]} for item in items}


def build(output):
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    app = output / "LocalFlowSpeechBenchmark.app"
    shutil.rmtree(app, ignore_errors=True)
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Info.plist").write_text("""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>apple-speech-benchmark</string>
<key>CFBundleIdentifier</key><string>com.localflow.speech-benchmark</string>
<key>CFBundleName</key><string>LocalFlow Speech Benchmark</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSSpeechRecognitionUsageDescription</key>
<string>Benchmarks Apple speech recognition on public LibriSpeech audio.</string>
</dict></plist>
""")
    sources = sorted([*(REPO / "Sources/Parakeet").glob("*.swift"), *(REPO / "Sources/Dictionary").glob("*.swift")])
    subprocess.run(["swiftc", "-parse-as-library", "-O", "-sdk", sdk, "-target", "arm64-apple-macosx26.0",
                    *map(str, sources), str(REPO / "scripts/apple-speech-benchmark.swift"),
                    "-o", str(app / "Contents/MacOS/apple-speech-benchmark")], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True, help="LocalFlow model bundle")
    parser.add_argument("--librispeech", type=Path, required=True, help="directory containing LibriSpeech/")
    parser.add_argument("--output", type=Path, required=True, help="experiment directory outside Git")
    parser.add_argument("--engines", nargs="+", choices=ENGINES, default=list(ENGINES))
    parser.add_argument("--splits", nargs="+", choices=SPLITS, default=list(SPLITS))
    parser.add_argument("--limit", type=int, help="first N utterances per split, for a smoke run")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("This benchmark requires Apple Silicon")
    if int(platform.mac_ver()[0].split(".")[0]) < 26:
        raise ValueError("This benchmark requires macOS 26 or later")
    output = outside_repo(args.output)
    output.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location("startup", REPO / "scripts/benchmark-parakeet-startup.py")
    startup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(startup)
    manifest = startup.verify_bundle(args.bundle)
    bundle = output / "bundle"
    if not bundle.exists():
        startup.copy_bundle(args.bundle.resolve(), bundle, manifest)
    built = []
    def app():
        """Build only when an engine has pending utterances, so re-scoring is cheap."""
        if not built:
            built.append(build(output))
        return built[0]
    spelling = fetch_spelling_map(output)
    report = {"schema": 1, "export_sha256": manifest["export_sha256"],
              "hardware": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
              "macOS": platform.mac_ver()[0], "date": time.strftime("%Y-%m-%d"), "limit": args.limit,
              "normalization": ("lowercase, punctuation removed, digits/currency/percent/Mr/Mrs/Dr spelled out, "
                                "British spellings mapped to American (Whisper english.json)"),
              "results": {}, "paired_vs_localflow": {}}
    for split in args.splits:
        items = load_librispeech(args.librispeech, split)[:args.limit]
        results = {}
        for engine in args.engines:
            print(f"Running {engine} on {split} ({len(items)} utterances)", flush=True)
            results[engine] = run_engine(app, engine, bundle, items, output / f"{engine}-{split}.jsonl")
            report["results"].setdefault(split, {})[engine] = summarize(list(results[engine].values()), seed=1, spelling=spelling)
            print(json.dumps({split: {engine: report["results"][split][engine]}}), flush=True)
        if "localflow" in results:
            for engine in results.keys() - {"localflow"}:
                report["paired_vs_localflow"].setdefault(split, {})[engine] = paired_difference(
                    results["localflow"], results[engine], seed=1, spelling=spelling)
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Results saved to {output / 'results.json'}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Speech benchmark failed: {error}", file=sys.stderr)
        sys.exit(1)

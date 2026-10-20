#!/usr/bin/env python3
"""Fail when a shared vectors file in linux/testdata is not used by both test suites.

Every linux/testdata/*.json file must be referenced by name from at least one
file under Tests/ (the macOS suite) and at least one file under linux/crates/
(the Rust suite). Usage: check-shared-vectors.py [repository-root]
"""
import os
from pathlib import Path
import sys

SUITES = ("Tests", "linux/crates")


def suite_text(directory):
    """Concatenated text of every readable file under directory, skipping build output."""
    chunks = []
    for root, dirs, files in os.walk(directory):
        dirs[:] = sorted(d for d in dirs if d != "target" and not d.startswith("."))
        for name in sorted(files):
            try:
                chunks.append((Path(root) / name).read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError):
                continue
    return "\n".join(chunks)


def unconsumed(repository):
    """Map each vectors file name to the suites that never reference it."""
    repository = Path(repository)
    vectors = sorted(path.name for path in (repository / "linux/testdata").glob("*.json"))
    texts = {suite: suite_text(repository / suite) for suite in SUITES}
    missing = {}
    for name in vectors:
        suites = [suite for suite in SUITES if name not in texts[suite]]
        if suites:
            missing[name] = suites
    return missing


def main(argv):
    repository = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[1]
    missing = unconsumed(repository)
    for name, suites in missing.items():
        print(f"linux/testdata/{name} is not referenced from {' or '.join(f'{s}/' for s in suites)}; "
              "every shared vectors file must be consumed by both the Swift and the Rust tests",
              file=sys.stderr)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

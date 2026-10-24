"""Data preparation commands (run as supervised jobs).

    ./python -m lfspk.harness.prep extract-zip ARCHIVE DEST [--prefix P ...]
    ./python -m lfspk.harness.prep index          # corpus index JSONs
    ./python -m lfspk.harness.prep bank --split dev [--workers 8]

Archives are untrusted: members are validated (no absolute paths, no '..',
regular files only, size budget) before extraction into a fresh directory.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import zipfile
from pathlib import Path, PurePosixPath

MAX_MEMBER_BYTES = 512 << 20
MAX_TOTAL_BYTES = 8 << 30


def safe_extract_zip(archive: Path, dest: Path, prefixes: list[str]) -> int:
    if dest.exists() and any(dest.iterdir()):
        raise SystemExit(f"{dest} exists and is not empty")
    dest.mkdir(parents=True, exist_ok=True)
    total = count = 0
    with zipfile.ZipFile(archive) as z:
        for info in z.infolist():
            name = info.filename
            p = PurePosixPath(name)
            if p.is_absolute() or ".." in p.parts or "\\" in name:
                raise SystemExit(f"unsafe member {name!r}")
            if prefixes and not any(name.startswith(x) for x in prefixes):
                continue
            if info.is_dir():
                continue
            mode = (info.external_attr >> 16) & 0o170000
            if mode not in (0, 0o100000):
                raise SystemExit(f"non-regular member {name!r}")
            if info.file_size > MAX_MEMBER_BYTES:
                raise SystemExit(f"member too large {name!r}")
            total += info.file_size
            if total > MAX_TOTAL_BYTES:
                raise SystemExit("archive exceeds total budget")
            out = dest / Path(*p.parts)
            out.parent.mkdir(parents=True, exist_ok=True)
            with z.open(info) as src, open(out, "wb") as dst:
                shutil.copyfileobj(src, dst)
            count += 1
    return count


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    ex = sub.add_parser("extract-zip")
    ex.add_argument("archive", type=Path)
    ex.add_argument("dest", type=Path)
    ex.add_argument("--prefix", action="append", default=[])
    ix = sub.add_parser("index")
    ix.add_argument("--splits", default="dev,test,train")
    ix.add_argument("--skip-aux", action="store_true", help="rebuild only the LibriSpeech indexes")
    bk = sub.add_parser("bank")
    bk.add_argument("--split", required=True)
    bk.add_argument("--workers", type=int, default=8)
    bk.add_argument("--count", type=int, default=None)
    a = ap.parse_args(argv)
    if a.cmd == "extract-zip":
        n = safe_extract_zip(a.archive, a.dest, a.prefix)
        print(f"extracted {n} files to {a.dest}")
    elif a.cmd == "index":
        from .corpora import build_index

        build_index(a.splits.split(","), aux=not a.skip_aux)
    elif a.cmd == "bank":
        from .corpora import build_bank

        build_bank(a.split, a.workers, a.count)


if __name__ == "__main__":
    sys.exit(main())

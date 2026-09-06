#!/usr/bin/env python3
"""Package the Go HTTP rendezvous server for a Pong release."""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import stat
import tarfile

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip().lstrip("v")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", type=Path, required=True)
    ap.add_argument("--arch", choices=("x64", "arm64"), default="x64")
    args = ap.parse_args()

    binary = args.binary.resolve()
    if not binary.is_file():
        raise SystemExit(f"binary does not exist: {binary}")

    name = f"pong-rendezvous-v{VERSION}-linux-{args.arch}"
    stage = DIST / name
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)

    out = stage / "pong-rendezvous"
    shutil.copy2(binary, out)
    out.chmod(out.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    shutil.copy2(ROOT / "server" / "README.md", stage / "README.md")
    shutil.copy2(ROOT / "VERSION", stage / "VERSION")

    archive = DIST / f"{name}.tar.gz"
    archive.unlink(missing_ok=True)
    with tarfile.open(archive, "w:gz", compresslevel=9) as tf:
        tf.add(stage, arcname=name)
    print(archive)


if __name__ == "__main__":
    main()

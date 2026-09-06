#!/usr/bin/env python3
"""Create portable Pong release archives from an already-built executable."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import stat
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
ASSETS = ROOT / "assets"
VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
DISPLAY_VERSION = VERSION if VERSION.startswith("v") else f"v{VERSION}"


def copy_common(dst: Path) -> None:
    shutil.copytree(ASSETS, dst / "assets", dirs_exist_ok=True)
    shutil.copy2(ROOT / "README.md", dst / "README.md")
    shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.md", dst / "THIRD_PARTY_NOTICES.md")
    shutil.copy2(ROOT / "VERSION", dst / "VERSION")


def make_executable(path: Path) -> None:
    mode = path.stat().st_mode
    path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def zip_tree(source: Path, archive: Path, root_name: str | None = None) -> None:
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for item in sorted(source.rglob("*")):
            if item.is_dir():
                continue
            rel = item.relative_to(source)
            arcname = Path(root_name) / rel if root_name else rel
            zf.write(item, arcname.as_posix())


def package_windows(binary: Path, arch: str, raylib_dll: Path) -> Path:
    name = f"pong-{DISPLAY_VERSION}-windows-{arch}"
    stage = DIST / name
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)
    shutil.copy2(binary, stage / "pong.exe")
    shutil.copy2(raylib_dll, stage / "raylib.dll")
    copy_common(stage)
    archive = DIST / f"{name}.zip"
    archive.unlink(missing_ok=True)
    zip_tree(stage, archive, name)
    return archive


def package_linux(binary: Path, arch: str) -> Path:
    name = f"pong-{DISPLAY_VERSION}-linux-{arch}"
    stage = DIST / name
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)
    out = stage / "pong"
    shutil.copy2(binary, out)
    make_executable(out)
    copy_common(stage)
    archive = DIST / f"{name}.tar.gz"
    archive.unlink(missing_ok=True)
    with tarfile.open(archive, "w:gz", compresslevel=9) as tf:
        tf.add(stage, arcname=name)
    return archive


def package_macos(binary: Path, arch: str) -> Path:
    name = f"pong-{DISPLAY_VERSION}-macos-{arch}"
    stage = DIST / name
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)

    app = stage / "Pong.app"
    contents = app / "Contents"
    macos = contents / "MacOS"
    macos.mkdir(parents=True)

    out = macos / "pong"
    shutil.copy2(binary, out)
    make_executable(out)
    shutil.copytree(ASSETS, macos / "assets", dirs_exist_ok=True)

    plist = {
        "CFBundleName": "Pong",
        "CFBundleDisplayName": "UDP Pong",
        "CFBundleExecutable": "pong",
        "CFBundleIdentifier": "game.ipv6udp.pong",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": VERSION.lstrip("v"),
        "CFBundleVersion": VERSION.lstrip("v"),
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "12.0",
    }
    with (contents / "Info.plist").open("wb") as f:
        plistlib.dump(plist, f, sort_keys=True)

    shutil.copy2(ROOT / "README.md", stage / "README.md")
    shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.md", stage / "THIRD_PARTY_NOTICES.md")
    shutil.copy2(ROOT / "VERSION", stage / "VERSION")

    archive = DIST / f"{name}.zip"
    archive.unlink(missing_ok=True)
    zip_tree(stage, archive, name)
    return archive


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", choices=("windows", "linux", "macos"), required=True)
    ap.add_argument("--arch", choices=("x64", "arm64"), required=True)
    ap.add_argument("--binary", type=Path, required=True)
    ap.add_argument("--raylib-dll", type=Path)
    args = ap.parse_args()

    binary = args.binary.resolve()
    if not binary.is_file():
        raise SystemExit(f"binary does not exist: {binary}")
    if not ASSETS.is_dir():
        raise SystemExit(f"assets directory does not exist: {ASSETS}")

    DIST.mkdir(exist_ok=True)
    if args.platform == "windows":
        if args.raylib_dll is None:
            raise SystemExit("--raylib-dll is required for Windows packages")
        raylib_dll = args.raylib_dll.resolve()
        if not raylib_dll.is_file():
            raise SystemExit(f"raylib DLL does not exist: {raylib_dll}")
        archive = package_windows(binary, args.arch, raylib_dll)
    elif args.platform == "linux":
        archive = package_linux(binary, args.arch)
    else:
        archive = package_macos(binary, args.arch)

    print(archive)


if __name__ == "__main__":
    main()

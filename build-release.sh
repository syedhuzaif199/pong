#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
case "$(uname -s)" in
  Linux)
    arch="x64"
    [ "$(uname -m)" = "aarch64" ] && arch="arm64"
    odin build . -out:build/pong -o:speed "$@"
    python3 scripts/package_release.py --platform linux --arch "$arch" --binary build/pong
    ;;
  Darwin)
    arch="x64"
    [ "$(uname -m)" = "arm64" ] && arch="arm64"
    odin build . -out:build/pong -o:speed "$@"
    python3 scripts/package_release.py --platform macos --arch "$arch" --binary build/pong
    ;;
  *)
    echo "Unsupported OS. On Windows use build-release.bat." >&2
    exit 1
    ;;
esac

# Releasing Pong

v10 retains the reproducible three-platform release pipeline introduced in v9.

## Toolchain

The GitHub Actions workflow is pinned to Odin `dev-2026-09` through the `ODIN_VERSION` environment variable in `.github/workflows/release.yml`.

## Build locally

Development build:

```bash
odin build . -out:pong
```

Optimized release archive on Linux/macOS:

```bash
./build-release.sh
```

Optimized Windows release archive:

```powershell
build-release.bat
```

Archives are written to `dist/`.

## GitHub Actions

The workflow can be launched manually from the Actions tab. A manual run builds and uploads CI artifacts but does not create a GitHub Release.

To publish a release, update `VERSION` and `APP_VERSION`, commit the changes, then create and push a version tag:

```bash
git tag v10.0.0
git push origin v10.0.0
```

The tag run builds:

- `pong-v10.0.0-windows-x64.zip`
- `pong-v10.0.0-linux-x64.tar.gz`
- `pong-v10.0.0-macos-arm64.zip`

and creates a GitHub Release containing those archives.

## Audio assets

The release archives include both v10 music loops under `assets/`:

- `pong_menu_loop.wav`
- `pong_gameplay_loop.wav`

The packager copies them unchanged on all platforms.

## macOS

The macOS archive contains `Pong.app`. It is not code-signed or notarized yet, so Gatekeeper may warn when it is downloaded from the Internet. Signing/notarization requires Apple developer credentials and is deliberately not part of the public CI workflow yet.

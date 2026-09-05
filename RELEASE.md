# Releasing Pong

This project uses semantic-style public release tags such as `v1.0.0`, `v1.1.0`, and `v1.1.1`. Internal development milestone numbers used before the first public release are not part of the public version history.

## v1.1.0 release scope

Before tagging v1.1.0, verify the feature release actually includes:

- IPv4 gameplay;
- dual-stack host gameplay where supported;
- IPv6-preferred LAN joining;
- automatic IPv4 LAN fallback;
- IPv4-only LAN hosting/discovery;
- direct IPv4 and IPv6 connect;
- IPv6-preferred / IPv4-fallback COPY INVITE;
- Windows firewall/path documentation;
- no visible references to the old internal milestone numbering.

Gameplay protocol remains **v4** and discovery protocol remains **v1** because the existing packet formats remain compatible.

## Toolchain

The GitHub Actions workflow is pinned to Odin `dev-2026-07` through the `ODIN_VERSION` environment variable in `.github/workflows/release.yml`.

Before changing the pinned Odin version, test networking and packaging locally on the affected platforms.

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

## Required networking smoke tests

Before publishing v1.1.0, test at least:

1. IPv6-capable host + IPv6-capable client: LAN discovery joins over IPv6.
2. IPv6-capable host + client without usable global IPv6: LAN discovery joins over IPv4.
3. IPv6 first path deliberately unavailable: LAN join retries over IPv4.
4. Host without usable global IPv6: it still advertises on LAN and accepts IPv4 gameplay.
5. Direct IPv4 literal connect.
6. Direct IPv6 literal connect.
7. Full lobby, countdown, match and rematch over both transports where possible.

The lobby/network stats display the selected gameplay transport and are useful for confirming whether IPv4 or IPv6 was chosen.

## Windows release check

Windows Firewall application rules are path-specific. A `pong.exe` that was allowed in one directory may not have the same permission after it is moved or extracted elsewhere.

For a realistic release test:

1. build/package the Windows archive;
2. extract it into a fresh, permanent directory;
3. run that extracted `pong.exe`;
4. grant the Windows firewall prompt for the intended network profile if shown;
5. verify both joining and hosting from that extracted location;
6. verify UDP `37776` discovery and the selected gameplay UDP port.

Do not diagnose a release binary solely by comparing it with a source-tree `pong.exe` that already has an existing firewall rule.

## GitHub Actions

The workflow can be launched manually from the Actions tab. A manual run builds and uploads CI artifacts but does not create a GitHub Release.

To publish `v1.1.0`, ensure `VERSION` and `APP_VERSION` both identify `1.1.0`, commit the changes, then create and push the tag:

```bash
git tag -a v1.1.0 -m "Pong v1.1.0"
git push origin v1.1.0
```

The tag run builds:

- `pong-v1.1.0-windows-x64.zip`
- `pong-v1.1.0-linux-x64.tar.gz`
- `pong-v1.1.0-macos-arm64.zip`

and creates a GitHub Release containing those archives.

## Audio assets

Release archives include both music loops under `assets/`:

- `pong_menu_loop.wav`
- `pong_gameplay_loop.wav`

The packager copies them unchanged on all platforms.

## macOS

The macOS archive contains `Pong.app`. It is not code-signed or notarized yet, so Gatekeeper may warn when it is downloaded from the Internet. Signing/notarization requires Apple developer credentials and is deliberately not part of the public CI workflow yet.

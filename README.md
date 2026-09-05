# IPv6 UDP Pong — Odin + raylib (v9)

A small two-player Pong game written in Odin with raylib. Gameplay is host-authoritative IPv6/UDP. v9 is the release/distribution milestone: it keeps the v8 networking/gameplay behavior while making the project portable to run and easy to build for Windows, Linux, and Apple Silicon macOS.

> **Gameplay protocol v4 / discovery protocol v1:** v9 remains directly network-compatible with v6-v8. No gameplay packet format changed in this release.

## What's new in v9

### Portable runtime layout

The game now resolves its bundled assets relative to the executable instead of assuming it was started from the source directory. Release archives can therefore be launched from Explorer, Finder, a terminal in another directory, or a desktop shortcut.

For `odin run .`, the game falls back to the original working directory if Odin's temporary executable directory does not contain `assets/`.

### Proper per-user configuration path

`pong.cfg` is now written to a user configuration directory rather than beside the executable:

- Windows: `%APPDATA%/IPv6UDPPong/pong.cfg`
- Linux: `$XDG_CONFIG_HOME/IPv6UDPPong/pong.cfg`, or `~/.config/IPv6UDPPong/pong.cfg`
- macOS: `~/Library/Application Support/IPv6UDPPong/pong.cfg`

If v9 cannot find the new config file, it still reads an old local `pong.cfg` from v8 or earlier as a migration fallback. The next save writes it to the new location.

### Release builds

Local release helpers:

```bash
./build-release.sh
```

or on Windows:

```powershell
build-release.bat
```

Release builds use Odin's speed optimization. Windows release builds also use `-subsystem:windows` so an extra console window does not appear when the game is double-clicked.

The packager creates:

```text
pong-v9.0.0-windows-x64.zip
pong-v9.0.0-linux-x64.tar.gz
pong-v9.0.0-macos-arm64.zip
```

The macOS archive contains a minimal `Pong.app` bundle with the executable and audio assets inside it.

### GitHub Actions

`.github/workflows/release.yml` builds all three platforms using Odin `dev-2026-09`:

- Windows x64 — `windows-latest`
- Linux x64 — `ubuntu-24.04`
- macOS arm64 — `macos-15`

A manual workflow run produces downloadable Actions artifacts. Pushing a version tag such as `v9.0.0` additionally creates a GitHub Release and uploads all three archives.

See `RELEASE.md` for the release procedure.

## Existing features

- host-authoritative IPv6/UDP Pong
- per-session IDs and handshake nonces
- player names
- pre-game lobby and ready states
- synchronized authoritative 3-2-1-GO countdown
- mutual rematch negotiation
- RTT/ping, inferred gameplay packet loss, UDP counters and timeout diagnostics
- local pause/settings overlay that does not pause the remote match
- music + persistent volume/mute
- SFX + persistent volume/mute
- fullscreen/windowed mode and Alt+Enter
- fixed 960x540 logical canvas with scaling/letterboxing
- ball trail, impact particles, paddle flash and score feedback
- persistent per-game host rule defaults
- IPv4-broadcast LAN discovery for IPv6 games
- copy/paste direct IPv6 invites
- remembered direct-connect endpoint

## Development build

From the project directory:

```bash
odin build . -out:pong
```

Windows:

```powershell
odin build . -out:pong.exe
```

Or run directly during development:

```bash
odin run .
```

## Quick local test

Start two copies. Host on the first:

```text
PLAY ONLINE -> HOST GAME
Port: 7777
START HOSTING
```

Join on the second:

```text
PLAY ONLINE -> JOIN GAME
IPv6: ::1
Port: 7777
CONNECT
```

## LAN discovery

Discovery uses UDP port **37776** and IPv4 broadcast only to find nearby hosts. The actual match still uses IPv6/UDP. A discovery response advertises the host's IPv6 endpoint and gameplay protocol version.

Discovery is best-effort. Guest Wi-Fi isolation, firewalls, VPNs, and multi-adapter routing can prevent it; direct IPv6 connect remains available.

## Linux / UFW

The firewall behavior encountered during development required these gameplay rules:

```bash
sudo ufw allow 7777/udp
sudo ufw allow in proto udp from any port 7777
```

For LAN discovery, if required:

```bash
sudo ufw allow 37776/udp
sudo ufw allow in proto udp from any port 37776
```

A normal stateful firewall may not require all source-port rules.

## Internet play

Internet play currently uses direct IPv6. v9 does not yet implement STUN, ICE, UDP hole punching, TURN/relay fallback, or invite-code rendezvous. Those can be layered on later without replacing the existing direct IPv6 transport.

## Release caveats

- The macOS `.app` is currently unsigned and unnotarized.
- There is not yet a custom platform executable/app icon; that is cosmetic and can be added without changing the release architecture.
- Windows and Linux archives are portable folders rather than installers/packages.

See `THIRD_PARTY_NOTICES.md` for dependency notices.

### Linux IPv6 address discovery

On current Odin builds, `core:net.enumerate_interfaces()` is stubbed on Linux. Pong therefore reads `/proc/net/if_inet6` on Linux when choosing the IPv6 address used for LAN advertisements and COPY INVITE. It prefers a non-temporary global IPv6 address and falls back to a temporary global address if necessary. Gameplay networking itself is unchanged.

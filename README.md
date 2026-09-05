# IPv6 UDP Pong — Odin + raylib (v10)

A small two-player Pong game written in Odin with raylib. Gameplay is host-authoritative IPv6/UDP. v10 builds on the v9 release/distribution foundation and adds separate menu and gameplay music with synchronized match-start transitions.

> **Gameplay protocol v4 / discovery protocol v1:** v10 remains directly network-compatible with v6-v9. No gameplay or discovery packet format changed in this release.

## What's new in v10

### Separate menu and gameplay music

v10 bundles two independent looping music streams:

- `assets/pong_menu_loop.wav` — main menu, online/setup screens, lobby, and game-over/rematch waiting
- `assets/pong_gameplay_loop.wav` — active gameplay only

Both uploaded WAV files are bundled unchanged so their supplied musical boundaries and loop crossfades are preserved.

### Match-start audio timing

When both players become ready:

1. the host remains in the lobby for a short pre-countdown transition,
2. menu music quickly fades to silence on both peers,
3. the authoritative synchronized `3 → 2 → 1 → GO!` countdown begins,
4. gameplay music restarts from its beginning on `GO!`.

The same sequence is used for mutually accepted rematches. Gameplay music fades out at game over and the menu loop returns while the players decide whether to rematch.

### v9 distribution foundation retained

The portable runtime layout, per-user `pong.cfg`, release scripts, GitHub Actions workflow, Windows GUI subsystem build, Linux archive, and native Apple Silicon `Pong.app` packaging remain in place.

Local release helpers:

```bash
./build-release.sh
```

or on Windows:

```powershell
build-release.bat
```

The packager creates:

```text
pong-v10.0.0-windows-x64.zip
pong-v10.0.0-linux-x64.tar.gz
pong-v10.0.0-macos-arm64.zip
```

The workflow remains pinned to Odin `dev-2026-09`.

## Existing features

- host-authoritative IPv6/UDP Pong
- per-session IDs and handshake nonces
- player names
- pre-game lobby and ready states
- synchronized authoritative 3-2-1-GO countdown
- mutual rematch negotiation
- RTT/ping, inferred gameplay packet loss, UDP counters and timeout diagnostics
- local pause/settings overlay that does not pause the remote match
- separate menu/gameplay music + persistent master volume/mute
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

Discovery is best-effort. Guest Wi-Fi isolation and firewalls can prevent it; direct IPv6 connect remains available. On Windows, Pong binds the discovery client to an active non-tunnel IPv4 interface with a gateway before sending the broadcast. This avoids the common case where `255.255.255.255` is accidentally routed through WSL, Hyper-V, VPN, or another virtual adapter. The Join screen shows the chosen address as `LAN search via ...`.

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

Internet play currently uses direct IPv6. v10 does not yet implement STUN, ICE, UDP hole punching, TURN/relay fallback, or invite-code rendezvous. Those can be layered on later without replacing the existing direct IPv6 transport.

## Release caveats

- The macOS `.app` is currently unsigned and unnotarized.
- There is not yet a custom platform executable/app icon; that is cosmetic and can be added without changing the release architecture.
- Windows and Linux archives are portable folders rather than installers/packages.

See `THIRD_PARTY_NOTICES.md` for dependency notices.

### Linux IPv6 address discovery

On current Odin builds, `core:net.enumerate_interfaces()` is stubbed on Linux. Pong therefore reads `/proc/net/if_inet6` on Linux when choosing the IPv6 address used for LAN advertisements and COPY INVITE. It prefers a non-temporary global IPv6 address and falls back to a temporary global address if necessary. Gameplay networking itself is unchanged.

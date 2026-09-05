# UDP Pong — Odin + raylib (v1.1.0)

A small two-player Pong game written in Odin with raylib. Gameplay is host-authoritative UDP with dual-stack IPv4/IPv6 support. LAN discovery uses IPv4 broadcast, prefers direct IPv6 gameplay when both peers have it, and automatically falls back to IPv4 when needed.

> **App version v1.1.0 · gameplay protocol v4 · discovery protocol v1**
>
> Application versions and network protocol versions are independent. The protocol numbers only change when packet compatibility changes.

## What's new in v1.1.0

- IPv4 gameplay support
- dual-stack hosting on one gameplay port where the platform supports it
- IPv6-preferred LAN joins with automatic IPv4 fallback
- IPv4-only LAN hosts can now be discovered and joined
- direct connect accepts either IPv4 or IPv6 literals
- COPY INVITE prefers IPv6 and uses IPv4 when no advertisable IPv6 address exists
- lobby and network diagnostics show the transport actually in use
- public versioning cleaned up to remove the old pre-release/internal milestone labels
- release CI pinned to the tested Odin `dev-2026-07` toolchain
- expanded Windows portable-ZIP/firewall guidance

## Features

- host-authoritative UDP Pong over IPv4 or IPv6
- IPv6 preferred when it is usable, with IPv4 fallback for LAN play
- per-session IDs and handshake nonces
- player names
- pre-game lobby and ready states
- synchronized authoritative 3-2-1-GO countdown
- mutual rematch negotiation
- RTT/ping, inferred gameplay packet loss, UDP counters and timeout diagnostics
- local pause/settings overlay that does not pause the remote match
- separate looping menu and gameplay music
- menu music quickly fades before the synchronized countdown
- gameplay music starts from the beginning on `GO!`
- persistent music/SFX volume and mute settings
- fullscreen/windowed mode and Alt+Enter
- fixed 960x540 logical canvas with scaling/letterboxing
- ball trail, impact particles, paddle flash and score feedback
- persistent per-game host rule defaults
- IPv4-broadcast LAN discovery
- copy/paste IPv4 or IPv6 direct invites
- remembered direct-connect endpoint

## Music behavior

Pong bundles two independent loops:

- `assets/pong_menu_loop.wav` — main menu, setup screens, lobby, and game-over/rematch waiting
- `assets/pong_gameplay_loop.wav` — active gameplay only

When both players are ready, menu music quickly fades to silence. The authoritative synchronized countdown then runs, and gameplay music starts from its beginning on `GO!`. The same transition is used for mutually accepted rematches.

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

The release workflow is pinned to Odin `dev-2026-07`, matching the locally validated toolchain family.

## Release builds

Linux/macOS:

```bash
./build-release.sh
```

Windows:

```powershell
build-release.bat
```

The packager writes archives to `dist/`:

```text
pong-v1.1.0-windows-x64.zip
pong-v1.1.0-linux-x64.tar.gz
pong-v1.1.0-macos-arm64.zip
```

The GitHub Actions release workflow is pinned to Odin `dev-2026-07`.

## Quick local test

Start two copies. Host on the first:

```text
PLAY ONLINE -> HOST GAME
Port: 7777
START HOSTING
```

Join on the second with either loopback family:

```text
PLAY ONLINE -> JOIN GAME
IP address: ::1
Port: 7777
CONNECT
```

or:

```text
IP address: 127.0.0.1
Port: 7777
CONNECT
```

## Dual-stack gameplay

The host first tries to create one IPv6 UDP socket with `IPV6_V6ONLY` disabled, then binds it to the chosen gameplay port. That socket accepts native IPv6 clients and IPv4 clients on the same port. If the platform cannot create that dual-stack socket, Pong falls back to an IPv4 gameplay socket instead of refusing to host.

A direct-connect client creates a socket matching the literal address entered by the player:

- IPv6 literal → IPv6 UDP client
- IPv4 literal → IPv4 UDP client

No DNS/hostname resolution is currently exposed by the UI.

## LAN discovery and automatic fallback

LAN discovery uses UDP port **37776** over IPv4 broadcast. The discovery reply identifies the gameplay port and, when available, the host's preferred global IPv6 address. The client also learns the host's IPv4 address directly from the source address of that discovery reply.

For a discovered LAN game, Pong chooses the gameplay route as follows:

1. if the host advertises usable IPv6 and the client has usable global IPv6, try IPv6 first;
2. if that IPv6 handshake does not answer quickly, retry the same host over the discovered IPv4 address;
3. if the client has no usable global IPv6, use IPv4 immediately.

This means a LAN no longer needs global IPv6 just to play Pong.

Discovery itself is best-effort. Guest Wi-Fi/client isolation and firewall rules can prevent broadcast discovery even when direct IP gameplay works.

On Windows, Pong binds the discovery client to an active non-tunnel IPv4 interface with a gateway before sending the broadcast. This avoids the common case where `255.255.255.255` is routed through WSL, Hyper-V, a VPN, or another virtual adapter. The Join screen shows the chosen interface address as `LAN search via ...`.

## COPY INVITE

When hosting, COPY INVITE chooses:

1. a usable global IPv6 address, formatted as `[IPv6]:port`, when available;
2. otherwise the selected local IPv4 address, formatted as `IPv4:port`.

For Internet play, an IPv4 invite is only reachable when the host's NAT/router/firewall configuration permits inbound UDP to that machine. Pong does not yet perform NAT traversal automatically.

## Windows firewall and portable ZIP

**Extract the ZIP to a normal, permanent folder before running `pong.exe`.** Do not run the game directly from inside the ZIP archive.

Windows Firewall application permissions are associated with the executable's **full path**. Allowing one copy of Pong does not necessarily allow another copy stored somewhere else. For example, permission for:

```text
C:\Games\Pong\pong.exe
```

does not automatically apply to:

```text
C:\Users\you\Downloads\pong-v1.1.0-windows-x64\pong.exe
```

If Windows asks whether Pong may communicate through the firewall, allow it on the networks on which you intend to play (normally **Private networks** for LAN play). If you later move `pong.exe`, Windows may require permission again for the new path.

If networking works from one Pong folder but not another, check Windows Defender Firewall's allowed-app/rule list for stale Pong paths rather than disabling the firewall globally.

For LAN play, both gameplay UDP (default `7777`, or your chosen port) and discovery UDP (`37776`) may need to be permitted.

## Linux / UFW

If UFW is enabled and blocks the game, these gameplay rules may be required for the default port:

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

### Linux interface discovery

The Odin toolchain pinned by this project currently has a Linux `core:net.enumerate_interfaces()` regression. Pong therefore uses small Linux-specific fallbacks:

- `/proc/net/if_inet6` to choose an advertisable global IPv6 address, preferring a non-temporary address;
- libc `getifaddrs()` to identify a usable local IPv4 address for invite/display purposes.

Actual gameplay still uses `core:net` UDP sockets.

## Internet play

Direct Internet play supports both address families, but their practical reachability differs:

- **IPv6:** usually the preferred direct path when both peers have usable global IPv6; host firewall rules still matter.
- **IPv4:** works directly only when the host is publicly reachable or the router/NAT forwards the gameplay UDP port to the host.

Pong does **not** yet implement STUN, ICE, UDP hole punching, TURN/relay fallback, or invite-code rendezvous. Those remain future work for making Internet play work automatically behind typical NATs.

## Release caveats

- The macOS `.app` is currently unsigned and unnotarized.
- There is not yet a custom platform executable/app icon.
- Windows and Linux archives are portable folders rather than installers/packages.
- Windows users may need to grant firewall permission for the folder from which `pong.exe` is actually run; see **Windows firewall and portable ZIP** above.

See `THIRD_PARTY_NOTICES.md` for dependency notices.

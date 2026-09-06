# UDP Pong — Odin + raylib (v1.5.0)

A small Pong game written in Odin with raylib, with solo CPU, local 2-player, and online multiplayer. Gameplay is host-authoritative UDP. Pong supports IPv4 and IPv6, LAN discovery, direct IP play, short-code Internet play, desktop controllers, and Android touch controls.

> **App v1.5.0 · gameplay protocol v4 · discovery protocol v1 · HTTP rendezvous protocol v1**
>
> Application versions and wire-protocol versions are independent. v1.5 keeps gameplay protocol 4, so its online mode remains wire-compatible with v1.3/v1.4 peers.


## What's new in v1.5.0

**Local Play** is now a first-class part of Pong:

- **VS CPU** with Easy, Normal, and Hard difficulty. Difficulty changes reaction time, aiming error, and dead-zone only; the CPU never exceeds the configured paddle speed.
- **Local 2P** on desktop: Player 1 uses `W/S` or controller 1; Player 2 uses arrow keys or controller 2.
- **Local 2P on Android**: each player owns one half of the touchscreen, so two simultaneous touches can control both paddles.
- Local matches use the same winning-score, ball-speed, and paddle-speed rules as online matches.
- Local pause actually freezes simulation, while online pause retains the existing host-authoritative behavior.
- Local rematches start immediately without network ready-state ceremony.

Online gameplay is intentionally unchanged and remains gameplay protocol **4**, so v1.5 does not introduce a protocol bump merely for local modes.

## What's new in v1.4.0

### Controls

- one paddle-input layer for keyboard, controller, and Android touch
- controller D-pad / left stick controls the paddle with the same fixed speed as keyboard
- controller A/Cross confirms ready/rematch actions; B/Circle backs out; Start opens the in-game pause menu
- Android supports both hold-upper/lower-half controls and swipe/drag direction control
- swipe does **not** introduce variable paddle speed; every platform still sends only `-1`, `0`, or `+1` input
- larger Android MENU target, Android Back opens the same pause overlay, and persistent low-opacity touch/swipe affordances make the mobile controls discoverable

### Resilience and lifecycle

- transient gameplay/lobby packet loss now enters a 10-second reconnect grace window instead of immediately destroying the session
- after 1.5 seconds of silence the host freezes authoritative gameplay while both peers continue probing
- a recovered path resumes the existing session automatically without changing protocol 4
- Android background/foreground handling suspends/resumes music, saves settings, and exposes a short resume/reconnect status banner

### Network feel and diagnostics

- RTT jitter and authoritative-state arrival jitter are measured separately
- net stats now show RTT, jitter, packet loss, received stream rate, transport, and active input source
- client extrapolation uses measured RTT with a bounded prediction horizon
- visual correction adapts to jitter: crisp on clean links, more damped on unstable links, with a hard catch-up path for large errors
- room-code setup shows explicit progress through DNS/STUN, rendezvous, peer discovery, UDP punching, and connected states

### Android and release polish

- Android settings remain in app-private `SharedPreferences` and survive process restarts
- Android launcher metadata/icon are included
- Windows executables embed the Pong icon directly; macOS releases are real `Pong.app` bundles with `.icns`; Linux releases ship a freedesktop launcher/icon installer
- GitHub Actions can produce a release-signed APK and AAB when Android signing secrets are configured
- without signing secrets CI publishes an explicitly named `-debug.apk` fallback rather than disguising a debug build as a release artifact

v1.5.0 still does **not** include TURN/relay gameplay. Symmetric NAT, restrictive CGNAT, enterprise firewalls, or networks that block peer-to-peer UDP can still prevent a direct connection.

## Connection modes

From **PLAY ONLINE** there are four paths:

- **HOST WITH CODE** — discover the host's public UDP mapping with Cloudflare STUN, then create a room through the configured HTTP rendezvous URL.
- **JOIN WITH CODE** — discover the joiner's public mapping, join the same room over HTTP, then punch the exchanged UDP candidates.
- **HOST LAN / DIRECT** — host the existing dual-stack UDP game directly.
- **JOIN LAN / DIRECT** — use LAN discovery or enter an IPv4/IPv6 address manually.

The rendezvous service introduces peers but does not carry gameplay traffic after a direct path is established.

## Room-code Internet flow

The two infrastructure roles are intentionally separate:

```text
                     Cloudflare STUN
                 stun.cloudflare.com:3478/udp
                       ^           ^
                       |           |
             same Pong UDP     same Pong UDP
                  socket           socket
                       |           |
                     HOST        JOINER
                       |           |
                       | HTTPS     | HTTPS
                       v           v
                  HTTP rendezvous service
                    e.g. Render Web Service
                       |           |
                       +-- candidates --+

                     HOST <=======> JOINER
                         direct UDP
                    PUNCH / PUNCH_ACK
                           then
               HELLO / WELCOME / STATE / INPUT
```

The steps are:

1. Each client opens its Pong gameplay UDP socket.
2. That same socket sends a STUN Binding request to Cloudflare.
3. Cloudflare returns the public IP/port mapping seen for that socket.
4. The host sends its candidates to the HTTP rendezvous service and receives a six-character room code.
5. The joiner sends the room code plus its candidates to the same HTTP service.
6. Both clients poll the short-lived room until the service returns the peer candidates and shared punch nonce.
7. Both clients send UDP `PUNCH` packets toward the candidates simultaneously.
8. The first working direct path is adopted, then the normal Pong protocol takes over.

Candidate preference is:

1. usable global IPv6;
2. local IPv4;
3. STUN-observed public endpoint.

The HTTP service never needs a public UDP port and never sees gameplay packets.

## Cloudflare STUN

Pong uses:

```text
stun.cloudflare.com:3478/udp
```

Cloudflare documents this as its public STUN endpoint. Pong sends STUN from the **same UDP socket used for gameplay**, because a NAT can assign different public ports to different local sockets.

Cloudflare STUN and the Pong rendezvous service are independent. If STUN times out, Pong can still exchange global IPv6/local candidates, but Internet IPv4 hole punching will usually be unavailable.

Official Cloudflare reference:

- https://developers.cloudflare.com/realtime/turn/

## HTTP rendezvous service

Server source is in `server/`. It is a normal Go HTTP service with no database and no UDP listener.

Endpoints:

```text
GET  /healthz
POST /v1/create
POST /v1/join
POST /v1/wait
POST /v1/leave
```

Rooms are short-lived and stored in memory. A server restart invalidates outstanding room codes, which is acceptable for this matchmaking use case.

Run locally:

```bash
cd server
go test ./...
go build -o pong-rendezvous .
./pong-rendezvous -listen 0.0.0.0:10000
```

Then configure Pong with:

```text
http://127.0.0.1:10000
```

### Deploy on Render

The repository root includes `render.yaml`. The Go service reads Render's `PORT` environment variable and binds `0.0.0.0:$PORT`.

You can deploy the repository as a Render Blueprint, or create a Web Service manually with:

```text
Root directory:   server
Build command:    go build -trimpath -ldflags="-s -w" -o pong-rendezvous .
Start command:    ./pong-rendezvous
Health check:     /healthz
```

After deployment, enter the Render HTTPS URL in both clients, for example:

```text
https://pong-rendezvous-example.onrender.com
```

No Render UDP port or firewall rule is required for rendezvous. Render only carries HTTPS control requests.

Official Render reference:

- https://render.com/docs/web-services

## Hole-punching limitation

STUN + rendezvous is enough for many home NATs, but not every NAT permits direct peer-to-peer UDP.

If Pong reports:

```text
UDP hole punching failed. This NAT may require a relay/TURN path.
```

then none of the exchanged direct candidates worked within the punching window. A future release can add TURN/relay fallback.

## Existing gameplay features

- host-authoritative gameplay simulation
- IPv4 + IPv6 UDP gameplay
- dual-stack host socket where supported, with IPv4-only fallback
- IPv4-broadcast LAN discovery
- IPv6-preferred LAN joins with automatic IPv4 fallback
- direct IPv4/IPv6 invites
- player names, lobby, ready state, and synchronized 3-2-1-GO countdown
- mutual rematches
- RTT/ping, inferred packet-loss counters, and transport diagnostics
- local pause/settings overlay without pausing the remote match
- separate looping menu/gameplay music
- persistent local settings
- fixed 960x540 logical canvas with letterboxing
- visual trail/impact/score effects

## Development build

Release CI is pinned to Odin `dev-2026-07`.

Windows:

```powershell
build.bat
```

`v1.2` uses Odin `vendor:curl` for HTTPS. Odin's bundled static Windows raylib and static libcurl use incompatible CRT-selection linker flags when linked into the same executable, so Windows builds use raylib as a DLL. `build.bat` automatically builds with `-define:RAYLIB_SHARED=true` and copies the matching `raylib.dll` from the active Odin installation beside `pong.exe`.

The equivalent manual commands are:

```powershell
odin build . -out:pong.exe -define:RAYLIB_SHARED=true -resource:desktop\windows\pong.res
copy <ODIN_ROOT>\vendor\raylib\windows\raylib.dll .\raylib.dll
```

Linux needs the usual raylib dependencies plus libcurl/mbedTLS development libraries because v1.2 uses `vendor:curl` for HTTPS rendezvous:

```bash
sudo apt-get install \
  libasound2-dev libgl1-mesa-dev libx11-dev libxcursor-dev libxi-dev \
  libxinerama-dev libxrandr-dev libcurl4-openssl-dev libmbedtls-dev zlib1g-dev

odin build . -out:pong
```

macOS:

```bash
odin build . -out:pong
```

Or during development:

Windows:

```powershell
odin run . -define:RAYLIB_SHARED=true -resource:desktop\windows\pong.res
```

Linux/macOS:

```bash
odin run .
```

## Client release builds

Windows:

```powershell
build-release.bat
```

Linux/macOS:

```bash
./build-release.sh
```

The Windows ZIP contains both `pong.exe` and `raylib.dll`; keep them together. The executable itself embeds the Pong icon, so Explorer/taskbar/shortcuts can use it without a sidecar `.ico` file.

The macOS ZIP contains a normal `Pong.app` bundle with `Contents/Resources/pong.icns` referenced by `Info.plist`. It remains unsigned/unnotarized.

The Linux archive contains the portable `pong` binary plus `pong.png`, `pong.desktop`, and `install-desktop.sh`. Running `./install-desktop.sh` installs a per-user launcher/icon under `~/.local` (or `$XDG_DATA_HOME`) without root privileges. The ELF binary itself does not embed an application icon.

Expected client archives:

```text
pong-v1.5.0-windows-x64.zip
pong-v1.5.0-linux-x64.tar.gz
pong-v1.5.0-macos-arm64.zip
pong-android-arm64-v1.5.0.apk
```

GitHub Actions also builds the standalone HTTP rendezvous binary archive:

```text
pong-rendezvous-v1.5.0-linux-x64.tar.gz
```

The standalone binary and the `server/` source are the same service. The binary is useful if you want to run the rendezvous API somewhere other than Render.

## Direct/LAN networking

LAN discovery listens on UDP `37776`. Gameplay defaults to UDP `7777`, although the host can choose another port.

For a discovered LAN game, Pong prefers a usable advertised IPv6 address and retries the discovered IPv4 address if the IPv6 handshake does not answer quickly. If global IPv6 is unavailable, IPv4 is used immediately.

On Windows, LAN discovery binds its broadcast socket to an active non-tunnel IPv4 interface with a gateway to avoid accidentally sending through WSL, Hyper-V, VPN, or other virtual interfaces.

### Linux interface discovery

The pinned Odin toolchain has a Linux `core:net.enumerate_interfaces()` regression. Pong therefore uses small Linux-specific fallbacks to find an advertisable global IPv6 address and a usable local IPv4 address. Gameplay itself still uses `core:net` UDP sockets.

## Windows firewall and portable ZIP

**Extract the ZIP to a normal, permanent folder before running `pong.exe`.** Do not run it from inside the ZIP archive.

Windows Firewall application permissions are associated with an executable's **full path**. Permission for:

```text
C:\Games\Pong\pong.exe
```

does not automatically apply to:

```text
C:\Users\you\Downloads\pong-v1.5.0-windows-x64\pong.exe
```

If Windows prompts for network access, allow Pong on the networks where you intend to play. Moving `pong.exe` later can cause Windows to require permission again for the new path.

For direct/LAN hosting, the selected gameplay UDP port and discovery UDP `37776` may need inbound permission. For room-code play, Pong also needs outbound UDP to Cloudflare STUN and direct inbound/outbound UDP for the peer-to-peer path. The Render rendezvous service itself is ordinary HTTPS and does not require a UDP firewall exception.

## Linux / UFW

If UFW is enabled on a game host and blocks direct/LAN play, the default gameplay/discovery ports can be allowed with:

```bash
sudo ufw allow 7777/udp
sudo ufw allow 37776/udp
```

There is no `3478/udp` rule to open on the HTTP rendezvous server. Cloudflare owns the STUN endpoint.

## Release caveats

- room-code connectivity is direct-only in v1.5.0; there is no TURN/relay fallback yet
- rendezvous traffic is protected by HTTPS when you configure an `https://` URL; local `http://` is supported for development
- room codes and peer tokens are short-lived and stored only in memory
- the macOS `.app` is unsigned and unnotarized
- Windows and macOS release artifacts carry the Pong application icon; Linux ships standard freedesktop icon/launcher metadata because ELF binaries do not embed application icons
- Windows and Linux distributions are portable archives rather than installers

See `THIRD_PARTY_NOTICES.md` for dependency notices.

### Room-code candidate lifetime fix

- Fixed an Internet-room bug where the native IPv6 candidate was returned as a string view into a local stack buffer. On machines with a global IPv6 address this could corrupt `RV_CREATE`/`RV_JOIN` and make the rendezvous service reply `BAD_REQUEST`; WSL often avoided the bug by having no advertisable global IPv6 and sending `-` instead.
- Native IPv6 candidate text is now copied into caller-owned storage before the HTTP rendezvous payload is formatted.
- The rendezvous server also treats malformed optional candidates as absent rather than rejecting otherwise valid room metadata.

## Android (v1.5)

v1.5 continues the **ARM64 Android client** while keeping gameplay protocol 4, discovery
protocol 1, rendezvous protocol 1, Cloudflare STUN, and the Render room service
compatible with v1.3/v1.4/v1.5 desktop clients.

Android uses raylib's NativeActivity backend. The build compiles raylib 6.0 against
the Android NDK, compiles the Odin package for `linux_arm64` with the Android
subtarget, then links both into `libmain.so` and packages an APK.

Requirements: Android SDK + NDK, CMake, JDK 17, Git, and Odin `dev-2026-07`.
On Windows use the native `build-android.bat` with the SDK/NDK installed by Android Studio. On Linux/macOS set `ANDROID_HOME` and `ANDROID_NDK_HOME`, then run `bash ./build-android.sh`.

The first target is `arm64-v8a` / API 29+. Room-code Internet play is the primary
Android path. Touch controls support upper/lower-half hold plus swipe/drag direction, while preserving the same fixed paddle speed as desktop. Android Back and the on-screen MENU button open the pause overlay, config lives in app-private storage, and rendezvous HTTPS uses Android's Java networking rather than desktop libcurl.

See `android/README.md` for setup, installation, and current caveats.

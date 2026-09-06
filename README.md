# UDP Pong — Odin + raylib (v1.3.0)

A small two-player Pong game written in Odin with raylib. Gameplay is host-authoritative UDP. Pong supports IPv4 and IPv6, LAN discovery, direct IP play, and short-code Internet play.

> **App v1.3.0 · gameplay protocol v4 · discovery protocol v1 · HTTP rendezvous protocol v1**
>
> Application versions and wire-protocol versions are independent. v1.3 keeps the v1.2 wire protocols so Android and desktop clients can play together.

## What's new in v1.3.0

- first Android ARM64 client (`arm64-v8a`, API 29+)
- raylib NativeActivity + Android NDK build pipeline
- touch menu interaction and touch paddle controls
- Android app-private preferences and APK-packaged audio assets
- Android Java HTTPS bridge for the Render rendezvous API
- Android APK artifact in GitHub release CI
- all v1.2 networking remains compatible, including six-character Internet room codes
- **Cloudflare public STUN** (`stun.cloudflare.com:3478/udp`) to discover the public UDP mapping of the exact Pong gameplay socket
- a separate **HTTP/HTTPS rendezvous service** for room creation and candidate exchange
- Render-ready Go rendezvous server and root `render.yaml`
- candidate exchange for global IPv6, same-LAN IPv4, and STUN-observed public IP/port
- simultaneous UDP hole punching
- direct IPv6 remains the preferred candidate when available
- existing LAN discovery and direct IP joining remain available
- rendezvous URL is remembered locally
- HTTPS client support through Odin's `vendor:curl`

v1.3.0 does **not** include TURN/relay gameplay. Symmetric NAT, restrictive CGNAT, enterprise firewalls, or networks that block peer-to-peer UDP can still prevent a direct connection.

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
odin build . -out:pong.exe -define:RAYLIB_SHARED=true
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
odin run . -define:RAYLIB_SHARED=true
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

The Windows ZIP contains both `pong.exe` and `raylib.dll`; keep them together.

Expected client archives:

```text
pong-v1.3.0-windows-x64.zip
pong-v1.3.0-linux-x64.tar.gz
pong-v1.3.0-macos-arm64.zip
pong-android-arm64-v1.3.0.apk
```

GitHub Actions also builds the standalone HTTP rendezvous binary archive:

```text
pong-rendezvous-v1.3.0-linux-x64.tar.gz
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
C:\Users\you\Downloads\pong-v1.2.0-windows-x64\pong.exe
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

- room-code connectivity is direct-only in v1.3.0; there is no TURN/relay fallback yet
- rendezvous traffic is protected by HTTPS when you configure an `https://` URL; local `http://` is supported for development
- room codes and peer tokens are short-lived and stored only in memory
- the macOS `.app` is unsigned and unnotarized
- there is no custom platform icon yet
- Windows and Linux distributions are portable archives rather than installers

See `THIRD_PARTY_NOTICES.md` for dependency notices.

### Room-code candidate lifetime fix

- Fixed an Internet-room bug where the native IPv6 candidate was returned as a string view into a local stack buffer. On machines with a global IPv6 address this could corrupt `RV_CREATE`/`RV_JOIN` and make the rendezvous service reply `BAD_REQUEST`; WSL often avoided the bug by having no advertisable global IPv6 and sending `-` instead.
- Native IPv6 candidate text is now copied into caller-owned storage before the HTTP rendezvous payload is formatted.
- The rendezvous server also treats malformed optional candidates as absent rather than rejecting otherwise valid room metadata.

## Android (v1.3)

v1.3 adds an **ARM64 Android client** while keeping gameplay protocol 4, discovery
protocol 1, rendezvous protocol 1, Cloudflare STUN, and the Render room service
compatible with the desktop v1.2 clients.

Android uses raylib's NativeActivity backend. The build compiles raylib 6.0 against
the Android NDK, compiles the Odin package for `linux_arm64` with the Android
subtarget, then links both into `libmain.so` and packages an APK.

Requirements: Android SDK + NDK, CMake, JDK 17, Git, and Odin `dev-2026-07`.
On Windows, WSL is the recommended build host. Set `ANDROID_HOME` and
`ANDROID_NDK_HOME`, then run:

```bash
./build-android.sh
```

The first target is `arm64-v8a` / API 29+. Room-code Internet play is the primary
Android path. Touch controls use the upper/lower halves of the screen for paddle
movement, menu widgets accept touch, config lives in app-private storage, and
rendezvous HTTPS uses Android's Java networking rather than desktop libcurl.

See `android/README.md` for setup, installation, and current caveats.

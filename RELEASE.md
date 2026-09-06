# Releasing Pong

Public releases use semantic versions such as `v1.0.0`, `v1.1.0`, and `v1.2.0`.

## v1.2.0 release scope

Before tagging, verify that v1.2.0 includes:

- v1.1 IPv4/IPv6 dual-stack gameplay and LAN fallback;
- six-character room-code hosting/joining;
- Cloudflare STUN Binding from the exact gameplay UDP socket;
- a separate HTTP/HTTPS rendezvous service;
- Render deployment support (`render.yaml`, `0.0.0.0:$PORT`, `/healthz`);
- rendezvous candidate exchange;
- simultaneous UDP hole punching;
- candidate preference of global IPv6, local IPv4, then STUN-observed public endpoint;
- explicit failure when direct punching requires a future relay/TURN path;
- bundled/tested Go HTTP rendezvous source;
- Windows full-path firewall guidance;
- no pre-public internal milestone labels in the UI or release metadata.

Protocol versions are **gameplay v4**, **discovery v1**, and **HTTP rendezvous v1**.

## Infrastructure split

```text
Cloudflare STUN        UDP 3478        public UDP mapping discovery
Render rendezvous      HTTPS           room codes + candidate exchange
Pong peers             UDP             hole punching + gameplay
```

The Render service does not need public UDP. Do not deploy the old combined STUN/rendezvous design for v1.2.0.

## Toolchains

Client release CI is pinned to Odin `dev-2026-07`. The rendezvous server uses Go `1.23.x` in GitHub Actions.

Linux client builds also require libcurl/mbedTLS development packages because the client uses Odin `vendor:curl` for HTTPS.

## Local client builds

Windows:

```powershell
build.bat
build-release.bat
```

Windows v1.2 builds use `-define:RAYLIB_SHARED=true` because the bundled static raylib and `vendor:curl` libraries select conflicting CRTs when linked together. Both scripts locate the active Odin installation automatically. Development builds copy `raylib.dll` beside `pong.exe`, and release packaging includes the DLL in the Windows ZIP.

Linux/macOS:

```bash
odin build . -out:pong
./build-release.sh
```

## Local rendezvous-server build

```bash
cd server
go test ./...
go build -o pong-rendezvous .
./pong-rendezvous -listen 0.0.0.0:10000
```

Use `http://127.0.0.1:10000` when the client and service are on the same machine.

## Render smoke test

Deploy from the root `render.yaml` or manually configure:

```text
Root directory: server
Build:          go build -trimpath -ldflags="-s -w" -o pong-rendezvous .
Start:          ./pong-rendezvous
Health check:   /healthz
```

Confirm:

```bash
curl https://YOUR-SERVICE.onrender.com/healthz
```

returns:

```text
ok
```

Then put the same `https://YOUR-SERVICE.onrender.com` URL into both Pong clients.

## Required v1.2 smoke tests

Test at least:

1. existing LAN IPv6-preferred join;
2. existing LAN IPv4 fallback;
3. direct IPv4 join;
4. direct IPv6 join where available;
5. Cloudflare STUN public endpoint appears on both clients;
6. room creation over HTTPS returns a six-character code;
7. room join over the same Render URL succeeds;
8. both peers receive candidate data and the same punch nonce;
9. peers establish a direct candidate and reach the normal lobby;
10. full match + synchronized countdown + rematch over the punched path;
11. punching timeout presents the relay/TURN limitation cleanly;
12. Render `/healthz` succeeds and no public UDP port is configured for the rendezvous service;
13. Windows release ZIP is extracted to its final path and firewall permission is granted for that path.

For NAT traversal, test on genuinely different access networks when possible. Two peers on one LAN are not sufficient to validate Internet hole punching.

## Expected release artifacts

```text
pong-v1.2.0-windows-x64.zip
pong-v1.2.0-linux-x64.tar.gz
pong-v1.2.0-macos-arm64.zip
pong-rendezvous-v1.2.0-linux-x64.tar.gz
```

## Tag release

After the tested commit is pushed:

```bash
git tag -a v1.2.0 -m "Pong v1.2.0"
git push origin v1.2.0
```

The GitHub Actions workflow builds all client archives plus the Linux x64 HTTP rendezvous binary and attaches them to the GitHub Release.

## Windows release note

Windows Firewall rules are path-specific. Test the downloaded/extracted release from the actual folder users will run it from. A `pong.exe` that is allowed in a development directory does not prove a copy under Downloads or another folder has permission.

## macOS

`Pong.app` is currently unsigned and unnotarized, so Gatekeeper may warn after Internet download.

### v1.2.0 candidate robustness fix

- Windows no longer advertises IPv4-mapped IPv6 interface addresses as native IPv6 candidates.
- Rendezvous CREATE/JOIN no longer rejects an otherwise valid room when an optional network candidate is malformed; the bad candidate is dropped and remaining candidates are used.

### Room-code candidate lifetime fix

- Fixed an Internet-room bug where the native IPv6 candidate was returned as a string view into a local stack buffer. On machines with a global IPv6 address this could corrupt `RV_CREATE`/`RV_JOIN` and make the rendezvous service reply `BAD_REQUEST`; WSL often avoided the bug by having no advertisable global IPv6 and sending `-` instead.
- Native IPv6 candidate text is now copied into caller-owned storage before the HTTP rendezvous payload is formatted.
- The rendezvous server also treats malformed optional candidates as absent rather than rejecting otherwise valid room metadata.

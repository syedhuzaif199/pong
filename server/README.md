# Pong HTTP rendezvous server

This directory contains the **room-code rendezvous service** for UDP Pong v1.2.0.
It does **not** implement STUN and it does **not** relay gameplay.

Pong clients use Cloudflare's public STUN service (`stun.cloudflare.com:3478/udp`) from the gameplay UDP socket to discover their public NAT mapping. They then use the Pong rendezvous service in this directory over ordinary HTTP/HTTPS to exchange candidates and a shared hole-punch nonce.

## API

All rendezvous control requests are small `POST` requests with a compact pipe-delimited body. Responses use the same text format.

- `GET /healthz`
- `POST /v1/create`
- `POST /v1/join`
- `POST /v1/wait`
- `POST /v1/leave`

Rooms are kept in memory, capped, protected by per-peer random tokens, and expire automatically. A restart clears outstanding room codes, which is acceptable for this short-lived matchmaking service.

## Run locally

```bash
cd server
go test ./...
go build -o pong-rendezvous .
./pong-rendezvous -listen 0.0.0.0:10000
```

Then use this rendezvous URL in Pong:

```text
http://127.0.0.1:10000
```

For another machine on your LAN, substitute the server machine's LAN address.

## Deploy on Render

The repository root includes `render.yaml`. The service reads Render's `PORT` environment variable and binds `0.0.0.0:$PORT`; when `PORT` is absent it defaults to `10000`.

Using the Render dashboard instead of the Blueprint:

- Service type: **Web Service**
- Root directory: `server`
- Build command: `go build -trimpath -ldflags="-s -w" -o pong-rendezvous .`
- Start command: `./pong-rendezvous`
- Health check path: `/healthz`

After deployment, configure both Pong clients with the public HTTPS URL, for example:

```text
https://pong-rendezvous-example.onrender.com
```

No UDP port needs to be exposed by Render. UDP is used only between each game client and Cloudflare STUN, and then directly between the two game clients.

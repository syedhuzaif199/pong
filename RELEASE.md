# UDP Pong v1.6.0 — release checklist

Application version **v1.6.0** uses gameplay protocol **5**, discovery protocol **1**, and rendezvous protocol **1**.

## Competitive-play smoke test

- VS CPU: BO3, win-by-two ON, spin ON, acceleration ON.
- Local 2P: complete at least two games in one match and verify the game counter advances.
- Verify a deuce-style game continues until one player leads by two.
- Verify moving a paddle during contact changes the outgoing vertical ball velocity when spin is ON.
- Verify disabling spin removes that paddle-velocity contribution.
- Verify disabling acceleration stops the horizontal 3.5% per-hit acceleration.
- Verify the final summary reports games, total points, per-game scores, longest rally, fastest ball, and time.
- Online: host rules appear identically in the client lobby.
- Online: v1.5/protocol-4 peer is rejected as incompatible instead of joining with mismatched rules.
- Online: complete a multi-game match and rematch on two networks.

## Release artifacts

Expected desktop/server artifacts follow `VERSION`:

- `pong-v1.6.0-windows-x64.zip`
- `pong-v1.6.0-linux-x64.tar.gz`
- `pong-v1.6.0-macos-arm64.zip`
- `pong-rendezvous-v1.6.0-linux-x64.tar.gz`

Android release signing produces:

- `pong-android-arm64-v1.6.0.apk`
- `pong-android-arm64-v1.6.0.aab`

Without signing secrets CI explicitly falls back to:

- `pong-android-arm64-v1.6.0-debug.apk`

## Tag

```bash
git tag -a v1.6.0 -m "Pong v1.6.0"
git push origin v1.6.0
```

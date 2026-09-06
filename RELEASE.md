# UDP Pong v1.5.0 — release checklist

Application version **v1.5.0** keeps gameplay protocol **4**, discovery protocol **1**, and rendezvous protocol **1**. v1.5 local modes do not change network packet formats.

## Smoke tests

- Desktop `VS CPU`: Easy / Normal / Hard each complete a full match and rematch.
- Desktop `LOCAL 2P`: W/S moves P1; arrows move P2; two controllers work when available.
- Android `VS CPU`: touch/hold/swipe controls P1 and MENU/Back pauses correctly.
- Android `LOCAL 2P`: two simultaneous touches on opposite halves move both paddles.
- Local pause freezes ball/paddles; resume continues normally.
- Local game-over rematch starts a fresh 3-2-1 countdown.
- Online host/join, room codes, LAN discovery, ready/countdown/rematch still work exactly as in v1.4.
- Settings persist across restart.
- Desktop icons and Android launcher icon remain present.

## Release artifacts

Expected desktop/server artifacts:

```text
pong-v1.5.0-windows-x64.zip
pong-v1.5.0-linux-x64.tar.gz
pong-v1.5.0-macos-arm64.zip
pong-rendezvous-v1.5.0-linux-x64.tar.gz
```

Android with signing secrets:

```text
pong-android-arm64-v1.5.0.apk
pong-android-arm64-v1.5.0.aab
```

Without signing secrets:

```text
pong-android-arm64-v1.5.0-debug.apk
```

## Tag

```bash
git tag -a v1.5.0 -m "Pong v1.5.0"
git push origin v1.5.0
```

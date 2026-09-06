# UDP Pong v1.4.0 — release checklist

Application version **v1.4.0** keeps gameplay protocol **4**, discovery protocol **1**, and rendezvous protocol **1**. v1.3 and v1.4 peers remain wire-compatible.

## Required smoke tests

Before tagging, verify at minimum:

1. Windows and Linux desktop builds launch and preserve v1.3 LAN/direct behavior.
2. Android ARM64 APK builds, installs, launches, accepts IME text, and persists settings after force-stop/relaunch.
3. Keyboard, controller, hold-touch, and swipe-touch all resolve to the same fixed-speed paddle input.
4. Android Back/MENU and controller Start open the in-game pause overlay without moving the paddle.
5. LAN discovery and direct IPv4/IPv6 joining still work.
6. Room-code create/join remains non-blocking while music continues.
7. Cross-network room-code play succeeds through Cloudflare STUN + HTTPS rendezvous + direct UDP punching.
8. RTT/jitter/loss/stream-rate diagnostics update during a match.
9. Brief network interruption freezes authoritative gameplay and recovers within the 10-second grace window.
10. A >10-second interruption exits cleanly with a reconnect-grace-expired message.
11. Android background/foreground resumes cleanly and does not lose settings.
12. Full match, synchronized countdown, game-over, and mutual rematch still work.
13. Windows `pong.exe` shows the Pong icon in Explorer/shortcuts.
14. macOS `Pong.app` shows the Pong icon in Finder.
15. Linux `./install-desktop.sh` creates a user-local launcher with the Pong icon.
16. Rendezvous server `go test ./...` and `/healthz` succeed.

## Android signing

See `ANDROID_SIGNING.md`. With the four signing secrets configured, release CI emits a signed APK and AAB. Without them it emits an explicitly named debug APK fallback.

## Expected artifacts

```text
pong-v1.4.0-windows-x64.zip
pong-v1.4.0-linux-x64.tar.gz
pong-v1.4.0-macos-arm64.zip
pong-rendezvous-v1.4.0-linux-x64.tar.gz

# with Android signing secrets:
pong-android-arm64-v1.4.0.apk
pong-android-arm64-v1.4.0.aab

# without Android signing secrets:
pong-android-arm64-v1.4.0-debug.apk
```

## Tagging

After committing, pushing, and testing the exact intended commit:

```bash
git status
git log -1 --oneline
git tag -a v1.4.0 -m "Pong v1.4.0"
git push origin v1.4.0
```

Tags matching `v*` trigger `.github/workflows/release.yml`. The GitHub Release is published only after desktop, Android, and rendezvous-server jobs succeed.

## Notes

- Windows Firewall permissions are path-specific; test the extracted release from its final directory.
- macOS output is still unsigned/unnotarized unless a separate signing/notarization pipeline is added.
- Internet room-code play remains direct P2P; there is no TURN/relay fallback in v1.4.0.

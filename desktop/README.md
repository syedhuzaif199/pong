# Desktop application icons

All desktop packages use the same Pong artwork as the Android launcher.

- `icons/pong.ico` — source multi-resolution Windows icon.
- `windows/pong.res` — precompiled Win32 resource linked with Odin's `-resource:` flag. It is checked in so Windows builds do not require `rc.exe` or `windres`.
- `icons/pong.icns` — macOS application icon copied into `Pong.app/Contents/Resources`.
- `icons/pong-256.png` — Linux freedesktop icon.
- `linux/pong.desktop` / `linux/install-desktop.sh` — portable launcher metadata and no-root per-user installation.

If `pong.ico` is replaced, regenerate the Windows resource with:

```bash
python scripts/make_windows_icon_res.py desktop/icons/pong.ico desktop/windows/pong.res
```

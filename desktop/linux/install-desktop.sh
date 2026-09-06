#!/usr/bin/env bash
set -euo pipefail

src_dir="$(cd "$(dirname "$0")" && pwd)"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
app_dir="$data_home/udp-pong"
applications_dir="$data_home/applications"
icons_dir="$data_home/icons/hicolor/256x256/apps"

mkdir -p "$app_dir" "$applications_dir" "$icons_dir"
install -m 0755 "$src_dir/pong" "$app_dir/pong"
rm -rf "$app_dir/assets"
cp -R "$src_dir/assets" "$app_dir/assets"
for file in README.md THIRD_PARTY_NOTICES.md VERSION; do
    if [[ -f "$src_dir/$file" ]]; then
        cp "$src_dir/$file" "$app_dir/$file"
    fi
done
install -m 0644 "$src_dir/pong.png" "$icons_dir/pong.png"

cat > "$applications_dir/udp-pong.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=UDP Pong
GenericName=Pong Game
Comment=Cross-platform host-authoritative multiplayer Pong
Exec=$app_dir/pong
Icon=pong
Terminal=false
Categories=Game;ArcadeGame;
StartupNotify=true
DESKTOP
chmod 0644 "$applications_dir/udp-pong.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$applications_dir" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "$data_home/icons/hicolor" >/dev/null 2>&1 || true
fi

echo "UDP Pong desktop launcher installed for this user."
echo "Application: $app_dir/pong"
echo "Launcher:    $applications_dir/udp-pong.desktop"

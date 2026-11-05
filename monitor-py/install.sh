#!/bin/sh
# Installs scrcpy monitor for the current user:
#   ~/.local/opt/scrcpy-monitor and ~/.local/share/applications/scrcpy-monitor.desktop
# Usage: ./install.sh [--uninstall]
set -eu

source_dir=$(cd "$(dirname "$0")" && pwd)
target="$HOME/.local/opt/scrcpy-monitor"
applications="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
desktop="$applications/scrcpy-monitor.desktop"

if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$desktop"
    rm -rf "$target"
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$applications" || true
    echo "Removed scrcpy monitor (settings and recordings were kept)."
    exit 0
fi

if [ ! -x "$source_dir/scrcpy-monitor" ]; then
    echo "scrcpy-monitor was not found next to install.sh ($source_dir)." >&2
    exit 1
fi

if [ "$source_dir" != "$target" ]; then
    if [ -x "$target/scrcpy-monitor" ]; then
        "$target/scrcpy-monitor" --command exit >/dev/null 2>&1 || true
    fi
    mkdir -p "$(dirname "$target")"
    staging="$target.new.$$"
    rm -rf "$staging"
    cp -a "$source_dir" "$staging"
    rm -rf "$target"
    mv "$staging" "$target"
fi

chmod +x "$target/scrcpy-monitor"
if [ -d "$target/bin" ]; then
    for tool in "$target"/bin/*; do
        if [ -f "$tool" ] && [ "$(basename "$tool")" != "scrcpy-server" ]; then
            chmod +x "$tool"
        fi
    done
fi

icon="$target/icons/scrcpy.png"
[ -f "$icon" ] || icon="scrcpy-monitor"
mkdir -p "$applications"
template="$target/scrcpy-monitor.desktop"
if [ -f "$template" ]; then
    sed -e "s|^Exec=.*|Exec=\"$target/scrcpy-monitor\"|" -e "s|^Icon=.*|Icon=$icon|" "$template" > "$desktop"
else
    cat > "$desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Scrcpy Monitor
Comment=Mirror and record every connected Android device with scrcpy
Exec="$target/scrcpy-monitor"
Icon=$icon
Terminal=false
Categories=Utility;Development;
EOF
fi
chmod 644 "$desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$applications" || true

echo "Installed scrcpy monitor in $target"
echo "Start it from the applications menu or run: $target/scrcpy-monitor"

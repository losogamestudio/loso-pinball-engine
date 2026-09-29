#!/usr/bin/env bash
# Put "Loso Pinball" and "Update Loso Pinball" icons on the Raspberry Pi
# desktop and in the app menu (under Games). Run once:
#     bash ~/loso-pinball-engine/tools/pi/install-desktop-icons.sh
# Safe to run again (e.g. after moving the repo); it just rewrites the icons.

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
MENU_DIR="$HOME/.local/share/applications"
mkdir -p "$DESKTOP_DIR" "$MENU_DIR"

# git on Windows can lose the "executable" bit; make sure the scripts can run.
chmod +x "$REPO/tools/pi/run.sh" "$REPO/tools/pi/update.sh"

write_icon() {   # write_icon <file name> <contents>
	for dir in "$DESKTOP_DIR" "$MENU_DIR"; do
		printf '%s\n' "$2" > "$dir/$1"
		chmod +x "$dir/$1"   # the desktop only launches executable .desktop files
	done
}

write_icon "loso-pinball.desktop" "[Desktop Entry]
Type=Application
Name=Loso Pinball
Comment=Run the Loso Pinball Engine
Exec=$REPO/tools/pi/run.sh
Icon=$REPO/icon.svg
Terminal=false
Categories=Game;"

write_icon "loso-pinball-update.desktop" "[Desktop Entry]
Type=Application
Name=Update Loso Pinball
Comment=git pull and refresh Godot's import cache
Exec=$REPO/tools/pi/update.sh
Icon=system-software-update
Terminal=true
Categories=Game;"

echo "Icons added to $DESKTOP_DIR and the app menu (Games)."
echo "If double-clicking asks what to do, choose \"Execute\" (see Docs/raspberry-pi.md)."

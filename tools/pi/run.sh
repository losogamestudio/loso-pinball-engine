#!/usr/bin/env bash
# Start Loso Pinball Engine on the Raspberry Pi.
# Used by the "Loso Pinball" desktop icon; also fine to run from a terminal.

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

# Newest Godot in ~/godot (so upgrading Godot doesn't break the icon).
# Set GODOT=/path/to/godot to use a specific one instead.
GODOT="${GODOT:-$(ls "$HOME"/godot/Godot_v*_linux.arm64 2>/dev/null | sort -V | tail -n 1)}"
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
	echo "Can't find Godot in ~/godot (expected Godot_v*_linux.arm64)."
	echo "See Docs/raspberry-pi.md, step 4."
	read -r -p "Press Enter to close."
	exit 1
fi

# Only one copy at a time: a second one can't open the Teensy's port
# ("Device or resource busy"). Starting the game again means you want this one.
pkill -f -- "--path $REPO --display-driver" 2>/dev/null && sleep 1

# Import first, every time. The Pi runs the project without the editor, so
# nothing else notices new scripts or media (after a git pull, or media synced
# in with Syncthing): without this, new class_name scripts fail to parse and
# new sounds fail to load. When nothing changed it only takes a few seconds.
# Output goes to a log; problems are shown here.
IMPORT_LOG="${XDG_CACHE_HOME:-$HOME/.cache}/loso-pinball-import.log"
mkdir -p "$(dirname "$IMPORT_LOG")"
echo "Checking for new scripts and media..."
"$GODOT" --headless --import --path "$REPO" >"$IMPORT_LOG" 2>&1
grep -iE "error|failed" "$IMPORT_LOG" | grep -v "^\s*at:" || true

# Wayland + OpenGL ES are what the Pi 4 actually supports; saying so up front
# skips Godot's failed X11/desktop-GL attempts. Extra arguments are passed on
# (e.g. ./run.sh --fullscreen).
exec "$GODOT" --path "$REPO" --display-driver wayland --rendering-driver opengl3_es "$@"

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

# Wayland + OpenGL ES are what the Pi 4 actually supports; saying so up front
# skips Godot's failed X11/desktop-GL attempts. Extra arguments are passed on
# (e.g. ./run.sh --fullscreen).
exec "$GODOT" --path "$REPO" --display-driver wayland --rendering-driver opengl3_es "$@"

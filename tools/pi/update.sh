#!/usr/bin/env bash
# Update Loso Pinball Engine on the Raspberry Pi: git pull, then re-import.
# Used by the "Update Loso Pinball" desktop icon (opens in a terminal so you
# can read what happened); also fine to run from a terminal.
#
# The import matters: the Pi runs the project without the editor, so new
# class_name scripts aren't known until --import refreshes .godot/.

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-$(ls "$HOME"/godot/Godot_v*_linux.arm64 2>/dev/null | sort -V | tail -n 1)}"

finish() {
	echo
	read -r -p "Press Enter to close."
	exit "$1"
}

# Everything is inside main() so bash reads the whole script before running
# it: git pull may replace this very file, and bash otherwise reads scripts
# a bit at a time while they run.
main() {
cd "$REPO" || finish 1

echo "=== Getting the latest code (git pull) ==="
if ! git pull; then
	echo
	echo "git pull failed. If it says your local changes would be overwritten and"
	echo "you don't need them, run this in a terminal, then try again:"
	echo "    cd $REPO && git checkout -- ."
	finish 1
fi

echo
echo "=== Refreshing Godot's import cache ==="
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
	echo "Can't find Godot in ~/godot (expected Godot_v*_linux.arm64). See Docs/raspberry-pi.md, step 4."
	finish 1
fi
echo "Using $GODOT"
# The import prints a lot; only show lines that look like problems.
"$GODOT" --headless --import --path "$REPO" 2>&1 | grep -iE "error|failed" | grep -v "^\s*at:" || true

echo
echo "=== Done. Start the game with the Loso Pinball icon. ==="
finish 0
}

main "$@"

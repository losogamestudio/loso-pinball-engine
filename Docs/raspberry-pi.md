# Deploying to a Raspberry Pi

The real cabinet target is a **Raspberry Pi 4 or later**, running 64-bit Raspberry Pi OS (Bookworm or newer). Day-to-day development happens on a desktop; this page is for getting the same project running on the actual hardware, from the fastest possible bench test up to a full kiosk setup.

## Quick path: just get it running (bench testing)

This is the fastest way to see it working on real hardware — no export step, no editor UI, just the engine running the project directly.

1. **Get the code:**
   ```sh
   git clone https://github.com/losogamestudio/loso-pinball-engine.git
   ```
2. **Get Godot** — the **Linux — arm64** standard build (not .NET), matching the version you use on desktop, from [godotengine.org/download/linux](https://godotengine.org/download/linux/):
   ```sh
   unzip Godot_v4.6.x-stable_linux.arm64.zip
   chmod +x Godot_v4.6.x-stable_linux.arm64
   ```
   No export templates needed yet — those are only required for the exported-standalone-build path below.
3. **Serial permissions** (one-time; needs a re-login or reboot to take effect):
   ```sh
   sudo usermod -aG dialout $USER
   ```
4. **Plug in the Teensy, then run the project directly.** Since `control.tscn` is already the main scene, pointing the engine at the project folder launches straight into the diagnostics panel — no editor window, no clicking Play:
   ```sh
   ./Godot_v4.6.x-stable_linux.arm64 --path /path/to/loso-pinball-engine
   ```
5. In the panel: pick the Teensy's port (it should show up as `/dev/ttyACM0`), hit **Connect**, then check **"Auto-connect at startup"** so it reconnects on its own from here on. See [Diagnostics panel](diagnostics-panel.md) for what everything on screen does.

That's the whole bench-test path — five steps, nothing exported or built. The GdSerial plugin already has a `linux-arm64` binary vendored in the repo (`addons/gdserial/bin/linux-arm64/libgdserial.so`, wired up in `gdserial.gdextension`), and the renderer is already set to GL Compatibility in `project.godot`, so there's nothing else to configure.

## Exporting a standalone build (for the actual cabinet)

Once you're past bench-testing and want something that boots straight into the game without a visible editor or terminal:

1. In the Godot editor: **Editor → Manage Export Templates**, install the templates matching your Godot version (one download covers every architecture, arm64 included).
2. **Project → Export… → Add… → Linux**. Set the preset's architecture to `arm64`.
3. Export Project. Check **"Embed PCK"** so you get a single self-contained binary instead of a binary plus a separate `.pck` file.
4. Copy the exported binary to the Pi (or export directly on it) and `chmod +x` it.

## Kiosk setup (fullscreen, boots straight into the game)

- **Fullscreen**: Project Settings → Display → Window, set **Mode** to `Fullscreen` — or just pass `--fullscreen` on the command line instead, without touching project settings at all.
- **Disable screen blanking** so the display doesn't sleep mid-game: `sudo raspi-config` → **Display Options** → **Screen Blanking** → off.
- **Autostart on boot**: drop a `.desktop` file under `~/.config/autostart/` (or use a systemd user service) that runs the exported binary, e.g.:

  ```ini
  [Desktop Entry]
  Type=Application
  Name=Loso Pinball Engine
  Exec=/home/pi/pinball/loso_pinball_engine.arm64
  ```

## The open risk: video cutscenes

Godot 4's built-in video player only supports **Ogg Theora**, decoded entirely in software — there's no hardware-accelerated video path in core Godot on Linux. That's rarely a problem on a desktop, but a Pi 4's CPU can struggle with it at higher resolutions or framerates.

**Before building out real cutscene content**, encode a representative test clip and play it back with `VideoStreamPlayer` on actual Pi 4 hardware, watching for dropped frames and CPU load. Don't assume desktop playback performance will carry over — the Pi's CPU is a different order of magnitude from a dev desktop's.

If it's not fast enough, in rough order of effort:
1. Drop resolution, framerate, or bitrate first — Theora's decode cost scales with all three.
2. Use sprite-sheet or `AnimationPlayer`-driven animation instead of true encoded video for short transitions.
3. As a last resort, an external hardware-accelerated player (e.g. GStreamer with V4L2 M2M) composited alongside the Godot window — real added complexity, worth avoiding unless the simpler options genuinely aren't enough.

See also the "Target hardware" section of `CLAUDE.md`, which carries this same constraint as a standing rule for any future changes to this project.

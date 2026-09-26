# Team America Pinball

A homebrew pinball machine with its own MPF/GMC-style architecture — built from scratch, not on top of the Mission Pinball Framework.

- A **Teensy 4.x** is the hardware controller. It runs switches, solenoids, and lamps in real time and owns everything safety- or timing-critical.
- **Godot 4.4+** (GDScript) is the game brain. It handles rules, scoring, modes, sound, video, and the display.
- The two talk over **USB serial** using a small, human-readable, line-based protocol.
- The game brain's actual deployment target is a **Raspberry Pi 4 or later** — desktops are for development only. See "Deploying to a Raspberry Pi" below.

This is also meant to become a **beginner-friendly reference build** — if you're comfortable with embedded C/C++ but new to game engines (or vice versa), the goal is that you can read this repo and follow along.

## Architecture, in one rule

**The Teensy owns anything with timing or safety. Godot owns rules and presentation.**

Stays on the Teensy, always:
- Flippers (24V pull-in, EOS-triggered PWM hold, released on button-up).
- Slingshots and pop bumpers as local hardware rules — switch closes, coil fires, *then* the Teensy tells Godot about it.
- Switch debouncing.
- Coil safety: a max pulse length on every coil, plus a watchdog that kills all outputs if Godot stops talking.

Godot's job:
- Enable/disable those hardware rules (e.g. off during tilt or game over) — Godot never fires a rule itself.
- Scoring, modes, ball tracking, audio, video, UI.
- One-off commands: kickout pulses, drop target resets, lamp states.

See [`CLAUDE.md`](CLAUDE.md) for the full architecture notes, coding conventions, and the complete serial protocol spec — that file is written as the source of truth for this project and is kept up to date as things change.

## Repo layout

```
res://
├── CLAUDE.md                 # full project spec: protocol, conventions, roadmap
├── project.godot
├── addons/gdserial/           # vendored GdSerial plugin (third-party, don't edit)
├── pinball_io.gd              # Autoload "PinballIO" — serial link, turned into signals
├── control.tscn               # diagnostics/test panel scene
├── test_panel.gd
└── Firmware/
    └── pinio_test/pinio_test.ino   # Teensy sketch (Arduino IDE + Teensyduino)
```

## Getting started

1. Install **Godot 4.4+**, standard build (not .NET) — this project is GDScript only.
2. Open the project folder in Godot. The GdSerial plugin is already vendored under `addons/gdserial` and enabled in `project.godot`, so there's nothing extra to install there.
3. Flash `Firmware/pinio_test/pinio_test.ino` to a Teensy 4.x with Arduino IDE + Teensyduino (USB Type: "Serial"). See the wiring notes at the top of that file for the practice hardware map.
4. Run the project (`control.tscn` is the main scene). Pick your Teensy's serial port from the dropdown and hit **Connect**.
5. Once linked, check "Auto-connect at startup" if you want it to remember that port and reconnect automatically next time.

## Deploying to a Raspberry Pi

The real cabinet target is a **Raspberry Pi 4 or later**, running 64-bit Raspberry Pi OS (Bookworm or newer). Day-to-day development happens on a desktop; this section is for getting the same project running on the actual hardware.

### 1. Install Godot on the Pi

Download the **Linux — arm64** build of Godot 4.6+ (standard, non-.NET) from [godotengine.org/download/linux](https://godotengine.org/download/linux/). Official arm64 editor builds and export templates are provided directly — no community/unofficial build needed. Extract it and make it executable:

```sh
chmod +x Godot_v4.6.x-stable_linux.arm64
```

### 2. Serial port access

Same as any Linux box: add your user to `dialout` so Godot can open the Teensy's serial port without root:

```sh
sudo usermod -aG dialout $USER
```

Log out and back in (or reboot) for the group change to take effect. The Teensy should show up as `/dev/ttyACM0` — confirm with `ls /dev/ttyACM*` after plugging it in.

### 3. The GdSerial plugin already has you covered

`addons/gdserial/bin/linux-arm64/libgdserial.so` is vendored in this repo and already wired up in `gdserial.gdextension`. There's nothing to build or install for the plugin itself on the Pi.

### 4. Run it — two ways

**In the editor** — fine for development/testing directly on the Pi: open the project with the arm64 Godot editor binary, same as on desktop.

**As an exported standalone build** — what the actual cabinet should run:

1. In the editor: **Editor → Manage Export Templates**, install the templates matching your Godot version (one download covers all architectures, arm64 included).
2. **Project → Export… → Add… → Linux**. Set the preset's architecture to `arm64`.
3. Export Project. Check "Embed PCK" so you get a single self-contained binary.
4. Copy the exported binary to the Pi (or export directly on it) and `chmod +x` it.

### 5. Kiosk setup (fullscreen, boots straight into the game)

- Project Settings → Display → Window: set **Mode** to `Fullscreen` — or just pass `--fullscreen` on the command line instead, without touching project settings.
- Disable screen blanking so the display doesn't sleep mid-game: `sudo raspi-config` → **Display Options** → **Screen Blanking** → off.
- Autostart on boot: drop a `.desktop` file under `~/.config/autostart/` (or use a systemd user service) that runs the exported binary, e.g.:

  ```ini
  [Desktop Entry]
  Type=Application
  Name=Team America Pinball
  Exec=/home/pi/pinball/team_america_pinball.arm64
  ```

### 6. The open risk: video cutscenes

Godot 4's built-in video player only supports **Ogg Theora**, decoded entirely in software — there's no hardware-accelerated video path in core Godot on Linux. That's rarely a problem on a desktop, but a Pi 4's CPU can struggle with it at higher resolutions or framerates.

**Before building out real cutscene content**, encode a representative test clip and play it back with `VideoStreamPlayer` on actual Pi 4 hardware, watching for dropped frames and CPU load. Don't assume desktop playback performance will carry over.

If it's not fast enough, in rough order of effort:
1. Drop resolution, framerate, or bitrate first — Theora's decode cost scales with all three.
2. Use sprite-sheet or `AnimationPlayer`-driven animation instead of true encoded video for short transitions.
3. As a last resort, an external hardware-accelerated player (e.g. GStreamer with V4L2 M2M) composited alongside the Godot window — real added complexity, worth avoiding unless the simpler options genuinely aren't enough.

## What's working right now

The main scene is a **diagnostics panel** for the serial link and I/O, and is meant to keep growing into the full diagnostics page for the real machine:

- Port picker with auto-connect: remembers the last port that actually answered the Teensy's `HELLO`, and can reconnect to it automatically on startup.
- Live link status, plus a heartbeat lamp that pulses on every `HB` from the Teensy — so a frozen board is visibly different from a merely-quiet one.
- Live switch lamps, coil pulse buttons, LED mode cycling, hardware-rule toggling (`SLING_L`), round-trip ping, and an analog bar for a pot on A0.
- A scrolling raw message log for everything crossing the link.

## Serial protocol

Plain ASCII, one message per line, ending in `\n`. Full message tables (Teensy→Godot and Godot→Teensy) and link/watchdog behavior are documented in `CLAUDE.md`. Short version: Godot says `HELLO` to arm the link and sends `HB` every 100ms to keep it alive; the Teensy runs a 500ms watchdog that kills all outputs and disables hardware rules the moment Godot goes quiet.

**Any protocol change is made on both sides in the same change** — the `.ino` sketch, `pinball_io.gd`, and the protocol table in `CLAUDE.md` all move together.

## Roadmap

1. ✅ Serial link, test sketch, `PinballIO` autoload, diagnostics panel.
2. Game state skeleton: attract → game start → ball in play → drain → next ball → game over, enabling/disabling hardware rules per state.
3. Real flipper state machine on the Teensy (24V pull-in → EOS → PWM hold) plus flipper enable/disable over the protocol.
4. Shared hardware map for the real playfield (switches/coils/lamps get names instead of magic numbers).
5. Audio, video, and a score display in Godot. Video cutscenes need validating on real Pi 4 hardware before much production time goes into them — see "Deploying to a Raspberry Pi" above.

## Hardware

Custom MOSFET driver boards: AOD4184 N-channel MOSFETs with SS3H10 Schottky flyback diodes. Dual-wound coils are intentionally ruled out — flippers use single-winding 12V coils overdriven at 24V for pull-in with a PWM hold once the EOS switch trips.

## License

Not yet decided — treat this as source-available for now (all rights reserved) until a license is chosen.

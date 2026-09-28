# Loso Pinball Engine

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

See [`CLAUDE.md`](CLAUDE.md) for the terse, authoritative project spec (protocol, conventions, roadmap), and [`Docs/`](Docs/README.md) for the fuller write-up — [Architecture](Docs/architecture.md) goes deeper on the reasoning behind this split.

## Documentation

Start in [`Docs/README.md`](Docs/README.md) for the full set. Highlights:

- [Getting started](Docs/getting-started.md) — desktop dev setup, step by step.
- [Architecture](Docs/architecture.md) — the Teensy/Godot split, and why.
- [Serial protocol](Docs/serial-protocol.md) — the wire protocol, with an example session.
- [Diagnostics panel](Docs/diagnostics-panel.md) — what every control in `control.tscn` does.
- [Deploying to a Raspberry Pi](Docs/raspberry-pi.md) — from imaging the SD card to a working bench test, up to a full kiosk build.

## Repo layout

```
res://
├── CLAUDE.md                 # terse, authoritative project spec: protocol, conventions, roadmap
├── Docs/                      # the fuller human-readable write-up — start at Docs/README.md
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

Full walkthrough (hardware shopping list, headless testing, what to expect on screen): [`Docs/getting-started.md`](Docs/getting-started.md).

## Deploying to a Raspberry Pi

The real cabinet target is a **Raspberry Pi 4 or later** — desktops are for development only. The step-by-step walkthrough goes from imaging the SD card to a working link with the Teensy, with no export/build required; there's also a full kiosk setup (fullscreen, autostart-on-boot) for when the cabinet's ready. Both, plus the one open risk (video cutscene performance on Pi hardware), are in [`Docs/raspberry-pi.md`](Docs/raspberry-pi.md).

## What's working right now

The main scene is a **diagnostics panel** for the serial link and I/O, and is meant to keep growing into the full diagnostics page for the real machine:

- Port picker with auto-connect: remembers the last port that actually answered the Teensy's `HELLO`, and can reconnect to it automatically on startup.
- Live link status, plus a heartbeat lamp that pulses on every `HB` from the Teensy — so a frozen board is visibly different from a merely-quiet one.
- Live switch lamps, coil pulse buttons (with Left/Right arrow-key shortcuts for bench testing — there's no keyboard on the real cabinet), LED mode cycling, hardware-rule toggling (`SLING_L`), round-trip ping, and an analog bar for a pot on A0.
- A scrolling raw message log for everything crossing the link.

Full walkthrough of every control: [`Docs/diagnostics-panel.md`](Docs/diagnostics-panel.md).

## Serial protocol

Plain ASCII, one message per line, ending in `\n`. Full message tables (Teensy→Godot and Godot→Teensy) and link/watchdog behavior are documented in `CLAUDE.md`, with a walked-through example session in [`Docs/serial-protocol.md`](Docs/serial-protocol.md). Short version: Godot says `HELLO` to arm the link and sends `HB` every 100ms to keep it alive; the Teensy runs a 500ms watchdog that kills all outputs and disables hardware rules the moment Godot goes quiet.

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

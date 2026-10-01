# Loso Pinball Engine

A homebrew pinball machine with its own MPF/GMC-style architecture — built from scratch, not on top of the Mission Pinball Framework.

- A **Teensy 4.1** is the hardware controller (more board types, and several boards at once, are on the way). It runs switches, solenoids, and lamps in real time and owns everything safety- or timing-critical.
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
- Tell each board its layout (which pin is which switch/coil/lamp, and how each coil's rule behaves) from one [machine config](Docs/configuration.md), then arm/disarm those rules (e.g. off during tilt or game over) — Godot never fires a rule itself.
- Scoring, modes, ball tracking, audio, video, UI.
- One-off commands: kickout pulses, drop target resets, lamp states.

See [`CLAUDE.md`](CLAUDE.md) for the terse, authoritative project spec (protocol, conventions, roadmap), and [`Docs/`](Docs/README.md) for the fuller write-up — [Architecture](Docs/architecture.md) goes deeper on the reasoning behind this split.

## Documentation

Start in [`Docs/README.md`](Docs/README.md) for the full set. Highlights:

- [Getting started](Docs/getting-started.md) — desktop dev setup, step by step.
- [Architecture](Docs/architecture.md) — the Teensy/Godot split, and why.
- [Machine configuration](Docs/configuration.md) — which pin is which switch, coil or lamp, and how coil rules are set up.
- [Serial protocol](Docs/serial-protocol.md) — the wire protocol, with an example session.
- [Service menu](Docs/service-menu.md) — the Monitor, Hardware and Audio & Video tabs, control by control.
- [Audio, music and video](Docs/audio-video.md) — sounds, the music manager, cutscenes, and syncing media (not in git) to the Pi.
- [Lighting](Docs/lighting.md) — WS2812B LED chains, effects, and light shows synced to music or video.
- [Deploying to a Raspberry Pi](Docs/raspberry-pi.md) — from imaging the SD card to a working bench test (desktop icons, sound setup, troubleshooting), up to a full kiosk build.

## Repo layout

```
res://
├── CLAUDE.md                 # terse, authoritative project spec: protocol, conventions, roadmap
├── Docs/                      # the fuller human-readable write-up — start at Docs/README.md
├── project.godot
├── addons/gdserial/           # vendored GdSerial plugin (third-party, don't edit)
├── pinball_io.gd              # Autoload "PinballIO" — every board link, turned into named signals
├── board_link.gd              # one serial link to one board
├── boards/                    # board type definitions (which pins can do what)
├── config/                    # Autoload "MachineConfig" + the default machine layout (JSON)
├── test/                      # headless tests, no hardware needed
├── main.tscn / main.gd        # base scene: always loaded, hosts mode scenes + the service menu (P key)
├── modes/                     # mode scenes (attract placeholder for now)
├── control.tscn               # diagnostics/test panel scene (the service page for now)
├── test_panel.gd
└── Firmware/
    └── pinio/                      # PINIO 0.3 generic, configurable firmware + WS2812B LED engine (Arduino IDE + Teensyduino)
```

## Getting started

1. Install **Godot 4.4+**, standard build (not .NET) — this project is GDScript only.
2. Open the project folder in Godot. The GdSerial plugin is already vendored under `addons/gdserial` and enabled in `project.godot`, so there's nothing extra to install there.
3. Flash `Firmware/pinio/pinio.ino` to a Teensy 4.1 with Arduino IDE + Teensyduino (USB Type: "Serial"). The bench wiring for the default config is in [`Docs/getting-started.md`](Docs/getting-started.md).
4. Run the project. It opens on the attract screen; click **Service** (bottom-right) or press **P** to open the service menu, then the **Hardware** tab. Pick your Teensy's serial port under **Connection** and hit **Connect**, then watch the **Monitor** tab.
5. Once linked, check "Auto-connect at startup" if you want it to remember that port and reconnect automatically next time.

Full walkthrough (hardware shopping list, headless testing, what to expect on screen): [`Docs/getting-started.md`](Docs/getting-started.md).

## Deploying to a Raspberry Pi

The real cabinet target is a **Raspberry Pi 4 or later** — desktops are for development only. The step-by-step walkthrough goes from imaging the SD card to a working link with the Teensy, with no export/build required; there's also a full kiosk setup (fullscreen, autostart-on-boot) for when the cabinet's ready. Both, plus the one open risk (video cutscene performance on Pi hardware), are in [`Docs/raspberry-pi.md`](Docs/raspberry-pi.md).

## What's working right now

The base scene (`main.tscn`) starts on the attract screen: the title, **Start game** for a 3-ball game with a score, and **Service**. Service (or **P**) opens the service menu, which has three tabs:

- **Monitor**: an LED for every input, coil and lamp, showing only its pin number and grouped per board. Also a heartbeat LED that pulses on every `HB` from the board, so a frozen board looks different from a quiet one. The right two thirds is a log of everything crossing the link in both directions, plus any config problems.
- **Hardware**:
  - Port picker with auto-connect, which remembers the last port a board actually answered on.
  - Board status and **Burn** (store the layout on the board).
  - Coils: add and edit them with a step-by-step wizard (flipper / sling / kicker / diverter presets, output pin, trigger and end-of-stroke switches, power, then live test-firing before saving). Each coil has **Fire** and **Armed**, plus Arm all / Disarm all.
  - Switches: edit each one (kind, points, sound), with a live lamp.
  - Lamp mode cycling.
- **Audio & Video**: screen size and text size, fullscreen, volume per bus, and test sounds and music. Also media players for checking synced music and cutscenes.

The whole I/O layout comes from one machine config file. On link, Godot checks it and sends it to the board, which then runs flippers (trigger → full power → EOS → PWM hold), slings and pops entirely by itself.

Full walkthrough of every control: [`Docs/service-menu.md`](Docs/service-menu.md).

## Serial protocol

Plain ASCII, one message per line, ending in `\n`. Full message tables (Teensy→Godot and Godot→Teensy) and link/watchdog behavior are documented in `CLAUDE.md`, with a walked-through example session in [`Docs/serial-protocol.md`](Docs/serial-protocol.md). Short version: Godot says `HELLO`, the board answers with its type and serial number, Godot sends the board its layout as `CFG` lines, then sends `HB` every 100ms to keep the link alive; the board runs a 500ms watchdog that kills all outputs and disarms all rules the moment Godot goes quiet.

**Any protocol change is made on both sides in the same change** — `Firmware/pinio/pinio.ino`, `board_link.gd`/`pinball_io.gd`, and the protocol table in `CLAUDE.md` all move together.

## Roadmap

1. ✅ Serial link, test sketch, `PinballIO` autoload, diagnostics panel.
2. Configurable I/O (in progress): ✅ always-loaded base scene, ✅ generic PINIO firmware with the configurable coil rule (flippers, slings, pops), ✅ machine config + name-based `PinballIO`, ✅ burn layout to board, ✅ service menu (Monitor / Hardware / Audio & Video) with the coil wizard, ✅ WS2812B LED chains with board-drawn effects and light shows synced to music/video. Next: several boards at once and Arduino Uno support.
3. Game state skeleton: attract → game start → ball in play → drain → next ball → game over, enabling/disabling hardware rules per state.
4. Real playfield layout in the machine config.
5. Audio, video, and a score display in Godot. Video cutscenes need validating on real Pi 4 hardware before much production time goes into them — see "Deploying to a Raspberry Pi" above.

## Hardware

Custom MOSFET driver boards: AOD4184 N-channel MOSFETs with SS3H10 Schottky flyback diodes. Dual-wound coils are intentionally ruled out — flippers use single-winding 12V coils overdriven at 24V for pull-in with a PWM hold once the EOS switch trips.

## License

Not yet decided — treat this as source-available for now (all rights reserved) until a license is chosen.

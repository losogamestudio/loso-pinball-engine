# CLAUDE.md — Homebrew Pinball: Godot Game Brain

This file gives Claude Code the context for this project. Read it fully before making changes.

## What this project is

A homebrew pinball machine with its own MPF/GMC-style architecture. We are **not** using MPF.

- A **Teensy 4.x** is the hardware controller. It runs switches, solenoids, and lamps in real time and handles safety.
- **Godot 4.4+ (GDScript)** is the game brain. It handles rules, scoring, modes, sound, video, and the display.
- The two talk over **USB serial** with a plain-text, line-based protocol (spec below).

The project is also meant to become a **beginner-friendly reference build** that non-technical people can follow. Keep code readable, well commented, and free of clever tricks.

## Target hardware (keep this in mind for every decision)

The game brain's end home is a **Raspberry Pi 4 or later**, not a desktop PC. The desktop is for development; the Pi is the deployment target for the actual cabinet. Concretely:

- `project.godot` already sets the renderer to **GL Compatibility** (OpenGL ES 3 under the hood). That's deliberate and Pi-appropriate — don't suggest switching to the Forward+ (Vulkan) renderer for this project, since the Pi's GPU doesn't run it well.
- **Video cutscenes are the one open risk.** Godot 4's built-in `VideoStreamPlayer` only decodes Ogg Theora, entirely in software — there is no hardware-accelerated video path in core Godot on Linux/Pi. That's fine on a desktop but can bog down a Pi 4's CPU at higher resolutions or framerates.
  - Don't assume heavy video cutscenes will just work on the Pi. Before investing real production time in cutscene content, encode a representative test clip and play it back on real Pi 4 hardware to see actual dropped-frame/CPU behavior — don't extrapolate from how it runs on a desktop.
  - If Theora playback turns out to be a bottleneck, the fallback options (roughly in order of effort) are: shrink resolution/framerate/bitrate first; consider sprite-sheet or `AnimationPlayer`-driven animation instead of true encoded video for shorter transitions; only as a last resort look at an external hardware-accelerated player (e.g. GStreamer/V4L2 M2M) composited alongside the Godot window, which adds real complexity and should be avoided if the simpler options are enough.
  - See the README's "Deploying to a Raspberry Pi" section for the concrete setup/export steps.

## About the developer (how to work with me)

- I'm an embedded systems engineer. I'm comfortable with firmware, electronics, C/C++, and the Teensy side.
- **I'm new to Godot.** I mostly used Unreal Engine and have only built a few Godot prototypes. When you introduce a Godot concept, explain it briefly and map it to Unreal where that helps. For example: signals ≈ event dispatchers, `_process` ≈ Tick, Autoload ≈ GameInstance subsystem, scenes ≈ Blueprints/prefabs, `@export` ≈ UPROPERTY(EditAnywhere).
- Prefer small, working steps I can run and test over large rewrites.
- Tell me when I need to do something in the editor (Project Settings, Autoloads, plugin enable) instead of assuming it's done.

## Core architecture rule (do not break this)

**The Teensy owns anything with timing or safety. Godot owns rules and presentation.**

Must stay on the Teensy (Godot never sits in these paths):
- Flippers. Each coil is a single-winding 12V coil overdriven at 24V for pull-in, switched to ~50% PWM hold when the EOS switch trips, and released when the button is released. Dual-wound coils are ruled out.
- Slingshots and pop bumpers as local **hardware rules**: switch closes → coil fires immediately → *then* the Teensy reports `FIRED <rule>` to Godot.
- Switch debouncing.
- Coil safety: a max pulse length cap on every coil, plus a watchdog that turns all outputs off if Godot goes quiet.

Godot's job:
- Enable and disable hardware rules (for example, off on tilt or game over). Godot never triggers them itself.
- Scoring, modes, ball tracking, audio, video, and UI.
- Commands like ball kickout pulses, drop target resets, and lamp states.

Driver hardware for reference: custom MOSFET boards using AOD4184 N-channel MOSFETs and SS3H10 Schottky flyback diodes.

## Project layout

```
res://
├── CLAUDE.md
├── project.godot
├── addons/gdserial/          # GdSerial plugin (third party, don't edit)
├── pinball_io.gd             # Autoload "PinballIO": serial link → signals
├── control.tscn              # Debug/test panel scene (root Control + test_panel.gd)
├── test_panel.gd
└── Firmware/
    └── pinio_test/pinio_test.ino   # Teensy sketch (built with Arduino IDE + Teensyduino)
```

Everything currently lives flat at the project root rather than under `autoload/`/`scenes/`/`scripts/` subfolders — that's how the user placed these files, so don't move them without asking.

If the actual files are somewhere else, update this section. Don't move files the user placed without asking.

## Dependencies & setup

1. **Godot 4.4+**, the standard build (not .NET). The game is GDScript only.
2. **GdSerial** plugin (https://github.com/SujithChristopher/gdserial). It's a Rust gdext serial library.
   - Installed at `addons/gdserial`, enabled under Project → Project Settings → Plugins.
   - We use the async class `GdSerialManager`: `open(name, baud, timeout_ms, mode)`, `write(name, PackedByteArray)`, `close(name)`, `list_ports()`, and `poll_events()`, which must be called every frame in `_process`. Its signals are `data_received(port, data)` and `port_disconnected(port)`.
   - We open ports in `MODE_RAW` (the default) and split lines ourselves in `pinball_io.gd`.
3. **Autoload**: `pinball_io.gd` is registered as **`PinballIO`** under Project Settings → Globals → Autoload.
   - ⚠️ Godot names it `PinballIo` from the filename by default. It must be renamed to exactly `PinballIO`, or every script fails with *Identifier "PinballIO" not declared*.
4. **Teensy**: Teensy 4.x, Arduino IDE with Teensyduino, USB Type "Serial". Baud is ignored on Teensy USB, but GdSerial requires a value, so we pass 115200. The Teensy doesn't reset when the port opens, so there are no DTR concerns.
5. **Linux (including the Raspberry Pi)**: the user must be in the `dialout` group to open serial ports. See the README's "Deploying to a Raspberry Pi" section for the full Pi-specific setup.

## Serial protocol (v0.1)

Plain ASCII text, one message per line, ending in `\n`. Tokens are separated by single spaces. Keep it human-readable so it can be debugged in a serial monitor. We may move to binary later (COBS + CRC), but not yet.

### Teensy → Godot

| Message | Meaning |
|---|---|
| `HELLO <firmware>` | Reply to HELLO, e.g. `HELLO PINIO 0.1` |
| `SWS <bits>` | Full switch state, one char per switch, e.g. `SWS 0100` means switch 1 is closed. Always sent right after HELLO so Godot can resync |
| `SW <id> <0\|1>` | Debounced switch change |
| `FIRED <rule>` | A hardware rule fired on the Teensy, e.g. `FIRED SLING_L` |
| `ANA <id> <0..1023>` | Analog value changed (deadbanded) |
| `PONG <n>` | Reply to `PING <n>` |
| `ACK <cmd> ...` | Command accepted, echoes the command |
| `ERR <message>` | Bad or unknown command |
| `WD TRIP` / `WD OK` | Watchdog turned outputs off / link restored |
| `HB <millis>` | Teensy heartbeat, once per second |

### Godot → Teensy

| Message | Meaning |
|---|---|
| `HELLO` | Start or restart the link. Arms the watchdog. Godot retries it every 1 s until linked |
| `HB` | Heartbeat, sent every 100 ms while linked. Any line counts as a heartbeat |
| `PULSE <coil> <ms>` | Fire a coil. The Teensy caps pulses at `MAX_PULSE_MS` (255) |
| `LED <id> <ON\|OFF\|BLINK>` | Lamp control |
| `RULE <name> <ON\|OFF>` | Enable or disable a hardware rule (currently only `SLING_L`) |
| `PING <n>` | Round-trip latency test |
| `WD <ON\|OFF>` | Enable or disable the watchdog. Only for manual serial monitor testing, never in the game |

### Link behavior

- Watchdog: if the Teensy hears nothing for **500 ms**, it turns off all coils and lamps, disables rules, and sends `WD TRIP`. The next line it receives clears the trip (`WD OK`), but outputs **stay off**. Godot must re-send rule and lamp state after `linked` and after `WD OK`.
- Godot marks the link lost if it hears nothing from the Teensy for 3 s.
- **Any protocol change must be made on both sides in the same change**: `pinio_test.ino` and `pinball_io.gd`, plus this table. Bump the firmware version string when the protocol changes.

### Current practice hardware map (test sketch)

| Item | Pin | Notes |
|---|---|---|
| Switches 0–3 | 2, 3, 4, 5 | INPUT_PULLUP, pressed = LOW |
| Coil 0 (sling stand-in) | 13 | Onboard LED |
| Coil 1 | 6 | LED + 330Ω |
| Lamps 0–1 | 7, 8 | LED + 330Ω |
| Analog 0 | A0 | Pot, 3.3V only. `USE_ANALOG` is false until wired |

Hardware rule: `SLING_L` = switch 0 → coil 0, 40 ms.

## PinballIO API (what game code should use)

Game code must **only** talk to hardware through `PinballIO`, never through GdSerial directly.

Signals: `linked(firmware)`, `unlinked`, `switch_changed(id, active)`, `rule_fired(rule_name)`, `analog_changed(id, value)`, `watchdog_changed(tripped)`, `latency_measured(ms)`, `line_received(line)`.

Functions: `list_ports()`, `open_port(name)`, `close_port()`, `pulse_coil(id, ms)`, `set_led(id, mode)`, `set_rule(name, enabled)`, `ping()`, `send(line)` (raw, for debugging).

State: `is_port_open`, `is_linked`, `switches` (id → bool).

## Coding conventions

- GDScript with **static typing everywhere** (`var x: int`, `-> void`, `:=`). Tabs for indentation (Godot default).
- `snake_case` for functions and variables, `PascalCase` for classes and nodes, `UPPER_SNAKE` for constants. Prefix private members with `_`.
- Communicate between systems with signals, not direct node paths across scenes. "Call down, signal up."
- No magic numbers for switch, coil, or lamp IDs in game code. Once the real machine is mapped, put them in one shared constants file (e.g. `hardware_map.gd`) and keep the firmware map in sync.
- Doc comments with `##` on public signals and functions.
- Firmware: no `delay()` in `loop()`. Everything non-blocking with `millis()` timing and rollover-safe comparisons. No dynamic allocation.

## Testing

- **Without hardware**: `GdSerialManager` can be replaced by a stub script with `class_name GdSerialManager` that fakes Teensy replies. Keep any stub in a `test/` folder, and never ship it alongside the real plugin, because the class names would clash. Headless run: `godot --headless --path . res://scenes/test_panel.tscn`.
- **Without Godot**: open the Arduino Serial Monitor (line ending "Newline"), send `WD OFF`, then type commands like `HELLO`, `LED 0 BLINK`, `PULSE 0 100`.
- After changing GDScript, check that the project parses (`godot --headless --path . --quit` should show no script errors).

## Roadmap / next steps

1. ✅ Serial link, test sketch, PinballIO autoload, and test panel.
2. Game state skeleton: attract mode → game start → ball in play → drain → next ball → game over. Enable and disable rules per state.
3. Real flipper state machine on the Teensy (24V pull-in → EOS → PWM hold), plus flipper enable/disable over the protocol.
4. Shared hardware map for the real playfield.
5. Audio, video, and a score display in Godot. An 80s-style segment display look is an option, possibly as a hybrid. **Validate cutscene video on real Pi 4 hardware before building out a lot of cutscene content** — see "Target hardware" above.

## Things to avoid

- Don't put coil timing or flipper logic in Godot.
- Don't call GdSerial from anywhere except `pinball_io.gd`.
- Don't change the protocol on only one side.
- Don't edit `addons/gdserial`.
- Don't switch to C#/.NET without asking. The decision was GDScript + GdSerial.

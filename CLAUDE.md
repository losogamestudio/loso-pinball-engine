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
- Flippers. Each coil is a single-winding 12V coil overdriven at 24V for pull-in, switched to ~50% PWM hold when the EOS switch trips, and released when the button is released. Dual-wound coils are ruled out. Implemented as the generic PINIO 0.2 coil rule (trigger + EOS + hold %), configured from Godot, executed on the board.
- Slingshots and pop bumpers as local **hardware rules**: switch closes → coil fires immediately → *then* the board reports `FIRED <coil>` to Godot.
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
├── Docs/                      # human-facing write-up: architecture, protocol, setup, Pi deployment
├── project.godot
├── addons/gdserial/          # GdSerial plugin (third party, don't edit)
├── pinball_io.gd             # Autoload "PinballIO": all board links → named signals
├── board_link.gd             # class BoardLink: one serial link speaking PINIO 0.2 (no GdSerial inside)
├── boards/board_types.gd     # class BoardTypes: what each board type's pins can do (mirror of board_<type>.h)
├── config/                   # Autoload "MachineConfig", IoDefs records, machine_config.default.json,
│                             #   and the service menu (P key): service_menu.tscn (Setup + Diagnostics tabs),
│                             #   setup_page.gd, coil_wizard.gd, input_editor.gd, ui_kit.gd (UiKit helpers)
├── test/                     # headless tests (test_config_link.gd)
├── main.tscn / main.gd       # Base scene (the main scene): always loaded, hosts modes + service page
├── modes/                    # Mode scenes swapped into Main's ModeHost (attract.tscn placeholder so far)
├── control.tscn              # Diagnostics panel (root Control + test_panel.gd), the Diagnostics tab of the service menu
├── test_panel.gd
└── Firmware/
    └── pinio/                      # PINIO 0.2 generic firmware: pinio.ino + board_<type>.h (Arduino IDE + Teensyduino)
```

The original files live flat at the project root — that's how the user placed them, so don't move them without asking. New work goes in subfolders (`modes/`, and per the build-out plan `boards/` and `config/`).

**Scene structure**: `main.tscn` is always loaded (like Unreal's persistent level). It has a `ModeHost` node holding exactly one mode scene, swapped with `Main.show_mode(scene)`, and a `ServiceLayer` CanvasLayer on top that loads the service page on open and frees it on close (`open_service()` / `close_service()` / `toggle_service()`, the P key on a keyboard: `Main.SERVICE_KEY`; not F1, the Pi on-screen keyboard has no function keys). Don't use `get_tree().change_scene_to_*()` — that would unload Main.

If the actual files are somewhere else, update this section. Don't move files the user placed without asking.

**`CLAUDE.md` vs `Docs/`**: this file stays terse and is the authoritative spec — the protocol table here, in particular, is ground truth and must stay in lockstep with `Firmware/pinio/pinio.ino` and `board_link.gd`/`pinball_io.gd`. `Docs/` is the expanded, human-facing version of the same material (architecture rationale, a worked serial-protocol example, setup walkthroughs, Raspberry Pi deployment) — update both when something in this file changes in a way that affects them, but don't let `Docs/` become a second copy of the raw protocol table that can drift.

## Dependencies & setup

1. **Godot 4.4+**, the standard build (not .NET). The game is GDScript only.
2. **GdSerial** plugin (https://github.com/SujithChristopher/gdserial). It's a Rust gdext serial library.
   - Installed at `addons/gdserial`, enabled under Project → Project Settings → Plugins.
   - We use the async class `GdSerialManager`: `open(name, baud, timeout_ms, mode)`, `write(name, PackedByteArray)`, `close(name)`, `list_ports()`, and `poll_events()`, which must be called every frame in `_process`. Its signals are `data_received(port, data)` and `port_disconnected(port)`.
   - We open ports in `MODE_RAW` (the default) and split lines ourselves in `board_link.gd`.
3. **Autoloads** (Project Settings → Globals → Autoload), in this order: `config/machine_config.gd` as **`MachineConfig`**, then `pinball_io.gd` as **`PinballIO`**.
   - ⚠️ Godot names it `PinballIo` from the filename by default. It must be renamed to exactly `PinballIO`, or every script fails with *Identifier "PinballIO" not declared*.
4. **Teensy**: Teensy 4.1 (the only board type so far), Arduino IDE with Teensyduino, USB Type "Serial". Flash `Firmware/pinio/`. Baud is ignored on Teensy USB, but GdSerial requires a value, so we pass 115200. The Teensy doesn't reset when the port opens, so there are no DTR concerns.
5. **Linux (including the Raspberry Pi)**: the user must be in the `dialout` group to open serial ports. See the README's "Deploying to a Raspberry Pi" section for the full Pi-specific setup.

## Serial protocol (v0.2)

Plain ASCII text, one message per line, ending in `\n`. Tokens are separated by single spaces. Keep it human-readable so it can be debugged in a serial monitor. We may move to binary later (COBS + CRC), but not yet.

Implemented by `Firmware/pinio/pinio.ino` (`PINIO 0.2`) on the board side and `board_link.gd` + `pinball_io.gd` on the Godot side. The firmware is generic: a board header (`Firmware/pinio/board_<type>.h`) says what each pin *can* do (IN / OUT / PWM), and Godot sends the actual layout (from `MachineConfig`) when the board's running layout doesn't match. The board runs it from RAM, and `CFG SAVE` burns it into EEPROM so the board boots configured.

### Board → Godot

| Message | Meaning |
|---|---|
| `HELLO <firmware> <board> <uid> <running\|-> <saved\|->` | Reply to HELLO, e.g. `HELLO PINIO 0.2 TEENSY41 12345670 4AC3701E 4AC3701E`. uid = the board's serial number, so Godot can tell boards apart. running/saved = layout fingerprints (see below), `-` = none |
| `SWS <bits>` | Every input's state by input index, e.g. `SWS 010` = input 1 active. Sent right after the `ACK CFG` for `CFG DONE`, and in reply to `SWS` |
| `SW <in> <0\|1>` | Debounced input change (active = 1, NO/NC already applied) |
| `FIRED <coil>` | A pulse-type coil rule (hold_pct 0) fired on the board |
| `PONG <n>` | Reply to `PING <n>` |
| `ACK <cmd> ...` | Command accepted, echoes the command. `ACK CFG <n_in> <n_coil> <n_lamp> <fingerprint>` = whole layout accepted. `ACK CFG SAVE <fingerprint>` = layout burned |
| `ERR <message>` | Bad or unknown command. `ERR CFG ...` = a config line was rejected |
| `WD TRIP` / `WD OK` | Watchdog turned outputs off / link restored |
| `HB <millis>` | Board heartbeat, once per second |

### Godot → Board

| Message | Meaning |
|---|---|
| `HELLO` | Start or restart the link. All outputs off, all rules disarmed, **layout kept**, arms the watchdog. Godot retries it every 1 s until linked |
| `HB` | Heartbeat, sent every 100 ms while linked. Any line counts as a heartbeat |
| `CFG CLEAR` | Forget the config, all outputs low. Required before re-sending a config after `CFG DONE` (otherwise `ERR CFG locked`) |
| `CFG PWM <hz>` | Board-wide hold PWM frequency, 100..100000 (default 20000) |
| `CFG IN <in> <pin> <NO\|NC> <debounce_ms>` | Define input index `<in>`. Debounce 0..100 |
| `CFG COIL <coil> <pin> <full_ms> <hold_pct> <trig\|-> <eos\|-> <recycle_ms>` | full_ms 1..255, hold_pct 0..100 (1..99 needs a PWM pin), trig/eos = an already-defined input index or `-`, recycle 0..5000 |
| `CFG LAMP <lamp> <pin>` | Define lamp index `<lamp>` |
| `CFG DONE` | → `ACK CFG <n_in> <n_coil> <n_lamp> <fingerprint>` then `SWS`, or `ERR CFG ...` if any CFG line since `CFG CLEAR` was rejected |
| `CFG SAVE` | Burn the running layout into EEPROM (turns all outputs off and disarms rules while writing) → `ACK CFG SAVE <fingerprint>`. At power-up the board replays it, so it's configured before Godot connects (rules still disarmed) |
| `CFG ERASE` | Forget the burned layout → `ACK CFG ERASE` |
| `SWS` | Ask for all input states → `SWS <bits>` |
| `PULSE <coil> [ms]` | Full power for ms (default: the coil's full_ms), capped at `MAX_PULSE_MS` (255). `ERR coil busy` while firing/holding/recycling |
| `HOLD <coil> <ON\|OFF>` | Full power for full_ms (or until EOS), then hold_pct until `OFF`. Coil needs hold_pct > 0 |
| `RULE <coil\|ALL> <ON\|OFF>` | Arm or disarm coil trigger rules. Coil needs a trigger input |
| `LED <lamp> <ON\|OFF\|BLINK>` | Lamp control |
| `PING <n>` | Round-trip latency test |
| `WD <ON\|OFF>` | Enable or disable the watchdog. Only for manual serial monitor testing, never in the game |

Before `CFG DONE`, `PULSE`/`HOLD`/`RULE`/`LED` reply `ERR not configured`, and inputs aren't scanned. Godot (`BoardLink.send_config`) sends CFG lines **one at a time, each waiting for its ACK**, so small boards can't be flooded.

**Coil rule (on the board, Godot never in the path)**: trigger closes with the rule armed → FULL power for full_ms. An EOS input closing ends FULL early (full_ms is then the failsafe for a broken EOS). After FULL: hold_pct > 0 → PWM hold while the trigger stays closed; hold_pct 0 → off and report `FIRED`. Releasing the trigger (or disarming the rule) drops a holding coil at once. After off, the coil ignores fires for recycle_ms. A flipper is just a coil with a trigger, an EOS and hold_pct > 0.

### Link behavior

- Watchdog: if the board hears nothing for **500 ms**, it turns off all coils and lamps, disarms all rules, and sends `WD TRIP`. The config is kept. The next line it receives clears the trip (`WD OK`), but outputs **stay off**. `PinballIO` re-sends the wanted rule and lamp state by itself after a (re)config and after `WD OK`.
- Godot marks the link lost if it hears nothing from the board for 3 s.
- On `HELLO`, `PinballIO` matches the board to `MachineConfig` by type and uid (a board with an empty uid in the config accepts any board of that type), checks the firmware string matches `BoardTypes.FIRMWARE`, and validates the config. If the board's running fingerprint equals Godot's, it just sends `SWS` (adopt); otherwise it sends `CFG CLEAR` + that board's CFG lines. Editing the config (`MachineConfig.changed`) does the same for every linked board. `MachineConfig` stays the master copy; burning is explicit (`PinballIO.burn_board`).
- **Layout fingerprint**: 32-bit FNV-1a over every accepted CFG line after `CFG CLEAR` (not DONE), each followed by `\n`, printed as 8 uppercase hex digits. Firmware: `cfgRecord()`/`fnvAdd()`; Godot: `MachineConfig.layout_hash()`. They must stay identical.
- **Any protocol change must be made on both sides in the same change**: `Firmware/pinio/pinio.ino` and `board_link.gd`/`pinball_io.gd`, plus this table. Bump the firmware version string (and `BoardTypes.FIRMWARE`) when the protocol changes. Pin tables live twice, in `board_<type>.h` and `boards/board_types.gd`: keep them in sync.

### Teensy 4.1 pin map (`board_teensy41.h`)

USB port up: left header = outputs, right header = inputs.

| Pins | Role |
|---|---|
| 2–12, 24, 25, 28, 29 | Coil/lamp output, PWM hold capable |
| 26, 27, 30, 31, 32 | Coil/lamp output, pulse only (no PWM on these pins) |
| 14–17, 20–23, 33–41 | Input (INPUT_PULLUP, switch to GND, 3.3 V only) |
| 18, 19 | Reserved: I2C (`Wire`) |
| 0, 1 | Reserved: Serial1 |
| 13 | Reserved: status LED. Slow blink = waiting for HELLO, medium = waiting for CFG, solid = running, fast = WD tripped. It can't be an input, because the onboard LED loads the pull-up. |

Every MOSFET gate needs a pulldown: pins float until `setup()` runs and while the board is being flashed.

The default machine layout (`config/machine_config.default.json`) uses: `flipper_left` coil pin 2 (trigger `flipper_left_button` pin 33, EOS `flipper_left_eos` pin 34, 60 ms, 50% hold), `sling_left` coil pin 26 (trigger `sling_left_switch` pin 35, 40 ms, 150 ms recycle), `kickout` coil pin 3 (no trigger), `lamp_0` pin 27.

## PinballIO API (what game code should use)

Game code must **only** talk to hardware through `PinballIO`, never through GdSerial directly.

Everything is by **name** (StringName) from `MachineConfig`, never by pin or board index.

Signals: `switch_changed(switch_name, active)`, `coil_fired(coil_name)`, `board_ready(board_id)`, `board_lost(board_id)`, `board_problem(port, message)`, `board_notice(port, message)`, `board_burned(board_id)`, `port_linked(port, firmware, board_type, uid)`, `port_unlinked(port)`, `watchdog_changed(board_id, tripped)`, `latency_measured(port, ms)`, `heartbeat(port, millis)`, `line_received(port, line)`, `line_sent(port, line)`.

Functions: `pulse_coil(name, ms := -1)`, `hold_coil(name, on)`, `set_coil_rule(name, on)`, `set_all_rules(on)`, `get_coil_rule(name)`, `set_lamp(name, "ON"|"OFF"|"BLINK")`, `get_lamp_mode(name)`, `is_switch_active(name)`, `list_ports()`, `open_port(port)`, `close_port(port := "")` (empty = all), `get_open_ports()`, `is_any_port_open()`, `is_ready()` (every configured board ready), `get_port_for_board(board_id)`, `burn_board(board_id)`, `is_board_burned(board_id)`, `ping()`, `send_raw(port, line)` (debugging), `set_auto_connect(on)`.

State: `switches` (name → bool), `auto_connect`, `last_port`.

Rule and lamp wishes are remembered, so game code can call `set_coil_rule`/`set_lamp` any time (even before a board links) and PinballIO applies them when the board is ready.

## MachineConfig (the machine's I/O layout)

Autoload **`MachineConfig`** (`config/machine_config.gd`), listed **above** PinballIO. Holds `boards`, `inputs`, `coils`, `lamps` as typed records from `config/io_defs.gd` (`IoDefs.BoardDef`, `InputDef`, `CoilDef`, `LampDef`, plus `BoardPlan`). Loads `user://machine_config.json` if present, else `res://config/machine_config.default.json`. Functions: `load_config()`, `save_config()`, `reset_to_default()`, `validate()` → readable problems, `build_plan(board)` → CFG lines + index↔name maps + fingerprint, `layout_hash(lines)` (static), `find_board/input/coil/lamp(name)`. Signal `changed`. Names must be unique across inputs, coils and lamps, with no spaces. A coil's trigger/EOS must be on the same board as the coil. Board capabilities come from `BoardTypes` (`boards/board_types.gd`, static).

## Coding conventions

- GDScript with **static typing everywhere** (`var x: int`, `-> void`, `:=`). Tabs for indentation (Godot default).
- `snake_case` for functions and variables, `PascalCase` for classes and nodes, `UPPER_SNAKE` for constants. Prefix private members with `_`.
- Communicate between systems with signals, not direct node paths across scenes. "Call down, signal up."
- No magic numbers for switch, coil, or lamp IDs in game code. Use the names from `MachineConfig` (e.g. `&"flipper_left"`); pins and board indexes never appear outside `MachineConfig`/`PinballIO`.
- Doc comments with `##` on public signals and functions.
- Firmware: no `delay()` in `loop()`. Everything non-blocking with `millis()` timing and rollover-safe comparisons. No dynamic allocation.

## Testing

- **Without hardware**: `godot --headless --path . -s res://test/test_config_link.gd` checks MachineConfig validation, the CFG lines built from the default config, and the BoardLink handshake against a fake board. `-s res://test/test_setup_ui.gd` drives the coil wizard and switch editor (always cancels, never writes user://). In `-s` mode, scripts that use autoload names must be `load()`ed at runtime, not preloaded. Tests live in `test/`. If a full `GdSerialManager` stub is ever added there, never ship it alongside the real plugin, because the class names would clash.
- **Without Godot**: open the Arduino Serial Monitor (line ending "Newline"), send `HELLO`, `WD OFF`, then `CFG IN ...` / `CFG COIL ...` / `CFG DONE` lines (see the top of `Firmware/pinio/pinio.ino`), then `RULE ALL ON`, `PULSE 0`, `LED 0 BLINK`.
- **Firmware compile check**: the Arduino IDE bundles `arduino-cli`: `arduino-cli compile --fqbn teensy:avr:teensy41 --warnings all Firmware/pinio`.
- After changing GDScript, check that the project parses (`godot --headless --path . --quit` should show no script errors).

## Roadmap / next steps

1. ✅ Serial link, test sketch, PinballIO autoload, and test panel.
2. Configurable I/O build-out (in progress):
   - ✅ Base scene (`main.tscn`, mode host, service layer on the P key).
   - ✅ PINIO 0.2 generic firmware with the trigger/EOS/hold coil rule, which covers the real flipper state machine. Compiles; not yet bench-tested on wired pins.
   - ✅ MachineConfig + BoardTypes + BoardLink, and a name-based PinballIO.
   - ✅ Burn layout to board (EEPROM, fingerprints in HELLO).
   - ✅ Setup tab (P key): coil wizard (kind → name/pin → trigger/EOS, can create switches → power → review + live test → save), switch editor, delete, Burn to board. Edits are drafts (MachineConfig.snapshot/restore) until Save.
   - Lamps: all lighting will be WS2812B LED chains (FastLED-style) on a few outputs. Not designed yet; the current CFG LAMP/LED on-off stays but has no setup UI.
   - Several boards at once (auto-scan ports, match by uid, machine fault if one drops).
   - Arduino Uno board support (`board_uno.h`).
   - Later: input expander (74HC165 / matrix), analog inputs as a configurable type, EOS-reopen re-pulse.
3. Game state skeleton: attract mode → game start → ball in play → drain → next ball → game over. Enable and disable rules per state.
4. Real playfield layout in the machine config.
5. Audio, video, and a score display in Godot. An 80s-style segment display look is an option, possibly as a hybrid. **Validate cutscene video on real Pi 4 hardware before building out a lot of cutscene content** — see "Target hardware" above.

## Things to avoid

- Don't put coil timing or flipper logic in Godot.
- Don't call GdSerial from anywhere except `pinball_io.gd`.
- Don't change the protocol on only one side.
- Don't edit `addons/gdserial`.
- Don't switch to C#/.NET without asking. The decision was GDScript + GdSerial.

# CLAUDE.md — Homebrew Pinball: Godot Game Brain

This file gives Claude Code the context for this project. Read it fully before making changes.

## What this project is

A homebrew pinball machine with its own MPF/GMC-style architecture. We are **not** using MPF.

- A **Teensy 4.x** is the hardware controller. It runs switches, solenoids, lamps and WS2812B LED chains in real time and handles safety.
- **Godot 4.4+ (GDScript)** is the game brain. It handles rules, scoring, modes, sound, video, and the display.
- The two talk over **USB serial** with a plain-text, line-based protocol (spec below).

The project is also meant to become a **beginner-friendly reference build** that non-technical people can follow. Keep code readable, well commented, and free of clever tricks.

## Target hardware (keep this in mind for every decision)

The game brain's end home is a **Raspberry Pi 4 or later**, not a desktop PC. The desktop is for development; the Pi is the deployment target for the actual cabinet. Concretely:

- **Screen scaling**: everything is laid out for **1280×720** and stretched to the real screen (`display/window/stretch/mode = canvas_items`, aspect `expand`). A per-machine UI scale (multiplier via `Window.content_scale_factor`), a separate **text size** (default 200%, a shared `Theme` from `DisplaySettings.text_theme()` that each screen sets on its root Control, since themes do not flow through the CanvasLayer; labels that set their own size must use `DisplaySettings.font_size(base)`), and fullscreen live in `DisplaySettings` (`config/display_settings.gd`, saved in `user://display.cfg`), applied in `main.gd` `_ready` and set from the Audio & Video tab. The current bench Pi screen is **800×480**: UI scale 100% with text size 200% is the readable setting there; layouts must still fit (rows wrap, pages scroll). Service screens use `UiKit.scroll_container()`: vertical bar always shown, 3× default width for touch (widened via its styleboxes, not custom_minimum_size, which the ScrollContainer ignores when reserving space).
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
- Flippers. Each coil is a single-winding 12V coil overdriven at 24V for pull-in, switched to ~50% PWM hold when the EOS switch trips, and released when the button is released. Dual-wound coils are ruled out. Implemented as the generic PINIO coil rule (trigger + EOS + hold %), configured from Godot, executed on the board.
- Slingshots and pop bumpers as local **hardware rules**: switch closes → coil fires immediately → *then* the board reports `FIRED <coil>` to Godot.
- Switch debouncing.
- Coil safety: a max pulse length cap on every coil, plus a watchdog that turns all outputs off if Godot goes quiet.
- Drawing LED effects (WS2812B chains, `Firmware/pinio/leds.h`): Godot sends short `FX` cues, the board renders ~60 fps by DMA. Never stream pixels from Godot.

Godot's job:
- Enable and disable hardware rules (for example, off on tilt or game over). Godot never triggers them itself.
- Scoring, modes, ball tracking, audio, video, and UI.
- Commands like ball kickout pulses, drop target resets, lamp states and LED light effects (including timed light shows synced to music/video).

Driver hardware for reference: custom MOSFET boards using AOD4184 N-channel MOSFETs and SS3H10 Schottky flyback diodes.

## Project layout

```
res://
├── CLAUDE.md
├── Docs/                      # human-facing write-up: architecture, protocol, setup, Pi deployment
├── project.godot
├── addons/gdserial/          # GdSerial plugin (third party, don't edit)
├── addons/loso_show_tools/   # our editor plugin: "Light Show" dock (show_dock.gd): live LED preview of a show while scrubbing, a row per light to edit/add/delete its key at the playhead
├── pinball_io.gd             # Autoload "PinballIO": all board links → named signals
├── board_link.gd             # class BoardLink: one serial link speaking PINIO 0.3 (no GdSerial inside)
├── boards/board_types.gd     # class BoardTypes: what each board type's pins can do (mirror of board_<type>.h)
├── config/                   # Autoload "MachineConfig", IoDefs records, machine_config.default.json,
│                             #   and the service menu: service_menu.tscn/.gd (top bar with Quit + Exit; tabs Monitor | Hardware | Audio & Video),
│                             #   hardware_page.gd, av_page.gd, coil_wizard.gd, input_editor.gd, ui_kit.gd (UiKit helpers),
│                             #   draft_editor.gd (shared shell) + chain_editor.gd, light_editor.gd (LED chains / lights),
│                             #   display_settings.gd (DisplaySettings: UI scale + fullscreen)
├── test/                     # headless tests (test_config_link, test_setup_ui, test_game, test_media, test_shows)
├── tools/pi/                 # Pi helper scripts: run.sh (import, then start; closes an old copy), update.sh (git pull + --import), install-desktop-icons.sh
├── game/game.gd              # Autoload "Game": start / 3 balls / score / abort, scoring by switch kind
├── media/media.gd            # Autoload "Media": sound effects, music (crossfade, push/pop), cutscene video, bus volumes
├── media/shows.gd            # Autoload "Shows": light shows (timeline cues) synced to music/video by name
├── media/light_show.gd       # class LightShow: root of a show scene (assets/shows/<name>.tscn), light(...) (old name cue(...))
├── media/show_cues.gd        # class ShowCues (@tool): reads cue keys, state at a time, the show-preview UDP lines; shared by Shows and the editor dock
├── assets/                   # sfx/, music/, video/, shows/ — NOT in git except README, shows/_template.tscn + test/ folders (synced PC → Pi)
├── default_bus_layout.tres   # audio buses: Master ← Music, SFX, Video
├── tools/make_test_sounds.gd # writes the generated test sounds in assets/**/test/
├── tools/convert_videos.ps1  # Resolve/any export → .ogv (Theora) in assets/video, Pi-friendly settings (needs ffmpeg)
├── tools/make_show_template.gd # writes assets/shows/_template.tscn and the demo show assets/shows/test/test_loop_a.tscn
├── main.tscn / main.gd       # Base scene (the main scene): always loaded, hosts modes + service page
├── modes/                    # Mode scenes swapped into Main's ModeHost: attract.tscn/.gd (title, Start game, Service),
│                             #   game_play.tscn/.gd (score, ball, Abort game, test buttons: cheats left, point grid right)
├── control.tscn              # Monitor tab of the service menu (root Control + test_panel.gd): I/O LEDs (pin numbers) + log
├── test_panel.gd
└── Firmware/
    └── pinio/                      # PINIO 0.3 generic firmware: pinio.ino + leds.h (WS2812B engine, OctoWS2811) + board_<type>.h
```

The original files live flat at the project root — that's how the user placed them, so don't move them without asking. New work goes in subfolders (`modes/`, and per the build-out plan `boards/` and `config/`).

**Scene structure**: `main.tscn` is always loaded (like Unreal's persistent level). It has a `ModeHost` node holding exactly one mode scene, swapped with `Main.show_mode(scene)`, and a `ServiceLayer` CanvasLayer on top that loads the service page on open and frees it on close (`open_service()` / `close_service()` / `toggle_service()`). `Main` swaps attract ⇄ game_play on `Game.game_started` / `Game.game_ended`; modes call `Game.start_game()` / `abort_game()` / `end_ball()` and never switch scenes themselves. The service page opens from the attract screen's touch **Service** button (the mode emits `service_requested`; Main connects it for any mode that has that signal) or the P key (`Main.SERVICE_KEY`; not F1, the Pi on-screen keyboard has no function keys). It closes from the menu's **Exit** button (`exit_requested`) or P.

**Service menu tabs** (left to right; see `Docs/service-menu.md`):
- **Monitor** (`control.tscn` + `test_panel.gd`): the left third has an LED per input/coil/lamp showing only the pin number, plus a color swatch per LED light (its first LED index), grouped per board, plus the heartbeat LED. Coil LEDs show what Godot knows (`coil_commanded`, `coil_fired`, held flippers), with a cyan outline when the rule is armed. The right two thirds is the log.
- **Hardware** (`config/hardware_page.gd`): Connection, Boards (Burn), Coils (Fire / Armed / Edit / Delete, Arm all), Switches, LED chains, Lights (Test / Edit / Delete, All off, Brightness), Lamps, Layout reset.
- **Audio & Video** (`config/av_page.gd`): Screen, Audio volumes and tests, the Media library (music/video/show players, Light sync offset, Show preview from the editor, Rescan).

**The UI is touch-first** (Pi touchscreen, no keyboard): every action needs an on-screen button, big enough for a finger (~56 px tall for primary buttons like Service/Exit). Keyboard shortcuts are extras only. Anything that would otherwise need a keyboard (e.g. leaving fullscreen, which is the default: `DisplaySettings.DEFAULT_FULLSCREEN`) needs a button, like the Fullscreen box on the Audio & Video tab and the Quit button in the service menu top bar. Don't use `get_tree().change_scene_to_*()` — that would unload Main.

**Service screen look** (`UiKit`): the shared theme (`UiKit.style_theme`, applied inside `DisplaySettings.text_theme()`) gives buttons, dropdowns, fields and tabs gray backgrounds.
- **Layout**: each group is a `UiKit.section()` card with a cyan heading. Each item is a `UiKit.row_card()` holding a `UiKit.name_block(name, details)`: the name on top, small dim details underneath (`DETAIL_SIZE`), buttons on the right.
- **Button text color says the role**: `UiKit.PRIMARY` cyan (Add, Save, Next, Burn), `UiKit.TEST` purple (fires hardware; the same purple as the game screen's test buttons), `UiKit.DANGER` salmon (Delete, Reset, Quit).
- **Text**: explanations use `UiKit.note()`, which is smaller. Keep row details short; long explanations go in the editors, not the lists.

If the actual files are somewhere else, update this section. Don't move files the user placed without asking.

**`CLAUDE.md` vs `Docs/`**: this file stays terse and is the authoritative spec — the protocol table here, in particular, is ground truth and must stay in lockstep with `Firmware/pinio/pinio.ino` and `board_link.gd`/`pinball_io.gd`. `Docs/` is the expanded, human-facing version of the same material (architecture rationale, a worked serial-protocol example, setup walkthroughs, Raspberry Pi deployment) — update both when something in this file changes in a way that affects them, but don't let `Docs/` become a second copy of the raw protocol table that can drift.

## Dependencies & setup

1. **Godot 4.4+**, the standard build (not .NET). The game is GDScript only.
2. **GdSerial** plugin (https://github.com/SujithChristopher/gdserial). It's a Rust gdext serial library.
   - Installed at `addons/gdserial`, enabled under Project → Project Settings → Plugins.
   - Our own editor plugin **Loso Show Tools** (`addons/loso_show_tools`) is enabled there too.
   - We use the async class `GdSerialManager`: `open(name, baud, timeout_ms, mode)`, `write(name, PackedByteArray)`, `close(name)`, `list_ports()`, and `poll_events()`, which must be called every frame in `_process`. Its signals are `data_received(port, data)` and `port_disconnected(port)`.
   - We open ports in `MODE_RAW` (the default) and split lines ourselves in `board_link.gd`.
3. **Autoloads** (Project Settings → Globals → Autoload), in this order: `config/machine_config.gd` as **`MachineConfig`**, then `pinball_io.gd` as **`PinballIO`**, then `game/game.gd` as **`Game`**, then `media/media.gd` as **`Media`**, then `media/shows.gd` as **`Shows`**.
   - ⚠️ Godot names it `PinballIo` from the filename by default. It must be renamed to exactly `PinballIO`, or every script fails with *Identifier "PinballIO" not declared*.
4. **Teensy**: Teensy 4.1 (the only board type so far), Arduino IDE with Teensyduino, USB Type "Serial". Flash `Firmware/pinio/` (uses the OctoWS2811 library, which ships with Teensyduino). Baud is ignored on Teensy USB, but GdSerial requires a value, so we pass 115200. The Teensy doesn't reset when the port opens, so there are no DTR concerns.
5. **Linux (including the Raspberry Pi)**: the user must be in the `dialout` group to open serial ports. The Pi runs the project without the editor, so after every `git pull` it needs `godot --headless --import --path .` to refresh the `class_name` list in `.godot/` (not in git); otherwise new `class_name` scripts fail with "Could not find type". See the README's "Deploying to a Raspberry Pi" section for the full Pi-specific setup.

## Serial protocol (v0.3)

Plain ASCII text, one message per line, ending in `\n`. Tokens are separated by single spaces. Keep it human-readable so it can be debugged in a serial monitor. We may move to binary later (COBS + CRC), but not yet.

Implemented by `Firmware/pinio/pinio.ino` + `leds.h` (`PINIO 0.3`) on the board side and `board_link.gd` + `pinball_io.gd` on the Godot side. The firmware is generic: a board header (`Firmware/pinio/board_<type>.h`) says what each pin *can* do (IN / OUT / PWM), and Godot sends the actual layout (from `MachineConfig`) when the board's running layout doesn't match. The board runs it from RAM, and `CFG SAVE` burns it into EEPROM so the board boots configured.

### Board → Godot

| Message | Meaning |
|---|---|
| `HELLO <firmware> <board> <uid> <running\|-> <saved\|->` | Reply to HELLO, e.g. `HELLO PINIO 0.3 TEENSY41 12345670 4AC3701E 4AC3701E`. uid = the board's serial number, so Godot can tell boards apart. running/saved = layout fingerprints (see below), `-` = none |
| `SWS <bits>` | Every input's state by input index, e.g. `SWS 010` = input 1 active. Sent right after the `ACK CFG` for `CFG DONE`, and in reply to `SWS` |
| `SW <in> <0\|1>` | Debounced input change (active = 1, NO/NC already applied) |
| `FIRED <coil>` | A pulse-type coil rule (hold_pct 0) fired on the board |
| `PONG <n>` | Reply to `PING <n>` |
| `ACK <cmd> ...` | Command accepted, echoes the command. `ACK CFG <n_in> <n_coil> <n_lamp> <n_chain> <n_zone> <fingerprint>` = whole layout accepted (the fingerprint is always the last word). `ACK CFG SAVE <fingerprint>` = layout burned |
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
| `CFG CHAIN <chain> <pin> <count> <GRB\|RGB\|BRG\|RBG\|GBR\|BGR>` | WS2812B chain on an output pin, 1..300 LEDs. Chains numbered 0,1,2… in order (max 4) |
| `CFG ZONE <zone> <chain> <first> <count>` | Zone = a named light: an LED range on a defined chain (max 96). Drawn in index order, later on top; Godot numbers bigger lights first |
| `CFG DONE` | → `ACK CFG <n_in> <n_coil> <n_lamp> <n_chain> <n_zone> <fingerprint>` then `SWS`, or `ERR CFG ...` if any CFG line since `CFG CLEAR` was rejected. Starts LED output |
| `CFG SAVE` | Burn the running layout into EEPROM (turns all outputs off and disarms rules while writing) → `ACK CFG SAVE <fingerprint>`. At power-up the board replays it, so it's configured before Godot connects (rules still disarmed) |
| `CFG ERASE` | Forget the burned layout → `ACK CFG ERASE` |
| `SWS` | Ask for all input states → `SWS <bits>` |
| `PULSE <coil> [ms]` | Full power for ms (default: the coil's full_ms), capped at `MAX_PULSE_MS` (255). `ERR coil busy` while firing/holding/recycling |
| `HOLD <coil> <ON\|OFF>` | Full power for full_ms (or until EOS), then hold_pct until `OFF`. Coil needs hold_pct > 0 |
| `RULE <coil\|ALL> <ON\|OFF>` | Arm or disarm coil trigger rules. Coil needs a trigger input |
| `LED <lamp> <ON\|OFF\|BLINK>` | Lamp control |
| `FX <zone\|ALL> <effect> [RRGGBB] [ms] [RRGGBB2]` | LED zone effect, drawn by the board: `OFF SOLID BLINK PULSE CHASE WIPE FADE RAINBOW SPARKLE`. Defaults FFFFFF, 500, 000000. `OFF` is see-through → `ACK FX <zone> <effect>` |
| `BRIGHT <0..255>` | Brightness for every LED chain (a power cap), default 128 → `ACK BRIGHT n` |
| `PING <n>` | Round-trip latency test |
| `WD <ON\|OFF>` | Enable or disable the watchdog. Only for manual serial monitor testing, never in the game |

Before `CFG DONE`, `PULSE`/`HOLD`/`RULE`/`LED`/`FX`/`BRIGHT` reply `ERR not configured`, and inputs aren't scanned. Godot (`BoardLink.send_config`) sends CFG lines **one at a time, each waiting for its ACK**, so small boards can't be flooded.

**Coil rule (on the board, Godot never in the path)**: trigger closes with the rule armed → FULL power for full_ms. An EOS input closing ends FULL early (full_ms is then the failsafe for a broken EOS). After FULL: hold_pct > 0 → PWM hold while the trigger stays closed; hold_pct 0 → off and report `FIRED`. Releasing the trigger (or disarming the rule) drops a holding coil at once. After off, the coil ignores fires for recycle_ms. A flipper is just a coil with a trigger, an EOS and hold_pct > 0.

### Link behavior

- Watchdog: if the board hears nothing for **500 ms**, it turns off all coils, lamps and LED zones, disarms all rules, and sends `WD TRIP`. The config is kept. The next line it receives clears the trip (`WD OK`), but outputs **stay off**. `PinballIO` re-sends the wanted rules, lamps, brightness and light effects by itself after a (re)config and after `WD OK`.
- Godot marks the link lost if it hears nothing from the board for 3 s.
- On `HELLO`, `PinballIO` matches the board to `MachineConfig` by type and uid (a board with an empty uid in the config accepts any board of that type), checks the firmware string matches `BoardTypes.FIRMWARE`, and validates the config. If the board's running fingerprint equals Godot's, it just sends `SWS` (adopt); otherwise it sends `CFG CLEAR` + that board's CFG lines. Editing the config (`MachineConfig.changed`) does the same for every linked board. `MachineConfig` stays the master copy; burning is explicit (`PinballIO.burn_board`).
- **Layout fingerprint**: 32-bit FNV-1a over every accepted CFG line after `CFG CLEAR` (not DONE), each followed by `\n`, printed as 8 uppercase hex digits. Firmware: `cfgRecord()`/`fnvAdd()`; Godot: `MachineConfig.layout_hash()`. They must stay identical.
- **Any protocol change must be made on both sides in the same change**: `Firmware/pinio/pinio.ino` and `board_link.gd`/`pinball_io.gd`, plus this table. Bump the firmware version string (and `BoardTypes.FIRMWARE`) when the protocol changes. Pin tables live twice, in `board_<type>.h` and `boards/board_types.gd`: keep them in sync.

### Teensy 4.1 pin map (`board_teensy41.h`)

USB port up: left header = outputs, right header = inputs.

| Pins | Role |
|---|---|
| 2–12, 24, 25, 28, 29 | Coil/lamp/LED-chain output, PWM hold capable |
| 26, 27, 30, 31, 32 | Coil/lamp/LED-chain output, pulse only (no PWM on these pins) |
| 14–17, 20–23, 33–41 | Input (INPUT_PULLUP, switch to GND, 3.3 V only) |
| 18, 19 | Reserved: I2C (`Wire`) |
| 0, 1 | Reserved: Serial1 |
| 13 | Reserved: status LED. Slow blink = waiting for HELLO, medium = waiting for CFG, solid = running, fast = WD tripped. It can't be an input, because the onboard LED loads the pull-up. |

Every MOSFET gate needs a pulldown: pins float until `setup()` runs and while the board is being flashed.

The default machine layout (`config/machine_config.default.json`) uses: `flipper_left` coil pin 2 (trigger `flipper_left_button` pin 33, EOS `flipper_left_eos` pin 34, 60 ms, 50% hold), `sling_left` coil pin 26 (trigger `sling_left_switch` pin 35, 40 ms, 150 ms recycle), `kickout` coil pin 3 (no trigger), `lamp_0` pin 27, LED chain `led_chain_0` pin 8 (30 LEDs, GRB) with lights `playfield` (LEDs 0–29) and `shoot_again` (LED 0). LED data needs a 3.3→5 V level shifter (see `Docs/lighting.md`). OctoWS2811 moves chain pins off the fast GPIO; `ledsReleasePins()` moves them back on `CFG CLEAR`.

## PinballIO API (what game code should use)

Game code must **only** talk to hardware through `PinballIO`, never through GdSerial directly.

Everything is by **name** (StringName) from `MachineConfig`, never by pin or board index.

Signals: `switch_changed(switch_name, active)`, `coil_fired(coil_name)`, `coil_commanded(coil_name, on, is_pulse)` (Godot sent PULSE/HOLD; for displays), `light_changed(light_name)`, `board_ready(board_id)`, `board_lost(board_id)`, `board_problem(port, message)`, `board_notice(port, message)`, `board_burned(board_id)`, `port_linked(port, firmware, board_type, uid)`, `port_unlinked(port)`, `watchdog_changed(board_id, tripped)`, `latency_measured(port, ms)`, `heartbeat(port, millis)`, `line_received(port, line)`, `line_sent(port, line)`.

Functions: `pulse_coil(name, ms := -1)`, `hold_coil(name, on)`, `set_coil_rule(name, on)`, `set_all_rules(on)`, `get_coil_rule(name)`, `set_lamp(name, "ON"|"OFF"|"BLINK")`, `get_lamp_mode(name)`, `set_light(name, effect, color := WHITE, ms := 500, color2 := BLACK)`, `get_light(name)` → {effect, color, ms, color2}, `all_lights_off()`, `set_light_brightness(0..1)` (saved in `user://pinball_settings.cfg`), `is_switch_active(name)`, `list_ports()`, `open_port(port)`, `close_port(port := "")` (empty = all), `get_open_ports()`, `is_any_port_open()`, `is_ready()` (every configured board ready), `get_port_for_board(board_id)`, `burn_board(board_id)`, `is_board_burned(board_id)`, `ping()`, `send_raw(port, line)` (debugging), `set_auto_connect(on)`.

State: `switches` (name → bool), `auto_connect`, `last_port`, `light_brightness`, `remember_port` (tests set it false so a fake board's port isn't saved as `last_port`).

Rule, lamp and light wishes are remembered, so game code can call `set_coil_rule`/`set_lamp` any time (even before a board links) and PinballIO applies them when the board is ready.

## MachineConfig (the machine's I/O layout)

Autoload **`MachineConfig`** (`config/machine_config.gd`), listed **above** PinballIO. Holds `boards`, `inputs`, `coils`, `lamps`, `chains`, `lights` as typed records from `config/io_defs.gd` (`IoDefs.BoardDef`, `InputDef`, `CoilDef`, `LampDef`, `ChainDef`, `LightDef`, plus `BoardPlan`; `IoDefs.EFFECTS`, `COLOR_ORDERS`). Loads `user://machine_config.json` if present, else `res://config/machine_config.default.json`. Functions: `load_config()`, `save_config()`, `reset_to_default()`, `validate()` → readable problems, `build_plan(board)` → CFG lines + index↔name maps + fingerprint, `layout_hash(lines)` (static), `find_board/input/coil/lamp/chain/light(name)`, `light_board(light)`, `lights_on_chain`, `remove_chain/light`. Signal `changed`. Names must be unique across inputs, coils, lamps, chains and lights, with no spaces. A light is on its chain's board; `build_plan` sends CHAIN lines, then ZONE lines with lights sorted by LED count, biggest first (so inserts draw on top). Each input also has a Godot-only **kind** (`IoDefs.KINDS`: `switch` plain, `target` and `spinner` add `points` per close, `drain` ends the ball, `start` starts a game) and `points`; these aren't in the CFG lines, so they don't change the fingerprint. A coil's trigger/EOS must be on the same board as the coil. Board capabilities come from `BoardTypes` (`boards/board_types.gd`, static).

## Game (autoload)

`game/game.gd`, registered as **`Game`** after PinballIO. The game state skeleton:
- **Functions**:
  - `start_game()`: ignored while playing. Arms all coil rules, sets ball 1 and score 0.
  - `add_points(n)`: only counts while playing.
  - `add_extra_ball()`: only while playing.
  - `end_ball()`: shoot again if an extra ball is waiting, else next ball, or game over after `balls_per_game` (default 3).
  - `abort_game()`, `is_playing()`, `format_score(n)`.
- **State**: `state`, `ball`, `score` (kept after the game as the last score), `extra_balls`, `balls_per_game`.
- **Signals**: `game_started`, `ball_started(ball)`, `score_changed(score)`, `extra_balls_changed(count)`, `game_ended(aborted)`.

The game screen's bench-test buttons (`SHOW_TEST_BUTTONS` in `modes/game_play.gd`, to become a service-menu setting) call the same Game functions real switches do:
- Left column: cheats from `_cheats()`. Extra ball and Drain ball exist now. Planned: Last ball, Tilt, Ball save, Kick out, Rules off/on.
- Right: a 2-column grid of point buttons from `TEST_POINTS`.

It scores from `PinballIO.switch_changed` by each input's kind, and disarms the rules at game end. Game events that need outputs (ball kickout, drop target reset, diverters) go here as direct `PinballIO.pulse_coil`/`hold_coil`/`set_lamp` calls. Later: kickout on `ball_started`, tilt, ball save, match.

## Media (autoload): audio and video

`media/media.gd`, registered as **`Media`** after Game. Everything is by **name**, the file name without its extension, found by scanning `res://assets/sfx|music|video/` (subfolders too) with `ResourceLoader.list_directory`. A missing name warns once and does nothing; it never crashes, because media isn't in git.

- **Sound effects**: `play_sfx(name, volume_db, pitch)` (16 voices, oldest reused), `play_optional_sfx(name)` (silent if missing).
- **Music**: `play_music(name, fade)` (A/B crossfade, loops, a missing track fades out), `stop_music`, `push_music` / `pop_music` / `clear_music_stack`, `duck_music` / `unduck_music`, `current_music`.
- **Video**: `play_video(name, duck, preview)` / `skip_video` on Media's own CanvasLayer, layer 5 (above the modes, below the service menu). With `preview` (the Audio & Video tab's Play) it's on layer 20, above the menu, and a tap skips it. Theora `.ogv` only.
- **Library and volume**: `list_sounds/music/videos`, `has_*`, `rescan`, `get_volume/set_volume(bus, 0..1)` (saved in `user://audio.cfg`).
- **Signals**: `sfx_played`, `music_changed`, `video_started`, `video_finished` (deferred for a missing video).

**Who decides**: modes. Mode screens pick their music (`attract`, `game`).
- Each input has an optional `sound` (switch editor) (Godot-only, not in the fingerprint) that Game plays on close during a game.
- Modes override it with `Game.set_switch_sound(name, sound)` (`&""` silences) or reset it with `clear_switch_sounds()`.
- Game plays `game_start`, `ball_start`, `drain`, `extra_ball` and `game_over` if those files exist.

**Media files are not in git.** The repo is public and some media is licensed. `.gitignore` skips `assets/**` except `assets/README.md` and `assets/**/test/**`, the generated test media (`tools/make_test_sounds.gd`). Never commit licensed media. It syncs PC → Pi with Syncthing (PC send-only, Pi receive-only) or `scp`. See `Docs/audio-video.md`.

## Shows (autoload): light shows

`media/shows.gd`, registered as **`Shows`** after Media. See `Docs/lighting.md`.
- **A show** is a scene `assets/shows/<name>.tscn`: a `LightShow` root (`media/light_show.gd`, `@export sync_to` = `music|video|none`), plus an AnimationPlayer with an animation named **`show`** (Call Method tracks on the root; each key's method is its **cue type**: `light(light_name, effect, color, ms, color2)`, with coil/servo cue types to come; old shows' `cue(...)` keys still read as light cues. **One track per light**: a track holds one key per moment. Godot draws a method key's text as method + all args with no hook to change it, so the type name leads; the Animation panel's **Toggle method names** hides it), plus an optional `SongPreview` AudioStreamPlayer with an Audio track for the waveform.
- **Shows don't run the AnimationPlayer.** `_load` instantiates the scene off-tree, reads the method-track keys into a sorted cue list (cached), and frees it. `_process` fires cues against the clock: `Media.get_music_position()` (playback + time since mix − output latency), `Media.get_video_position()`, or its own timer. Minus `sync_offset_ms` (−300..300, saved in `user://audio.cfg`). A clock that jumps back (a loop) restarts the cues.
- **By name**: `Media.music_changed(name)` / `video_started(name)` start the show with the same name; stopping or changing the song or video stops it. `stop_show()` turns off only the lights the show touched. `play_show(name)` also starts the song with that name if needed.
- **API**: `play_show`, `stop_show`, `is_show_playing`, `current_show`, `list_shows`, `has_show`, `get_cues`, `rescan`, `set_sync_offset`, `clock_override` (tests), `set_preview_listening(on, remember)`, `is_previewing`. State `preview_listening`, `preview_peer`. Signals `show_started`, `show_finished`, `preview_changed(peer)`. Names starting with `_` (the template) aren't shows.
- **Editor preview** (Godot never calls Call Method keys in the editor): the **Light Show** dock (`addons/loso_show_tools/show_dock.gd`) reads the open show's keys with `ShowCues`, works out each light's cue at the playhead (`ShowCues.state_at`), and with **Send to game** on sends each change as a UDP text line to the running game on port `ShowCues.PREVIEW_PORT` (4777): `PING` → `PONG <light>...`, `FX <light> <effect> <RRGGBB> <ms> <RRGGBB2>`, `OFF`. Shows only listens while **Show preview** is on (Audio & Video tab, saved in `user://audio.cfg`, off by default), stops a running show when cues arrive, and calls `PinballIO.set_light`. Lights only, never coils. Each light's row in the dock edits the key it follows at the playhead (`edit_at_playhead`, `track_set_key_value`; adds one if none), **+** adds a key at the playhead on the light's own track (`add_cue`, `ShowCues.track_for_light`, a new Call Method track if none), **✕** deletes it (`delete_at_playhead`), **Key all** keys every light at the playhead with its current settings (`key_all_at_playhead`, one undo step), the row's name field / ▾ machine-light picker renames all of a light's keys (`rename_light`, arg 0), all through the editor's undo history. `Shows.preview_port` / the dock's `port` let tests use another port than a running game's.
- **Shows sync to the Pi with the media** (not in git), except `assets/shows/_template.tscn` and `assets/shows/test/` (the demo for `test_loop_a`), made by `tools/make_show_template.gd`.

## Coding conventions

- GDScript with **static typing everywhere** (`var x: int`, `-> void`, `:=`). Tabs for indentation (Godot default).
- `snake_case` for functions and variables, `PascalCase` for classes and nodes, `UPPER_SNAKE` for constants. Prefix private members with `_`.
- Communicate between systems with signals, not direct node paths across scenes. "Call down, signal up."
- No magic numbers for switch, coil, or lamp IDs in game code. Use the names from `MachineConfig` (e.g. `&"flipper_left"`); pins and board indexes never appear outside `MachineConfig`/`PinballIO`.
- Doc comments with `##` on public signals and functions.
- Firmware: no `delay()` in `loop()`. Everything non-blocking with `millis()` timing and rollover-safe comparisons. No dynamic allocation.

## Testing

- **Without hardware**: `godot --headless --path . -s res://test/test_config_link.gd` checks MachineConfig validation, the CFG lines built from the default config, and the BoardLink handshake against a fake board. `-s res://test/test_shows.gd` checks LED lights through PinballIO against a fake PINIO 0.3 board (FX lines, re-send after WD OK) and light shows (cue reading, firing on a fake clock, loops, start by song name), plus the editor dock outside the editor talking to Shows over real UDP on 127.0.0.1 (scrubbing drives the lights, Add cue). `-s res://test/test_media.gd` checks Media (library, sfx voices, crossfade, push/pop, missing video) and switch sounds, using the generated test media. `-s res://test/test_game.gd` checks the Game autoload (scoring by switch kind, drains, abort) with faked `switch_changed` signals. `-s res://test/test_setup_ui.gd` drives the coil wizard and switch editor (always cancels, never writes user://). In `-s` mode, scripts that use autoload names must be `load()`ed at runtime, not preloaded. Tests live in `test/`. If a full `GdSerialManager` stub is ever added there, never ship it alongside the real plugin, because the class names would clash.
- **Without Godot**: open the Arduino Serial Monitor (line ending "Newline"), send `HELLO`, `WD OFF`, then `CFG IN ...` / `CFG COIL ...` / `CFG DONE` lines (see the top of `Firmware/pinio/pinio.ino`), then `RULE ALL ON`, `PULSE 0`, `LED 0 BLINK`. LEDs: `CFG CHAIN 0 8 30 GRB`, `CFG ZONE 0 0 0 30` before `CFG DONE`, then `FX 0 RAINBOW 000000 3000` (see `Docs/lighting.md`).
- **Firmware compile check**: the Arduino IDE bundles `arduino-cli`: `arduino-cli compile --fqbn teensy:avr:teensy41 --warnings all Firmware/pinio`.
- After changing GDScript, check that the project parses (`godot --headless --path . --quit` should show no script errors).

## Roadmap / next steps

1. ✅ Serial link, test sketch, PinballIO autoload, and test panel.
2. Configurable I/O build-out (in progress):
   - ✅ Base scene (`main.tscn`, mode host, service layer on the P key).
   - ✅ PINIO generic firmware with the trigger/EOS/hold coil rule, which covers the real flipper state machine. Compiles; not yet bench-tested on wired pins.
   - ✅ MachineConfig + BoardTypes + BoardLink, and a name-based PinballIO.
   - ✅ Burn layout to board (EEPROM, fingerprints in HELLO).
   - ✅ Service menu (P key): Monitor tab (I/O LEDs by pin + log), Hardware tab with the coil wizard (kind → name/pin → trigger/EOS, can create switches → power → review + live test → save), switch editor, delete, Burn to board. Edits are drafts (MachineConfig.snapshot/restore) until Save.
   - ✅ WS2812B LED chains (PINIO 0.3, OctoWS2811 DMA): chains + named lights (zones) set up on the Hardware tab, board-drawn effects, brightness, Monitor swatches. Compiles; not yet bench-tested on a strip. CFG LAMP on/off pins stay for simple outputs.
   - Several boards at once (auto-scan ports, match by uid, machine fault if one drops).
   - Arduino Uno board support (`board_uno.h`).
   - Later: input expander (74HC165 / matrix), analog inputs as a configurable type, EOS-reopen re-pulse.
3. Game state skeleton (in progress):
   - ✅ Attract → Start game → 3 balls with score → drain → game over, plus Abort game and switch kinds (target/spinner/drain/start).
   - Next: ball kickout, tilt, ball save, per-state rules, a balls-per-game setting.
4. Real playfield layout in the machine config.
5. Audio, video, and a score display in Godot. ✅ Media autoload (sfx, music crossfade/stack, cutscene layer), switch and event sounds, volumes and media players on the Audio & Video tab. ✅ Light shows (Shows autoload, Godot-timeline authoring, synced to music/video by name, sync offset, editor Light Show dock with live LED preview and Add cue). Not yet done: Pi cutscene test, callouts/voice. An 80s-style segment display look is an option, possibly as a hybrid. **Validate cutscene video on real Pi 4 hardware before building out a lot of cutscene content** — see "Target hardware" above.

## Things to avoid

- Don't put coil timing or flipper logic in Godot.
- Don't call GdSerial from anywhere except `pinball_io.gd`.
- Don't change the protocol on only one side.
- Don't edit `addons/gdserial`.
- Don't switch to C#/.NET without asking. The decision was GDScript + GdSerial.

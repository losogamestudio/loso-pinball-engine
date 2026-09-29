# Machine configuration

Which pin on which board is which switch, coil, or lamp is **data, not code**. It lives in one config file that Godot reads at startup and sends to each board when it links. Game code never sees a pin number. It uses names like `flipper_left` and `sling_left_switch`.

## The Setup tab (P key)

Touch **Service** (bottom-right of the opening screen) or press **P**, and open the **Setup** tab. **Exit** (top-right) closes the menu; **Quit to desktop** is at the bottom of the Setup tab. The top row is for this machine's screen: a **UI scale** (the game is laid out for 1280×720 and shrunk or stretched to fit; leave it at 100% on a small screen), a **Text size** that makes only the letters bigger and keeps the layout (200% by default, which suits an 800×480 screen), and **Fullscreen**. Both apply immediately and are remembered on this machine (`user://display.cfg`). Below that it lists every coil and switch, with **Edit** and **Delete** buttons and live lamps for the switches. The board row shows whether each board is connected and whether its layout is burned, with a **Burn to board** button when it isn't.

**+ Add coil** opens a step-by-step wizard:

1. **Kind**: Flipper, Slingshot/pop bumper, Kicker/eject, or Diverter/magnet. This only fills in starting values.
2. **Name and output pin**: only free output pins are offered. A coil that holds only gets PWM pins.
3. **Trigger and end-of-stroke switches**: pick "(none)", an existing switch, or **New switch on pin N**, which creates the switch for you (named after the coil, e.g. `flipper_left_button`, `flipper_left_eos`) with NO/NC and debounce options. Lamps show switches that are already live, so you can check wiring.
4. **Power**: full-power ms, hold %, recycle ms, each with an explanation.
5. **Review and test**: the draft is sent to the board straight away. **Fire once**, **Hold for 1 second** and **Arm the rule, then press the real switch** let you try it for real, and the trigger/EOS lamps show the switches live. Nothing is written to disk until **Save**. **Cancel** (or closing the menu with P) puts the board and the layout back as they were.

**+ Add switch** / **Edit** on a switch opens a one-page editor for its name, pin, NO/NC and debounce, with **Send to board to test** and a live lamp. Renaming a switch also renames it in every coil that uses it. A switch a coil still uses can't be deleted.

After saving, press **Burn to board** so the Teensy keeps the layout at power-off.

Lamps aren't in the Setup tab: lighting will be WS2812B LED chains, set up in a later version.

The rest of this page describes the file the Setup tab edits. You can still edit it by hand.

## Where it lives

| File | What it is |
|---|---|
| `res://config/machine_config.default.json` | The layout that ships with the project (in git). Used when nothing is saved. |
| `user://machine_config.json` | This machine's saved layout. When it exists, it wins. The Setup tab writes it; "Reset to default layout" deletes it. |

`user://` is Godot's per-user data folder, outside the project, so it's never committed. On Windows it's `%APPDATA%\Godot\app_userdata\Loso Pinball Engine\`; on Linux and the Pi it's `~/.local/share/godot/app_userdata/Loso Pinball Engine/`.

The diagnostics panel (P key) shows which file was loaded, and lists any problems with it in its log.

## The file

```json
{
  "version": 1,
  "boards": [
    { "id": "main", "type": "TEENSY41", "uid": "", "pwm_hz": 20000 }
  ],
  "inputs": [
    { "name": "flipper_left_button", "board": "main", "pin": 33, "nc": false, "debounce_ms": 5 },
    { "name": "flipper_left_eos",    "board": "main", "pin": 34, "nc": false, "debounce_ms": 2 },
    { "name": "sling_left_switch",   "board": "main", "pin": 35, "nc": false, "debounce_ms": 5 }
  ],
  "coils": [
    { "name": "flipper_left", "board": "main", "pin": 2,  "full_ms": 60, "hold_pct": 50,
      "trigger": "flipper_left_button", "eos": "flipper_left_eos", "recycle_ms": 0 },
    { "name": "sling_left",   "board": "main", "pin": 26, "full_ms": 40, "hold_pct": 0,
      "trigger": "sling_left_switch", "eos": "", "recycle_ms": 150 },
    { "name": "kickout",      "board": "main", "pin": 3,  "full_ms": 30, "hold_pct": 0,
      "trigger": "", "eos": "", "recycle_ms": 500 }
  ],
  "lamps": [
    { "name": "lamp_0", "board": "main", "pin": 27 }
  ]
}
```

### boards

| Field | Meaning |
|---|---|
| `id` | Your name for the board. Inputs, coils and lamps say which board they're on with this. |
| `type` | Board type: `TEENSY41` for now. Types are defined in `boards/board_types.gd`. |
| `uid` | The board's serial number (shown in the diagnostics log when it links). Leave it `""` to accept any board of this type, which is fine with one board. Fill it in once you have two of the same type, so each one gets the right layout no matter which USB port it's on. |
| `pwm_hz` | Hold PWM frequency for this whole board. 20000 (20 kHz) is above hearing range. |

### inputs

| Field | Meaning |
|---|---|
| `name` | What game code calls it. |
| `pin` | Must be an input pin on that board type. On a Teensy 4.1: 14–17, 20–23, 33–41. |
| `nc` | `true` for a normally-closed switch (active when it *opens*, like many EOS switches). |
| `debounce_ms` | 0–100. How long the switch must be stable before it counts. |

### coils

| Field | Meaning |
|---|---|
| `pin` | Must be an output pin. On a Teensy 4.1: 2–12 and 24–32. |
| `full_ms` | 1–255. Full-power time. With an EOS set, this is the maximum (the failsafe if the EOS switch breaks). |
| `hold_pct` | 0 = pulse only (slings, pops, kickers). 1–100 = PWM hold after full power (flippers, diverters). 1–99 needs a PWM-capable pin: on a Teensy 4.1 that's 2–12, 24, 25, 28, 29, **not** 26, 27, 30, 31, 32. |
| `trigger` | Name of the input that fires this coil *on the board*, with no Godot round trip. `""` = only Godot fires it. |
| `eos` | Name of the end-of-stroke input that cuts full power early. `""` = none. |
| `recycle_ms` | 0–5000. After turning off, the coil ignores new fires for this long. |

A coil's trigger and EOS must be inputs **on the same board** as the coil: the board runs the rule by itself, so it can only see its own switches.

### lamps

Just a `name`, `board` and output `pin`.

## Getting it onto the board

When a board connects, Godot compares the board's layout fingerprint with its own. If they differ, it sends this file's layout to the board, which runs it straight away but only in RAM. **Burn to board** (P → Setup, or "Burn layout to board" on the Diagnostics tab) stores it in the board's EEPROM, so the board boots configured. This file stays the master copy: after changing it, burn again. See [Serial protocol](serial-protocol.md#burning-the-layout-and-fingerprints) for the details.

## Rules the config must follow

Godot checks these before sending anything to a board (`MachineConfig.validate()`), and the board checks them again:

- Every name is unique across inputs, coils *and* lamps, and has no spaces.
- A pin is used by only one thing per board, and never a reserved pin (on a Teensy 4.1: 0 and 1 are Serial1, 13 is the status LED, and 18 and 19 are I2C).
- Inputs go on input pins and coils/lamps on output pins. A hold % between 1 and 99 needs a PWM pin.
- A trigger or EOS names an existing input on the same board, and a coil's trigger and EOS aren't the same input.
- A board can have at most 24 inputs, 24 coils and 24 lamps (Teensy 4.1).

If the config has problems, the diagnostics panel lists them and PinballIO won't configure the board until they're fixed.

## Using it from game code

```gdscript
PinballIO.set_coil_rule(&"flipper_left", true)   # arm the flipper (e.g. when a ball starts)
PinballIO.set_all_rules(false)                   # everything off (tilt, game over)
PinballIO.pulse_coil(&"kickout")                 # fire once, using the coil's full_ms
PinballIO.set_lamp(&"lamp_0", "BLINK")
PinballIO.switch_changed.connect(_on_switch)     # _on_switch(switch_name: StringName, active: bool)
PinballIO.coil_fired.connect(_on_coil_fired)     # a sling/pop fired on its own
```

The `&"..."` is a StringName, Godot's interned string (a bit like `FName` in Unreal): fast to compare, which suits names used as IDs. A plain `"flipper_left"` works too.

Rule and lamp calls are remembered, so you can make them before a board is even connected. PinballIO applies them as soon as the board is ready, and again after a watchdog trip.

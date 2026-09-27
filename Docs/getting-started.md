# Getting started (desktop development)

This walks through going from a fresh checkout to a live serial link on your desktop, with a breadboard standing in for the real playfield. For running the same project on a Raspberry Pi, see [Deploying to a Raspberry Pi](raspberry-pi.md) instead.

## What you need

- **Godot 4.4 or later**, the standard build (not the .NET/C# build — this project is GDScript only).
- **Arduino IDE** with **Teensyduino** installed, for building and flashing the firmware.
- A **Teensy 4.x** board.
- Some breadboard hardware to stand in for the real playfield while there's no real machine yet: 4 pushbuttons (or jumper wires to ground) for switches, a couple of LEDs with resistors for "coils," a couple more for lamps, and optionally a potentiometer for the analog input. Exact pins are in the wiring comment at the top of `Firmware/pinio_test/pinio_test.ino`.

## Steps

### 1. Get the code

```sh
git clone https://github.com/losogamestudio/loso-pinball-engine.git
```

### 2. Open the project in Godot

Point Godot at the cloned folder and open it. There's nothing to install for the serial plugin — `addons/gdserial` is vendored directly in the repo and already enabled in `project.godot`. If you ever want to double-check it's active: **Project → Project Settings → Plugins** should show GdSerial checked.

### 3. Flash the practice firmware

Open `Firmware/pinio_test/pinio_test.ino` in the Arduino IDE. Select your Teensy board and **USB Type: "Serial"** under Tools, then upload. Baud rate doesn't matter for Teensy's USB serial (it's always full USB speed), but the code sets 115200 anyway since some tools want a value.

Wire up the practice hardware per the comment at the top of the sketch:

| Item | Pin | Notes |
|---|---|---|
| Switches 0–3 | 2, 3, 4, 5 | `INPUT_PULLUP`, pressed = LOW |
| Coil 0 (sling stand-in) | 13 | Onboard LED |
| Coil 1 | 6 | LED + 330Ω |
| Lamps 0–1 | 7, 8 | LED + 330Ω |
| Analog 0 | A0 | Pot, 3.3V only. `USE_ANALOG` is `false` until you actually wire one up |

You don't need real coils or lamps to try this out — LEDs make the pulses and blink modes visible, which is the point of a practice rig.

### 4. Run the project

`control.tscn` is the main scene, so just hit Play (or run it directly — see below). You'll land on the [diagnostics panel](diagnostics-panel.md):

1. Pick your Teensy's port from the dropdown (it'll show up as something like `COM9` on Windows or `/dev/ttyACM0` on Linux) and hit **Connect**.
2. The status label should go from "Port open, waiting for Teensy…" to "Linked: PINIO 0.1" within a second, and the four switch lamps should reflect whatever's currently pressed.
3. The little green "Teensy HB" lamp should start pulsing once a second — that's proof the Teensy is actually alive and talking, not just that the OS thinks the port is open.
4. Try the coil buttons (or the **Left/Right arrow keys** — see [diagnostics panel](diagnostics-panel.md) for why keyboard shortcuts exist here at all), toggle an LED's mode, flip on the "Sling rule" checkbox and press switch 0 to see `FIRED SLING_L` show up in the log and the score bump.
5. Once it's linked the way you want, check **"Auto-connect at startup"** — next time you run the project, it'll remember that port and reconnect on its own.

### 5. Running headless (no window, useful for scripting/CI)

```sh
godot --headless --path . --quit
```

This loads the project and immediately quits — a quick way to confirm there are no GDScript parse errors after making a change, without needing a display.

## Where to go next

- [Architecture](architecture.md) if you want the *why* behind the Teensy/Godot split before changing anything.
- [Serial protocol](serial-protocol.md) if you're touching the wire format.
- [Diagnostics panel](diagnostics-panel.md) for what every control on screen actually does.
- [Deploying to a Raspberry Pi](raspberry-pi.md) once you're ready to get off the desktop.

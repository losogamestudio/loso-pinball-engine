# Getting started (desktop development)

This walks through going from a fresh checkout to a live serial link on your desktop, with a breadboard standing in for the real playfield. For running the same project on a Raspberry Pi, see [Deploying to a Raspberry Pi](raspberry-pi.md) instead.

## What you need

- **Godot 4.4 or later**, the standard build (not the .NET/C# build — this project is GDScript only).
- **Arduino IDE** with **Teensyduino** installed, for building and flashing the firmware.
- A **Teensy 4.1** board.
- Optional breadboard hardware to stand in for the real playfield: 3 pushbuttons (or jumper wires to ground) and a few LEDs with resistors. The pins are in step 3. Without any of it you can still link, configure the board, and watch the status LED.

## Steps

### 1. Get the code

```sh
git clone https://github.com/losogamestudio/loso-pinball-engine.git
```

### 2. Open the project in Godot

Point Godot at the cloned folder and open it. There's nothing to install for the serial plugin — `addons/gdserial` is vendored directly in the repo and already enabled in `project.godot`. If you ever want to double-check it's active: **Project → Project Settings → Plugins** should show GdSerial checked.

### 3. Flash the firmware

Open `Firmware/pinio/pinio.ino` in the Arduino IDE. Under Tools, select **Teensy 4.1** and **USB Type: "Serial"**, then upload. Baud rate doesn't matter for Teensy's USB serial (it's always full USB speed), but the code uses 115200 anyway because some tools want a value.

The firmware is generic: it doesn't know your playfield until Godot sends it the layout from the [machine config](configuration.md). With the Teensy's USB port pointing up, the **left** header pins are outputs and the **right** header pins are inputs. The shipped default config uses:

| Name | Kind | Pin | Stand-in |
|---|---|---|---|
| `flipper_left_button` | input | 33 | pushbutton to GND |
| `flipper_left_eos` | input | 34 | pushbutton to GND |
| `sling_left_switch` | input | 35 | pushbutton to GND |
| `flipper_left` | coil, 60 ms full, 50% hold | 2 | LED + 330Ω to GND |
| `sling_left` | coil, 40 ms pulse | 26 | LED + 330Ω to GND |
| `kickout` | coil, 30 ms pulse, Godot-fired | 3 | LED + 330Ω to GND |
| `lamp_0` | lamp | 27 | LED + 330Ω to GND |

Inputs are **3.3 V only**: wire switches to GND, never to 5 V. LEDs make pulses, holds (dimmer) and blinking visible, which is the point of a practice rig. On real driver boards, every MOSFET gate needs a pulldown resistor, because the pins float while the Teensy boots or is being flashed.

The onboard LED (pin 13) is the **status LED**:

| Pattern | Meaning |
|---|---|
| slow blink | waiting for Godot |
| medium blink | linked, waiting for its config |
| solid | configured and running |
| fast blink | watchdog tripped |

### 4. Run the project

Hit Play (or run it directly — see below). The base scene, `main.tscn`, opens on an attract-mode placeholder. Press **F1** to open the [diagnostics panel](diagnostics-panel.md) (F1 again closes it):

1. Pick your Teensy's port from the dropdown (it'll show up as something like `COM9` on Windows or `/dev/ttyACM0` on Linux) and hit **Connect**.
2. Within a second the status goes "Linked on …: PINIO 0.2, sending config…", then "Ready: board 'main' configured". The log shows the `CFG` lines going out and `ACK CFG 3 3 1 <fingerprint>` coming back, and the Teensy's status LED goes solid. Click **Burn layout to board** to store it on the Teensy: from then on it boots configured, and on the next connect Godot sees the fingerprints match and sends nothing.
3. The green "Board HB" lamp pulses once a second. That's proof the Teensy is alive and talking, not just that the OS thinks the port is open.
4. Try the coil buttons (or the **Left/Right arrow keys**; see [diagnostics panel](diagnostics-panel.md) for why keyboard shortcuts exist at all) and cycle the lamp's mode. Then check **Rule: flipper_left_button → flipper_left** and hold the button on pin 33: the LED on pin 2 is bright for 60 ms, then dims to 50% until you let go (pressing 34, the EOS, dims it sooner). Arm the sling rule and press 35 to see `FIRED 1` in the log and the score jump.
5. Once it's linked the way you want, check **"Auto-connect at startup"** — next time you run the project, it'll remember that port and reconnect on its own.

### 5. Running headless (no window, useful for scripting/CI)

```sh
godot --headless --path . --quit
```

This loads the project and immediately quits — a quick way to confirm there are no GDScript parse errors after making a change, without needing a display.

There's also a no-hardware test of the config and link code, using a fake board:

```sh
godot --headless --path . -s res://test/test_config_link.gd
```

It prints `PASS`/`FAIL` per check and ends with `ALL PASSED`.

## Where to go next

- [Architecture](architecture.md) if you want the *why* behind the Teensy/Godot split before changing anything.
- [Machine configuration](configuration.md) to change which pin is which switch, coil or lamp.
- [Serial protocol](serial-protocol.md) if you're touching the wire format.
- [Diagnostics panel](diagnostics-panel.md) for what every control on screen actually does.
- [Deploying to a Raspberry Pi](raspberry-pi.md) once you're ready to get off the desktop.

# Servos: on board pins and PCA9685 boards

Hobby servos move the toys: a ramp gate, a diverter, a skull's jaw, a spinning head. The Teensy drives them, and like everything with timing, **the board runs the motion**. Godot only says "go to 80 % over 0.6 s, smoothly", and the board updates the servo every 10 ms by itself.

There are two ways to wire a servo:

| | On a board pin | On a PCA9685 |
|---|---|---|
| What | The servo's signal wire goes straight to a Teensy output pin | A PCA9685 16-channel servo board on the Teensy's I2C pins |
| How many | Up to 12 per Teensy | 16 per PCA9685, up to 4 PCA9685s (64 channels) |
| Good for | One or two servos near the Teensy | Toys with several servos, servos far from the Teensy |

A Teensy can run 32 servos in all.

## Wiring

**Power first:** servos draw a lot of current when they start moving or stall (often 1 A or more each), so they get their **own 5-6 V supply**. Never power them from the Teensy or its USB. **Join the grounds**: the servo supply, the Teensy and the PCA9685 share GND.

**On a board pin:**
- Signal (usually orange, yellow or white) → any free output pin on the left header (USB port up).
- Red → the servo supply's + (5-6 V).
- Brown or black → GND.
- The Teensy's 3.3 V signal drives nearly all hobby servos fine.

**On a PCA9685** (the common Adafruit-style breakout):
- **VCC** → Teensy **3.3 V** (the chip's logic).
- **GND** → Teensy GND.
- **SDA** → Teensy pin **18**, **SCL** → pin **19**. Those two pins are kept free for this.
- **V+** (the screw terminal) → the servo supply's + (5-6 V). The servos plug into the 3-pin headers.
- **Address:** 0x40 with no jumpers bridged. Bridge **A0**-**A5** to give each extra board its own address (A0 = 0x41, A1 = 0x42, A0+A1 = 0x43, ...). The servo editor shows which jumpers make each address.
- **Several PCA9685s** daisy-chain: the I2C wires and power go from one board to the next.

## Setting it up (service menu → Hardware → Servos)

Tap **+ Add servo**. The editor has:
- **Name**: what game code and shows call it.
- **Wired to**: **PCA9685 servo board** (then its **address** and **channel** 0-15) or **Board output pin** (then which free pin).
- **Pulse at 0 %** and **Pulse at 100 %**, in microseconds. This is the servo's travel. Start with **1000-2000 µs**, which is safe for nearly every servo. Widen it a little at a time (e.g. 600-2400) for more travel. If the servo buzzes or strains at an end, that end is too far: bring it back in. The pulse at 0 % must be the shorter one, so there's no "reverse" setting: if a servo turns the wrong way for a toy, mount its horn the other way round, or use the positions the other way round (1 for closed, 0 for open).
- **Home**: where it goes when the board starts up and whenever a new layout is sent, as a % of the travel.
- **Try it**: drag the slider and the real servo follows. **Min**, **Home** and **Max** move there over the ramp time, Linear (steady) or Smooth (eases in and out). Trying it sends the draft to the board; **Save** keeps it, **Cancel** puts things back.

The Servos list then has **Min / Home / Max** buttons for a quick check (1 s, smooth). On the **Monitor** tab, each servo has an LED (its pin, or `P0:3` for the first PCA9685's channel 3) that's lit while a move is running.

Press **Burn to board** afterwards, so the Teensy keeps the layout at power-off.

## From game code

```gdscript
PinballIO.set_servo(&"ramp_gate", 1.0)                     # straight to 100 %
PinballIO.set_servo(&"ramp_gate", 0.0, 600, "SMOOTH")      # back to 0 % over 0.6 s, easing in and out
PinballIO.set_servo(&"skull_jaw", 0.5, 200, "LINEAR")      # half open over 0.2 s at a steady speed
if PinballIO.is_servo_moving(&"ramp_gate"): ...
```

Positions are **0..1 of the servo's travel** (its pulse at 0 % to its pulse at 100 %), so game code never deals in microseconds. Like rules, lamps and lights, PinballIO remembers where each servo should be.

## Shows

A show can move servos with `servo(...)` keys, next to its light and coil keys. Each servo has a row in the editor's Light Show dock (position slider, ramp ms, Linear / Smooth), and with **Send to game** on the real servo follows the playhead while you scrub. See [Lighting: Shows](lighting.md#shows-lights-servos-and-coils).

## Safety

- **Nobody in control, nothing moves.** If Godot goes quiet (the 500 ms watchdog), restarts the link (`HELLO`), or burns the layout, every move in progress stops and each servo **holds where it is**. When the link is back, PinballIO eases each servo back to where game code wants it, over half a second.
- **At power-up** (with a burned layout) and when a new layout arrives, every servo goes to its **home** position. The board can't know where a servo was, so this is a jump, not a ramp: give toys room to reach home.
- **A PCA9685 that stops answering** (cable off, no power) is reported once in the Monitor log (`ERR PCA 0 lost ...`) and then skipped, so a loose I2C cable never slows down the flippers. Its servos start again with the next layout (fix the cable, then tap Connect again or edit anything).

## Testing without Godot (Serial Monitor)

With the Arduino Serial Monitor (line ending **Newline**) on the Teensy:

```
HELLO
WD OFF
CFG CLEAR
CFG PCA 0 40
CFG SERVO 0 P0:0 1000 2000 500
CFG SERVO 1 5 1000 2000 500
CFG DONE
SERVO 0 1000 1500 SMOOTH
SERVO 1 0
SERVO 0 0 1500 LINEAR
```

- `CFG PCA 0 40`: a PCA9685 at address 0x40. If it says `doesn't answer`, check SDA/SCL, VCC, GND and the jumpers.
- `CFG SERVO 0 P0:0 1000 2000 500`: servo 0 on that PCA's channel 0, 1000-2000 µs, home in the middle (500 of 1000).
- `CFG SERVO 1 5 1000 2000 500`: servo 1 on pin 5.
- `SERVO 0 1000 1500 SMOOTH`: servo 0 to its 100 % over 1.5 s, easing in and out.

See [Serial protocol](serial-protocol.md) for the exact commands.

## How it works inside (for the curious)

`Firmware/pinio/servos.h`:
- **Pin servos** get their 50 Hz pulses from one timer interrupt (`IntervalTimer`): pin A high for its pulse width, then pin B, and so on, then a gap to the end of the 20 ms frame. It's the same idea as Teensy's own Servo library, written into the firmware so a different "Servo" library in your Arduino sketchbook can't break the build, and it never uses the hardware PWM timers the coil holds need.
- **PCA9685s** are set to 50 Hz and written over I2C at 400 kHz, **one channel per pass of the main loop** (about 0.15 ms), so coils and flippers never wait on I2C. The setup follows the PCA9685 code from the animatronics projects.
- **Ramps** are worked out every 10 ms: Linear moves at a steady speed; Smooth uses a smoothstep curve (slow, faster, slow).

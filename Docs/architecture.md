# Architecture

## The one rule

**The Teensy owns anything with timing or safety. Godot owns rules and presentation.**

Everything else in this project falls out of that split. It's worth understanding *why* before touching either side.

## Why split it this way at all

A pinball machine has two very different kinds of problems:

1. **Hard real-time, safety-critical control.** A flipper coil that stays energized too long burns out or catches fire. A switch that isn't debounced fires a rule twice. A solenoid that never gets a watchdog keeps firing if the software driving it crashes. These need guaranteed, low-jitter timing and a fail-safe default (outputs off) — the kind of thing a microcontroller running a tight loop is good at, and a general-purpose OS running a game engine is not.
2. **Everything else**: scoring, modes, ball tracking, sound, video, the display. This is exactly what a game engine is built for, and Godot is a good one — but it's running on a frame-based scheduler under a general-purpose OS (eventually Linux on a Raspberry Pi), which is fine for anything that can tolerate a frame or two of slop, and not fine for anything that can't.

So: **Teensy 4.x** for problem 1, **Godot 4 (GDScript)** for problem 2, talking over a plain-text USB serial link. This is a homebrew, from-scratch take on the same split MPF (Mission Pinball Framework) makes with its own hardware controllers — we're just not using MPF itself.

## What stays on the Teensy, and why

- **Flippers.** Each coil is a single-winding 12V coil overdriven at 24V for pull-in, switched down to roughly 50% PWM hold once the EOS (end-of-stroke) switch trips, and released the instant the flipper button is released. Dual-wound coils are ruled out. This whole state machine — button press → full power → EOS closes → PWM hold → button release → off — has to react within microcontroller-grade timing, so it lives entirely in firmware. In PINIO 0.2 a flipper isn't special code: it's a coil configured with a trigger (the button), an EOS input and a hold %, running the same generic coil rule as everything else (see [Serial protocol](serial-protocol.md)). Godot hears about the button press as an ordinary switch event, after the flipper has already moved.
- **Slingshots and pop bumpers, as local hardware rules.** The pattern is: switch closes → the Teensy fires the coil *immediately*, in the same firmware pass → *then* it tells Godot `FIRED <coil>` after the fact. Godot finds out a slingshot fired; it never causes one to fire. This matters because a slingshot needs to respond faster than a round-trip over serial plus a game-engine frame can reliably guarantee, and because losing the serial link should never mean losing slingshots (or, from a safety standpoint, should mean the opposite — see the watchdog below).
- **Switch debouncing.** Raw switch input is noisy; the Teensy is the one place that turns "raw" into a clean `SW <id> <0|1>` transition, so Godot only ever sees stable state changes.
- **Coil safety.** Two independent mechanisms: a hard cap on every coil's pulse length (`MAX_PULSE_MS`, currently 255ms in the practice sketch) enforced in firmware regardless of what Godot asks for, and a **watchdog** that turns every output off and disables every hardware rule the moment Godot goes quiet for too long (500ms in the current protocol). Godot crashing, hanging, or a USB cable falling out should always fail toward "everything off," never toward "something stuck on."
- **Anything that moves smoothly over time.** LED effects ([Lighting](lighting.md)) and servo ramps ([Servos](servos.md)) are drawn and stepped on the board, LEDs about 60 times a second and servos every 10 ms. Godot sends one short line per change ("servo 0 to 80 % over 600 ms, smoothly"), never a stream of frames, so a busy Pi or a slow USB link can't make them stutter. On the watchdog, servos stop and hold where they are.

## What Godot owns

- **Configuring and arming hardware rules.** Godot *describes* each coil to the board (pin, full-power time, hold %, trigger input, EOS input, recycle time) from the [machine config](configuration.md), and arms or disarms its rule, for example off during tilt or between balls. It never fires a rule itself. The rule always runs on the board; Godot only decides what it looks like and whether it's currently armed.
- **Scoring, modes, ball tracking, audio, video, and the UI.** All the parts of a pinball game that are really a game-engine problem, not a real-time-control problem.
- **One-off output commands that aren't time-critical in the same way**: firing a kickout coil to launch a ball, resetting drop targets, setting lamp/LED state, moving servos. These go out as explicit serial commands (`PULSE`, `LED`, `FX`, `SERVO`, ...) whenever Godot's game logic (or a show) decides they should happen.

## Game flow

The `Game` autoload (`game/game.gd`) runs a game: **Start game** (touch, or a switch of kind `start`) arms every coil rule, sets ball 1 of 3 and zeroes the score. Switches of kind `target`/`spinner` add their points, a `drain` switch (or the **Drain ball** test button) moves to the next ball, or replays the same ball if an extra ball is waiting, and after the last ball, or **Abort game**, the rules are disarmed and the game ends. `Main` listens to `Game.game_started`/`game_ended` and swaps the attract screen and the game screen (`modes/game_play.tscn`). Game events that need an output (a ball kickout, a drop target reset) will be direct `pulse_coil`/`hold_coil`/`set_lamp` commands from game logic.

## Data flow, end to end

```
startup:     MachineConfig (names → board + pin)  →  PinballIO  →  serial: CFG ... lines  →  board knows its layout
Playfield switch  →  board (debounce, run any coil rule)  →  serial: SW <n> <state>  →  PinballIO (n → name)  →  switch_changed(&"sling_left_switch", true)  →  game logic
game logic  →  PinballIO.pulse_coil(&"kickout") / set_lamp() / set_coil_rule()  →  (name → board + n)  →  serial: PULSE / LED / RULE  →  board  →  physical output
```

Godot code never talks to the serial port directly. Everything goes through the `PinballIO` autoload (see [Serial protocol](serial-protocol.md) for the wire format, and `pinball_io.gd` for the signal/function surface). That's a deliberate choke point: one place owns every link, the retries, heartbeats, reconnects and configuration, and everything else just reacts to signals using names. Each board's link is a `BoardLink` object, so several boards can be connected at once; a coil's trigger and EOS must be on the same board as the coil, because that board runs the rule on its own.

## Driver hardware (for reference)

Custom MOSFET driver boards: **AOD4184** N-channel MOSFETs switching each coil, with **SS3H10** Schottky flyback diodes across each coil for back-EMF protection. This is the physical layer the Teensy's `PULSE`/rule outputs ultimately drive.

## Why not MPF

MPF (Mission Pinball Framework) already solves a lot of this problem, but this project is intentionally a from-scratch build — partly because a custom Teensy-based hardware layer fits the intended electronics better than MPF's usual hardware controllers, and partly because the point is to end up with a **beginner-friendly reference build**: something a person comfortable with embedded C/C++ but new to game engines (or vice versa) can read end-to-end and actually follow, rather than a framework's internals.

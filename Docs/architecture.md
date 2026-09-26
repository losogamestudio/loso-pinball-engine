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

- **Flippers.** Each coil is a single-winding 12V coil overdriven at 24V for pull-in, switched down to roughly 50% PWM hold once the EOS (end-of-stroke) switch trips, and released the instant the flipper button is released. Dual-wound coils are ruled out. This whole state machine — button press → full power → EOS closes → PWM hold → button release → off — has to react within microcontroller-grade timing, so it lives entirely in firmware. Godot never sees a flipper button press.
- **Slingshots and pop bumpers, as local hardware rules.** The pattern is: switch closes → the Teensy fires the coil *immediately*, in the same firmware pass → *then* it tells Godot `FIRED <rule>` after the fact. Godot finds out a slingshot fired; it never causes one to fire. This matters because a slingshot needs to respond faster than a round-trip over serial plus a game-engine frame can reliably guarantee, and because losing the serial link should never mean losing slingshots (or, from a safety standpoint, should mean the opposite — see the watchdog below).
- **Switch debouncing.** Raw switch input is noisy; the Teensy is the one place that turns "raw" into a clean `SW <id> <0|1>` transition, so Godot only ever sees stable state changes.
- **Coil safety.** Two independent mechanisms: a hard cap on every coil's pulse length (`MAX_PULSE_MS`, currently 255ms in the practice sketch) enforced in firmware regardless of what Godot asks for, and a **watchdog** that turns every output off and disables every hardware rule the moment Godot goes quiet for too long (500ms in the current protocol). Godot crashing, hanging, or a USB cable falling out should always fail toward "everything off," never toward "something stuck on."

## What Godot owns

- **Enabling and disabling hardware rules.** Godot can turn `SLING_L` (or any future rule) on or off — for example, off during tilt or between balls — but it never fires a rule directly. The rule always lives and fires on the Teensy; Godot just decides whether that rule is currently armed.
- **Scoring, modes, ball tracking, audio, video, and the UI.** All the parts of a pinball game that are really a game-engine problem, not a real-time-control problem.
- **One-off output commands that aren't time-critical in the same way**: firing a kickout coil to launch a ball, resetting drop targets, setting lamp/LED state. These go out as explicit serial commands (`PULSE`, `LED`, ...) whenever Godot's game logic decides they should happen.

## Data flow, end to end

```
Playfield switch  →  Teensy (debounce)  →  serial: SW <id> <state>  →  PinballIO autoload  →  switch_changed signal  →  game logic
game logic  →  PinballIO.pulse_coil() / set_led() / set_rule()  →  serial: PULSE / LED / RULE  →  Teensy  →  physical output
```

Godot code never talks to the serial port directly — everything goes through the `PinballIO` autoload (see [Serial protocol](serial-protocol.md) for the wire format, and `pinball_io.gd` for the actual signal/function surface). That's a deliberate choke point: one place owns the link, retries, heartbeat, and reconnect logic, and everything else just reacts to signals.

## Driver hardware (for reference)

Custom MOSFET driver boards: **AOD4184** N-channel MOSFETs switching each coil, with **SS3H10** Schottky flyback diodes across each coil for back-EMF protection. This is the physical layer the Teensy's `PULSE`/rule outputs ultimately drive.

## Why not MPF

MPF (Mission Pinball Framework) already solves a lot of this problem, but this project is intentionally a from-scratch build — partly because a custom Teensy-based hardware layer fits the intended electronics better than MPF's usual hardware controllers, and partly because the point is to end up with a **beginner-friendly reference build**: something a person comfortable with embedded C/C++ but new to game engines (or vice versa) can read end-to-end and actually follow, rather than a framework's internals.

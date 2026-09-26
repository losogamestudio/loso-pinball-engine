# Serial protocol (v0.1)

The Teensy and Godot talk over USB serial using plain ASCII text: one message per line, ending in `\n`, tokens separated by single spaces. It's deliberately human-readable — you can plug into the Teensy with a plain serial monitor (Arduino IDE's, `screen`, `minicom`, whatever) and type commands by hand, or just watch traffic scroll by. A binary framing (COBS + CRC) is a possible future step, but not yet.

> **This page explains the protocol.** The single-source-of-truth table that must stay byte-for-byte in sync with the actual firmware and GDScript lives in [`CLAUDE.md`](../CLAUDE.md) at the repo root — if the two ever disagree, `CLAUDE.md` is right and this page is stale. Whenever the protocol changes, three things move together in the same change: `Firmware/pinio_test/pinio_test.ino`, `pinball_io.gd`, and the table in `CLAUDE.md` (this page should get a fourth look, but isn't load-bearing the way those three are).

## Teensy → Godot

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

## Godot → Teensy

| Message | Meaning |
|---|---|
| `HELLO` | Start or restart the link. Arms the watchdog. Godot retries it every 1s until linked |
| `HB` | Heartbeat, sent every 100ms while linked. Any line counts as a heartbeat |
| `PULSE <coil> <ms>` | Fire a coil. The Teensy caps pulses at `MAX_PULSE_MS` (255) |
| `LED <id> <ON\|OFF\|BLINK>` | Lamp control |
| `RULE <name> <ON\|OFF>` | Enable or disable a hardware rule (currently only `SLING_L`) |
| `PING <n>` | Round-trip latency test |
| `WD <ON\|OFF>` | Enable or disable the watchdog. Only for manual serial-monitor testing, never sent by the game itself |

## A typical session

```
Godot: HELLO
Teensy: HELLO PINIO 0.1
Teensy: SWS 0000                  # four switches, all open
Godot: HB                         # repeats every 100ms from here on
Teensy: HB 41213                  # repeats every 1s from here on
...
Godot: RULE SLING_L ON            # arm the slingshot rule
Teensy: ACK RULE SLING_L ON
...                                # player nudges the ball into the sling
Teensy: FIRED SLING_L             # Teensy already fired the coil before this line was even sent
Teensy: SW 0 1                    # the switch transition that caused it
...
Godot: PULSE 1 150                # fire coil 1 for 150ms (e.g. bench-testing, or a kickout)
Teensy: ACK PULSE 1 150
...                                # someone unplugs the Teensy mid-game
                                    # (500ms of silence trips the Teensy's own watchdog)
Teensy: WD TRIP
                                    # (3s of silence from the Teensy trips Godot's link-lost detection)
Godot: (unlinked signal fires; PinballIO starts retrying HELLO)
```

## Link and watchdog behavior

There are two independent timeouts, one on each side, and they matter for different failure modes:

- **The Teensy's watchdog (500ms).** If it hears nothing from Godot for 500ms, it immediately turns off every coil and lamp, disables every hardware rule, and sends `WD TRIP`. This is what protects the hardware if Godot crashes, hangs, or the USB cable comes loose — outputs fail to "off," not to "stuck on." The very next line the Teensy receives clears the trip (`WD OK`), but **outputs stay off** even after that — Godot is responsible for explicitly re-sending every rule and lamp state it wants active, both right after `linked` and right after `WD OK`. Nothing is assumed to still be true from before the trip.
- **Godot's link-lost detection (3s).** If Godot hears nothing from the Teensy for 3 seconds, it considers the link lost, fires its `unlinked` signal, and starts retrying `HELLO` once a second until the Teensy answers again.

Why the asymmetry (500ms vs. 3s)? The Teensy's watchdog is a hardware-safety mechanism — it needs to be fast, because "outputs stay on for an extra 2.5 seconds" is a real problem for a solenoid. Godot's detection just governs UI/state responsiveness (showing "link lost," retrying); there's no hardware risk in waiting a bit longer to declare the link dead there.

## Versioning

The firmware string (`PINIO 0.1`) is meant to move whenever the protocol shape actually changes — bump it in the same change that touches `pinio_test.ino`, `pinball_io.gd`, and the `CLAUDE.md` table.

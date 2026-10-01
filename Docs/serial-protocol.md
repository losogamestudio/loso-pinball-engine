# Serial protocol (v0.3)

The boards and Godot talk over USB serial using plain ASCII text: one message per line, ending in `\n`, tokens separated by single spaces. It's deliberately human-readable. You can plug into a board with a plain serial monitor (the Arduino IDE's, `screen`, `minicom`, whatever) and type commands by hand, or just watch traffic scroll by. A binary framing (COBS + CRC) is a possible future step, but not yet.

> **This page explains the protocol.** The exact message table, which must stay in sync with the firmware and GDScript, lives in [`CLAUDE.md`](../CLAUDE.md) at the repo root. If the two ever disagree, `CLAUDE.md` is right and this page is stale. Whenever the protocol changes, these move together in the same change: `Firmware/pinio/pinio.ino`, `board_link.gd` / `pinball_io.gd`, and the table in `CLAUDE.md`.

## The big idea: the board is told what it is

The firmware (`PINIO 0.3`) is **generic**. It knows only what each of its own pins *can* do: input, output, or PWM-capable output (that's `Firmware/pinio/board_teensy41.h`). It doesn't know it's driving a flipper or reading a slingshot switch.

Godot tells it. After every `HELLO`, Godot sends the layout from the [machine config](configuration.md) as a series of `CFG` lines:

- **Inputs** get a number, a pin, NO/NC, and a debounce time.
- **Coils** get a number, a pin, full-power time, hold %, an optional trigger input, an optional end-of-stroke (EOS) input, and a recycle time.
- **Lamps** get a number and a pin.

From then on, everything on the wire uses those **numbers**. Only Godot knows the **names**: input 0 on the board is `flipper_left_button` in game code.

## Burning the layout, and fingerprints

The board runs its layout from RAM. **`CFG SAVE` burns it into the board's EEPROM**: at power-up the board replays the stored layout, so it's configured before Godot even connects. Its rules stay disarmed until Godot arms them, so nothing fires on its own.

To keep the board and Godot from disagreeing, every layout has a **fingerprint**: a short hash (32-bit FNV-1a, shown as 8 hex digits) of its CFG lines. The board reports two fingerprints in its `HELLO` reply: the layout it's *running*, and the one it has *burned*.

- If the running fingerprint equals the one Godot computes from its machine config, Godot sends nothing. It just asks for the switch states (`SWS`) and carries on.
- If they differ (or the board is blank), Godot sends its own layout. Godot's machine config is always the master copy, and the log notes that the board had something else.
- If the burned fingerprint differs from the running one, the layout will be lost at power-off, and the diagnostics panel says "NOT burned". Burning is always an explicit button press, never automatic.

## Message families

| Family | Direction | Messages |
|---|---|---|
| Link | both | `HELLO`, `HB`, `PING`/`PONG`, `WD TRIP`/`WD OK` |
| Config | Godot → board | `CFG CLEAR`, `CFG PWM`, `CFG IN`, `CFG COIL`, `CFG LAMP`, `CFG CHAIN`, `CFG ZONE`, `CFG DONE`, `CFG SAVE`, `CFG ERASE` |
| Commands | Godot → board | `PULSE`, `HOLD`, `RULE`, `LED`, `FX`, `BRIGHT`, `SWS` |
| Events | board → Godot | `SWS`, `SW`, `FIRED` |
| Replies | board → Godot | `ACK ...`, `ERR ...` |

## Coils: one rule covers flippers, slings and pops

Every coil runs the same little state machine **on the board**. Godot configures it and arms or disarms it, but is never in the timing path:

1. The trigger input closes while the rule is armed, so the coil goes to **full power**.
2. Full power ends when the **EOS** input closes, or when `full_ms` runs out, whichever comes first. With an EOS set, `full_ms` is the failsafe for a broken EOS switch.
3. Then:
   - **hold % > 0**: PWM **hold** at that duty for as long as the trigger stays closed. That's a flipper.
   - **hold % = 0**: **off**, and the board reports `FIRED <coil>`. That's a sling or pop bumper.
4. Releasing the trigger (or disarming the rule) drops a holding coil immediately.
5. After turning off, the coil ignores new fires for `recycle_ms`, so a chattering pop bumper can't machine-gun.

A coil with no trigger is fired only by Godot: `PULSE` (once) or `HOLD ON`/`HOLD OFF` (diverters, magnets).

## LED chains: the board draws, Godot cues

WS2812B strips work the same way. Godot tells the board where they are, and then only sends short cues:

- `CFG CHAIN <chain> <pin> <count> <order>` defines a strip on an output pin. Chains are numbered 0, 1, 2… in order.
- `CFG ZONE <zone> <chain> <first> <count>` defines a named light (a range of LEDs). Godot numbers the bigger lights first, and the board draws zones in number order, so small inserts land on top of the strips they sit in.
- `FX <zone|ALL> <effect> [RRGGBB] [ms] [RRGGBB2]` starts an effect, which the board then draws about 60 times a second by itself. Effects: `OFF SOLID BLINK PULSE CHASE WIPE FADE RAINBOW SPARKLE`.
- `BRIGHT <0..255>` sets the brightness for every chain.

The watchdog, `HELLO` and `CFG SAVE` turn every zone off, like coils and lamps, and PinballIO re-sends the wanted effects. See [Lighting](lighting.md) for wiring and light shows.

## A typical session

```
Godot:  HELLO
Board:  HELLO PINIO 0.3 TEENSY41 12345670 - -   # firmware, board type, serial number,
                                          # running + burned fingerprints ("-" = blank board)
Godot:  CFG CLEAR                         # config lines go one at a time,
Board:  ACK CFG CLEAR                     # each waiting for its ACK
Godot:  CFG PWM 20000
Board:  ACK CFG PWM 20000
Godot:  CFG IN 0 33 NO 5                  # input 0 = flipper_left_button
Board:  ACK CFG IN 0
Godot:  CFG IN 1 34 NO 2                  # input 1 = flipper_left_eos
Board:  ACK CFG IN 1
Godot:  CFG IN 2 35 NO 5                  # input 2 = sling_left_switch
Board:  ACK CFG IN 2
Godot:  CFG COIL 0 2 60 50 0 1 0          # coil 0 = flipper_left: trigger in 0, EOS in 1, 50% hold
Board:  ACK CFG COIL 0
Godot:  CFG COIL 1 26 40 0 2 - 150        # coil 1 = sling_left: trigger in 2, no EOS
Board:  ACK CFG COIL 1
Godot:  CFG COIL 2 3 30 0 - - 500         # coil 2 = kickout: Godot-fired only
Board:  ACK CFG COIL 2
Godot:  CFG LAMP 0 27
Board:  ACK CFG LAMP 0
Godot:  CFG CHAIN 0 8 30 GRB              # LED chain 0 = WS2812B strip on pin 8, 30 LEDs
Board:  ACK CFG CHAIN 0
Godot:  CFG ZONE 0 0 0 30                 # zone 0 = playfield (LEDs 0-29)
Board:  ACK CFG ZONE 0
Godot:  CFG ZONE 1 0 0 1                  # zone 1 = shoot_again (LED 0), drawn on top
Board:  ACK CFG ZONE 1
Godot:  CFG DONE
Board:  ACK CFG 3 3 1 1 2 4AC3701E        # 3 inputs, 3 coils, 1 lamp, 1 chain, 2 zones, fingerprint
Board:  SWS 000                           # every input's state, so Godot starts in sync
Godot:  HB                                # every 100 ms from here on
Board:  HB 41213                          # every 1 s from here on
...
Godot:  RULE ALL ON                       # game started: arm flipper and sling
Board:  ACK RULE ALL ON
...                                       # player hits the flipper button
Board:  SW 0 1                            # the board already fired the flipper before sending this
Board:  SW 1 1                            # EOS closed: board has dropped to 50% hold
Board:  SW 1 0
Board:  SW 0 0                            # button released: flipper off
...                                       # ball hits the slingshot
Board:  FIRED 1                           # board already fired the sling coil
Board:  SW 2 1
...
Godot:  PULSE 2                           # kick the ball out (uses the coil's 30 ms)
Board:  ACK PULSE 2 30
Godot:  FX 1 BLINK FF8000 250 000000      # shoot_again: orange / black, 250 ms each
Board:  ACK FX 1 BLINK
...                                       # someone unplugs the board
                                          # (500 ms of silence trips the board's watchdog)
Board:  WD TRIP
                                          # (3 s of silence trips Godot's link-lost detection)
Godot:  (port_unlinked + board_lost fire; PinballIO starts retrying HELLO)
```

Burning the layout, then powering the machine off and on:

```
Godot:  CFG SAVE                          # "Burn to board" (board turns outputs off while writing)
Board:  ACK CFG SAVE 4AC3701E
Godot:  RULE ALL ON                       # PinballIO re-arms what the game wants
Board:  ACK RULE ALL ON
...                                       # power off, power on: the board replays its EEPROM
Godot:  HELLO
Board:  HELLO PINIO 0.3 TEENSY41 12345670 4AC3701E 4AC3701E   # already running the burned layout
Godot:  SWS                               # fingerprint matches Godot's: nothing to send
Board:  SWS 000
```

## Link and watchdog behavior

There are two independent timeouts, one on each side, and they matter for different failure modes:

- **The board's watchdog (500 ms).** If it hears nothing from Godot for 500 ms, it immediately turns off every coil and lamp, disarms every rule, and sends `WD TRIP`. This protects the hardware if Godot crashes, hangs, or the USB cable comes loose: outputs fail to "off", never "stuck on". The config is kept. The next line the board receives clears the trip (`WD OK`), but **outputs stay off**. `PinballIO` remembers which rules and lamps game code wants, and re-sends them by itself after `WD OK` and after every (re)config.
- **Godot's link-lost detection (3 s).** If Godot hears nothing from a board for 3 seconds, it considers the link lost and starts retrying `HELLO` once a second until the board answers. The answer triggers a full re-config.

Why the asymmetry (500 ms vs. 3 s)? The board's watchdog is a hardware-safety mechanism, so it needs to be fast: "outputs stay on for an extra 2.5 seconds" is a real problem for a solenoid. Godot's detection only governs UI and state (showing "link lost", retrying), so there's no hardware risk in waiting longer there.

## Errors you might see

| Reply | Usually means |
|---|---|
| `ERR CFG pin can't be an input on this board` | The config uses a pin that's output-only, reserved, or doesn't exist on this board type. Godot's config check normally catches this first. |
| `ERR CFG hold needs a PWM pin` | A coil has a hold % on one of the pulse-only pins (26, 27, 30, 31, 32 on a Teensy 4.1). |
| `ERR CFG locked, send CFG CLEAR first` | Config lines arrived after `CFG DONE`. Godot always sends `CFG CLEAR` first, so this only happens when typing by hand. |
| `ERR not configured, send CFG first` | A `PULSE`/`RULE`/`LED` arrived before `CFG DONE`. |
| `ERR coil busy` | `PULSE` while the coil is firing, holding, or in its recycle time. |
| `ERR CFG nothing to save, send CFG DONE first` | `CFG SAVE` on a board that isn't running a complete layout. |
| `ERR CFG layout too big to store on this board` | The layout text doesn't fit the board's storage (3 KB on a Teensy 4.1, far more than 24 + 24 + 24 items need). |

## Versioning

The firmware string (`PINIO 0.3`) moves whenever the protocol shape changes. Bump it in the same change that touches `pinio.ino`, `board_link.gd`/`pinball_io.gd`, and the `CLAUDE.md` table, and update `BoardTypes.FIRMWARE` to match. Godot refuses to configure a board that reports a different version, and says so in the diagnostics log.

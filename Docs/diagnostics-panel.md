# Diagnostics panel

`control.tscn` (built entirely in code by `test_panel.gd`, so there's no scene tree to wire up by hand) is the **Diagnostics** tab of the service menu (`config/service_menu.tscn`), next to the **Setup** tab where coils and switches are configured (see [Machine configuration](configuration.md)). The base scene (`main.tscn`) loads the menu on top of whatever mode is running when you press **F1**, and frees it when you press F1 again. Because it's freed on close, its log and fake score reset each time it opens; the serial links themselves live in `PinballIO` and stay up.

Everything machine-specific on it comes from the [machine config](configuration.md): it shows whichever switches, coils and lamps the config defines, by name. It's meant to keep growing into the permanent diagnostics page for the real machine, next to the config page that's coming in the next build-out step.

This page walks through every control and why it's there.

## Connection row

- **Port dropdown + Refresh**: lists the serial ports the OS currently sees. Refresh re-scans (useful if you just plugged a board in).
- **Connect**: opens the selected port through `PinballIO` and starts sending `HELLO`. When the board answers, PinballIO matches it to a board in the config and sends it its `CFG` lines. Several ports can be open at once, one per board.
- **Disconnect all**: closes every open port.
- **Auto-connect at startup** (checkbox): when checked, `PinballIO` remembers the last port a board *actually answered* on (not just "the OS let us open it") and opens it automatically the next time the project starts. It's stored in `user://pinball_settings.cfg`, Godot's per-user data folder outside the project, so it's personal to each machine and never committed.
- **Status label**, from start to finish:
  1. "Port open, waiting for board…"
  2. "Linked on COM9: PINIO 0.2, sending config…"
  3. "Ready: board 'main' configured"

  Or, if something goes wrong: "Problem on COM9 (see log)", "Not linked", or "Watchdog tripped on 'main'".
- **Board HB lamp**: pulses green on each board's `HB <millis>` heartbeat (once a second), and snaps off the moment a link is declared lost. "Linked" only changes on connect/disconnect events, and Godot waits 3 seconds before calling a link lost. The lamp is proof that bytes are arriving *right now*, so a board that has crashed but still shows up as a USB device is obvious at a glance.

## Config line

Shows which config file was loaded (the project default, or your saved `user://` one), how many switches, coils and lamps it has, and how many problems it has. Each problem is written out in the log.

## Score

A placeholder: +10 for any switch closing, +100 (with a flash) when a coil rule fires on a board (`coil_fired`, e.g. a slingshot). These aren't game rules, just something that moves so the link feels alive while testing.

## Switches

One lamp per input in the config, labeled with its name and pin, lit amber while the input is active. It's driven by `PinballIO.switch_changed`, which already has NO/NC applied: "active" means pressed for a normal switch and open for an NC one.

## Coils

For each coil in the config:

- **Pulse <name> (pin N)**: sends `PULSE` for the coil's own `full_ms`. The **Left/Right arrow keys** pulse the first and second coil in the config. There's no keyboard on the real cabinet, so this only exists as a quick way to bench-test from a desktop. It ignores key-repeat and calls `accept_event()`, so holding a key doesn't spam pulses or move UI focus.
- **Rule: <trigger> → <coil>** (only for coils with a trigger input): arms or disarms that coil's rule on the board (`RULE <n> ON/OFF`). It never fires the coil directly; see [Architecture](architecture.md) for why that distinction matters. With the flipper rule armed, holding its button makes the board fire, drop to hold on EOS, and release, all by itself.

**Arm all rules / Disarm all rules** do every coil with a trigger at once. **Ping** measures round-trip time to every linked board.

**Burn layout to board** stores each ready board's current layout in its EEPROM (`CFG SAVE`), so it boots already configured. The board turns its outputs off while writing, and PinballIO re-arms your rules and lamps right after. The status line shows "(burned)" or "(NOT burned)", and the log warns whenever a board is running a layout it would lose at power-off.

## Lamps

One button per lamp. Click to cycle `OFF → ON → BLINK → OFF …`.

## Message log

Every line crossing the link, both directions: lines sent by Godot are gray and start with `>`, lines from the board start with `<`. Heartbeats and pings are left out because they'd drown everything else. You'll see the whole `CFG` exchange each time a board links, plus any `ERR` replies, config problems, and board problems. For example, a board still running old firmware gets: "board runs PINIO 0.1 but this Godot build needs PINIO 0.2: flash Firmware/pinio".

## Why this matters going forward

Everything above uses only `PinballIO`'s and `MachineConfig`'s public signals and functions, never anything lower-level (see the "PinballIO API" section of `CLAUDE.md`). Adding a switch or coil to the config makes it appear here with no code change.

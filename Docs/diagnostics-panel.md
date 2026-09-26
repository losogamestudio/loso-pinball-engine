# Diagnostics panel

`control.tscn` (built entirely in code by `test_panel.gd` — there's no scene tree to wire up by hand) is the project's main scene right now. It started as a way to exercise the serial link during development, and is meant to keep growing into the permanent diagnostics page for the real machine, rather than getting thrown away once the game itself exists.

This page walks through every control and why it's there.

## Connection row

- **Port dropdown + Refresh** — lists whatever serial ports the OS currently sees. Refresh re-scans (useful if you just plugged the Teensy in).
- **Connect / Disconnect** — opens or closes the selected port through `PinballIO`. Connecting immediately sends `HELLO`; the status label reads "Port open, waiting for Teensy…" until the Teensy actually answers.
- **Auto-connect at startup** (checkbox) — when checked, `PinballIO` remembers the last port that *actually linked* (i.e. the Teensy answered `HELLO`, not just "the OS let us open a handle") and tries it again automatically the next time the project starts, before the diagnostics scene has even finished building its UI. This is stored in `user://pinball_settings.cfg` — Godot's per-user data directory, outside the project folder, so it's personal to each machine and never gets committed to the repo.
- **Status label** — "Not connected" / "Port open, waiting for Teensy…" / "Linked: PINIO 0.1" / "Not linked" (link lost) / "Watchdog tripped — outputs off".
- **Teensy HB lamp** — pulses bright green and fades out over the Teensy's own `HB <millis>` heartbeat (once a second while linked), then snaps fully off the instant the link is declared lost. The point of this, separate from the status label: "Linked" only changes on connect/disconnect *events*, and Godot's own link-lost detection has a 3-second grace period. A pulsing lamp gives you real-time proof bytes are still arriving *right now* — a Teensy that's crashed but still enumerated as a USB serial device would show "Linked" with a dead lamp, which is exactly the failure mode you want to be able to spot at a glance.

## Score

A placeholder scoring display: +10 for any switch closing, +100 (with a little flash) when the `SLING_L` hardware rule fires. Not meaningful game rules — just something that moves so the link feels alive while testing.

## Switch lamps

One lamp per practice switch (4 in the current firmware), lit amber while the switch is held closed. Driven directly off `PinballIO.switch_changed`.

## Outputs row

- **Pulse coil 0 (←) / Pulse coil 1 (→)** — sends `PULSE <id> <ms>` for a fixed test duration (40ms / 150ms). The **Left/Right arrow keys** do the exact same thing as clicking these buttons — there is no keyboard on the real cabinet, so this only ever exists as a fast way to bench-test coils from a desktop without reaching for the mouse. See `test_panel.gd`'s `_input()` for the implementation; it ignores key-repeat (`echo`) so holding the key down doesn't spam pulses, and calls `accept_event()` so the arrows don't also shift UI focus around the panel.
- **LED 0 / LED 1 buttons** — click to cycle through `OFF → ON → BLINK → OFF …`, sending `LED <id> <mode>` each time.
- **Sling rule checkbox** — sends `RULE SLING_L ON/OFF`. This *arms or disarms* the rule; it never fires the coil directly (see [Architecture](architecture.md) for why that distinction matters). With the rule armed, closing switch 0 makes the Teensy fire coil 0 on its own and then report `FIRED SLING_L`.
- **Ping** — sends `PING <n>`, logs the round-trip time in milliseconds when `PONG <n>` comes back.

## Analog bar

Shows the last `ANA 0 <value>` reading (0–1023) from a potentiometer on A0, if `USE_ANALOG` is enabled in the firmware and one's actually wired up.

## Message log

Every line crossing the link, except `HB` (both directions) since those would otherwise be the majority of the log and add no information. Useful for seeing `ACK`/`ERR` replies and anything unexpected.

## Why this matters going forward

Everything above is deliberately built against `PinballIO`'s public signals and functions, never anything lower-level — see [Architecture](architecture.md) and the "PinballIO API" section of `CLAUDE.md`. As the real hardware map replaces the practice sketch's four switches and two coils, this panel is where that expands: more switch lamps, named coils instead of "coil 0/1", flipper status, and so on, without needing a rewrite.

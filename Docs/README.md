# Documentation

This folder is the deeper write-up of the whole system. The root [`README.md`](../README.md) is the quick pitch and quick-start; these pages go further.

- **[Architecture](architecture.md)** — the Teensy/Godot split, why it's built this way, the driver hardware.
- **[Machine configuration](configuration.md)** — the one file that says which pin on which board is which switch, coil or lamp, and how each coil's rule behaves.
- **[Serial protocol](serial-protocol.md)** — the wire protocol between the Teensy and Godot, with a walked-through example session.
- **[Getting started](getting-started.md)** — desktop dev setup, from a blank machine to a working link on the bench.
- **[Service menu](service-menu.md)** — the Monitor, Hardware and Audio & Video tabs: what every control does and why it's there.
- **[Audio, music and video](audio-video.md)** — sound effects, the music manager (crossfades, per-mode songs), cutscenes, and getting media files (not in git) onto the Pi.
- **[Deploying to a Raspberry Pi](raspberry-pi.md)** — getting the same project running on the real cabinet hardware, from a fast bench-test path up to a full kiosk setup.

For coding conventions and the terse, authoritative project spec that Claude Code (or any contributor) should treat as ground truth, see [`CLAUDE.md`](../CLAUDE.md) at the repo root. These docs explain the *why* and walk through things step by step; `CLAUDE.md` is the compact reference that has to stay perfectly in sync with the code.

## Status

This is a living set of docs for a project that's still early — expect it to grow alongside the game. Right now it covers the serial link, the configurable I/O (machine config, PINIO 0.2 firmware with its flipper/sling coil rule), the diagnostics panel, and Raspberry Pi deployment. As the config page, multi-board support, the game-state skeleton, and audio/video land, they'll get their own pages or sections here.

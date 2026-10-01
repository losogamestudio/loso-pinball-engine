# Service menu

The service menu (`config/service_menu.tscn`) is how you set up and check the machine. The base scene (`main.tscn`) loads it on top of whatever mode is running when you touch **Service** on the opening screen (or press **P**). It's freed when you touch **Exit** (or press P again), so its log resets each time it opens. The serial links live in `PinballIO` and stay up.

The top bar has **Quit**, which asks first and then returns to the desktop (the only way out of fullscreen without a keyboard), and **Exit ✕**. Below it are three tabs, left to right: **Monitor**, **Hardware**, and **Audio & Video**.

Everything machine-specific comes from the [machine config](configuration.md), so adding a switch or coil makes it show up in every tab with no code change. All three tabs use only the public signals and functions of `PinballIO`, `MachineConfig` and `Media`.

## Monitor

`control.tscn` + `test_panel.gd`, built in code. This is live state at a glance.

### Left third: LEDs

**Link** shows a heartbeat LED and the link status.
- The LED pulses green on each board's `HB` heartbeat (once a second) and goes dark the moment a link is lost. It proves bytes are arriving right now, so a board that crashed but still shows up as a USB device is obvious.
- The status reads, for example, "Ready: 'main' running (burned)", "Problem on COM9 (see log)" or "Watchdog tripped on 'main'".

**I/O** has one LED per item, grouped **Inputs**, **Coils**, **Lamps** and **Lights**. Each group gets its own card per board if there's more than one board. Each LED shows only its **pin number**, so the whole machine fits in a tight cluster. With a mouse, hovering shows the name. The Hardware tab has all the details.

| LED | Lit amber when |
|---|---|
| Input | The switch is active (NO/NC already applied) |
| Coil | A pulse or hold that Godot sent is running, a rule reports `FIRED`, or a flipper is held (rule armed and its button pressed). A **cyan outline** means the coil's rule is armed |
| Lamp | ON, or blinking for BLINK |
| Light | Shows the LED light's current color instead of amber (blinking for BLINK, cycling for RAINBOW). It's numbered with its first LED, since lights have no pin of their own |

Boards don't report their coil outputs, so a coil LED shows what Godot knows. That's close, but it isn't a measurement.

### Right two thirds: the log

Every line crossing the link in both directions:
- Lines sent by Godot are gray and start with `>`. Lines from the board start with `<`. Heartbeats and pings are left out.
- It also shows every `CFG` exchange, any `ERR`, config problems and board problems. For example: "board runs PINIO 0.2 but this Godot build needs PINIO 0.3: flash Firmware/pinio".

**Ping** measures the round trip to every linked board. **Clear** empties the log.

## Hardware

`config/hardware_page.gd`. Boards and wiring, in the order you set a machine up.

- **Connection**:
  - The port dropdown and **Refresh** list the serial ports the OS sees.
  - **Connect** opens a port and starts `HELLO`. When the board answers, PinballIO matches it to a board in the config and sends its layout.
  - **Disconnect all** closes every open port.
  - **Auto-connect at startup** reopens the last port a board actually answered on, saved in `user://pinball_settings.cfg`.
- **Boards**: each board's status. **Burn** stores its layout in EEPROM (`CFG SAVE`) so it boots configured.
- **Coils**:
  - **+ Add coil** opens the coil wizard (see [Machine configuration](configuration.md)).
  - **Arm all** / **Disarm all** do every coil rule at once.
  - Each coil row has **Fire** (a `PULSE` for the coil's full_ms), **Armed** (only for coils with a trigger), **Edit** and **Delete**.
  - **Armed** turns the coil's rule on the board on or off (`RULE <n> ON/OFF`). It never fires the coil itself; see [Architecture](architecture.md). With the flipper armed, holding its button makes the board fire, drop to hold on EOS, and release, all by itself.
  - The **←/→ keys** fire the first two coils (desktop bench testing only).
- **Switches**: a live lamp, name, pin and details for each switch, plus **Edit** (name, pin, NO/NC, debounce, kind, points, sound) and **Delete**.
- **LED chains**: one row per WS2812B strip (data pin, LED count, color order, how many lights), with **+ Add chain**, **Edit** and **Delete**. A chain with lights on it can't be deleted.
- **Lights**: named LED ranges on the chains (an insert is one LED).
  - **Brightness** sets every chain's brightness. It's a power cap too, saved on this machine.
  - Each light row shows its chain, LEDs and current effect. **Test** runs a rainbow (press again for off), and **Edit** opens the light editor, whose **Try it** row runs any effect with any colors on the real LEDs.
  - **All off** turns every light off. See [Lighting](lighting.md).
- **Lamps**: one button per plain on/off lamp output (`CFG LAMP`) that cycles OFF → ON → BLINK.
- **Layout**: **Reset to default layout**, and the path of the layout file in use.

## Audio & Video

`config/av_page.gd`. This machine's screen and sound. It's all saved per machine, not in git.

- **Screen**: **UI scale**, **Text size** (200% by default) and **Fullscreen** (on by default). Saved in `user://display.cfg`. On the 800×480 bench screen, use UI 100% and Text 200%.
- **Audio**: a volume slider each for Master, Music, SFX and Video, saved in `user://audio.cfg`. **Test sound** plays a chime. **Test music** plays loop A, then crossfades to loop B, then fades out.
- **Media**: what's in `assets/` on this machine.
  - The **Music** dropdown with **Play** / **Stop**.
  - The **Video** dropdown with **Play**. It plays full screen on top of the menu, and a tap stops it. Use it for the Pi cutscene test.
  - The **Show** dropdown with **Play** / **Stop**: a light show and its song together.
  - **Light sync** moves light shows later (right) or earlier (left) than the sound, by up to 300 ms, to match this machine.
  - **Rescan** picks up files and shows synced in since startup.

  See [Audio, music and video](audio-video.md) and [Lighting](lighting.md).

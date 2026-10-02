# Lighting: WS2812B LED chains and light shows

Playfield lighting is **WS2812B LED strips** (addressable RGB LEDs), driven by the Teensy. This page covers wiring them, setting them up in the service menu, controlling them from game code, and making **light shows** that run in sync with a song or a video.

**How the work is split** (the same rule as the coils): the **Teensy draws the effects**, about 60 frames a second, so they stay smooth whatever Godot is doing. Godot only sends a short line when a light should change, like "playfield: red chase, 120 ms". It never streams pixels.

## Words used here

| Word | Meaning |
|---|---|
| **Chain** | One strip, or several soldered end to end, on one Teensy output pin. Up to 4 chains of up to 300 LEDs on a Teensy 4.1. |
| **Light** | A named range of LEDs on a chain: a single insert (1 LED), a section, or the whole strip. Up to 96 per board. Game code and shows use the names. |
| **Effect** | What a light shows right now, drawn by the board (table below). |
| **Show** | A timed list of light cues, made on Godot's timeline, that plays along with a song or video. |

Lights may **overlap**. The board draws smaller lights over bigger ones, so an insert inside a "whole playfield" light still shows its own effect. A light set to `OFF` is see-through: whatever is under it shows. To force LEDs dark, use `SOLID` with black.

## Wiring

WS2812B LEDs run on **5 V**, but the Teensy's pins are **3.3 V**:
- **Level shifter:** put a 74AHCT125 (or 74HCT245) between the Teensy pin and the strip's **DIN**, powered from 5 V. Many strips work without one on a short wire, but not reliably.
- **330 Ω resistor** in series with the data line, close to the strip's first LED.
- **1000 µF capacitor** across 5 V and GND where power enters the strip.
- **Common ground:** the Teensy, the level shifter and the LED power supply share GND.
- **Power injection:** feed 5 V into a long strip at both ends (or every ~100 LEDs), not just through the first LED.
- **Power budget:** about **60 mA per LED** at full white. 150 LEDs is 9 A. That's why **brightness defaults to 50%** (Hardware tab → Lights → Brightness). Size the 5 V supply for the brightness you actually use.
- **Data direction:** the strip has arrows. Data goes in at **DIN**, and LED 0 is the one nearest DIN.
- **Which pins:** any output pin on the left header (USB port up) can drive a chain, like a coil. The firmware uses PJRC's OctoWS2811 library (included with Teensyduino), which sends all chains at once by DMA. Drawing LEDs never delays switch scanning or coil timing.

## Setting it up (service menu → Hardware)

1. **LED chains → + Add chain**: pick the data pin, the LED count and the color order. Most WS2812B are **GRB**; if red and green come out swapped, try RGB.
2. **Lights → + Add light**: give it a name (e.g. `shoot_again`), pick the chain, then the first LED and how many LEDs. Use **Try it** to run any effect on the real LEDs before saving.
3. **Test** on a light row runs a rainbow; press it again for off. **All off** turns every light off.
4. **Brightness** applies to every chain and is saved on this machine.
5. Press **Burn** (under Boards) so the Teensy keeps the chains and lights at power-off, just like coils.

The Monitor tab's **Lights** group shows a swatch per light in its current color. The number on each swatch is its first LED.

The shipped default layout has one chain, `led_chain_0`: pin 8, 30 LEDs, GRB. It has two lights: `playfield` (all 30 LEDs) and `shoot_again` (LED 0).

## Effects

`ms` is the effect's speed: its period, or its duration for FADE and WIPE. Colors are any color; "color 2" is the second color some effects use.

| Effect | What it does |
|---|---|
| `OFF` | Nothing; see-through |
| `SOLID` | Color 1 |
| `BLINK` | Color 1 and color 2, `ms` each |
| `PULSE` | Color 1 breathing in and out, one breath every `ms` |
| `CHASE` | Every 3rd LED in color 1 over color 2, moving one step every `ms` |
| `WIPE` | Fills from the first LED to the last with color 1 (over color 2) across `ms`, then holds |
| `FADE` | Fades from the light's previous color to color 1 across `ms`, then holds |
| `RAINBOW` | A rainbow along the light, one full cycle every `ms` |
| `SPARKLE` | Random LEDs flash color 1 over color 2, a new pattern every `ms` |

## From game code

```gdscript
PinballIO.set_light(&"shoot_again", "BLINK", Color.ORANGE, 250)     # orange / black, 250 ms
PinballIO.set_light(&"playfield", "CHASE", Color.CYAN, 80, Color.BLUE)
PinballIO.set_light(&"shoot_again", "OFF")
PinballIO.all_lights_off()
```

Like rules and lamps, PinballIO remembers what each light should show, and sends it again after a board reconnects or after a watchdog trip (which turns every LED off).

## Light shows

A show is a small scene in `assets/shows/`, named like the song or video it goes with:
- **Starts by itself:** `assets/shows/attract.tscn` runs whenever `assets/music/attract.ogg` plays, and stops with it.
- **Plays from the service menu:** Service → **Audio & Video** → **Media** → **Show** → **Play**.
- **From game code:** `Shows.play_show(&"name")`.

Shows sit with the media, so they **sync to the Pi like the media** and aren't committed to the public repo. The exceptions are the template and the demo.

**The demo:** `assets/shows/test/test_loop_a.tscn` goes with the test loop. Play **Test music** on the Audio & Video tab, or pick `test_loop_a` under Show, and the default `playfield` and `shoot_again` lights run a 4-second show that loops with the music.

### Making a show in the Godot editor

A show is an **AnimationPlayer** timeline, much like Unreal's Sequencer. Each key on it calls `cue(...)` with one light's new effect.

1. **Copy the template.** In the FileSystem dock, right-click `assets/shows/_template.tscn` → **Duplicate**. Name it **exactly like the song** without the extension, e.g. `attract.tscn` for `attract.ogg`, and open it.
2. **Add the song so you can see it.** Select the **AnimationPlayer** node; the **Animation** panel opens at the bottom with the `show` animation.
   1. **Add Track → Audio Playback Track** → pick **SongPreview**.
   2. Right-click on that track at 0 s → **Insert Key**.
   3. Drag the song file from the FileSystem dock onto the key (or set its **Stream** in the Inspector). Its waveform now shows on the timeline, and pressing play in the Animation panel plays it.
3. **Set the length.** Set the animation **length** (the box at the top right of the Animation panel, in seconds) to the song's length. Turn **looping** on if the song loops.
4. **Add cues with the Light Show dock** (right side of the editor, under the Inspector; see [below](#the-light-show-dock-live-preview-in-the-editor)).
   1. Move the playhead to the beat.
   2. Each light has a row under **Lights at the playhead**: a swatch, which key it's following (**key at 2.00 s**, **key here**, or **no key yet**), **+** and **✕**, then its **effect**, **color**, **color 2** and **speed** (ms).
   3. **+** adds a new key at the playhead for that light, a copy of the row's settings. Then change the effect, colors or speed in the row: that edits the key. The key goes on the light's own track, which the dock makes the first time.
   4. Changing a row's fields **edits the key the light is following**, even when that key is earlier than the playhead (the row says which). A light with **no key yet** gets one at the playhead. **✕** deletes the key. Ctrl+Z undoes any of it, and dragging a color is one undo step.
   - Move or copy keys on the timeline as usual. Selecting a key there and editing its arguments in the **Inspector** works too.
   - **By hand, without the dock:** **Add Track → Call Method Track** → the **LightShow** root node, one track per light (a track holds one key at each moment, so two lights changing together need two tracks). Right-click the track → **Insert Key** → **`cue`**, then fill in **light**, **effect**, **color**, **ms**, **color2** in the Inspector.
5. **Watch it on the real LEDs** while you work: see the next section.
6. **Pick what it follows.** Select the **LightShow** root node. In the Inspector, **Sync To** is `music` (the song with the same name, the usual case), `video` (a cutscene with the same name), or `none` (its own clock from when it starts).
7. **Save, sync to the Pi, and play it.** Restarting the game with the **Loso Pinball** icon imports it, or tap **Rescan** on the Audio & Video tab. Then play it from the Audio & Video tab or start its song.

The template, the demo, and `media/light_show.gd` all follow this layout. To regenerate them, run `godot --headless --path . -s res://tools/make_show_template.gd`.

### The Light Show dock: live preview in the editor

Godot doesn't call Call Method keys while you preview an animation in the editor, so on its own the timeline can't light anything. Our editor plugin, **Loso Show Tools** (`addons/loso_show_tools/`, enabled in **Project → Project Settings → Plugins**), adds a **Light Show** dock (right side, under the Inspector) that fills the gap. Can't see it? Check the plugin is on in Project Settings → Plugins, or turn it off and on again there; you can drag the dock anywhere. It reads the cue keys itself, works out what every light is doing at the playhead, and:

- **Shows it in the dock:** one row per light with its swatch and its settings, while you play or scrub. Edits in a row show on the LEDs as you make them.
- **Sends it to the running game** with **Send to game** on. The game passes each change to the board, so **the real LEDs follow the playhead**. Dragging the playhead backwards or jumping around sends each light's state at the new spot, so you can step through a show beat by beat.

**Setting it up:**
1. Start the game with the board connected: on this PC (F5 in the editor, Teensy on USB) or on the Pi.
2. In the game: **Service → Audio & Video → Media → Show preview from the editor** on. It's saved, so this is once per machine. The note under it shows this machine's IP address.
3. In the editor's Light Show dock: **Game at** `127.0.0.1` for a game on this PC, or the Pi's IP (or its name, e.g. `loso-pi.local`). Turn **Send to game** on. The dock says **Game answering: N lights** when it's connected.
4. Open your show, pick the `show` animation in the Animation panel, and play or scrub. The song plays from the editor on your PC, and the lights follow on the machine.

**Good to know:**
- The light list in the dock comes from the game (or from this PC's machine config if the game isn't answering). A light the show uses that the game doesn't have is listed in red.
- **Resend** sends every light again (e.g. if the game restarted; the dock also does this by itself when the game comes back).
- Leaving the show, or turning **Send to game** off, turns the lights off.
- It's plain UDP on port 4777 on your local network, and the game only listens while **Show preview** is on. It controls lights only, never coils.
- A running show stops when the editor starts sending, so the two don't fight.

### Keeping it in sync

**How the clock works:**
- The show's clock is the song's **actual playback position**, as heard from the speakers, or the video's position.
- If the Pi stutters, the next cues catch up instead of drifting.
- When the song loops, the cues start over.

**Lining it up by ear:** if the lights run ahead of or behind the music on the real machine, move **Light sync** on the Audio & Video tab (−300…+300 ms). Moving it right makes the lights later. The setting is saved on this machine.

**When a show stops:** it turns off the lights it used, and leaves the others alone.

## Testing without Godot (Serial Monitor)

With the Arduino Serial Monitor (line ending **Newline**) on the Teensy:

```
HELLO
WD OFF
CFG CLEAR
CFG CHAIN 0 8 30 GRB
CFG ZONE 0 0 0 30
CFG ZONE 1 0 0 1
CFG DONE
FX 0 RAINBOW 000000 3000
FX 1 BLINK FF0000 250 000000
BRIGHT 64
FX ALL OFF
```

See [Serial protocol](serial-protocol.md) for the exact commands.

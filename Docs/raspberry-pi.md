# Deploying to a Raspberry Pi

The real cabinet target is a **Raspberry Pi 4 or later**, running 64-bit Raspberry Pi OS (Bookworm or newer). Day-to-day development happens on a desktop; this page is for getting the same project running on the actual hardware, from a blank SD card to a working link with the Teensy, and later a full kiosk setup.

Everything below was walked through on a real Pi 4. Commands are meant to be copied one block at a time.

## 1. Image the SD card

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) on your desktop:

1. **Device:** Raspberry Pi 4.
2. **Operating System:** **Raspberry Pi OS (64-bit)** — the plain one at the top of the list, which includes the desktop.
   - **Not Lite.** Lite has no desktop or graphics stack, so Godot has nothing to draw a window on.
   - **Not 32-bit.** Godot's Linux ARM build is 64-bit only (`arm64`).
   - **Not "Full".** It adds office and education apps you won't use.
3. **Storage:** your SD card (or a USB SSD, which boots and loads faster).

When Imager asks about **OS customisation**, say yes and fill in:

- **Hostname:** e.g. `pinball`, so you can reach it as `pinball.local`.
- **Username and password:** your choice — write them down.
- **Wi-Fi:** your network, plus the country code (Wi-Fi stays off without it).
- **Locale / timezone / keyboard layout.**
- **Services → Enable SSH:** on.

## 2. Connect over the network (SSH)

Give the Pi a minute or two to boot the first time. Then, from PowerShell (Windows) or a terminal (Mac/Linux) on your desktop, using the username you set in Imager:

```sh
ssh yourusername@pinball.local
```

- The first time, it asks whether to trust the Pi's key. Type `yes` (the full word).
- Nothing appears while you type the password — no dots either. That's normal.
- `Permission denied` means the username or password is wrong. `yourusername` above is a placeholder; use your own.
- If `pinball.local` isn't found, use the Pi's IP address instead (check your router's device list, or run `hostname -I` on the Pi).

Optional: VS Code's **Remote - SSH** extension lets you edit files on the Pi as if they were local.

## 3. Set up the Pi (bench-test path)

This is the fastest way to see the project working on real hardware: no export step and no editor, just the engine running the project folder directly. Run all of these in your SSH session.

1. **Update the system** (takes a few minutes the first time):
   ```sh
   sudo apt update && sudo apt full-upgrade -y
   ```

2. **Let your user open serial ports** (takes effect after the reboot in step 6):
   ```sh
   sudo usermod -aG dialout $USER
   ```

3. **Get the project:**
   ```sh
   git clone https://github.com/losogamestudio/loso-pinball-engine.git
   ```

4. **Get Godot** — the **Linux arm64** standard build (not .NET). It must be the same version as on your desktop: the project is on 4.6, and your desktop editor's **Help → About** shows the exact version. Replace `4.6.1` below with yours:
   ```sh
   mkdir -p ~/godot && cd ~/godot
   ```
   ```sh
   wget https://github.com/godotengine/godot/releases/download/4.6.1-stable/Godot_v4.6.1-stable_linux.arm64.zip
   ```
   ```sh
   unzip Godot_v4.6.1-stable_linux.arm64.zip && chmod +x Godot_v4.6.1-stable_linux.arm64
   ```
   If `wget` returns a 404, the version number is wrong — the [releases page](https://github.com/godotengine/godot/releases) lists the exact filenames. No export templates are needed for this path.

5. **Import the project.** The `.godot/` import cache isn't in git, so a fresh clone has none. Let Godot build it now, and you'll see any problems before the first real run. Later, `run.sh` (the **Loso Pinball** icon) does this by itself each time it starts; see "Updating later".
   ```sh
   ~/godot/Godot_v4.6.1-stable_linux.arm64 --headless --import --path ~/loso-pinball-engine
   ```
   Some warnings are normal here. Look for these two lines, which mean the GdSerial plugin loaded on the Pi's ARM CPU:
   ```
   Initialize godot-rust (...)
   GdSerial plugin activated
   ```
   A line saying `gdserial` *failed* to load is not normal.

6. **Reboot** so the `dialout` change takes effect:
   ```sh
   sudo reboot
   ```
   Your SSH session drops. Wait a minute, then `ssh` back in.

7. **Add the desktop icons** (once). From then on you start and update the game by tapping icons, with no typing (see [Desktop icons](#desktop-icons-skip-the-typing)):
   ```sh
   bash ~/loso-pinball-engine/tools/pi/install-desktop-icons.sh
   ```

8. **Plug in the Teensy and run the project.** Tap the **Loso Pinball** icon on the Pi's desktop, or start it from SSH:
   ```sh
   ~/loso-pinball-engine/tools/pi/run.sh
   ```
   - The window appears on the **Pi's own screen**, even when you start it from SSH.
   - The script runs the import, then starts Godot with the Wayland and OpenGL ES flags the Pi needs (see [What the Godot log means](#what-the-godot-log-means)).
   - It starts **fullscreen**, on the attract screen. To get back to the desktop, touch **Service** (bottom-right), then **Quit** (top-right).

9. **Connect the Teensy.** Touch **Service**, open the **Hardware** tab, and under **Connection** pick `/dev/ttyACM0` and click **Connect**. Check **"Auto-connect at startup"** so it reconnects on its own from now on. Then press a switch and **Fire** a coil, and watch the LEDs and log on the **Monitor** tab to confirm the round trip. See [Service menu](service-menu.md) for what everything on screen does.

10. **Check the sound:** plug a speaker into the 3.5 mm jack, then go to Service → **Audio & Video** → **Test sound**. If it's silent, see [Sound](#sound).

The GdSerial plugin already has a `linux-arm64` binary in the repo (`addons/gdserial/bin/linux-arm64/libgdserial.so`, wired up in `gdserial.gdextension`), and the renderer is already set to GL Compatibility in `project.godot`, so there's nothing else to configure.

### Updating later

After pushing changes from your desktop, tap **Update Loso Pinball** on the Pi (it does `git pull` plus the import), then **Loso Pinball**. By hand, over SSH:

```sh
cd ~/loso-pinball-engine && git pull
```
```sh
~/loso-pinball-engine/tools/pi/run.sh
```

**Why the import matters:**
- The Pi runs the project without the editor, so nothing else notices new files. Godot keeps its list of `class_name` scripts (like `IoDefs` or `BoardLink`) and its converted copies of sounds and videos in the `.godot/` cache folder, which isn't in git.
- Without an import after a pull, new scripts fail with a wall of `Could not find type "IoDefs"` / `Identifier "DisplaySettings" not declared` errors. New sounds fail with `Cannot open file 'res://.godot/imported/...sample'`, and play nothing.
- `run.sh` (the **Loso Pinball** icon) runs the import every time it starts, so this can only happen when starting Godot some other way. The fix is always the same:
  ```sh
  ~/godot/Godot_v4.6.1-stable_linux.arm64 --headless --import --path ~/loso-pinball-engine
  ```

If `git pull` complains about local changes you don't care about, discard them first with `git checkout -- .`.

**Media isn't in git.** Sounds, music and video sync from the PC to the Pi's `assets/` folder separately, with Syncthing or `scp`; see [Audio, music and video](audio-video.md#getting-media-from-the-pc-to-the-pi). The only exception is the test media in `assets/**/test/`. Start (or restart) the game with the **Loso Pinball** icon, and new media is imported as it starts.

### Sound

The game plays through whatever output the Pi's desktop has selected. **Godot picks the output once, when it starts**, so after changing speakers, restart the game.

- **3.5 mm jack (simplest)**:
  1. Plug the speaker in and right-click the **speaker icon** in the Pi's taskbar (top-right).
  2. Choose **AV Jack** (it may be called Headphones or Analog). A Pi 4 often defaults to HDMI.
  3. Restart the game.
- **Bluetooth speaker**:
  1. Pair it from the taskbar's Bluetooth icon.
  2. Pick it under the speaker icon **before** starting the game.
  3. If it says connected but is silent, remove the pairing, pair again, and restart the game.
- In the game, check Service → **Audio & Video**: the **Master**, **Music** and **SFX** sliders mustn't be at 0. **Test sound** plays a chime, and **Test music** plays a loop.

**Still silent? Test outside the game, over SSH:**

1. List the sound hardware. **Headphones** is the 3.5 mm jack; `vc4hdmi` are the HDMI ports.
   ```sh
   aplay -l
   ```
2. Play straight to the jack, skipping the Pi's sound system. It should say "Front Left, Front Right". Silence here means the speaker or cable: check its power, volume and AUX input.
   ```sh
   speaker-test -D plughw:Headphones -c 2 -t wav -l 1
   ```
3. Play through the Pi's sound system (PipeWire). The game uses the same path. `paplay` isn't installed on Raspberry Pi OS; `pw-play` is.
   ```sh
   pw-play /usr/share/sounds/alsa/Front_Center.wav
   ```
4. Show where sound goes. Under **Audio → Sinks**, `*` marks the output in use. With the game running, it's listed under **Streams** with the output it plays to (e.g. `bcm2835 Headphones` for the jack).
   ```sh
   wpctl status
   ```
   Make a different sink the default with `wpctl set-default <its number>`, then restart the game.
5. Check the jack's own volume. It should show `[100%]` and `[on]`.
   ```sh
   amixer -c 0
   ```

If all of these work but the game is silent, look for `Cannot open file 'res://.godot/imported/...'` in the game's log. That means the import hasn't run since the media arrived (see above).

### Small screens

Everything is laid out for 1280×720 and scaled to fit the screen, so it works at any resolution. On a small display, such as the 800×480 bench screen, touch **Service**, then on the **Audio & Video** tab keep **UI scale** at 100% with **Text size** 200% (the default). It runs fullscreen by default; its **Screen** section has the Fullscreen box to turn that off. All of these are remembered on the Pi. If the screen is smaller than 1280×720, the window also starts maximized automatically.

### Desktop icons (skip the typing)

`tools/pi/` has scripts that do the above for you. Step 7 installs them; to install them again (for example after moving the project), run this on the Pi, in a terminal or over SSH:

```sh
bash ~/loso-pinball-engine/tools/pi/install-desktop-icons.sh
```

It puts two icons on the desktop, and in the app menu under Games:

- **Loso Pinball** runs `tools/pi/run.sh`: closes any copy of the game that's already running (two copies can't share the Teensy's port), runs the import (a few seconds; it picks up new scripts and media, so a hand `git pull` or synced media just works), then starts the game with the Wayland/OpenGL ES flags.
- **Update Loso Pinball** runs `tools/pi/update.sh`: `git pull` plus the import, in a terminal window so you can read the result. Press Enter to close it.

Both find the newest Godot in `~/godot` by themselves, so they keep working after you upgrade Godot.

The first time you double-click an icon, the desktop may ask what to do: choose **Execute**. To stop it asking, open the File Manager and go to **Edit → Preferences → General → "Don't ask options on launch executable file"**.

### What the Godot log means

A healthy run on a Pi 4 prints something like this. None of it is an error:

| Message | Meaning |
|---|---|
| `OpenGL API OpenGL ES 3.1 Mesa … Using Device: Broadcom - V3D 4.2` | **The line that matters:** Godot is rendering on the Pi's GPU. |
| `X11 Display is not available` → falling back to Wayland | Raspberry Pi OS uses Wayland. Only appears without `--display-driver wayland`. |
| `Can't create an EGL context` → switching to OpenGLES | The Pi's GPU doesn't do desktop OpenGL, so Godot uses OpenGL ES — the expected path. Only appears without `--rendering-driver opengl3_es`. |
| `DRI_PRIME` lines | Harmless multi-GPU noise; the Pi has one GPU. |
| `No plugins found, falling back on no decorations` | The window has no title bar. Doesn't matter; the cabinet runs fullscreen. |
| `FIFO protocol not found! Frame pacing will be degraded` | Animation may be slightly less smooth. Ignore for now; revisit if motion looks juddery once there are real game graphics. |

### The terminal "hangs" while Godot runs

That's normal: the terminal stays attached to Godot until it exits. Quit from the game (Service → **Quit**), or press **Ctrl+C** in that terminal. To keep working meanwhile, either open a second SSH session, or add `&` to the end of the launch command to run it in the background and stop it later with:

```sh
pkill -f Godot_v4
```

### "Device or resource busy" on /dev/ttyACM0

Another copy of the game is still running and holds the Teensy's port. For example, one was started from the desktop icon and another from SSH. `run.sh` (the **Loso Pinball** icon) closes an old copy before it starts. If you started Godot some other way, close every copy with `pkill -f Godot_v4` and start again.

The Arduino IDE's Serial Monitor holds the port the same way, so close it before running the game.

## 4. Seeing the Pi's screen without a monitor

Godot draws on the Pi's own desktop, so with no monitor attached you need a remote view:

- **Raspberry Pi Connect** (easiest; works from anywhere). It's installed but off by default:
  ```sh
  rpi-connect on
  ```
  ```sh
  rpi-connect signin
  ```
  Open the printed link on your desktop, sign in with a (free) Raspberry Pi ID, then use **Screen sharing** at [connect.raspberrypi.com](https://connect.raspberrypi.com). If only **Remote shell** is offered, the Pi's desktop isn't running without a monitor — check with `rpi-connect status`, and either plug a monitor in for a boot or set a headless resolution under `sudo raspi-config` → **Display Options → VNC Resolution**, then reboot.
- **VNC:** `sudo raspi-config` → **Interface Options → VNC → Enable**, then point a VNC viewer on your desktop (RealVNC Viewer, TigerVNC) at `pinball.local`.

**Monitor not showing anything?** The Pi 4 has two micro-HDMI ports — use **HDMI0**, the one next to the USB-C power port. Some monitors are only detected if they're plugged in and switched on before the Pi boots, so reboot with the monitor already on.

## 5. Optional: Claude Code on the Pi

Claude Code runs on 64-bit ARM Linux. Handy when a problem only shows up on the real hardware (reading Godot's log, checking `/dev/ttyACM0`, first-run issues). In your SSH session:

```sh
curl -fsSL https://claude.ai/install.sh | bash
```
```sh
cd ~/loso-pinball-engine && claude
```

Over SSH, the first login prints a URL — open it on your desktop, sign in, and paste the code back. If `claude` isn't found right after installing, open a new SSH session or run `source ~/.bashrc`. A 4 GB or 8 GB Pi 4 is comfortable; 2 GB gets tight with Godot running too (`free -h` shows what you have).

With a copy of the repo on each machine, stick to one rule: commit and push from wherever you made a change, and `git pull` before starting work on the other one.

## Exporting a standalone build (for the actual cabinet)

Once you're past bench-testing and want something that boots straight into the game without a visible editor or terminal:

1. In the Godot editor: **Editor → Manage Export Templates**, install the templates matching your Godot version (one download covers every architecture, arm64 included).
2. **Project → Export… → Add… → Linux**. Set the preset's architecture to `arm64`.
3. Export Project. Check **"Embed PCK"** so you get a single self-contained binary instead of a binary plus a separate `.pck` file.
4. Copy the exported binary to the Pi (or export directly on it) and `chmod +x` it.

## Kiosk setup (fullscreen, boots straight into the game)

- **Fullscreen** is already the default (the Fullscreen box on the Audio & Video tab turns it off). Service → **Quit** gets you back to the desktop.
- **Disable screen blanking** so the display doesn't sleep mid-game: `sudo raspi-config` → **Display Options** → **Screen Blanking** → off.
- **Autostart on boot**: drop a `.desktop` file under `~/.config/autostart/` that starts the game. The simplest one reuses `run.sh`, so it runs from the project folder (no export needed) and imports before starting:

  ```ini
  [Desktop Entry]
  Type=Application
  Name=Loso Pinball Engine
  Exec=/home/yourusername/loso-pinball-engine/tools/pi/run.sh
  ```

  With an exported binary instead, run it with the same display flags: `Exec=/home/yourusername/pinball/loso_pinball_engine.arm64 --display-driver wayland --rendering-driver opengl3_es`.
- **Sound output**: pick the speaker under the taskbar speaker icon once (see [Sound](#sound)). It's remembered across reboots.

## The open risk: video cutscenes

Godot 4's built-in video player only supports **Ogg Theora**, decoded entirely in software — there's no hardware-accelerated video path in core Godot on Linux. That's rarely a problem on a desktop, but a Pi 4's CPU can struggle with it at higher resolutions or framerates.

**Before building out real cutscene content**, encode a representative test clip ([how to make one](audio-video.md#making-videos-davinci-resolve--ogv)), sync it to the Pi's `assets/video/`, and play it with Service → **Audio & Video** → **Media** → **Video** → **Play** on actual Pi 4 hardware. Watch for dropped frames, and check CPU load with `top` over SSH. Don't assume desktop playback performance will carry over — the Pi's CPU is a different order of magnitude from a dev desktop's.

If it's not fast enough, in rough order of effort:
1. Drop resolution, framerate, or bitrate first — Theora's decode cost scales with all three.
2. Use sprite-sheet or `AnimationPlayer`-driven animation instead of true encoded video for short transitions.
3. As a last resort, an external hardware-accelerated player (e.g. GStreamer with V4L2 M2M) composited alongside the Godot window — real added complexity, worth avoiding unless the simpler options genuinely aren't enough.

See also the "Target hardware" section of `CLAUDE.md`, which carries this same constraint as a standing rule for any future changes to this project.

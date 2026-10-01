# Audio, music and video

Everything that makes noise or plays video goes through one autoload, **`Media`** (`media/media.gd`). It's roughly Unreal's audio subsystem plus a media player. Game and mode code ask for media **by name**, the file name without its extension, just as `PinballIO` uses switch names. The files live in `assets/` (see [assets/README.md](../assets/README.md) for the folders and formats).

A name with no file behind it never crashes. `Media` warns once in the log and carries on, so a fresh clone with no media still runs.

## Who decides what plays

The running **mode** decides. The engine only provides the calls.

- **Switch sounds**: each switch can have a **Sound** picked in its switch editor (Hardware tab). It plays when the switch closes during a game.
  - A mode can change it with `Game.set_switch_sound(&"sling_left_switch", &"boing")`.
  - Setting it to `&""` silences the switch; it still scores.
  - `Game.clear_switch_sounds()` goes back to the sounds picked in the switch editors. That happens automatically at the start and end of every game.
- **Game events** play these names if the files exist: `game_start`, `ball_start`, `drain`, `extra_ball`, `game_over`.
- **Music**: each mode screen picks its track when it starts. `modes/attract.gd` plays `attract` and `modes/game_play.gd` plays `game`. Swapping screens crossfades between them.
- **Anything else** is plain calls from mode code: `Media.play_sfx(&"jackpot")`, `Media.play_video(&"wizard_intro")`.
- **Light shows** follow the same naming: a show in `assets/shows/` with the same name as a song or video runs along with it. See [Lighting](lighting.md).

## The Media calls

| Call | What it does |
|---|---|
| `play_sfx(name, volume_db := 0, pitch := 1)` | Sound effect. Up to 16 play at once; after that the oldest is cut off |
| `play_optional_sfx(name)` | Same, but silent when there's no such file (no warning) |
| `play_music(name, fade := 1.0)` | Crossfade to a looping track. The same track again does nothing. A missing track fades out |
| `stop_music(fade)` | Fade out |
| `push_music(name, fade)` / `pop_music(fade)` | A mode plays its own song, then hands the old one back (multiball, wizard mode) |
| `duck_music(level := 0.3, fade)` / `unduck_music(fade)` | Turn the music down for a callout, then back up |
| `play_video(name, duck := true)` / `skip_video()` | Full-screen cutscene over the game, under the service menu. Music fades out while it plays and comes back after |
| `list_sounds()`, `has_sound(name)`, … | What's available (for editors) |
| `rescan()` | Look through `assets/` again |

Signals: `sfx_played(name)`, `music_changed(name)`, `video_started(name)`, and `video_finished(name)`. `video_finished` also fires for a missing video, one frame later, so `await Media.video_finished` never hangs.

**No sound on the Pi?** Godot uses the output selected on the Pi's desktop when the game starts. Pick the 3.5 mm jack (**AV Jack**) or your Bluetooth speaker under the taskbar speaker icon, then restart the game. See [Raspberry Pi: Sound](raspberry-pi.md#sound) for step-by-step checks.

## Volume and buses

Sound goes through audio buses (`default_bus_layout.tres`; open the **Audio** panel at the bottom of the editor): **Master** feeds from **Music**, **SFX** and **Video**. It's the same idea as Unreal sound classes.

The **Audio & Video** tab of the service menu has:
- a slider for each bus, saved per machine in `user://audio.cfg`
- a **Test sound** button
- a **Test music** button: the first press plays loop A, the second crossfades to loop B, the third fades out

## Formats

- **Short sound effects**: `.wav`. They start instantly, with nothing to decode.
- **Longer sounds and music**: `.ogg` or `.mp3`. These are streamed, so a long song doesn't sit in memory.
- **Video**: Godot core only plays **Ogg Theora, `.ogv`**, decoded in software by the Pi's CPU. No editor exports it, so make videos as below. The video keeps its shape: a 16:9 clip on the 5:3 bench screen gets thin black bars instead of being squashed.

## Making videos (DaVinci Resolve → .ogv)

Resolve can't export Theora, so it takes two steps: export a normal high-quality file, then convert it with the free tool ffmpeg.

**1. Resolve project settings** (set before you edit): timeline **1280×720** (the game's layout size), **30 fps**. Lower frame rates are less work for the Pi, and 60 isn't worth it.

**2. Export** on the **Deliver** page with **Custom Export**:

| Setting | Value |
|---|---|
| Format / Codec | MP4 / H.264. QuickTime / DNxHR HQ loses less, but the files are much bigger |
| Resolution / Frame rate | 1280×720, 30 |
| Quality | High, e.g. "Restrict to" about 20,000 Kb/s. This is only an intermediate file |
| Audio | On. AAC for MP4 or Linear PCM for QuickTime, 48 kHz stereo |

Keep these exports **outside** `assets/`, so they don't get synced to the Pi, e.g. `D:\Videos\resolve_exports`.

**3. Convert.** Install ffmpeg once in PowerShell with `winget install Gyan.FFmpeg`, then open a new PowerShell window. `tools/convert_videos.ps1` converts a file, or every video in a folder, into `assets/video/` with Pi-friendly settings. It skips files that are already up to date:

```sh
.\tools\convert_videos.ps1 -Source D:\Videos\resolve_exports
```

The file name becomes the video's name in the game: `intro.mp4` → `assets/video/intro.ogv` → `Media.play_video(&"intro")`. The same thing by hand:

```sh
ffmpeg -i intro.mp4 -vf "scale=-2:720,fps=30" -c:v libtheora -q:v 7 -g 30 -pix_fmt yuv420p -c:a libvorbis -q:a 5 intro.ogv
```

The script's settings:
- `-q:v` / `-Quality`: video quality 0–10. 6–8 is the useful range, and lower means a smaller file that's easier on the Pi.
- `-g 30`: a keyframe every second, so playback and skipping stay smooth.

**4. Test on the Pi before making lots of cutscenes.** Sync the file, restart the game, then go to Service → **Audio & Video** → **Media** → **Video** → **Play**, and watch for stutter. `top` over SSH shows the CPU use. If it struggles, convert at 480 lines. That's close to the 800×480 bench screen anyway, and much less work for the Pi:

```sh
.\tools\convert_videos.ps1 -Source D:\Videos\resolve_exports -Height 480 -Force
```

See also [Raspberry Pi: the open risk](raspberry-pi.md#the-open-risk-video-cutscenes).

## Getting media from the PC to the Pi

The GitHub repo is public and some media is licensed, so **media isn't in git**. `.gitignore` skips everything in `assets/` except its README and the `test/` folders, which hold test sounds we generate ourselves with `tools/make_test_sounds.gd`. The PC is the master copy, and the Pi gets a copy over the local network.

### Syncthing (recommended, automatic)

[Syncthing](https://syncthing.net) is free and open source, and needs no cloud account. It keeps a folder the same on two machines over your network. We set the PC to send only and the Pi to receive only, so the Pi can never change the master copy.

**On the PC** (Windows):

1. Install it with `winget install Syncthing.Syncthing` in PowerShell (or use the installer from syncthing.net), then run `syncthing`. Its control page opens at http://127.0.0.1:8384.
2. In `D:\Dev\Godot\loso-pinball-engine\assets\`, create a text file named `.stignore` containing:
   ```
   // Godot makes its own .import files on each machine
   *.import
   // the test media comes with git
   test
   ```

**On the Pi** (over SSH):

1. Install it and start it, including after a reboot:
   ```sh
   sudo apt install -y syncthing
   ```
   ```sh
   systemctl --user enable --now syncthing
   ```
   ```sh
   sudo loginctl enable-linger $USER
   ```
2. The Pi's control page only listens on the Pi itself. Reach it from the PC through SSH. In a PowerShell window on the PC, run this and leave it open:
   ```sh
   ssh -L 8385:127.0.0.1:8384 yourusername@yourpi.local
   ```
   Then open http://localhost:8385 in the PC's browser. That's the Pi's Syncthing.

**Pair them and share the folder:**

1. In the PC's Syncthing: **Actions → Show ID** and copy it. In the Pi's Syncthing: **Add Remote Device** and paste it. Accept the prompt that appears on the PC.
2. On the PC: **Add Folder**, set the path to `D:\Dev\Godot\loso-pinball-engine\assets`, set **Folder Type** (Advanced tab) to **Send Only**, and share it with the Pi (Sharing tab).
3. On the Pi, accept the folder. Set its path to `/home/yourusername/loso-pinball-engine/assets` and its **Folder Type** to **Receive Only**.

From then on, anything you drop into `assets/` on the PC shows up on the Pi within seconds. Then start (or restart) the game with the **Loso Pinball** icon: it imports new files as it starts.

### scp (no install, by hand)

Windows includes an SSH client, so from PowerShell you can copy folders by hand:

```sh
scp -r D:\Dev\Godot\loso-pinball-engine\assets\music yourusername@yourpi.local:~/loso-pinball-engine/assets/
```

Then start (or restart) the game with the **Loso Pinball** icon: it imports new files as it starts.

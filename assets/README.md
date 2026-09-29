# assets/: game media

Sounds, music and video for the game. Everything here is played by **name**: the file name without its extension. For example, `Media.play_sfx(&"sling")` plays `sfx/sling.wav`, `sfx/sling.ogg` or `sfx/hits/sling.mp3`.

| Folder | What | Formats |
|---|---|---|
| `sfx/` | Sound effects | `.wav` for short hits (plays instantly), `.ogg` / `.mp3` for longer ones |
| `music/` | Music and background loops | `.ogg` or `.mp3` (streamed from disk), `.wav` |
| `video/` | Cutscenes | `.ogv` (Ogg Theora) only. See `Docs/audio-video.md` to convert |

- **Subfolders are fine.** Only the file name counts, so keep names unique within each of the three folders.
- **Optional names the game plays by itself**, if a file with that name exists:
  - Sound effects: `game_start`, `ball_start`, `drain`, `extra_ball`, `game_over`.
  - Music: `attract` on the attract screen, `game` during a game.

## Not in git

This repo is public, and some media is licensed and can't be redistributed. So **everything in this folder is ignored by git**, except:
- this README
- any `test/` folder, which holds the test sounds we generate ourselves with `tools/make_test_sounds.gd`

The media gets from the PC to the Pi with Syncthing (or `scp`). See [Docs/audio-video.md](../Docs/audio-video.md). After new media arrives on the Pi, start (or restart) the game with the **Loso Pinball** icon: it imports new files as it starts.

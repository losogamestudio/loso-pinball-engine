class_name LightShow
extends Node
## LightShow — the root node of a light show scene (assets/shows/<name>.tscn).
##
## A light show is a list of timed light cues, made on Godot's animation
## timeline (like Unreal's Sequencer). The scene looks like this:
##
##   LightShow (this script)
##   ├── AnimationPlayer    with an animation called "show":
##   │                        a Call Method track on the LightShow node, whose
##   │                        keys call cue(...) at the right moments
##   └── SongPreview        an AudioStreamPlayer; put the song on an Audio
##                          track so its waveform shows while you place cues
##
## You never play this scene yourself: the Shows autoload reads the cue keys
## out of it and fires them against the song's (or video's) real playback
## position, so lights stay in sync even if the Pi hiccups. Name the scene
## like the song (assets/shows/attract.tscn goes with assets/music/attract.ogg)
## and it starts by itself whenever that song plays. See Docs/lighting.md.

## What the show follows: "music" (the song with the same name), "video" (the
## cutscene with the same name) or "none" (its own clock, from when it starts).
@export_enum("music", "video", "none") var sync_to: String = "music"


## One light cue. Each Call Method key on the "show" track calls this.
##   light:  a light's name from the Hardware tab, e.g. &"playfield"
##   effect: OFF SOLID BLINK PULSE CHASE WIPE FADE RAINBOW SPARKLE
##   color / color2: the effect's colors
##   ms:     the effect's speed: period, or duration for FADE and WIPE
func cue(light: StringName, effect: String = "SOLID", color: Color = Color.WHITE,
		ms: int = 500, color2: Color = Color.BLACK) -> void:
	# Only runs if someone plays the AnimationPlayer by hand; the Shows autoload
	# reads the keys instead. Either way the board gets the same command.
	PinballIO.set_light(light, effect, color, ms, color2)

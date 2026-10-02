extends SceneTree
## Writes the light show template and the demo show that ship in git:
##     assets/shows/_template.tscn          copy this to start a new show
##     assets/shows/test/test_loop_a.tscn   a demo that runs with the test music loop
##
##     godot --headless --path . -s res://tools/make_show_template.gd
##
## Built with Godot's own API (the same objects the editor makes), so the
## files are valid scenes you can open and edit in the editor afterwards.
##
## test/test_shows.gd builds the demo in memory with demo_scene() instead of
## loading the file, so you can play with the demo in the editor (and save it)
## without breaking the tests. Run this script to put the demo file back.

const LIGHT_SHOW := "res://media/light_show.gd"
const TEMPLATE_PATH := "res://assets/shows/_template.tscn"
const DEMO_PATH := "res://assets/shows/test/test_loop_a.tscn"


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame   # LightShow uses autoload names, which exist once the tree runs
	_save(template_scene(), TEMPLATE_PATH)
	_save(demo_scene(), DEMO_PATH)
	quit()


## Template: one example cue; add the song and your own cues in the editor.
static func template_scene() -> PackedScene:
	return _make_show(4.0, false, [
		[0.0, &"playfield", "SOLID", Color.WHITE, 500, Color.BLACK],
	], null)


## Demo: 4 seconds, matching assets/music/test/test_loop_a (16 notes of 0.25 s), looping with it.
static func demo_scene() -> PackedScene:
	return _make_show(4.0, true, [
		[0.0, &"playfield", "RAINBOW", Color.WHITE, 2000, Color.BLACK],
		[0.0, &"shoot_again", "PULSE", Color.RED, 500, Color.BLACK],
		[1.0, &"playfield", "CHASE", Color.CYAN, 100, Color.BLACK],
		[2.0, &"playfield", "BLINK", Color.MAGENTA, 125, Color.BLACK],
		[2.0, &"shoot_again", "SOLID", Color.WHITE, 500, Color.BLACK],
		[3.0, &"playfield", "WIPE", Color.ORANGE, 900, Color.BLACK],
		[3.5, &"shoot_again", "BLINK", Color.YELLOW, 100, Color.BLACK],
	], load("res://assets/music/test/test_loop_a.wav"))


## A LightShow scene: root + AnimationPlayer ("show" animation with a Call
## Method track of light keys, and an Audio track with the song if given) + SongPreview.
static func _make_show(length: float, loops: bool, cues: Array, song: AudioStream) -> PackedScene:
	var root := Node.new()
	root.name = "LightShow"
	root.set_script(load(LIGHT_SHOW))

	var preview := AudioStreamPlayer.new()
	preview.name = "SongPreview"
	root.add_child(preview)
	preview.owner = root

	var anim := Animation.new()
	anim.length = length
	anim.loop_mode = Animation.LOOP_LINEAR if loops else Animation.LOOP_NONE
	# One Call Method track per light, like one lane per light in Sequencer.
	# (A track holds one key per moment, so two lights changing at the same
	# time need two tracks.) All of them call light() on "." = the LightShow root.
	var tracks := {}   # light name -> track index
	for c: Array in cues:
		var light: StringName = c[1]
		if not tracks.has(light):
			tracks[light] = anim.add_track(Animation.TYPE_METHOD)
			anim.track_set_path(tracks[light], NodePath("."))
		anim.track_insert_key(tracks[light], c[0], {"method": &"light", "args": c.slice(1)})
	if song:
		var audio := anim.add_track(Animation.TYPE_AUDIO)
		anim.track_set_path(audio, NodePath("SongPreview"))
		anim.audio_track_insert_key(audio, 0.0, song)

	var library := AnimationLibrary.new()
	library.add_animation(&"show", anim)
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	player.add_animation_library(&"", library)
	root.add_child(player)
	player.owner = root

	var scene := PackedScene.new()
	scene.pack(root)
	root.free()
	return scene


static func _save(scene: PackedScene, path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := ResourceSaver.save(scene, path)
	print("%s %s" % ["wrote" if err == OK else "FAILED (%d)" % err, path])

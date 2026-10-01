extends Node
## Shows — autoload that plays light shows in sync with music or video.
##
## A show is a scene in assets/shows/ (see media/light_show.gd): timed light
## cues made on Godot's animation timeline. This reads the cues out of the
## scene once, then each frame fires every cue whose time has come, using the
## song's or video's actual playback position as the clock. The board draws
## the effects; Godot only sends the cue lines (PinballIO.set_light).
##
## Shows start by themselves: when Media plays music (or a video) and a show
## has the same name, that show runs along with it, and stops with it. Game
## code can also call play_show(name) directly.
##
## Register under Project Settings > Globals > Autoload as "Shows", below Media.

signal show_started(show_name: StringName)
signal show_finished(show_name: StringName)

const SHOWS_DIR := "res://assets/shows"
const ANIMATION_NAME := &"show"
const CUE_METHOD := &"cue"
const SETTINGS_PATH := "user://audio.cfg"   ## shared with Media's volumes
const MAX_SYNC_OFFSET_MS := 300

## Shift every cue later (positive) or earlier (negative), in ms, to match
## this machine's audio delay. Set on the Audio & Video tab.
var sync_offset_ms := 0

## Tests can replace the clock: a Callable returning seconds (or -1 = paused).
var clock_override := Callable()

var _library := {}   ## show name -> scene path
var _cue_cache := {}  ## show name -> ShowData

var _show: ShowData            ## the show running now, or null
var _show_name: StringName = &""
var _next := 0                 ## index of the next cue to fire
var _last_position := 0.0
var _started_ms := 0           ## for sync_to "none"
var _touched := {}             ## lights this show has set, turned off when it stops
var _warned := {}


## Everything read from one show scene.
class ShowData:
	var sync_to := "music"
	var length := 0.0                  ## the "show" animation's length, seconds
	var loops := false                 ## for sync_to "none": the animation's loop setting
	var cues: Array[Dictionary] = []   ## {time, light, effect, color, ms, color2}, by time


func _ready() -> void:
	rescan()
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	sync_offset_ms = cfg.get_value("lights", "sync_offset_ms", 0)
	Media.music_changed.connect(_on_music_changed)
	Media.video_started.connect(_on_video_started)
	Media.video_finished.connect(_on_video_finished)


# ---------------------------------------------------------------- library

## Look through assets/shows again (after new shows were synced in).
func rescan() -> void:
	_library.clear()
	_cue_cache.clear()
	var found: Dictionary = Media.scan_folder(SHOWS_DIR, ["tscn", "scn"] as Array[String])
	for show_name: StringName in found:
		if not String(show_name).begins_with("_"):   # _template.tscn is not a show
			_library[show_name] = found[show_name]


func list_shows() -> Array[StringName]:
	var names: Array[StringName] = []
	names.assign(_library.keys())
	names.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return names


func has_show(show_name: StringName) -> bool:
	return _library.has(show_name)


func current_show() -> StringName:
	return _show_name


func is_show_playing() -> bool:
	return _show != null


## The cues of a show, read from its scene: [{time, light, effect, color, ms, color2}].
## Empty if the show doesn't exist or has no cues. (Also handy for tests.)
func get_cues(show_name: StringName) -> Array[Dictionary]:
	var data := _load(show_name)
	return data.cues if data else ([] as Array[Dictionary])


# ---------------------------------------------------------------- playing

## Start a show. A show that follows music starts its song too (if a song
## with that name exists and isn't already playing); one that follows a video
## waits for that video to play.
func play_show(show_name: StringName) -> void:
	var data := _load(show_name)
	if data == null:
		return
	stop_show()
	_show = data
	_show_name = show_name
	_next = 0
	_last_position = -1.0
	_started_ms = Time.get_ticks_msec()
	show_started.emit(show_name)
	if data.sync_to == "music" and Media.current_music() != show_name and Media.has_music(show_name):
		Media.play_music(show_name)   # its music_changed comes back here and is ignored


## Stop the running show and turn off the lights it used.
func stop_show() -> void:
	if _show == null:
		return
	var finished := _show_name
	_show = null
	_show_name = &""
	for light_name: StringName in _touched:
		PinballIO.set_light(light_name, "OFF")
	_touched.clear()
	show_finished.emit(finished)


## Change the sync offset (ms) and remember it on this machine.
func set_sync_offset(ms: int) -> void:
	sync_offset_ms = clampi(ms, -MAX_SYNC_OFFSET_MS, MAX_SYNC_OFFSET_MS)
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("lights", "sync_offset_ms", sync_offset_ms)
	cfg.save(SETTINGS_PATH)


func _process(_delta: float) -> void:
	if _show == null:
		return
	var position := _clock()
	if position < 0.0:
		return   # the song or video isn't running (yet): wait
	position -= sync_offset_ms / 1000.0
	if position < _last_position - 0.25:
		_next = 0   # the song looped (or jumped back): start the cues over
	_last_position = position
	while _next < _show.cues.size() and _show.cues[_next]["time"] <= position:
		_fire(_show.cues[_next])
		_next += 1
	if _show.sync_to == "none" and not _show.loops and _next >= _show.cues.size() and position >= _show.length:
		stop_show()


## Seconds into the show, from whatever it follows; -1 = not running.
func _clock() -> float:
	if clock_override.is_valid():
		return clock_override.call()
	match _show.sync_to:
		"music":
			return Media.get_music_position() if Media.current_music() == _show_name else -1.0
		"video":
			return Media.get_video_position() if Media.current_video() == _show_name else -1.0
		_:
			var seconds := (Time.get_ticks_msec() - _started_ms) / 1000.0
			return fmod(seconds, _show.length) if _show.loops and _show.length > 0.0 else seconds


func _fire(cue: Dictionary) -> void:
	var light_name: StringName = cue["light"]
	if MachineConfig.find_light(light_name) == null:
		if not _warned.has(light_name):
			_warned[light_name] = true
			push_warning("Shows: '%s' uses light '%s', which isn't in the machine config; skipping it" % [_show_name, light_name])
		return
	_touched[light_name] = true
	PinballIO.set_light(light_name, cue["effect"], cue["color"], cue["ms"], cue["color2"])


# ---------------------------------------------------------------- automatic start / stop

func _on_music_changed(track_name: StringName) -> void:
	if _show != null and _show.sync_to == "music" and track_name != _show_name:
		stop_show()   # its song stopped or changed
	if track_name != &"" and track_name != _show_name and has_show(track_name):
		var data := _load(track_name)
		if data and data.sync_to == "music":
			play_show(track_name)


func _on_video_started(video_name: StringName) -> void:
	if video_name != _show_name and has_show(video_name):
		var data := _load(video_name)
		if data and data.sync_to == "video":
			play_show(video_name)


func _on_video_finished(video_name: StringName) -> void:
	if _show != null and _show.sync_to == "video" and video_name == _show_name:
		stop_show()


# ---------------------------------------------------------------- reading show scenes

## Read a show's cues out of its scene (once; cached).
func _load(show_name: StringName) -> ShowData:
	if _cue_cache.has(show_name):
		return _cue_cache[show_name]
	if not _library.has(show_name):
		if not _warned.has(show_name):
			_warned[show_name] = true
			push_warning("Shows: no show named '%s' in %s" % [show_name, SHOWS_DIR])
		return null
	var scene := load(_library[show_name]) as PackedScene
	if scene == null:
		push_warning("Shows: couldn't load %s" % _library[show_name])
		return null
	# Make the scene's nodes just long enough to read them: they never join the tree.
	var root := scene.instantiate()
	var data := ShowData.new()
	if "sync_to" in root:
		data.sync_to = root.sync_to
	var player: AnimationPlayer = null
	for child in root.get_children():
		if child is AnimationPlayer:
			player = child
	if player and player.has_animation(ANIMATION_NAME):
		var anim := player.get_animation(ANIMATION_NAME)
		data.length = anim.length
		data.loops = anim.loop_mode != Animation.LOOP_NONE
		_read_cues(anim, data)
	else:
		push_warning("Shows: %s needs an AnimationPlayer with an animation named \"show\"" % _library[show_name])
	root.free()
	_cue_cache[show_name] = data
	return data


## Every cue(...) key on the animation's Call Method tracks, sorted by time.
func _read_cues(anim: Animation, data: ShowData) -> void:
	for track in anim.get_track_count():
		if anim.track_get_type(track) != Animation.TYPE_METHOD or not anim.track_is_enabled(track):
			continue
		for key in anim.track_get_key_count(track):
			if anim.method_track_get_name(track, key) != CUE_METHOD:
				continue
			var args: Array = anim.method_track_get_params(track, key)
			# Fill in anything left out, with the same defaults as LightShow.cue().
			data.cues.append({
				"time": anim.track_get_key_time(track, key),
				"light": StringName(args[0]) if args.size() > 0 else &"",
				"effect": str(args[1]) if args.size() > 1 and str(args[1]) != "" else "SOLID",
				"color": args[2] if args.size() > 2 and args[2] is Color else Color.WHITE,
				"ms": int(args[3]) if args.size() > 3 and int(args[3]) > 0 else 500,
				"color2": args[4] if args.size() > 4 and args[4] is Color else Color.BLACK,
			})
	data.cues.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["time"] < b["time"])

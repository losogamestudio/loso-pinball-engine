extends Node
## Media — autoload for sound effects, music and cutscene video.
##
## Roughly an Unreal audio subsystem plus a media player. Game and mode code
## ask for things by NAME: the file name without its extension, found under
##   res://assets/sfx/     sound effects   (.wav for short hits, .ogg/.mp3)
##   res://assets/music/   music           (.ogg/.mp3, or .wav)
##   res://assets/video/   cutscenes       (.ogv, Ogg Theora: the only video Godot plays)
## Subfolders are fine; the name is still just the file name. Media files are
## not in git (see assets/README.md), so a missing name never crashes: it
## warns once and does nothing.
##
## Mixing goes through audio buses (default_bus_layout.tres, the Audio panel at
## the bottom of the editor): Master -> Music, SFX, Video. Their volumes are set
## on the Audio & Video tab and saved in user://audio.cfg.
##
## Register under Project Settings > Globals > Autoload as "Media", below Game.

signal sfx_played(sound_name: StringName)
signal music_changed(track_name: StringName)   ## &"" = music stopped
signal video_started(video_name: StringName)
signal video_finished(video_name: StringName)  ## also right away for a missing video

const SFX_DIR := "res://assets/sfx"
const MUSIC_DIR := "res://assets/music"
const VIDEO_DIR := "res://assets/video"
const AUDIO_EXTENSIONS: Array[String] = ["wav", "ogg", "mp3"]
const VIDEO_EXTENSIONS: Array[String] = ["ogv"]

const SETTINGS_PATH := "user://audio.cfg"
const BUSES: Array[StringName] = [&"Master", &"Music", &"SFX", &"Video"]

const SFX_VOICES := 16          ## sounds that can play at once
const SILENT := 0.0             ## linear volume for "faded out"
const DUCK_LEVEL := 0.3         ## music level (linear) while ducked for a callout
const VIDEO_LAYER := 5          ## above mode screens (0), below the service menu (10)
const PREVIEW_LAYER := 20       ## a preview from the service menu shows above it

var _sounds := {}   ## name -> path
var _music := {}
var _videos := {}
var _cache := {}    ## path -> loaded resource
var _warned := {}   ## names already warned about

var _sfx_players: Array[AudioStreamPlayer] = []
var _next_voice := 0

var _music_players: Array[AudioStreamPlayer] = []   ## two, for crossfades
var _music_active := 0            ## index of the player carrying the current track
var _music_name: StringName = &""
var _music_level := 1.0           ## 1.0 normally, lower while ducked
var _music_stack: Array[StringName] = []
var _fades := {}                  ## player -> its running Tween

var _video_layer: CanvasLayer
var _video_player: VideoStreamPlayer
var _video_name: StringName = &""
var _video_ducked := false
var _video_preview := false   ## tap to skip


func _ready() -> void:
	rescan()
	_apply_saved_volumes()
	for i in SFX_VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = &"SFX"
		add_child(p)
		_sfx_players.append(p)
	for i in 2:
		var p := AudioStreamPlayer.new()
		p.bus = &"Music"
		p.finished.connect(_on_music_finished.bind(p))
		add_child(p)
		_music_players.append(p)
	_build_video_layer()


# ---------------------------------------------------------------- library

## Look through the asset folders again (after new media was synced in).
func rescan() -> void:
	_sounds = _scan(SFX_DIR, AUDIO_EXTENSIONS)
	_music = _scan(MUSIC_DIR, AUDIO_EXTENSIONS)
	_videos = _scan(VIDEO_DIR, VIDEO_EXTENSIONS)


func list_sounds() -> Array[StringName]:
	return _sorted_names(_sounds)


func list_music() -> Array[StringName]:
	return _sorted_names(_music)


func list_videos() -> Array[StringName]:
	return _sorted_names(_videos)


func has_sound(sound_name: StringName) -> bool:
	return _sounds.has(sound_name)


func has_music(track_name: StringName) -> bool:
	return _music.has(track_name)


func has_video(video_name: StringName) -> bool:
	return _videos.has(video_name)


# ---------------------------------------------------------------- sound effects

## Play a sound effect. Several can play at once (up to SFX_VOICES; after that
## the oldest is cut off). [param volume_db] 0 = as recorded.
func play_sfx(sound_name: StringName, volume_db := 0.0, pitch := 1.0) -> void:
	if sound_name == &"":
		return
	var stream := _load(_sounds, sound_name, "sound", SFX_DIR) as AudioStream
	if stream == null:
		return
	var player := _free_voice()
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = pitch
	player.play()
	sfx_played.emit(sound_name)


## Like play_sfx, but silent (no warning) when there's no such sound. For
## optional sounds, such as the game's event sounds (drain, game_over, ...).
func play_optional_sfx(sound_name: StringName) -> void:
	if has_sound(sound_name):
		play_sfx(sound_name)


# ---------------------------------------------------------------- music

## Switch to [param track], crossfading over [param fade] seconds. Music loops.
## Asking for the track that's already playing does nothing. A missing track
## fades the music out (and warns once).
func play_music(track_name: StringName, fade := 1.0) -> void:
	if track_name == _music_name:
		return
	var stream := _load(_music, track_name, "music", MUSIC_DIR) as AudioStream
	if stream == null:
		stop_music(fade)
		return
	var old := _music_players[_music_active]
	_music_active = 1 - _music_active
	var new := _music_players[_music_active]
	new.stream = stream
	new.volume_db = linear_to_db(SILENT) if fade > 0.0 else linear_to_db(_music_level)
	new.play()
	_fade(new, _music_level, fade)
	_fade(old, SILENT, fade, true)
	_music_name = track_name
	music_changed.emit(track_name)


## Fade the music out and stop it.
func stop_music(fade := 1.0) -> void:
	_fade(_music_players[_music_active], SILENT, fade, true)
	if _music_name != &"":
		_music_name = &""
		music_changed.emit(&"")


## Play [param track] on top of the current music; pop_music() goes back to it.
## For modes: multiball pushes its song, and pops when it ends.
func push_music(track_name: StringName, fade := 1.0) -> void:
	_music_stack.push_back(_music_name)
	play_music(track_name, fade)


## Go back to the music that was playing before the last push_music().
func pop_music(fade := 1.0) -> void:
	if _music_stack.is_empty():
		return
	var previous: StringName = _music_stack.pop_back()
	if previous == &"":
		stop_music(fade)
	else:
		play_music(previous, fade)


## Forget every push (e.g. when a game ends), without changing what's playing.
func clear_music_stack() -> void:
	_music_stack.clear()


func current_music() -> StringName:
	return _music_name


## Turn the music down (for a callout); unduck_music() brings it back.
func duck_music(level := DUCK_LEVEL, fade := 0.3) -> void:
	_music_level = level
	if _music_name != &"":
		_fade(_music_players[_music_active], level, fade)


func unduck_music(fade := 0.5) -> void:
	duck_music(1.0, fade)


# ---------------------------------------------------------------- video

## Play a cutscene full screen, above the game and below the service menu.
## Music fades out while it plays (if [param duck]) and comes back after.
## `video_finished` fires when it ends, is skipped, or doesn't exist.
## [param preview] (the service menu's Play button): show it above the
## service menu too, and let a tap anywhere skip it.
func play_video(video_name: StringName, duck := true, preview := false) -> void:
	if is_video_playing():
		skip_video()
	var stream := _load(_videos, video_name, "video", VIDEO_DIR) as VideoStream
	if stream == null:
		video_finished.emit.call_deferred(video_name)   # deferred, so `await` after this call still catches it
		return
	_video_name = video_name
	_video_ducked = duck
	if duck:
		duck_music(SILENT, 0.5)
	_video_player.stream = stream
	_video_preview = preview
	_video_layer.layer = PREVIEW_LAYER if preview else VIDEO_LAYER
	_video_layer.visible = true
	_video_player.play()
	video_started.emit(video_name)


## End the cutscene now.
func skip_video() -> void:
	if is_video_playing():
		_video_player.stop()
		_on_video_finished()


func is_video_playing() -> bool:
	return _video_name != &""


# ---------------------------------------------------------------- volume

## Volume of a bus (Master, Music, SFX, Video), 0.0..1.0.
func get_volume(bus: StringName) -> float:
	var index := AudioServer.get_bus_index(bus)
	if index == -1 or AudioServer.is_bus_mute(index):
		return 0.0
	return db_to_linear(AudioServer.get_bus_volume_db(index))


## Set a bus volume (0.0..1.0) now and remember it on this machine.
func set_volume(bus: StringName, level: float) -> void:
	_apply_volume(bus, level)
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)   # a missing file just means "all defaults"
	cfg.set_value("volume", String(bus), level)
	cfg.save(SETTINGS_PATH)


# ---------------------------------------------------------------- internals

func _apply_saved_volumes() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	for bus in BUSES:
		_apply_volume(bus, cfg.get_value("volume", String(bus), 1.0))


func _apply_volume(bus: StringName, level: float) -> void:
	var index := AudioServer.get_bus_index(bus)
	if index == -1:
		push_warning("Media: no audio bus '%s' (check default_bus_layout.tres)" % bus)
		return
	AudioServer.set_bus_mute(index, level <= 0.0)
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(level, 0.0001)))


## Every file under [param dir] with one of [param extensions]: name -> path.
func _scan(dir: String, extensions: Array[String]) -> Dictionary:
	var found := {}
	if not DirAccess.dir_exists_absolute(dir):
		return found
	# ResourceLoader.list_directory lists resources the same way in the editor,
	# in an unexported project (the Pi) and in an export.
	for entry in ResourceLoader.list_directory(dir):
		if entry.ends_with("/"):   # a subfolder: its files count as if they were here
			var sub := _scan(dir.path_join(entry.trim_suffix("/")), extensions)
			for item: StringName in sub:
				_add_found(found, item, sub[item])
		elif entry.get_extension().to_lower() in extensions:
			_add_found(found, StringName(entry.get_basename()), dir.path_join(entry))
	return found


func _add_found(found: Dictionary, item: StringName, path: String) -> void:
	if found.has(item):
		push_warning("Media: two files named '%s' (%s and %s); using the first" % [item, found[item], path])
	else:
		found[item] = path


func _sorted_names(library: Dictionary) -> Array[StringName]:
	var names: Array[StringName] = []
	names.assign(library.keys())
	names.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return names


func _load(library: Dictionary, item: StringName, what: String, dir: String) -> Resource:
	if not library.has(item):
		if not _warned.has(item):
			_warned[item] = true
			push_warning("Media: no %s named '%s' in %s (media files sync separately; see assets/README.md)" % [what, item, dir])
		return null
	var path: String = library[item]
	if not _cache.has(path):
		_cache[path] = load(path)
	return _cache[path]


## The first player that isn't busy, or else the next one round-robin (the oldest).
func _free_voice() -> AudioStreamPlayer:
	for i in SFX_VOICES:
		var p := _sfx_players[(_next_voice + i) % SFX_VOICES]
		if not p.playing:
			_next_voice = (_next_voice + i + 1) % SFX_VOICES
			return p
	var oldest := _sfx_players[_next_voice]
	_next_voice = (_next_voice + 1) % SFX_VOICES
	return oldest


## Fade a music player to [param level] (linear) over [param seconds], then
## stop it if [param stop_after]. Fades are linear in loudness, not in dB,
## which sounds even to the ear.
func _fade(player: AudioStreamPlayer, level: float, seconds: float, stop_after := false) -> void:
	var running: Tween = _fades.get(player)
	if running and running.is_valid():
		running.kill()
	_fades.erase(player)
	if seconds <= 0.0:
		player.volume_db = linear_to_db(maxf(level, 0.0001))
		if stop_after:
			player.stop()
		return
	var tween := create_tween()
	var from := db_to_linear(player.volume_db)
	tween.tween_method(func(v: float) -> void: player.volume_db = linear_to_db(maxf(v, 0.0001)), from, level, seconds)
	if stop_after:
		tween.tween_callback(player.stop)
	_fades[player] = tween


## Music loops by starting again when it ends. That works for every format
## without changing each file's import settings.
func _on_music_finished(player: AudioStreamPlayer) -> void:
	if player == _music_players[_music_active] and _music_name != &"":
		player.play()


func _build_video_layer() -> void:
	_video_layer = CanvasLayer.new()
	_video_layer.layer = VIDEO_LAYER
	_video_layer.visible = false
	add_child(_video_layer)
	var backdrop := ColorRect.new()
	backdrop.color = Color.BLACK
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP   # the game underneath gets no taps during a cutscene
	backdrop.gui_input.connect(_on_video_tapped)
	_video_layer.add_child(backdrop)
	_video_player = VideoStreamPlayer.new()
	_video_player.set_anchors_preset(Control.PRESET_FULL_RECT)
	_video_player.mouse_filter = Control.MOUSE_FILTER_IGNORE   # taps go to the backdrop
	_video_player.expand = true
	_video_player.bus = &"Video"
	_video_player.finished.connect(_on_video_finished)
	_video_layer.add_child(_video_player)


func _on_video_tapped(event: InputEvent) -> void:
	if _video_preview and event is InputEventMouseButton and event.pressed:
		skip_video()


func _on_video_finished() -> void:
	var finished_name := _video_name
	_video_name = &""
	_video_layer.visible = false
	_video_player.stream = null
	if _video_ducked:
		_video_ducked = false
		unduck_music()
	video_finished.emit(finished_name)

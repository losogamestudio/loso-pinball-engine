extends SceneTree
## Headless check of the Media autoload and the game's switch sounds, using
## the generated test media in git (assets/**/test/).
##
##     godot --headless --path . -s res://test/test_media.gd
##
## Headless Godot uses a dummy audio driver: nothing is heard, but players,
## fades and signals all run. Never writes user:// (volumes aren't changed).

var _failures := 0
var _config: Node
var _io: Node
var _game: Node
var _media: Node
var _played: Array[StringName] = []


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	_config = root.get_node("MachineConfig")
	_io = root.get_node("PinballIO")
	_game = root.get_node("Game")
	_media = root.get_node("Media")
	_media.sfx_played.connect(func(n: StringName) -> void: _played.append(n))
	var saved_layout: Dictionary = _config.snapshot()

	_test_library()
	_test_switch_sounds()
	await _test_music()
	await _test_missing_video()

	_config.restore(saved_layout, false)
	print("\n%s" % ("ALL PASSED" if _failures == 0 else "%d FAILURE(S)" % _failures))
	quit(1 if _failures > 0 else 0)


func _check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		_failures += 1


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _test_library() -> void:
	_check(_media.has_sound(&"test_beep") and _media.has_sound(&"test_chime") and _media.has_sound(&"test_buzz"),
			"test sounds found by name (subfolder assets/sfx/test)")
	_check(_media.has_music(&"test_loop_a") and _media.has_music(&"test_loop_b"), "test music loops found")
	for bus: StringName in [&"Master", &"Music", &"SFX", &"Video"]:
		_check(AudioServer.get_bus_index(bus) != -1, "audio bus %s exists" % bus)
	_played.clear()
	_media.play_sfx(&"no_such_sound")
	_check(_played.is_empty(), "a missing sound is skipped (warning only)")
	_media.play_sfx(&"test_beep")
	_check(_played == [&"test_beep"], "play_sfx plays a sound")
	for i in 20:
		_media.play_sfx(&"test_beep")
	_check(_played.size() == 21, "more sounds than voices at once still play (oldest reused)")


func _test_switch_sounds() -> void:
	_config.restore({"boards": [{"id": "main", "type": "TEENSY41"}], "coils": [], "lamps": [], "inputs": [
		{"name": "target_a", "board": "main", "pin": 33, "kind": "target", "points": 100, "sound": "test_beep"},
		{"name": "plain", "board": "main", "pin": 34},
	]}, false)
	_played.clear()
	_io.switch_changed.emit(&"target_a", true)
	_check(_played.is_empty(), "no switch sound while no game is running")
	_game.start_game()
	_played.clear()
	_io.switch_changed.emit(&"target_a", true)
	_io.switch_changed.emit(&"target_a", false)
	_io.switch_changed.emit(&"plain", true)
	_check(_played == [&"test_beep"], "switch sound plays on close only; a switch with no sound is quiet: %s" % [_played])
	_game.set_switch_sound(&"target_a", &"test_chime")
	_game.set_switch_sound(&"plain", &"test_buzz")
	_played.clear()
	_io.switch_changed.emit(&"target_a", true)
	_io.switch_changed.emit(&"plain", true)
	_check(_played == [&"test_chime", &"test_buzz"], "a mode can change switch sounds")
	_game.set_switch_sound(&"target_a", &"")
	_played.clear()
	_io.switch_changed.emit(&"target_a", true)
	_check(_played.is_empty() and _game.score == 300, "a mode can silence a switch (it still scores)")
	_game.abort_game()
	_check(_game.get_switch_sound(&"target_a") == &"test_beep", "game end goes back to the Setup sounds")


func _test_music() -> void:
	var players: Array = _media._music_players
	_media.play_music(&"test_loop_a", 0.2)
	_check(_media.current_music() == &"test_loop_a", "play_music starts track A")
	await _wait(0.4)
	_media.play_music(&"test_loop_b", 0.2)
	await _wait(0.4)
	var playing: Array = players.filter(func(p: AudioStreamPlayer) -> bool: return p.playing)
	_check(playing.size() == 1 and (playing[0] as AudioStreamPlayer).stream.resource_path.ends_with("test_loop_b.wav"),
			"after the crossfade only track B is playing")
	_media.push_music(&"test_loop_a", 0.1)
	_check(_media.current_music() == &"test_loop_a", "push_music plays the mode's track")
	_media.pop_music(0.1)
	_check(_media.current_music() == &"test_loop_b", "pop_music goes back to the previous track")
	_media.play_music(&"no_such_song", 0.1)
	await _wait(0.3)
	_check(_media.current_music() == &"" and players.all(func(p: AudioStreamPlayer) -> bool: return not p.playing),
			"a missing track fades the music out")


func _test_missing_video() -> void:
	var finished := []
	_media.video_finished.connect(func(n: StringName) -> void: finished.append(n), CONNECT_ONE_SHOT)
	_media.play_video(&"no_such_video")
	_check(finished.is_empty(), "video_finished for a missing video waits a frame (so await still catches it)")
	await process_frame
	await process_frame
	_check(finished == [&"no_such_video"] and not _media.is_video_playing(), "a missing video finishes right away")

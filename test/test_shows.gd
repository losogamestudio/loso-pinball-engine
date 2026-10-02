extends SceneTree
## Headless check of LED lights through PinballIO and of light shows, using a
## fake board and the demo show (assets/shows/test/test_loop_a.tscn), built in
## memory from tools/make_show_template.gd, so edits saved to the demo file in
## the editor don't change what's tested.
##
##     godot --headless --path . -s res://test/test_shows.gd
##
## Uses the shipped default layout in memory; never writes user://.

var _failures := 0
var _config: Node
var _io: Node
var _media: Node
var _shows: Node
var _clock := -1.0   ## the fake song position the show follows
var _demo: PackedScene   ## the generated demo show, standing in for the file (kept referenced)

const TEST_PREVIEW_PORT := 47770   ## the show-preview test's port, away from a running game's 4777


## A PINIO 0.4 board, just enough for lights, servos and coils: answers HELLO, ACKs config and commands.
class FakeBoard:
	var link: BoardLink
	var received: PackedStringArray = []
	var layout: PackedStringArray = []
	var counts := {"IN": 0, "COIL": 0, "LAMP": 0, "CHAIN": 0, "ZONE": 0, "PCA": 0, "SERVO": 0}

	func handle(line: String) -> void:
		received.append(line)
		var parts := line.split(" ")
		match parts[0]:
			"HELLO":
				reply("HELLO PINIO 0.4 TEENSY41 12345670 - -")
			"CFG":
				if parts[1] == "CLEAR":
					layout.clear()
					for key: String in counts:
						counts[key] = 0
					reply("ACK CFG CLEAR")
				elif parts[1] == "DONE":
					reply("ACK CFG %d %d %d %d %d %d %s" % [counts["IN"], counts["COIL"], counts["LAMP"],
							counts["CHAIN"], counts["ZONE"], counts["SERVO"], load("res://config/machine_config.gd").layout_hash(layout)])
					reply("SWS " + "0".repeat(counts["IN"]))
				else:
					counts[parts[1]] = counts.get(parts[1], 0) + 1
					layout.append(line)
					reply("ACK " + line)
			"HB":
				pass
			_:
				reply("ACK " + line)

	func reply(line: String) -> void:
		link.feed((line + "\n").to_utf8_buffer())



func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	_config = root.get_node("MachineConfig")
	_io = root.get_node("PinballIO")
	_media = root.get_node("Media")
	_shows = root.get_node("Shows")
	var saved_layout: Dictionary = _config.snapshot()
	var default_data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/machine_config.default.json"))
	# Plus two servos (the shipped layout has none): one on a pin, one on a PCA9685.
	default_data["servos"] = [
		{"name": "gate", "board": "main", "pin": 5, "min_us": 1000, "max_us": 2000, "home": 0.5},
		{"name": "head", "board": "main", "pca_addr": 0x40, "channel": 0, "min_us": 600, "max_us": 2400, "home": 0.0},
	]
	_config.restore(default_data, false)
	# The demo as generated, in place of whatever is saved in the file: taking
	# over its path puts it in Godot's resource cache, so load() of that path
	# (as Shows does) returns this one. Nothing is written to disk.
	_demo = load("res://tools/make_show_template.gd").demo_scene()
	_demo.take_over_path(load("res://tools/make_show_template.gd").DEMO_PATH)
	_shows.rescan()
	var saved_offset: int = _shows.sync_offset_ms
	_shows.sync_offset_ms = 0   # this machine's Light sync setting would shift every clock below (not saved)

	var board := _test_lights_on_board()
	_test_servos_and_coil_power(board)
	await _test_show_cues_and_clock(board)
	await _test_show_follows_music()
	_test_show_cues_helpers()
	await _test_servo_and_coil_cues(board)
	await _test_editor_preview(board)

	_io.close_port()
	board.link = null   # the fake board and its link point at each other; let them go
	_config.restore(saved_layout, false)
	_shows.sync_offset_ms = saved_offset
	print("\n%s" % ("ALL PASSED" if _failures == 0 else "%d FAILURE(S)" % _failures))
	quit(1 if _failures > 0 else 0)


func _check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		_failures += 1


func _frames(n := 2) -> void:
	for i in n:
		await process_frame


func _test_lights_on_board() -> FakeBoard:
	var board := FakeBoard.new()
	var link := BoardLink.new("FAKE", board.handle)
	board.link = link
	_io.remember_port = false   # don't save "FAKE" as this machine's board port
	_io._attach_link(link)   # HELLO -> config -> ready, all synchronous with the fake
	_check(_io.get_port_for_board(&"main") == "FAKE", "fake board linked and configured")
	_check(board.received.has("CFG CHAIN 0 8 30 GRB") and board.received.has("CFG ZONE 1 0 0 1"),
			"board got the LED chain and zones")

	board.received.clear()
	_io.set_light(&"playfield", "RAINBOW", Color.WHITE, 2000)
	_io.set_light(&"shoot_again", "BLINK", Color(1, 0.5, 0), 250, Color.BLUE)
	_check(board.received == PackedStringArray(["FX 0 RAINBOW FFFFFF 2000 000000", "FX 1 BLINK FF8000 250 0000FF"]),
			"set_light sends FX lines by zone number: %s" % [board.received])
	_check(_io.get_light(&"shoot_again")["effect"] == "BLINK", "get_light remembers the wanted effect")

	board.received.clear()
	board.reply("WD TRIP")
	board.reply("WD OK")
	_check(board.received.has("BRIGHT 128") and board.received.has("FX 0 RAINBOW FFFFFF 2000 000000"),
			"after a watchdog trip, brightness and lights are sent again: %s" % [board.received])

	_io.all_lights_off()
	_check(_io.get_light(&"playfield")["effect"] == "OFF" and _io.get_light(&"shoot_again")["effect"] == "OFF",
			"all_lights_off turns every light off")
	return board


func _test_servos_and_coil_power(board: FakeBoard) -> void:
	_check(board.layout.has("CFG PCA 0 40") and board.layout.has("CFG SERVO 0 5 1000 2000 500")
			and board.layout.has("CFG SERVO 1 P0:0 600 2400 0"), "board got the PCA and servo lines")
	board.received.clear()
	_io.set_servo(&"gate", 0.75, 400, "SMOOTH")
	_check(board.received == PackedStringArray(["SERVO 0 750 400 SMOOTH"]), "set_servo sends a SERVO line: %s" % [board.received])
	_check(_io.is_servo_moving(&"gate") and is_equal_approx(_io.get_servo(&"gate")["position"], 0.75),
			"PinballIO remembers the move and knows it's running")
	_check(_io.get_servo(&"head")["position"] == 0.0, "a servo that was never moved reports its home")
	board.received.clear()
	board.reply("WD TRIP")
	board.reply("WD OK")
	_check(board.received.has("SERVO 0 750 500 SMOOTH"), "after a watchdog trip the servo eases back where it was wanted: %s" % [board.received])
	board.received.clear()
	_io.pulse_coil(&"kickout", 20, 40)
	_io.pulse_coil(&"kickout")
	_check(board.received == PackedStringArray(["PULSE 2 20 40", "PULSE 2"]), "pulse_coil with power sends PULSE n ms power: %s" % [board.received])


func _test_show_cues_and_clock(board: FakeBoard) -> void:
	_check(_shows.list_shows().has(&"test_loop_a") and not _shows.list_shows().has(&"_template"),
			"demo show found; the template isn't listed as a show")
	var cues: Array[Dictionary] = _shows.get_cues(&"test_loop_a")
	var times := cues.map(func(c: Dictionary) -> float: return c["time"])
	_check(cues.size() == 7 and times == [0.0, 0.0, 1.0, 2.0, 2.0, 3.0, 3.5],
			"7 cues read from the timeline, sorted by time: %s" % [times])

	_shows.clock_override = func() -> float: return _clock
	_shows.play_show(&"test_loop_a")
	board.received.clear()
	_clock = 0.1
	await _frames()
	_check(_io.get_light(&"playfield")["effect"] == "RAINBOW" and _io.get_light(&"shoot_again")["effect"] == "PULSE",
			"cues at 0 s fire once the clock passes them")
	_clock = 2.1
	await _frames()
	_check(_io.get_light(&"playfield")["effect"] == "BLINK" and _io.get_light(&"shoot_again")["effect"] == "SOLID",
			"cues up to 2 s fired in order (CHASE then BLINK)")
	_check(board.received.has("FX 0 CHASE 00FFFF 100 000000"), "cues reach the board as FX lines")
	_clock = 0.05   # the song looped
	await _frames()
	_check(_io.get_light(&"playfield")["effect"] == "RAINBOW", "a loop starts the cues over")
	_shows.stop_show()
	_check(not _shows.is_show_playing() and _io.get_light(&"playfield")["effect"] == "OFF",
			"stop_show turns off the lights the show used")
	_shows.clock_override = Callable()
	_check(_media.current_music() == &"test_loop_a", "play_show started the show's song too")
	_media.stop_music(0.0)
	await _frames()


func _test_show_follows_music() -> void:
	_media.play_music(&"test_loop_a", 0.0)
	await _frames()
	_check(_shows.current_show() == &"test_loop_a", "playing a song starts the show with the same name")
	_media.play_music(&"test_loop_b", 0.0)
	await _frames()
	_check(not _shows.is_show_playing(), "changing the song stops its show")
	_media.stop_music(0.0)


func _test_show_cues_helpers() -> void:
	var cues: Array[Dictionary] = _shows.get_cues(&"test_loop_a")
	var state := ShowCues.state_at(cues, 2.0)
	_check(state[&"playfield"]["effect"] == "BLINK" and state[&"shoot_again"]["effect"] == "SOLID",
			"state_at gives each light's latest cue (a cue exactly at the playhead counts)")
	_check(not ShowCues.state_at(cues, -1.0).has(&"playfield"), "before the first cue a light has no state (off)")
	var line := ShowCues.fx_line(&"playfield", state[&"playfield"])
	_check(line == "FX playfield BLINK FF00FF 125 000000", "fx_line: %s" % line)
	var fx := ShowCues.parse_fx(line)
	_check(fx["light"] == &"playfield" and fx["ms"] == 125 and fx["color"] == Color(1, 0, 1), "parse_fx reads it back")
	_check(ShowCues.parse_fx("FX playfield BLINK nothex 125 000000").is_empty(), "parse_fx rejects a bad line")


## The editor's Light Show dock, run outside the editor, talking to Shows over
## real UDP on this computer: scrubbing the timeline drives PinballIO's lights.
func _test_editor_preview(board: FakeBoard) -> void:
	_shows.preview_port = TEST_PREVIEW_PORT   # not the real one: a running game may hold it
	_shows.set_preview_listening(true, false)   # false: don't save it in user://
	_check(_shows.preview_listening, "game listens for the show preview on UDP %d" % _shows.preview_port)

	var show_scene: Node = _demo.instantiate()
	var player: AnimationPlayer = show_scene.get_node("AnimationPlayer")
	# Outside the editor a playing player would call cue() itself; we only want its playhead.
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	root.add_child(show_scene)
	player.assigned_animation = &"show"
	player.seek(2.1, false)

	var dock: Node = load("res://addons/loso_show_tools/show_dock.gd").new()
	root.add_child(dock)
	dock.port = TEST_PREVIEW_PORT
	dock.set_show(show_scene)
	dock.set_host("127.0.0.1")
	dock.set_live(true)
	_check(is_equal_approx(dock.playhead(), 2.1), "dock reads the playhead: %.2f" % dock.playhead())
	await _until(func() -> bool: return _io.get_light(&"playfield")["effect"] == "BLINK", 120)
	_check(_io.get_light(&"playfield")["effect"] == "BLINK" and _io.get_light(&"shoot_again")["effect"] == "SOLID",
			"lights follow the playhead at 2.1 s over UDP")
	_check(dock._game_list(ShowCues.TYPE_LIGHT) == PackedStringArray(["playfield", "shoot_again"])
			and dock._game_list(ShowCues.TYPE_SERVO) == PackedStringArray(["gate", "head"])
			and dock._game_list(ShowCues.TYPE_COIL).has("kickout"),
			"the game told the dock its lights, servos and coils: %s" % [dock._game_names])
	_check(_shows.is_previewing(), "the game knows it's being previewed (%s)" % _shows.preview_peer)

	player.seek(0.5, false)   # scrub back
	await _until(func() -> bool: return _io.get_light(&"playfield")["effect"] == "RAINBOW", 120)
	_check(is_equal_approx(dock.playhead(), 0.5), "dock follows the scrub: %.2f" % dock.playhead())
	_check(_io.get_light(&"playfield")["effect"] == "RAINBOW" and _io.get_light(&"shoot_again")["effect"] == "PULSE",
			"scrubbing back sends the state at the new playhead")

	# Add cues. This changes the loaded demo show in memory only (never saved).
	var anim := player.get_animation(&"show")
	var tracks_before := anim.get_track_count()
	dock.add_cue(1.5, &"shoot_again", "FADE", Color.RED, 300, Color.BLACK)
	var track := ShowCues.track_for_light(anim, &"shoot_again")
	_check(anim.get_track_count() == tracks_before and anim.track_get_key_count(track) == 4,
			"a cue for a light with a track goes on that track")
	dock.add_cue(1.5, &"shoot_again", "SOLID", Color.GREEN, 300, Color.BLACK)
	_check(anim.track_get_key_count(track) == 4 and anim.method_track_get_params(track, 1)[1] == "SOLID",
			"a cue at the same moment replaces the old one")
	dock.add_cue(0.25, &"new_light", "BLINK", Color.BLUE, 100, Color.BLACK)
	var new_track := ShowCues.track_for_light(anim, &"new_light")
	_check(anim.get_track_count() == tracks_before + 1 and new_track == tracks_before
			and anim.track_get_path(new_track) == NodePath("."),
			"a cue for a new light makes its own Call Method track on the show node")
	var cues := ShowCues.read(anim)
	_check(cues.size() == 9 and cues.any(func(c: Dictionary) -> bool: return c["light"] == &"new_light"),
			"the dock reads the new cues back (%d cues)" % cues.size())

	# Edit the key a light follows at the playhead (the light rows' fields).
	player.seek(2.5, false)   # playfield follows its BLINK key at 2.0 s
	await _frames()
	var pf_track := ShowCues.track_for_light(anim, &"playfield")
	var keys_before := anim.track_get_key_count(pf_track)
	dock.edit_at_playhead(&"playfield", "PULSE", Color.GREEN, 700, Color.BLACK)
	var edited: Array = anim.method_track_get_params(pf_track, anim.track_find_key(pf_track, 2.0, Animation.FIND_MODE_APPROX))
	_check(anim.track_get_key_count(pf_track) == keys_before and edited[1] == "PULSE" and edited[3] == 700,
			"editing at 2.5 s changes the 2.0 s key in place: %s" % [edited])
	await _until(func() -> bool: return _io.get_light(&"playfield")["effect"] == "PULSE", 120)
	_check(_io.get_light(&"playfield")["effect"] == "PULSE", "the edit reaches the game's lights right away")
	dock.delete_at_playhead(&"playfield")
	_check(anim.track_get_key_count(pf_track) == keys_before - 1 and anim.track_find_key(pf_track, 2.0, Animation.FIND_MODE_APPROX) < 0,
			"delete removes the key the light follows")
	player.seek(0.1, false)   # new_light's first key is at 0.25 s: nothing yet
	await _frames()
	dock.edit_at_playhead(&"new_light", "OFF", Color.RED, 500, Color.BLACK)
	var nl_track := ShowCues.track_for_light(anim, &"new_light")
	var made: Array = anim.method_track_get_params(nl_track, anim.track_find_key(nl_track, 0.1, Animation.FIND_MODE_APPROX))
	_check(made[1] == "SOLID" and made[2] == Color.RED,
			"editing a light with no key yet adds one at the playhead (SOLID, not OFF): %s" % [made])

	# Key all: a key on every light at the playhead, same settings, nothing changes yet.
	player.seek(2.75, false)
	await _frames()
	var before := ShowCues.state_at(ShowCues.read(anim), 2.75)
	var count_before := ShowCues.read(anim).size()
	dock.key_all_at_playhead()
	var after := ShowCues.state_at(ShowCues.read(anim), 2.75)
	var same := after.size() == before.size()
	for light: StringName in before:
		same = same and is_equal_approx(after[light]["time"], 2.75) and after[light]["effect"] == before[light]["effect"] \
				and after[light]["color"] == before[light]["color"] and after[light]["ms"] == before[light]["ms"]
	_check(same and ShowCues.read(anim).size() == count_before + before.size(),
			"Key all adds a key at the playhead on each of the %d lights, keeping their settings" % before.size())
	dock.key_all_at_playhead()
	_check(ShowCues.read(anim).size() == count_before + before.size(), "Key all again at the same moment adds nothing")

	# Rename: a key added by hand with no light name, then a light with several keys.
	var blank_track := anim.add_track(Animation.TYPE_METHOD)
	anim.track_set_path(blank_track, NodePath("."))
	anim.track_insert_key(blank_track, 1.25, {"method": &"light", "args": [&"", "SOLID", Color.WHITE, 500, Color.BLACK]})
	await _frames()
	_check(dock.has_row(ShowCues.TYPE_LIGHT, &""), "a key with no light name gets its own row")
	dock.rename_light(&"", "shoot again")
	_check(anim.method_track_get_params(blank_track, 0)[0] == &"shoot_again",
			"renaming it sets arg 0 (spaces become _): %s" % [anim.method_track_get_params(blank_track, 0)])
	var count_new := ShowCues.read(anim).filter(func(c: Dictionary) -> bool: return c["light"] == &"new_light").size()
	dock.rename_light(&"new_light", "flasher")
	var count_renamed := ShowCues.read(anim).filter(func(c: Dictionary) -> bool: return c["light"] == &"flasher").size()
	_check(count_new >= 2 and count_renamed == count_new and ShowCues.read(anim).all(func(c: Dictionary) -> bool: return c["light"] != &"new_light"),
			"renaming a light renames all %d of its keys" % count_new)
	await _frames()
	_check(dock.has_row(ShowCues.TYPE_LIGHT, &"flasher") and not dock.has_row(ShowCues.TYPE_LIGHT, &"new_light")
			and not dock.has_row(ShowCues.TYPE_LIGHT, &""),
			"the rows follow the new names")

	# Servo and coil cues from the dock.
	player.seek(1.5, false)
	await _frames()
	dock.edit_servo_at_playhead(&"gate", 0.25, 300, "LINEAR")   # no servo key yet: adds one here
	var gate_track := ShowCues.track_for(anim, ShowCues.TYPE_SERVO, &"gate")
	_check(gate_track >= 0 and anim.method_track_get_name(gate_track, 0) == &"servo"
			and anim.method_track_get_params(gate_track, 0) == [&"gate", 0.25, 300, "LINEAR"],
			"a servo row's first change adds a servo(...) key on its own track")
	await _until(func() -> bool: return is_equal_approx(_io.get_servo(&"gate")["position"], 0.25), 120)
	_check(is_equal_approx(_io.get_servo(&"gate")["position"], 0.25) and _io.get_servo(&"gate")["ramp_ms"] == 300,
			"the servo key reaches the game as a SERVO move")
	dock.edit_servo_at_playhead(&"gate", 0.8, 300, "SMOOTH")
	_check(anim.track_get_key_count(gate_track) == 1 and anim.method_track_get_params(gate_track, 0)[1] == 0.8,
			"editing the servo changes its key in place")
	dock.edit_coil_at_playhead(&"kickout", 20, 60)
	var kick_track := ShowCues.track_for(anim, ShowCues.TYPE_COIL, &"kickout")
	_check(kick_track >= 0 and anim.method_track_get_params(kick_track, 0) == [&"kickout", 20, 60],
			"a coil row's first change adds a coil(...) key")
	board.received.clear()
	await _frames(10)
	_check(not board.received.has("PULSE 2 20 60"), "a coil key doesn't pulse just because the playhead sits on it")
	dock.set_fire_coils(true)
	dock._play_coils(1.4, true)    # playing...
	dock._play_coils(1.6, true)    # ...past the coil key at 1.5
	await _until(func() -> bool: return board.received.has("PULSE 2 20 60"), 120)
	_check(board.received.has("PULSE 2 20 60"), "playing past a coil key pulses the coil (power 60 %%): %s" % [board.received])
	board.received.clear()
	dock._play_coils(3.5, true)    # a jump while playing: not a pass
	dock._play_coils(1.4, false)   # scrubbing back...
	dock._play_coils(1.6, false)   # ...and over the key, not playing
	await _frames(10)
	_check(not board.received.has("PULSE 2 20 60"), "scrubbing or jumping over a coil key doesn't pulse it")
	dock.set_fire_coils(false)
	dock._play_coils(1.4, true)
	dock._play_coils(1.6, true)
	await _frames(10)
	_check(not board.received.has("PULSE 2 20 60"), "with Fire coils off, playing past it doesn't pulse it either")

	dock.set_live(false)   # sends OFF
	await _until(func() -> bool: return _io.get_light(&"playfield")["effect"] == "OFF", 120)
	_check(_io.get_light(&"playfield")["effect"] == "OFF", "turning Send to game off turns the lights off")

	dock.queue_free()
	show_scene.queue_free()
	_shows.set_preview_listening(false, false)
	_shows.preview_port = _shows.PREVIEW_PORT
	_check(not _shows.is_previewing(), "stop listening ends the preview")
	await _frames()


## A show with servo and coil keys, fed to Shows directly (as if read from a scene).
func _test_servo_and_coil_cues(board: FakeBoard) -> void:
	var anim := Animation.new()
	anim.length = 4.0
	var servo_track := anim.add_track(Animation.TYPE_METHOD)
	anim.track_insert_key(servo_track, 0.0, ShowCues.servo_key(&"gate", 1.0, 400, "SMOOTH"))
	anim.track_insert_key(servo_track, 2.0, ShowCues.servo_key(&"gate", 0.0, 0, "LINEAR"))
	var coil_track := anim.add_track(Animation.TYPE_METHOD)
	for t in [0.0, 1.0, 2.0, 2.4]:
		anim.track_insert_key(coil_track, t, ShowCues.coil_key(&"kickout", 0 if t < 2.0 else 15, 100 if t < 2.4 else 50))
	var cues := ShowCues.read(anim)
	_check(cues.size() == 6 and cues.filter(func(c: Dictionary) -> bool: return c["type"] == ShowCues.TYPE_COIL).size() == 4
			and cues[0]["type"] == ShowCues.TYPE_SERVO and cues[0]["position"] == 1.0 and cues[0]["ease"] == "SMOOTH",
			"servo(...) and coil(...) keys read as servo and coil cues")
	_check(ShowCues.state_at(cues, 2.1, ShowCues.TYPE_SERVO)[&"gate"]["position"] == 0.0 and ShowCues.state_at(cues, 2.1).is_empty(),
			"state_at gives servo state by type (and no lights here)")
	_check(ShowCues.events_between(cues, 0.5, 2.0).size() == 2, "events_between finds the coil pulses in a span")
	_check(ShowCues.parse_preview("SERVO gate 250 300 LINEAR")["position"] == 0.25
			and ShowCues.parse_preview("COIL kickout 20 60")["power"] == 60 and ShowCues.parse_preview("SERVO gate x").is_empty(),
			"SERVO and COIL preview lines read back")

	var data = _shows.ShowData.new()   # what Shows would read from a scene with these keys
	data.sync_to = "none"
	data.length = 4.0
	data.cues = cues
	_shows._library[&"cue_types"] = "res://not/a/file.tscn"
	_shows._cue_cache[&"cue_types"] = data
	_shows.clock_override = func() -> float: return _clock
	board.received.clear()
	_shows.play_show(&"cue_types")
	_clock = 0.05
	await _frames()
	_check(board.received.has("SERVO 0 1000 400 SMOOTH") and board.received.has("PULSE 2"),
			"at 0 s the servo moves and the coil pulses: %s" % [board.received])
	board.received.clear()
	_clock = 1.05
	await _frames()
	_clock = 1.1
	await _frames()
	_check(board.received.count("PULSE 2") == 1, "a coil key fires once when the clock passes it: %s" % [board.received])
	_shows.stop_show()
	board.received.clear()
	_shows.play_show(&"cue_types")   # a late start, 2.5 s in
	_clock = 2.5
	await _frames()
	_check(board.received.has("SERVO 0 0 0 LINEAR") and board.received.has("PULSE 2 15 50")
			and not board.received.has("PULSE 2") and not board.received.has("PULSE 2 15 100"),
			"a late start catches the servo up and fires only the coil pulse that's due now: %s" % [board.received])
	_shows.stop_show()
	_shows.clock_override = Callable()
	_shows._library.erase(&"cue_types")
	_shows._cue_cache.erase(&"cue_types")


## Wait until a condition holds, or `frames` frames.
func _until(condition: Callable, frames: int) -> void:
	for i in frames:
		if condition.call():
			return
		await process_frame

extends SceneTree
## Headless check of LED lights through PinballIO and of light shows, using a
## fake board and the demo show in git (assets/shows/test/test_loop_a.tscn).
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


## A PINIO 0.3 board, just enough for lights: answers HELLO, ACKs config and commands.
class FakeBoard:
	var link: BoardLink
	var received: PackedStringArray = []
	var layout: PackedStringArray = []
	var counts := {"IN": 0, "COIL": 0, "LAMP": 0, "CHAIN": 0, "ZONE": 0}

	func handle(line: String) -> void:
		received.append(line)
		var parts := line.split(" ")
		match parts[0]:
			"HELLO":
				reply("HELLO PINIO 0.3 TEENSY41 12345670 - -")
			"CFG":
				if parts[1] == "CLEAR":
					layout.clear()
					for key: String in counts:
						counts[key] = 0
					reply("ACK CFG CLEAR")
				elif parts[1] == "DONE":
					reply("ACK CFG %d %d %d %d %d %s" % [counts["IN"], counts["COIL"], counts["LAMP"],
							counts["CHAIN"], counts["ZONE"], load("res://config/machine_config.gd").layout_hash(layout)])
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
	_config.restore(default_data, false)

	var board := _test_lights_on_board()
	await _test_show_cues_and_clock(board)
	await _test_show_follows_music()

	_io.close_port()
	board.link = null   # the fake board and its link point at each other; let them go
	_config.restore(saved_layout, false)
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

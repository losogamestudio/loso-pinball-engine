extends SceneTree
## Headless checks for MachineConfig + BoardLink, no hardware needed.
##
## Run from the project folder:
##     godot --headless --path . -s res://test/test_config_link.gd
## Prints PASS/FAIL per check and exits with code 1 if anything failed.
##
## A tiny fake board stands in for the Teensy: it answers HELLO, ACKs CFG
## lines the way PINIO 0.2 does, and can be told to reject one line.

const MachineConfigScript := preload("res://config/machine_config.gd")

var _failures := 0


func _init() -> void:
	_test_fnv_vectors()
	_test_default_config()
	_test_validation_catches_mistakes()
	_test_link_handshake()
	_test_link_config_rejected()
	_test_adopt_and_burn()
	print("\n%s" % ("ALL PASSED" if _failures == 0 else "%d FAILURE(S)" % _failures))
	quit(1 if _failures > 0 else 0)


func _check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		_failures += 1


func _new_config() -> Node:
	# A private MachineConfig instance (not the autoload), loaded from the default file.
	var cfg: Node = load("res://config/machine_config.gd").new()
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/machine_config.default.json"))
	cfg._apply_dict(data)
	return cfg


# ---------------------------------------------------------------- MachineConfig

func _test_fnv_vectors() -> void:
	# Published FNV-1a 32-bit test values: if these match, Godot's hash is the
	# same algorithm as the firmware's fnvAdd().
	var ok := MachineConfigScript.fnv1a("".to_utf8_buffer()) == 0x811C9DC5 \
			and MachineConfigScript.fnv1a("a".to_utf8_buffer()) == 0xE40C292C \
			and MachineConfigScript.fnv1a("foobar".to_utf8_buffer()) == 0xBF9CF968
	_check(ok, "FNV-1a matches the published test vectors")
	_check(MachineConfigScript.layout_hash(["CFG CLEAR", "CFG DONE"]) == "811C9DC5",
			"layout hash skips CLEAR/DONE and prints 8 hex digits")


func _test_default_config() -> void:
	var cfg := _new_config()
	var problems: PackedStringArray = cfg.validate()
	_check(problems.is_empty(), "default config validates (%s)" % ", ".join(problems))

	var plan: IoDefs.BoardPlan = cfg.build_plan(cfg.boards[0])
	var expected: PackedStringArray = [
		"CFG PWM 20000",
		"CFG IN 0 33 NO 5",
		"CFG IN 1 34 NO 2",
		"CFG IN 2 35 NO 5",
		"CFG COIL 0 2 60 50 0 1 0",
		"CFG COIL 1 26 40 0 2 - 150",
		"CFG COIL 2 3 30 0 - - 500",
		"CFG LAMP 0 27",
		"CFG DONE",
	]
	_check(plan.lines == expected, "default config builds the expected CFG lines\n      got: %s" % "\n           ".join(plan.lines))
	_check(plan.coil_names[0] == &"flipper_left" and plan.input_names[2] == &"sling_left_switch",
			"plan maps board numbers back to names")

	# Round trip through the JSON shape.
	var again: Node = load("res://config/machine_config.gd").new()
	again._apply_dict(cfg.to_dict())
	_check(JSON.stringify(again.to_dict()) == JSON.stringify(cfg.to_dict()), "to_dict/from_dict round trip")
	cfg.free()
	again.free()


func _test_validation_catches_mistakes() -> void:
	var cfg := _new_config()
	cfg.coils[1].hold_pct = 30             # sling on pin 26: no PWM there
	cfg.inputs[0].pin = 13                 # reserved status LED
	cfg.lamps[0].pin = 2                   # clashes with flipper_left
	var second := IoDefs.BoardDef.new()
	second.id = &"aux"
	cfg.boards.append(second)
	cfg.coils[2].board = &"aux"
	cfg.coils[2].pin = 4
	cfg.coils[2].trigger = &"sling_left_switch"   # an input on the other board
	var problems: PackedStringArray = cfg.validate()
	var text := "\n".join(problems)
	_check(text.contains("can't do PWM"), "catches hold on a non-PWM pin")
	_check(text.contains("reserved (status LED)"), "catches a reserved pin")
	_check(text.contains("both use pin 2"), "catches two things on one pin")
	_check(text.contains("different board"), "catches a trigger on another board")
	cfg.free()


# ---------------------------------------------------------------- BoardLink with a fake board

## Just enough of a PINIO 0.2 board to exercise the link.
class FakeBoard:
	var link: BoardLink
	var received: PackedStringArray = []
	var reject_prefix := ""   # reply ERR CFG to the first line starting with this
	var layout: PackedStringArray = []   # accepted CFG lines since CFG CLEAR
	var running := "-"                   # fingerprint of the running layout
	var saved := "-"                     # fingerprint "burned" into EEPROM
	var inputs := 0
	var coils := 0
	var lamps := 0

	func handle(line: String) -> void:
		received.append(line)
		var parts := line.split(" ")
		match parts[0]:
			"HELLO":
				_reply("HELLO PINIO 0.2 TEENSY41 12345670 %s %s" % [running, saved])
			"SWS":
				_reply("SWS " + "0".repeat(inputs))
			"CFG":
				if reject_prefix != "" and line.begins_with(reject_prefix):
					_reply("ERR CFG pin already used")
				elif parts[1] == "CLEAR":
					layout.clear()
					running = "-"
					inputs = 0
					coils = 0
					lamps = 0
					_reply("ACK CFG CLEAR")
				elif parts[1] == "DONE":
					running = MachineConfigScript.layout_hash(layout)
					_reply("ACK CFG %d %d %d %s" % [inputs, coils, lamps, running])
					_reply("SWS " + "0".repeat(inputs))
				elif parts[1] == "SAVE":
					saved = running
					_reply("ACK CFG SAVE " + saved)
				else:
					match parts[1]:
						"IN": inputs += 1
						"COIL": coils += 1
						"LAMP": lamps += 1
					layout.append(line)
					_reply("ACK " + line)

	func _reply(line: String) -> void:
		link.feed((line + "\n").to_utf8_buffer())


func _make_link(board: FakeBoard) -> BoardLink:
	var link := BoardLink.new("FAKE", board.handle)
	board.link = link
	return link


func _test_link_handshake() -> void:
	var cfg := _new_config()
	var board := FakeBoard.new()
	var link := _make_link(board)
	var events: Array[String] = []
	link.linked.connect(func(fw: String, type: String, uid: String) -> void: events.append("linked %s %s %s" % [fw, type, uid]))
	link.switches_synced.connect(func(states: Array[bool]) -> void: events.append("sws %d" % states.size()))
	link.configured.connect(func() -> void: events.append("configured"))

	link.start()
	_check(events.size() == 1 and events[0] == "linked PINIO 0.2 TEENSY41 12345670", "HELLO reply parsed: %s" % str(events))

	var plan: IoDefs.BoardPlan = cfg.build_plan(cfg.boards[0])
	var lines: PackedStringArray = ["CFG CLEAR"]
	lines.append_array(plan.lines)
	link.send_config(lines)
	_check(board.received.slice(1) == lines, "config sent one line at a time, in order")
	_check(link.is_configured and events.slice(1) == ["sws 3", "configured"], "configured after ACK CFG + SWS: %s" % str(events))
	cfg.free()


func _test_link_config_rejected() -> void:
	var board := FakeBoard.new()
	board.reject_prefix = "CFG COIL"
	var link := _make_link(board)
	var failed := []
	link.config_failed.connect(func(message: String) -> void: failed.append(message))
	link.start()
	link.send_config(["CFG CLEAR", "CFG IN 0 33 NO 5", "CFG COIL 0 2 60 50 0 - 0", "CFG LAMP 0 27", "CFG DONE"])
	_check(failed == ["CFG pin already used"], "ERR CFG reported as config_failed: %s" % str(failed))
	_check(not link.is_configured and not board.received.has("CFG LAMP 0 27"), "stops sending after a rejected line")


func _test_adopt_and_burn() -> void:
	var cfg := _new_config()
	var plan: IoDefs.BoardPlan = cfg.build_plan(cfg.boards[0])
	var lines: PackedStringArray = ["CFG CLEAR"]
	lines.append_array(plan.lines)

	# First connection: board is blank, gets the layout, then burns it.
	var board := FakeBoard.new()
	var link := _make_link(board)
	link.start()
	link.send_config(lines)
	_check(link.running_fingerprint == plan.fingerprint, "board's fingerprint after config matches Godot's (%s)" % plan.fingerprint)
	var burned := []
	link.burned.connect(func(fp: String) -> void: burned.append(fp))
	link.burn()
	_check(burned == [plan.fingerprint] and link.saved_fingerprint == plan.fingerprint, "burn reports the saved fingerprint")

	# "Power cycle": the board boots with its burned layout already running.
	board.received.clear()
	link.start()
	_check(link.running_fingerprint == plan.fingerprint and link.saved_fingerprint == plan.fingerprint,
			"HELLO reports running and saved fingerprints")
	var configured := []
	link.configured.connect(func() -> void: configured.append(true))
	link.adopt_config()
	_check(configured == [true] and not board.received.has("CFG CLEAR"),
			"matching layout is adopted without re-sending it")
	cfg.free()

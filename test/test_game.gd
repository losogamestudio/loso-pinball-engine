extends SceneTree
## Headless check of the Game autoload: start, scoring by switch kind, drains,
## abort. No hardware needed; switch presses are faked by emitting
## PinballIO.switch_changed the way a board would.
##
##     godot --headless --path . -s res://test/test_game.gd
##
## Uses an in-memory layout and puts the machine's own layout back after, so
## it never writes user://machine_config.json.

var _failures := 0
var _config: Node   # MachineConfig autoload
var _io: Node       # PinballIO autoload
var _game: Node     # Game autoload
var _ended := []   # game_ended(aborted) values, in order


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	_config = root.get_node("MachineConfig")
	_io = root.get_node("PinballIO")
	_game = root.get_node("Game")
	var saved_layout: Dictionary = _config.snapshot()
	_config.restore(_test_layout(), false)
	_game.game_ended.connect(func(aborted: bool) -> void: _ended.append(aborted))

	_test_three_ball_game()
	_test_abort_and_start_switch()
	_test_extra_ball()
	_check(_game.format_score(1234567) == "1,234,567" and _game.format_score(500) == "500",
			"format_score adds thousands separators")

	_config.restore(saved_layout, false)
	print("\n%s" % ("ALL PASSED" if _failures == 0 else "%d FAILURE(S)" % _failures))
	quit(1 if _failures > 0 else 0)


func _check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		_failures += 1


## One switch of each kind (pins 33..37 on the main board).
func _test_layout() -> Dictionary:
	var inputs := []
	var kinds := {"plain_sw": ["switch", 0], "target_a": ["target", 500], "spinner_a": ["spinner", 100],
			"drain_sw": ["drain", 0], "start_sw": ["start", 0]}
	var pin := 33
	for n: String in kinds:
		inputs.append({"name": n, "board": "main", "pin": pin, "kind": kinds[n][0], "points": kinds[n][1]})
		pin += 1
	return {"boards": [{"id": "main", "type": "TEENSY41"}], "inputs": inputs, "coils": [], "lamps": []}


## A switch closing and opening, as the board reports it.
func _press(switch_name: StringName) -> void:
	_io.switch_changed.emit(switch_name, true)
	_io.switch_changed.emit(switch_name, false)


func _test_three_ball_game() -> void:
	_check((_config.validate() as PackedStringArray).is_empty(), "test layout with every switch kind validates")
	_press(&"target_a")
	_check(not _game.is_playing() and _game.score == 0, "no points while no game is running")

	_game.start_game()
	_check(_game.is_playing() and _game.ball == 1 and _game.score == 0, "Start game: ball 1, score 0")
	_press(&"target_a")
	_press(&"spinner_a")
	_press(&"spinner_a")
	_press(&"plain_sw")
	_check(_game.score == 700, "target 500 + spinner 2x100, plain switch scores nothing: %d" % _game.score)
	_game.start_game()
	_check(_game.ball == 1 and _game.score == 700, "Start during a game is ignored")

	_press(&"drain_sw")
	_check(_game.ball == 2 and _game.is_playing(), "drain switch -> ball 2")
	_game.end_ball()   # the touch Drain ball button
	_check(_game.ball == 3, "Drain ball button -> ball 3")
	_press(&"drain_sw")
	_check(not _game.is_playing() and _ended == [false], "drain on the last ball ends the game (not aborted)")
	_check(_game.score == 700, "score is kept after the game (last score)")


func _test_abort_and_start_switch() -> void:
	_ended.clear()
	_press(&"start_sw")
	_check(_game.is_playing() and _game.ball == 1 and _game.score == 0, "start switch starts a new game")
	_press(&"target_a")
	_game.abort_game()
	_check(not _game.is_playing() and _ended == [true], "Abort game ends it (aborted)")
	_press(&"drain_sw")
	_check(_ended == [true], "a drain after the game does nothing")


func _test_extra_ball() -> void:
	_ended.clear()
	_game.add_extra_ball()
	_check(_game.extra_balls == 0, "no extra ball outside a game")
	_game.start_game()
	_game.end_ball()
	_game.end_ball()   # now on ball 3, the last one
	_game.add_extra_ball()
	_game.add_extra_ball()
	_check(_game.extra_balls == 2, "two extra balls waiting")
	_press(&"drain_sw")
	_check(_game.ball == 3 and _game.extra_balls == 1 and _game.is_playing(), "drain with an extra ball: shoot again, ball 3")
	_press(&"drain_sw")
	_press(&"drain_sw")
	_check(not _game.is_playing() and _ended == [false], "extra balls used up, then game over")
	_game.start_game()
	_check(_game.extra_balls == 0, "a new game starts with no extra balls")
	_game.abort_game()

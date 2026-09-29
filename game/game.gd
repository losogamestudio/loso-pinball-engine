extends Node
## Game — autoload that runs a game: start, balls, score, end.
##
## Roughly Unreal's GameMode + GameState in one: the single place that knows
## whether a game is running, which ball it is and the score. Screens (the
## attract and game_play modes) call its functions and listen to its signals;
## Main swaps the screens when a game starts or ends.
##
## Switches score by their kind in MachineConfig (IoDefs.KIND_*): targets and
## spinners add their points, the drain switch ends the ball, the start switch
## starts a game.
##
## Coil rules (flippers, slings) are armed when a game starts and disarmed when
## it ends; the board fires them itself. Game events that need a coil or lamp
## (ball kickout, drop target reset, diverters) will send direct commands from
## here through PinballIO (pulse_coil / hold_coil / set_lamp).
##
## Register under Project Settings > Globals > Autoload as "Game", below PinballIO.
##
## TODO (later): kick a ball into play on ball_started, tilt, ball save, match,
## a minimum ball time so a bouncy drain can't end a ball twice.

signal game_started              ## a new game began (ball 1 follows)
signal ball_started(ball: int)   ## ball number [param ball] is now in play (1-based)
signal score_changed(score: int)
signal extra_balls_changed(count: int)   ## extra balls waiting ("shoot again")
signal game_ended(aborted: bool) ## the game is over; aborted = ended early with Abort

enum State { IDLE, PLAYING }

var balls_per_game := 3
var state := State.IDLE
var ball := 0          ## current ball, 1..balls_per_game (0 before the first game)
var score := 0         ## current game's score, kept after the game ends ("last score")
var extra_balls := 0   ## earned extra balls: a drain replays the same ball number instead of moving on


func _ready() -> void:
	PinballIO.switch_changed.connect(_on_switch_changed)


func is_playing() -> bool:
	return state == State.PLAYING


## A score with thousands separators, e.g. 1234567 -> "1,234,567".
func format_score(value: int) -> String:
	var digits := str(absi(value))
	var out := ""
	while digits.length() > 3:
		out = "," + digits.right(3) + out
		digits = digits.left(digits.length() - 3)
	return ("-" if value < 0 else "") + digits + out


## Start a new game. Ignored while one is already running.
func start_game() -> void:
	if is_playing():
		return
	state = State.PLAYING
	score = 0
	extra_balls = 0
	PinballIO.set_all_rules(true)   # flippers and slings live
	game_started.emit()
	score_changed.emit(score)
	extra_balls_changed.emit(extra_balls)
	_start_ball(1)


## Add points to the score (only while a game is running).
func add_points(points: int) -> void:
	if not is_playing() or points <= 0:
		return
	score += points
	score_changed.emit(score)


## Award an extra ball (only while a game is running).
func add_extra_ball() -> void:
	if not is_playing():
		return
	extra_balls += 1
	extra_balls_changed.emit(extra_balls)


## The ball drained: shoot again if an extra ball is waiting, else next ball,
## or game over after the last one.
func end_ball() -> void:
	if not is_playing():
		return
	if extra_balls > 0:
		extra_balls -= 1
		extra_balls_changed.emit(extra_balls)
		_start_ball(ball)   # same ball number again
	elif ball >= balls_per_game:
		_end_game(false)
	else:
		_start_ball(ball + 1)


## Stop the game right now (the Abort game button).
func abort_game() -> void:
	if is_playing():
		_end_game(true)


# ---------------------------------------------------------------- internals

func _start_ball(number: int) -> void:
	ball = number
	ball_started.emit(ball)


func _end_game(aborted: bool) -> void:
	state = State.IDLE
	PinballIO.set_all_rules(false)   # flippers dead between games
	game_ended.emit(aborted)


func _on_switch_changed(switch_name: StringName, active: bool) -> void:
	if not active:
		return   # everything here reacts to a switch closing, not opening
	var input := MachineConfig.find_input(switch_name)
	if input == null:
		return
	match input.kind:
		IoDefs.KIND_TARGET, IoDefs.KIND_SPINNER:
			add_points(input.points)
		IoDefs.KIND_DRAIN:
			end_ball()
		IoDefs.KIND_START:
			start_game()

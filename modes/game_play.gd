extends Control
## Game screen: score, ball number, Abort game, and bench-test buttons.
##
## Only shows what the Game autoload says (score_changed / ball_started /
## extra_balls_changed) and calls Game functions for the buttons. Main swaps
## this screen in when a game starts and back to attract when it ends.
##
## Test buttons (for playing a game on the bench without a playfield):
##   left  - cheat buttons (Extra ball, Drain ball, ...), built from _cheats()
##   right - a grid of point buttons, built from TEST_POINTS
## They call the same Game functions real switches do, so what they test is real.

## Show the test buttons. TODO: make this a Setup-tab setting, off on a finished machine.
const SHOW_TEST_BUTTONS := true

## Point buttons in the right-hand grid (two columns).
const TEST_POINTS: Array[int] = [10, 50, 100, 500, 1000, 5000, 10000, 50000]

const MUSIC := &"game"   ## assets/music/game.ogg (or .mp3/.wav), if there is one

const TEST_FONT_SIZE := 28
const TEST_BUTTON_SIZE := Vector2(130, 64)
const TEST_COLOR := Color(0.75, 0.6, 1.0)   # test buttons look different from real ones


func _ready() -> void:
	# The dialog is its own window, so it doesn't get font sizes from this
	# screen; the service text size keeps it readable on a small screen.
	$AbortConfirm.theme = DisplaySettings.text_theme()
	for b: Button in [$AbortConfirm.get_ok_button(), $AbortConfirm.get_cancel_button()]:
		b.custom_minimum_size = Vector2(260, 88)   # finger-sized, like the buttons on the screen
	$AbortButton.pressed.connect(_ask_abort)
	$AbortConfirm.confirmed.connect(Game.abort_game)
	Game.score_changed.connect(_on_score_changed)
	Game.ball_started.connect(_on_ball_started)
	Game.extra_balls_changed.connect(_on_extra_balls_changed)
	_on_score_changed(Game.score)
	_on_ball_started(Game.ball)
	_on_extra_balls_changed(Game.extra_balls)
	Media.play_music(MUSIC, 1.5)   # crossfades from the attract music
	if SHOW_TEST_BUTTONS:
		_build_test_buttons()


## The cheat buttons on the left, as [label, what it does]. Add new ones here.
## Planned, once Game has the feature behind them:
##   "Last ball"      jump straight to the final ball
##   "Tilt"           trigger a tilt (disarms rules, ends the ball with no bonus)
##   "Ball save"      turn ball save on for this ball
##   "Kick out"       fire the ball kickout coil
##   "Rules off/on"   disarm/arm the flippers and slings mid-game
func _cheats() -> Array:
	return [
		["Extra ball", Game.add_extra_ball],
		["Drain ball", Game.end_ball],   # until a switch of kind "drain" is wired
	]


func _build_test_buttons() -> void:
	var heading := Label.new()
	heading.text = "Test"
	heading.add_theme_font_size_override("font_size", TEST_FONT_SIZE)
	heading.add_theme_color_override("font_color", TEST_COLOR)
	$CheatPanel.add_child(heading)
	for cheat: Array in _cheats():
		var b := _test_button(cheat[0], cheat[1])
		b.custom_minimum_size = Vector2(260, 72)
		$CheatPanel.add_child(b)

	for points in TEST_POINTS:
		$PointGrid.add_child(_test_button("+" + Game.format_score(points), Game.add_points.bind(points)))


func _test_button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = TEST_BUTTON_SIZE
	b.add_theme_font_size_override("font_size", TEST_FONT_SIZE)
	b.add_theme_color_override("font_color", TEST_COLOR)
	b.focus_mode = Control.FOCUS_NONE   # touch buttons; don't leave a focus box behind
	b.pressed.connect(on_press)
	return b


func _ask_abort() -> void:
	$AbortConfirm.popup_centered()


func _on_score_changed(score: int) -> void:
	$Score.text = Game.format_score(score)


func _on_ball_started(ball: int) -> void:
	$Ball.text = "Ball %d of %d" % [ball, Game.balls_per_game]


func _on_extra_balls_changed(count: int) -> void:
	match count:
		0: $ExtraBalls.text = ""
		1: $ExtraBalls.text = "Extra ball"
		_: $ExtraBalls.text = "%d extra balls" % count

extends Control
## Attract mode: the screen shown while no game is running.
##
## Start game (touch) starts a game through the Game autoload, the same as a
## switch of kind "start" (the cabinet button, once it's wired). Main then
## swaps in the game screen. Mode scenes don't reach up into Main; they emit
## signals and Main decides ("call down, signal up"). Main connects
## `service_requested` for any mode that has it.

signal service_requested   ## the touch-screen Service button was pressed

const MUSIC := &"attract"   ## assets/music/attract.ogg (or .mp3/.wav), if there is one


func _ready() -> void:
	$ServiceButton.pressed.connect(service_requested.emit)
	$StartButton.pressed.connect(Game.start_game)
	# Each mode picks its music; Media crossfades from whatever was playing.
	Media.play_music(MUSIC, 1.5)
	# After a game, show how it went. ball is 0 until the first game.
	$LastScore.text = "Last score: %s" % Game.format_score(Game.score) if Game.ball > 0 else ""

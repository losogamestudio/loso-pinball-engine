extends Control
## Attract mode (placeholder for now): the screen shown while no game is running.
##
## Mode scenes don't reach up into Main; they emit signals and Main decides
## ("call down, signal up"). Main connects `service_requested` for any mode
## that has it.

signal service_requested   ## the touch-screen Service button was pressed


func _ready() -> void:
	$ServiceButton.pressed.connect(service_requested.emit)

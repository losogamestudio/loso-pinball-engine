extends Control
## ServiceMenu — the Setup + Diagnostics tabs, with a touch-friendly Exit
## button in the top-right corner. Main opens it (Service button or P key)
## and closes it when `exit_requested` fires.

signal exit_requested   ## the Exit button was pressed


func _ready() -> void:
	$TopBar/ExitButton.pressed.connect(exit_requested.emit)

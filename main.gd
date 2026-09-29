extends Node
## Main — the base scene. It is always loaded and never replaced.
##
## Think of it like Unreal's persistent level: it stays put for the whole run,
## and other scenes get streamed in and out underneath it.
##
##   Main
##   ├── ModeHost       holds exactly one "mode" scene (attract, game, ...)
##   └── ServiceLayer   CanvasLayer drawn on top; holds the service/config page
##
## Mode scenes are swapped with show_mode(). The service page is loaded when
## opened and freed when closed, so it costs nothing while the game runs.
## Press P to toggle it (on the cabinet this will become a coin-door button).

## Keyboard key that opens/closes the service menu. P rather than F1, because
## the Raspberry Pi's on-screen keyboard has no function keys.
const SERVICE_KEY := KEY_P

signal mode_changed(mode: Node)          ## a new mode scene is now running
signal service_toggled(is_open: bool)    ## service page opened or closed

## Scene shown in ModeHost at startup.
@export var start_mode: PackedScene
## Scene shown in the ServiceLayer when service is opened.
@export var service_scene: PackedScene

@onready var _mode_host: Node = $ModeHost
@onready var _service_layer: CanvasLayer = $ServiceLayer
@onready var _service_host: Node = $ServiceLayer/ServiceHost

var _current_mode: Node


func _ready() -> void:
	_service_layer.visible = false
	if start_mode:
		show_mode(start_mode)


func _unhandled_input(event: InputEvent) -> void:
	# _unhandled_input only sees events nothing else consumed, so a text field
	# on the service page (e.g. typing a name with a "p" in it) never closes the page.
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == SERVICE_KEY:
			toggle_service()
			get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- modes

## Replace whatever mode is running with a new instance of [param scene].
## Returns the new mode node so the caller can configure it.
func show_mode(scene: PackedScene) -> Node:
	if _current_mode:
		# queue_free waits until the end of the frame, so nothing still using
		# the old mode this frame crashes. Remove it from the tree right away
		# so the old and new mode never run side by side.
		_mode_host.remove_child(_current_mode)
		_current_mode.queue_free()
	_current_mode = scene.instantiate()
	_mode_host.add_child(_current_mode)
	mode_changed.emit(_current_mode)
	return _current_mode


## The mode scene currently running, or null.
func get_current_mode() -> Node:
	return _current_mode


# ---------------------------------------------------------------- service page

## True while the service page is on screen.
func is_service_open() -> bool:
	return _service_layer.visible


func open_service() -> void:
	if is_service_open() or not service_scene:
		return
	_service_host.add_child(service_scene.instantiate())
	_service_layer.visible = true
	service_toggled.emit(true)


func close_service() -> void:
	if not is_service_open():
		return
	for child in _service_host.get_children():
		child.queue_free()
	_service_layer.visible = false
	service_toggled.emit(false)


func toggle_service() -> void:
	if is_service_open():
		close_service()
	else:
		open_service()

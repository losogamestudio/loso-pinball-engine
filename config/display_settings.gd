class_name DisplaySettings
## Screen settings for this machine: UI scale and fullscreen.
##
## The project is laid out for 1280x720 and Godot scales the whole picture to
## fit the actual screen (Project Settings > Display > Window > Stretch:
## mode "canvas_items", aspect "expand" — like Unreal's DPI scaling). On a small
## screen that makes text small too, so the UI scale here multiplies on top of
## it: e.g. 150% on an 800x480 display.
##
## Saved per machine in user://display.cfg (not in git), applied at startup by
## main.gd and changed live from the Setup page. Static: DisplaySettings.apply_saved().

const PATH := "user://display.cfg"
const DESIGN_SIZE := Vector2i(1280, 720)   ## keep in sync with display/window/size in project.godot
const SCALES: Array[float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]


## Apply whatever is saved (called once at startup).
static func apply_saved() -> void:
	_apply_scale(get_ui_scale())
	if get_fullscreen():
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif _screen_smaller_than_design():
		# The 1280x720 window wouldn't fit this screen: fill it instead.
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)


static func get_ui_scale() -> float:
	return _load().get_value("display", "ui_scale", 1.0)


static func get_fullscreen() -> bool:
	return _load().get_value("display", "fullscreen", false)


## Change the UI scale (1.0 = 100%), apply it now, and remember it.
static func set_ui_scale(scale: float) -> void:
	_apply_scale(scale)
	_save("ui_scale", scale)


## Switch fullscreen on or off now, and remember it.
static func set_fullscreen(on: bool) -> void:
	if on:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED
				if _screen_smaller_than_design() else DisplayServer.WINDOW_MODE_WINDOWED)
	_save("fullscreen", on)


## The physical screen size, for showing on the Setup page.
static func screen_size() -> Vector2i:
	return DisplayServer.screen_get_size()


# ---------------------------------------------------------------- internals

static func _apply_scale(scale: float) -> void:
	# content_scale_factor multiplies on top of the stretch-to-fit scaling.
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.content_scale_factor = scale


static func _screen_smaller_than_design() -> bool:
	var screen := DisplayServer.screen_get_size()
	return screen.x < DESIGN_SIZE.x or screen.y < DESIGN_SIZE.y


static func _load() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(PATH)   # a missing file just means "all defaults"
	return cfg


static func _save(key: String, value: Variant) -> void:
	var cfg := _load()
	cfg.set_value("display", key, value)
	cfg.save(PATH)

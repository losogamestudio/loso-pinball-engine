class_name DisplaySettings
## Screen settings for this machine: UI scale, text size and fullscreen.
##
## The project is laid out for 1280x720 and Godot scales the whole picture to
## fit the actual screen (Project Settings > Display > Window > Stretch:
## mode "canvas_items", aspect "expand" — like Unreal's DPI scaling). On a small
## screen that makes text small too. Two knobs multiply on top of it:
##   UI scale  - everything (layout and text) bigger or smaller
##   Text size - only the letters (200% by default, right for an 800x480 screen
##               at UI scale 100%)
##
## Saved per machine in user://display.cfg (not in git), applied at startup by
## main.gd and changed live from the Audio & Video tab. Static: DisplaySettings.apply_saved().

const PATH := "user://display.cfg"
const DESIGN_SIZE := Vector2i(1280, 720)   ## keep in sync with display/window/size in project.godot
const SCALES: Array[float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

## Text size is separate from UI scale: it makes letters bigger without
## changing the layout (column widths, spacing). 200% by default.
const TEXT_SCALES: Array[float] = [1.0, 1.3, 1.6, 2.0, 2.4]
const DEFAULT_TEXT_SCALE := 2.0
const BASE_FONT_SIZE := 16   ## Godot's default font size, before text scaling
const DEFAULT_FULLSCREEN := true   ## until the Fullscreen box (Audio & Video tab) is unticked

static var _text_scale_cache := 0.0   ## so font_size() doesn't read the file for every label
static var _text_theme: Theme          ## shared by every screen; see text_theme()


## Apply whatever is saved (called once at startup).
static func apply_saved() -> void:
	_apply_scale(get_ui_scale())
	_apply_text_scale(get_text_scale())
	if get_fullscreen():
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif _screen_smaller_than_design():
		# The 1280x720 window wouldn't fit this screen: fill it instead.
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)


static func get_ui_scale() -> float:
	return _load().get_value("display", "ui_scale", 1.0)


## Fullscreen unless this machine turned it off (the cabinet screen is the whole display).
static func get_fullscreen() -> bool:
	return _load().get_value("display", "fullscreen", DEFAULT_FULLSCREEN)


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


static func get_text_scale() -> float:
	if _text_scale_cache <= 0.0:
		_text_scale_cache = _load().get_value("display", "text_scale", DEFAULT_TEXT_SCALE)
	return _text_scale_cache


## Change the text size (1.0 = 100%), apply it now, and remember it.
## Screens that set their own heading sizes should rebuild afterwards.
static func set_text_scale(scale: float) -> void:
	_text_scale_cache = scale
	_apply_text_scale(scale)
	_save("text_scale", scale)


## A font size scaled by the text size setting. Use this wherever a label
## sets its own size (headings), so it grows along with normal text.
static func font_size(base: int) -> int:
	return roundi(base * get_text_scale())


## The physical screen size, for showing on the Audio & Video tab.
static func screen_size() -> Vector2i:
	return DisplayServer.screen_get_size()


# ---------------------------------------------------------------- internals

static func _apply_scale(scale: float) -> void:
	# content_scale_factor multiplies on top of the stretch-to-fit scaling.
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.content_scale_factor = scale


## The Theme that carries the text size. Screens put it on their root Control
## (`theme = DisplaySettings.text_theme()`); every Control inside that doesn't
## set its own font size then uses it, including dropdown lists and dialogs.
## Gotcha: a theme only flows down through Controls and Windows, so setting it
## on the root window doesn't reach screens under a CanvasLayer (like the
## service menu). That's why each screen sets it on itself instead.
## One shared object: changing the text size updates every screen using it.
static func text_theme() -> Theme:
	if _text_theme == null:
		_text_theme = Theme.new()
		_text_theme.default_font_size = roundi(BASE_FONT_SIZE * get_text_scale())
		UiKit.style_theme(_text_theme)   # gray buttons, fields and cards
	return _text_theme



static func _apply_text_scale(scale: float) -> void:
	text_theme().default_font_size = roundi(BASE_FONT_SIZE * scale)


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

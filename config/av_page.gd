extends MarginContainer
## AvPage — the "Audio & Video" tab of the service menu: this machine's screen
## settings (user://display.cfg), audio volumes (user://audio.cfg) and the
## media library (assets/, synced separately from git).

## Generated test media that ships in git (tools/make_test_sounds.gd).
const TEST_SOUND := &"test_chime"
const TEST_MUSIC_A := &"test_loop_a"
const TEST_MUSIC_B := &"test_loop_b"

var _list: VBoxContainer
var _music_pick: OptionButton
var _video_pick: OptionButton
var _show_pick: OptionButton


func _ready() -> void:
	for side in ["left", "right", "top", "bottom"]:
		add_theme_constant_override("margin_" + side, 16)
	var scroll := UiKit.scroll_container()   # always-on, finger-wide scroll bar
	add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 12)
	scroll.add_child(_list)
	_rebuild()


func _rebuild() -> void:
	UiKit.free_children(_list)
	_build_screen()
	_build_audio()
	_build_media()


# ---------------------------------------------------------------- screen

## UI scale, text size and fullscreen for this machine's display.
func _build_screen() -> void:
	var screen := DisplaySettings.screen_size()
	var body := UiKit.section(_list, "Screen")
	var row := _flow()
	body.add_child(row)

	var scale_pick := OptionButton.new()
	var current := DisplaySettings.get_ui_scale()
	for ui_scale in DisplaySettings.SCALES:
		scale_pick.add_item("UI scale %d%%" % roundi(ui_scale * 100))
		if is_equal_approx(ui_scale, current):
			scale_pick.select(scale_pick.item_count - 1)
	scale_pick.item_selected.connect(func(i: int) -> void: DisplaySettings.set_ui_scale(DisplaySettings.SCALES[i]))
	row.add_child(scale_pick)

	var text_pick := OptionButton.new()
	var current_text := DisplaySettings.get_text_scale()
	for text_scale in DisplaySettings.TEXT_SCALES:
		text_pick.add_item("Text size %d%%" % roundi(text_scale * 100))
		if is_equal_approx(text_scale, current_text):
			text_pick.select(text_pick.item_count - 1)
	text_pick.item_selected.connect(_on_text_size_picked)
	row.add_child(text_pick)

	var full := CheckBox.new()
	full.text = "Fullscreen"
	full.button_pressed = DisplaySettings.get_fullscreen()
	full.toggled.connect(DisplaySettings.set_fullscreen)
	row.add_child(full)

	body.add_child(UiKit.detail("Screen %d×%d. UI scale sizes everything, Text size only the letters. 800×480: UI 100%%, Text 200%%." % [screen.x, screen.y]))


func _on_text_size_picked(index: int) -> void:
	DisplaySettings.set_text_scale(DisplaySettings.TEXT_SCALES[index])
	# Headings set their own size, so every tab builds them again.
	for page in get_parent().get_children():
		if page.has_method("_rebuild"):
			page._rebuild.call_deferred()


# ---------------------------------------------------------------- audio

## A volume slider per audio bus, plus quick sound checks.
func _build_audio() -> void:
	var tests: Array[Control] = [
		UiKit.button("Test sound", func() -> void: Media.play_sfx(TEST_SOUND), UiKit.TEST),
		UiKit.button("Test music", _toggle_test_music, UiKit.TEST),
	]
	var body := UiKit.section(_list, "Audio", tests)
	var grid := GridContainer.new()   # label | slider | percent, one line per bus
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 12)
	body.add_child(grid)
	for bus in Media.BUSES:
		var label := Label.new()
		label.text = String(bus)
		grid.add_child(label)
		var slider := HSlider.new()
		slider.min_value = 0
		slider.max_value = 100
		slider.step = 5
		slider.value = roundf(Media.get_volume(bus) * 100.0)
		slider.size_flags_horizontal = SIZE_EXPAND_FILL
		slider.size_flags_vertical = SIZE_SHRINK_CENTER
		slider.custom_minimum_size = Vector2(240, 40)   # tall enough to grab with a finger
		grid.add_child(slider)
		var percent := Label.new()
		percent.text = "%d%%" % slider.value
		percent.custom_minimum_size.x = 90
		grid.add_child(percent)
		slider.value_changed.connect(func(v: float) -> void:
			Media.set_volume(bus, v / 100.0)
			percent.text = "%d%%" % v)


## Test music, each press: loop A, crossfade to loop B, fade out.
func _toggle_test_music() -> void:
	match Media.current_music():
		TEST_MUSIC_A:
			Media.play_music(TEST_MUSIC_B, 1.5)
		TEST_MUSIC_B:
			Media.stop_music(1.5)
		_:
			Media.play_music(TEST_MUSIC_A, 1.5)


# ---------------------------------------------------------------- media library

## What's in assets/ on this machine, with players for music and cutscenes.
func _build_media() -> void:
	var head: Array[Control] = [UiKit.button("Rescan", _rescan)]
	var body := UiKit.section(_list, "Media", head)

	_music_pick = _picker(Media.list_music(), "(no music)")
	var music_row := _flow()
	music_row.add_child(_label("Music"))
	music_row.add_child(_music_pick)
	var play_music := UiKit.button("Play", func() -> void: Media.play_music(_picked(_music_pick), 1.0), UiKit.TEST)
	play_music.disabled = _music_pick.disabled
	music_row.add_child(play_music)
	music_row.add_child(UiKit.button("Stop", func() -> void: Media.stop_music(1.0)))
	body.add_child(music_row)

	_video_pick = _picker(Media.list_videos(), "(no videos)")
	var video_row := _flow()
	video_row.add_child(_label("Video"))
	video_row.add_child(_video_pick)
	var play_video := UiKit.button("Play", func() -> void: Media.play_video(_picked(_video_pick), true, true), UiKit.TEST)
	play_video.disabled = _video_pick.disabled
	video_row.add_child(play_video)
	body.add_child(video_row)
	body.add_child(UiKit.detail("A video plays full screen on top of this menu; tap it to stop early. Try a real clip on the Pi before making lots of cutscenes (Docs/audio-video.md)."))

	_show_pick = _picker(Shows.list_shows(), "(no shows)")
	var show_row := _flow()
	show_row.add_child(_label("Show"))
	show_row.add_child(_show_pick)
	var play_show := UiKit.button("Play", func() -> void: Shows.play_show(_picked(_show_pick)), UiKit.TEST)
	play_show.disabled = _show_pick.disabled
	show_row.add_child(play_show)
	show_row.add_child(UiKit.button("Stop", func() -> void:
		Shows.stop_show()
		Media.stop_music(1.0)))
	body.add_child(show_row)
	body.add_child(UiKit.detail("A light show plays with its song (same name). Watch the lights, or the Lights LEDs on the Monitor tab."))

	# Light sync offset: lights later (+) or earlier (-) than the sound.
	var offset_row := HBoxContainer.new()
	offset_row.add_theme_constant_override("separation", 12)
	offset_row.add_child(_label("Light sync"))
	var slider := HSlider.new()
	slider.min_value = -Shows.MAX_SYNC_OFFSET_MS
	slider.max_value = Shows.MAX_SYNC_OFFSET_MS
	slider.step = 10
	slider.value = Shows.sync_offset_ms
	slider.size_flags_horizontal = SIZE_EXPAND_FILL
	slider.size_flags_vertical = SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(200, 40)
	offset_row.add_child(slider)
	var ms_label := Label.new()
	ms_label.text = "%+d ms" % slider.value
	ms_label.custom_minimum_size.x = 110
	offset_row.add_child(ms_label)
	slider.value_changed.connect(func(v: float) -> void:
		Shows.set_sync_offset(int(v))
		ms_label.text = "%+d ms" % v)
	body.add_child(offset_row)
	body.add_child(UiKit.detail("If the lights run ahead of the music, move it right (later); behind, move it left."))

	body.add_child(UiKit.detail("%d sounds, %d songs, %d videos, %d light shows in %s. Media isn't in git: it syncs from the PC (see assets/README.md), then tap Rescan." % [
			Media.list_sounds().size(), Media.list_music().size(), Media.list_videos().size(),
			Shows.list_shows().size(), ProjectSettings.globalize_path("res://assets")]))


func _rescan() -> void:
	Media.rescan()
	Shows.rescan()
	_rebuild()


func _picker(names: Array[StringName], empty_text: String) -> OptionButton:
	var pick := OptionButton.new()
	pick.custom_minimum_size.x = 240
	for n in names:
		pick.add_item(String(n))
		pick.set_item_metadata(pick.item_count - 1, n)
	if names.is_empty():
		pick.add_item(empty_text)
		pick.set_item_metadata(0, &"")
		pick.disabled = true
	return pick


func _picked(pick: OptionButton) -> StringName:
	return pick.get_item_metadata(pick.selected) if pick.selected >= 0 else &""


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size.x = 90
	return l


func _flow() -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", 12)
	f.add_theme_constant_override("v_separation", 8)
	return f

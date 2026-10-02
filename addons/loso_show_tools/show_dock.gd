@tool
extends VBoxContainer
## ShowDock — the "Light Show" dock in the Godot editor (addons/loso_show_tools).
##
## Open a light show scene (assets/shows/<name>.tscn) and pick its "show"
## animation in the Animation panel. Then this dock has one row per light,
## showing (and editing) what that light does at the playhead:
##   * a swatch, and the time of the key it's following ("key at 1.00 s")
##   * effect, color, color 2 and speed fields: changing one edits that key,
##     with undo (or adds a key at the playhead if the light has none yet)
##   * "+" adds a new key at the playhead (a copy, ready to change), and
##     "✕" deletes the key the light is following
## With "Send to game" on, every change also goes to the running game over UDP,
## so the real LEDs follow while you play, scrub or edit (the game needs
## "Show preview" on, in Service > Audio & Video).
##
## Godot doesn't call Call Method keys while you preview in the editor, so this
## reads the keys itself (ShowCues) and works out each light's cue at the playhead.

const SETTINGS_SECTION := "loso_show_tools"
const LIGHT_SHOW_SCRIPT := "res://media/light_show.gd"
const PING_EVERY_MS := 1000
const ANSWER_TIMEOUT_MS := 3000      ## no PONG for this long = the game isn't listening
const REREAD_EVERY_MS := 500         ## re-read the keys this often too, in case a change was missed
const OFF_COLOR := Color(0.12, 0.12, 0.14)
const AT_KEY := 0.0005               ## the playhead counts as "on" a key this close to it (seconds)

## The editor's undo history (set by plugin.gd). Null in tests: changes apply directly.
var undo_redo: EditorUndoRedoManager

var _show: Node                  ## the LightShow scene root being edited, or null
var _player: AnimationPlayer
var _anim: Animation
var _cues: Array[Dictionary] = []
var _cues_dirty := true
var _reread_ms := 0

var _udp := PacketPeerUDP.new()
var _host := "127.0.0.1"
## The game's show-preview UDP port. Tests change it, so they don't clash with a running game.
var port := ShowCues.PREVIEW_PORT
var _address := ""               ## _host resolved to an IP, "" = couldn't
var _live := false
var _next_ping_ms := 0
var _last_answer_ms := -ANSWER_TIMEOUT_MS
var _game_lights: PackedStringArray = []   ## from the game's PONG
var _sent := {}                  ## light -> cue_id last sent to the game
var _shown := {}                 ## light -> cue_id shown in its row

# UI
var _status: Label
var _live_box: CheckBox
var _host_edit: LineEdit
var _link_label: Label
var _rows_box: VBoxContainer
var _rows := {}                  ## light -> LightRow
var _row_names: Array[StringName] = []


## The controls of one light's row.
class LightRow:
	var swatch: TextureRect
	var at: Label                ## "key at 1.00 s" / "no key yet"
	var effect: OptionButton
	var color1: ColorPickerButton
	var color2: ColorPickerButton
	var ms: SpinBox
	var add: Button
	var delete: Button


func _ready() -> void:
	_build_ui()
	var settings := _editor_settings()
	if settings:
		_host = settings.get_project_metadata(SETTINGS_SECTION, "host", _host)
		_host_edit.text = _host
	_resolve_host()
	_udp.bind(0)   # any free port, so the game's PONG has somewhere to come back to
	_refresh_rows()


func _exit_tree() -> void:
	_udp.close()


# ---------------------------------------------------------------- what's being edited

## The scene being edited changed (plugin.gd connects EditorPlugin.scene_changed).
func set_show(scene_root: Node) -> void:
	if _anim and _anim.changed.is_connected(_mark_dirty):
		_anim.changed.disconnect(_mark_dirty)
	if _live and _show != null and scene_root != _show:
		_send("OFF")   # leaving a show: don't leave its lights on
	_show = null
	_player = null
	_anim = null
	if scene_root and scene_root.get_script() and (scene_root.get_script() as Script).resource_path == LIGHT_SHOW_SCRIPT:
		_show = scene_root
		for child in scene_root.get_children():
			if child is AnimationPlayer and (child as AnimationPlayer).has_animation(ShowCues.ANIMATION_NAME):
				_player = child
				_anim = _player.get_animation(ShowCues.ANIMATION_NAME)
				_anim.changed.connect(_mark_dirty)
				break
	_cues = ShowCues.read(_anim)
	_cues_dirty = false
	_sent.clear()
	_refresh_rows()


func _mark_dirty() -> void:
	_cues_dirty = true


## Seconds into the "show" animation at the editor's playhead, or -1.
func playhead() -> float:
	if _player == null or not is_instance_valid(_player) or _player.assigned_animation != ShowCues.ANIMATION_NAME:
		return -1.0
	return _player.current_animation_position


## Read the keys again if they changed since last time.
func _reread_if_needed() -> void:
	var now := Time.get_ticks_msec()
	if not _cues_dirty and now < _reread_ms:
		return
	_cues = ShowCues.read(_anim)
	_cues_dirty = false
	_reread_ms = now + REREAD_EVERY_MS
	if _light_names() != _row_names:
		_refresh_rows()   # a light was added to (or gone from) the show


# ---------------------------------------------------------------- every frame

func _process(_delta: float) -> void:
	_poll_udp()
	if _show != null and not is_instance_valid(_show):
		set_show(null)
	_reread_if_needed()
	var time := playhead()
	for row: LightRow in _rows.values():
		row.add.disabled = time < 0.0
	if _show == null:
		_status.text = "Open a light show scene (assets/shows/) to preview it."
		return
	if time < 0.0:
		_status.text = "%s: pick the \"show\" animation in the Animation panel." % _show.name
		return
	_status.text = "%s at %.2f s, %d cues" % [_show.scene_file_path.get_file().get_basename(), time, _cues.size()]
	_apply_state(ShowCues.state_at(_cues, time), time)


## Bring the rows (and the game, when live) to the lights' state at the playhead.
func _apply_state(state: Dictionary, time: float) -> void:
	for light: StringName in _rows:
		var cue: Dictionary = state.get(light, {})
		var id := ShowCues.cue_id(cue)
		if _shown.get(light, "") != id:
			_shown[light] = id
			_show_cue(light, cue)
		var row: LightRow = _rows[light]
		row.delete.disabled = cue.is_empty()
		if not cue.is_empty():
			var on_key: bool = absf(cue["time"] - time) < AT_KEY
			row.at.text = "key here" if on_key else "key at %.2f s" % cue["time"]
		if _live and _game_answering() and _sent.get(light, "") != id:
			if _send(ShowCues.fx_line(light, cue)):
				_sent[light] = id


# ---------------------------------------------------------------- the link to the game

func _poll_udp() -> void:
	var now := Time.get_ticks_msec()
	while _udp.get_available_packet_count() > 0:
		var words := _udp.get_packet().get_string_from_utf8().strip_edges().split(" ", false)
		if words.size() >= 1 and words[0] == "PONG":
			if not _game_answering():
				_sent.clear()   # the game (re)appeared: send every light again
			_last_answer_ms = now
			words.remove_at(0)
			if words != _game_lights:
				_game_lights = words
				_refresh_rows()
	if _live and now >= _next_ping_ms:
		_next_ping_ms = now + PING_EVERY_MS
		_send("PING")
	if _link_label:
		if not _live:
			_link_label.text = "Off. The game needs Service > Audio & Video > Show preview on."
		elif _address == "":
			_link_label.text = "Can't find '%s'. Use the game machine's IP (it's on its Audio & Video tab)." % _host
		elif _game_answering():
			_link_label.text = "Game answering at %s: %d lights." % [_address, _game_lights.size()]
		else:
			_link_label.text = "No answer from %s:%d. Is the game running with Show preview on?" % [_address, port]


func _game_answering() -> bool:
	return Time.get_ticks_msec() - _last_answer_ms < ANSWER_TIMEOUT_MS


func _send(line: String) -> bool:
	if _address == "":
		return false
	_udp.set_dest_address(_address, port)
	return _udp.put_packet(line.to_utf8_buffer()) == OK


## Turn "Send to game" on or off (the checkbox; tests call it directly).
func set_live(on: bool) -> void:
	_live = on
	if _live_box and _live_box.button_pressed != on:
		_live_box.set_pressed_no_signal(on)
	_sent.clear()
	_next_ping_ms = 0
	if not on:
		_send("OFF")


## Where the game runs: 127.0.0.1 (this PC), or the Pi's IP or name.
func set_host(host: String) -> void:
	_host = host.strip_edges()
	if _host_edit and _host_edit.text != _host:
		_host_edit.text = _host
	var settings := _editor_settings()
	if settings:
		settings.set_project_metadata(SETTINGS_SECTION, "host", _host)
	_resolve_host()
	_last_answer_ms = -ANSWER_TIMEOUT_MS
	_sent.clear()
	_next_ping_ms = 0


func _resolve_host() -> void:
	_address = _host if _host.is_valid_ip_address() else IP.resolve_hostname(_host, IP.TYPE_IPV4)


# ---------------------------------------------------------------- editing keys

## Add (or replace) a cue on a light's track at a time, with undo when in the editor.
func add_cue(time: float, light: StringName, effect: String, color: Color, ms: int, color2: Color) -> void:
	if _anim == null or light == &"":
		return
	var key := ShowCues.cue_key(light, effect, color, ms, color2)
	var track := ShowCues.track_for_light(_anim, light)
	if track < 0:
		# A new Call Method track on the LightShow node for this light.
		track = _anim.get_track_count()
		var path := _player.get_node(_player.root_node).get_path_to(_show)
		_do([["add_track", Animation.TYPE_METHOD, track], ["track_set_path", track, path],
				["track_insert_key", track, time, key]],
				[["remove_track", track]], "Add light cue (new track for %s)" % light)
	else:
		var old := _anim.track_find_key(track, time, Animation.FIND_MODE_APPROX)
		var undo: Array = [["track_remove_key_at_time", track, time]]
		if old >= 0:   # a key at this moment already: it gets replaced, undo puts it back
			undo = [["track_insert_key", track, _anim.track_get_key_time(track, old), _anim.track_get_key_value(track, old)]]
		_do([["track_insert_key", track, time, key]], undo, "Add light cue for %s" % light)
	_cues_dirty = true


## Change the key a light follows at the playhead (or add one at the playhead
## if it has none yet). Several changes in a row (dragging a color) are one undo step.
func edit_at_playhead(light: StringName, effect: String, color: Color, ms: int, color2: Color) -> void:
	var time := playhead()
	if _anim == null or time < 0.0:
		return
	_reread_if_needed()
	var cue: Dictionary = ShowCues.state_at(_cues, time).get(light, {})
	if cue.is_empty():
		# No key yet: the first change makes one. Its effect still reads OFF if
		# a color or speed was changed first, which would light nothing.
		add_cue(time, light, "SOLID" if effect == "OFF" else effect, color, ms, color2)
		return
	var track: int = cue["track"]
	var index := _anim.track_find_key(track, cue["time"], Animation.FIND_MODE_APPROX)
	if index < 0:
		return
	var value := ShowCues.cue_key(light, effect, color, ms, color2)
	_do([["track_set_key_value", track, index, value]],
			[["track_set_key_value", track, index, _anim.track_get_key_value(track, index)]],
			"Edit light cue for %s at %.2f s" % [light, cue["time"]], true)
	_cues_dirty = true


## Delete the key a light follows at the playhead.
func delete_at_playhead(light: StringName) -> void:
	var time := playhead()
	if _anim == null or time < 0.0:
		return
	_reread_if_needed()
	var cue: Dictionary = ShowCues.state_at(_cues, time).get(light, {})
	if cue.is_empty():
		return
	var track: int = cue["track"]
	var index := _anim.track_find_key(track, cue["time"], Animation.FIND_MODE_APPROX)
	if index < 0:
		return
	_do([["track_remove_key", track, index]],
			[["track_insert_key", track, _anim.track_get_key_time(track, index), _anim.track_get_key_value(track, index)]],
			"Delete light cue for %s at %.2f s" % [light, cue["time"]])
	_cues_dirty = true


## Run Animation calls through the editor's undo history (or directly in tests).
## merge = repeated actions with the same name become one undo step.
func _do(do_calls: Array, undo_calls: Array, action: String, merge := false) -> void:
	if undo_redo == null:
		for c: Array in do_calls:
			_anim.callv(c[0], c.slice(1))
		return
	undo_redo.create_action(action, UndoRedo.MERGE_ENDS if merge else UndoRedo.MERGE_DISABLE)
	for c: Array in do_calls:   # add_do_method(object, method, args...)
		undo_redo.add_do_method.callv([_anim] + c)
	for c: Array in undo_calls:
		undo_redo.add_undo_method.callv([_anim] + c)
	undo_redo.commit_action()


## A row's field changed: edit the key it follows.
func _on_row_changed(_value: Variant, light: StringName) -> void:
	var row: LightRow = _rows[light]
	edit_at_playhead(light, IoDefs.EFFECTS[maxi(row.effect.selected, 0)], row.color1.color,
			int(row.ms.value), row.color2.color)


## "+": a new key at the playhead with the row's settings, ready to change.
func _on_row_add(light: StringName) -> void:
	var time := playhead()
	if time < 0.0:
		return
	var row: LightRow = _rows[light]
	var effect: String = IoDefs.EFFECTS[maxi(row.effect.selected, 0)]
	if effect == "OFF":
		effect = "SOLID"   # a new key that does nothing isn't much use
	add_cue(time, light, effect, row.color1.color, int(row.ms.value), row.color2.color)


# ---------------------------------------------------------------- the light rows

## Light names: the game's (when it answers), else this PC's machine config,
## plus any light already used in the show.
func _light_names() -> Array[StringName]:
	var names: Array[StringName] = []
	var source: PackedStringArray = _game_lights if not _game_lights.is_empty() else _config_light_names()
	for n in source:
		if not names.has(StringName(n)):
			names.append(StringName(n))
	for cue in _cues:
		if not names.has(cue["light"]):
			names.append(cue["light"])
	return names


func _config_light_names() -> PackedStringArray:
	var path := "user://machine_config.json"
	if not FileAccess.file_exists(path):
		path = "res://config/machine_config.default.json"
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var names := PackedStringArray()
	if data is Dictionary:
		for l: Variant in (data as Dictionary).get("lights", []):
			if l is Dictionary and (l as Dictionary).has("name"):
				names.append(str(l["name"]))
	return names


## Build one row per light.
func _refresh_rows() -> void:
	if _rows_box == null:
		return
	_row_names = _light_names()
	for child in _rows_box.get_children():
		child.queue_free()
	_rows.clear()
	_shown.clear()
	for n in _row_names:
		_rows_box.add_child(_make_row(n))
		_show_cue(n, {})
	var not_on_game: Array[String] = []
	if not _game_lights.is_empty():
		for n in _row_names:
			if not _game_lights.has(String(n)):
				not_on_game.append(String(n))
	if not not_on_game.is_empty():
		var warn := Label.new()
		warn.text = "Not on the game machine: " + ", ".join(not_on_game)
		warn.modulate = Color(1, 0.6, 0.5)
		warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_rows_box.add_child(warn)


func _make_row(light: StringName) -> Control:
	var row := LightRow.new()
	_rows[light] = row
	var panel := PanelContainer.new()   # a box around each light
	var lines := VBoxContainer.new()
	panel.add_child(lines)

	# Line 1: swatch, name, which key, + and ✕.
	var top := HBoxContainer.new()
	lines.add_child(top)
	row.swatch = TextureRect.new()
	row.swatch.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	row.swatch.custom_minimum_size = Vector2(20, 20)
	top.add_child(row.swatch)
	var name_label := Label.new()
	name_label.text = String(light)
	name_label.size_flags_horizontal = SIZE_EXPAND_FILL
	name_label.clip_text = true
	top.add_child(name_label)
	row.at = Label.new()
	row.at.modulate = Color(1, 1, 1, 0.6)
	top.add_child(row.at)
	row.add = Button.new()
	row.add.text = "+"
	row.add.tooltip_text = "New key at the playhead (a copy of these settings)"
	row.add.pressed.connect(_on_row_add.bind(light))
	top.add_child(row.add)
	row.delete = Button.new()
	row.delete.text = "✕"
	row.delete.tooltip_text = "Delete the key this light is following"
	row.delete.pressed.connect(delete_at_playhead.bind(light))
	top.add_child(row.delete)

	# Line 2: effect, colors, speed. Changing any edits the key.
	var fields := HBoxContainer.new()
	lines.add_child(fields)
	row.effect = OptionButton.new()
	for effect in IoDefs.EFFECTS:
		row.effect.add_item(effect)
		row.effect.set_item_tooltip(row.effect.item_count - 1, IoDefs.EFFECT_HELP.get(effect, ""))
	row.effect.size_flags_horizontal = SIZE_EXPAND_FILL
	row.effect.fit_to_longest_item = false
	row.effect.item_selected.connect(_on_row_changed.bind(light))
	fields.add_child(row.effect)
	row.color1 = _color_button("Color")
	row.color1.color_changed.connect(_on_row_changed.bind(light))
	fields.add_child(row.color1)
	row.color2 = _color_button("Color 2 (BLINK, CHASE, WIPE, SPARKLE background)")
	row.color2.color_changed.connect(_on_row_changed.bind(light))
	fields.add_child(row.color2)
	row.ms = SpinBox.new()
	row.ms.min_value = 1
	row.ms.max_value = 600000
	row.ms.step = 1   # any ms; the arrows still move 50 at a time
	row.ms.custom_arrow_step = 50
	row.ms.tooltip_text = "Speed in ms: the period, or the duration for FADE and WIPE"
	row.ms.custom_minimum_size.x = 76
	row.ms.value_changed.connect(_on_row_changed.bind(light))
	fields.add_child(row.ms)
	return panel


## Show a light's cue in its row: swatch, and the fields (without firing edits).
func _show_cue(light: StringName, cue: Dictionary) -> void:
	var row: LightRow = _rows.get(light)
	if row == null:
		return
	var effect: String = cue.get("effect", "OFF")
	var image := Image.create(18, 18, false, Image.FORMAT_RGBA8)
	image.fill(OFF_COLOR if effect == "OFF" else cue["color"])
	if effect == "RAINBOW":   # stripes of hue, since its color isn't a setting
		for x in 18:
			for y in 18:
				image.set_pixel(x, y, Color.from_hsv(x / 18.0, 0.9, 1.0))
	row.swatch.texture = ImageTexture.create_from_image(image)
	if cue.is_empty():
		row.at.text = "no key yet"
		row.effect.select(IoDefs.EFFECTS.find("OFF"))
		return
	row.effect.select(maxi(IoDefs.EFFECTS.find(cue["effect"]), 0))   # select() doesn't fire item_selected
	if not row.color1.color.is_equal_approx(cue["color"]):
		row.color1.color = cue["color"]       # setting it doesn't fire color_changed
	if not row.color2.color.is_equal_approx(cue["color2"]):
		row.color2.color = cue["color2"]
	row.ms.set_value_no_signal(cue["ms"])


# ---------------------------------------------------------------- UI

func _build_ui() -> void:
	name = "Light Show"
	add_theme_constant_override("separation", 8)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	add_child(_heading("Send to game"))
	_live_box = CheckBox.new()
	_live_box.text = "Send to game (real LEDs)"
	_live_box.toggled.connect(set_live)
	add_child(_live_box)
	var host_row := HBoxContainer.new()
	var host_label := Label.new()
	host_label.text = "Game at"
	host_row.add_child(host_label)
	_host_edit = LineEdit.new()
	_host_edit.text = _host
	_host_edit.placeholder_text = "127.0.0.1 or the Pi's IP"
	_host_edit.size_flags_horizontal = SIZE_EXPAND_FILL
	_host_edit.text_submitted.connect(set_host)
	_host_edit.focus_exited.connect(func() -> void:
		if _host_edit.text.strip_edges() != _host:
			set_host(_host_edit.text))
	host_row.add_child(_host_edit)
	var resend := Button.new()
	resend.text = "Resend"
	resend.tooltip_text = "Send every light's cue at the playhead again"
	resend.pressed.connect(func() -> void: _sent.clear())
	host_row.add_child(resend)
	add_child(host_row)
	_link_label = Label.new()
	_link_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_link_label.modulate = Color(1, 1, 1, 0.7)
	add_child(_link_label)

	add_child(_heading("Lights at the playhead"))
	_rows_box = VBoxContainer.new()
	add_child(_rows_box)

	var help := Label.new()
	help.text = "Each row shows the key a light follows at the playhead. Change its effect, colors or speed to edit that key (a light with no key yet gets one at the playhead). + adds a new key at the playhead, ✕ deletes the key. Ctrl+Z undoes. Move keys on the Animation timeline as usual."
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.modulate = Color(1, 1, 1, 0.6)
	add_child(help)


func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.3, 0.9, 1.0))
	return l


func _color_button(tip: String) -> ColorPickerButton:
	var b := ColorPickerButton.new()
	b.edit_alpha = false
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(30, 24)
	return b


func _editor_settings() -> EditorSettings:
	return EditorInterface.get_editor_settings() if Engine.is_editor_hint() else null

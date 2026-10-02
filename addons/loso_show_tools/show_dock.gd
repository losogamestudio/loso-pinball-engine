@tool
extends VBoxContainer
## ShowDock — the "Light Show" dock in the Godot editor (addons/loso_show_tools).
##
## Open a show scene (assets/shows/<name>.tscn) and pick its "show" animation
## in the Animation panel. Then this dock has one row per light, servo and
## coil, showing (and editing) the key each one follows at the playhead:
##   * lights: swatch, effect, color, color 2, speed
##   * servos: position (0..100 %), ramp time, Linear / Smooth
##   * coils:  pulse ms (0 = the coil's own), power %, and Fire to try it
##   * changing a field edits that key, with undo (or adds a key at the
##     playhead if there's none yet); "+" adds a new key at the playhead (a copy,
##     ready to change), "✕" deletes the key, the name field renames them all
## With "Send to game" on, changes also go to the running game over UDP, so the
## real hardware follows while you play, scrub or edit (the game needs "Show
## preview" on, in Service > Audio & Video). Lights and servos follow the
## playhead, scrubbing too. Coils only pulse while the editor PLAYS across
## their keys, and only with "Fire coils" ticked: they're real solenoids.
##
## Godot doesn't call Call Method keys while you preview in the editor, so this
## reads the keys itself (ShowCues) and works out what each one does at the playhead.

const SETTINGS_SECTION := "loso_show_tools"
const LIGHT_SHOW_SCRIPT := "res://media/light_show.gd"
const PING_EVERY_MS := 1000
const ANSWER_TIMEOUT_MS := 3000      ## no PONG for this long = the game isn't listening
const REREAD_EVERY_MS := 500         ## re-read the keys this often too, in case a change was missed
const OFF_COLOR := Color(0.12, 0.12, 0.14)
const AT_KEY := 0.0005               ## the playhead counts as "on" a key this close to it (seconds)
const MAX_PLAY_STEP := 0.5           ## a bigger playhead jump while playing is a seek: no coil pulses
const SECTION_TITLES := {&"light": "Lights", &"servo": "Servos", &"coil": "Coils"}

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
var _fire_coils := false         ## send coil pulses while playing (never saved: real solenoids)
var _next_ping_ms := 0
var _last_answer_ms := -ANSWER_TIMEOUT_MS
var _game_names := {}            ## type -> PackedStringArray, from the game's PONG
var _sent := {}                  ## row key -> cue_id last sent to the game
var _shown := {}                 ## row key -> cue_id shown in its row
var _last_play_time := -1.0      ## playhead last frame while playing, for coil pulses; -1 = not playing

# UI
var _status: Label
var _live_box: CheckBox
var _coils_box: CheckBox
var _host_edit: LineEdit
var _link_label: Label
var _rows_box: VBoxContainer
var _key_all: Button
var _rows := {}                  ## row key ("light:playfield") -> CueRow
var _row_keys: Array[String] = []


## The controls of one row. Which fields exist depends on the type.
class CueRow:
	var type: StringName
	var target: StringName
	var name_edit: LineEdit      ## the name in its keys (arg 0); edit to rename
	var at: Label                ## "@1.00 s" / "here" / "no key"
	var add: Button
	var delete: Button
	# lights
	var swatch: TextureRect
	var effect: OptionButton
	var color1: ColorPickerButton
	var color2: ColorPickerButton
	var ms: SpinBox              ## lights: speed; coils: pulse ms
	# servos
	var position: HSlider
	var position_label: Label    ## the slider's value, "80%"
	var ramp: SpinBox
	var ease: OptionButton
	# coils
	var power: SpinBox
	var fire: Button


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


static func row_key(type: StringName, target: StringName) -> String:
	return "%s:%s" % [type, target]


## Is there a row for this light / servo / coil? (For tests.)
func has_row(type: StringName, target: StringName) -> bool:
	return _rows.has(row_key(type, target))


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
	_last_play_time = -1.0
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
	if _wanted_row_keys() != _row_keys:
		_refresh_rows()   # something was added to (or gone from) the show


# ---------------------------------------------------------------- every frame

func _process(_delta: float) -> void:
	_poll_udp()
	if _show != null and not is_instance_valid(_show):
		set_show(null)
	_reread_if_needed()
	var time := playhead()
	for row: CueRow in _rows.values():
		row.add.disabled = time < 0.0
	if _key_all:
		_key_all.disabled = time < 0.0
	if _show == null:
		_status.text = "Open a show scene (assets/shows/) to preview it."
		return
	if time < 0.0:
		_status.text = "%s: pick the \"show\" animation in the Animation panel." % _show.name
		return
	_status.text = "%s at %.2f s, %d cues" % [_show.scene_file_path.get_file().get_basename(), time, _cues.size()]
	_apply_state(time)
	_play_coils(time, _player.is_playing())


## Bring the rows (and the game, when live) to the state at the playhead.
func _apply_state(time: float) -> void:
	var states := {}
	for type in ShowCues.TYPES:
		states[type] = ShowCues.state_at(_cues, time, type)
	for key: String in _rows:
		var row: CueRow = _rows[key]
		var cue: Dictionary = (states[row.type] as Dictionary).get(row.target, {})
		var id := ShowCues.cue_id(cue)
		if _shown.get(key, "") != id:
			_shown[key] = id
			_show_cue(row, cue)
		row.delete.disabled = cue.is_empty()
		if not cue.is_empty():
			row.at.text = "here" if absf(cue["time"] - time) < AT_KEY else "@%.2f s" % cue["time"]
		# Lights and servos follow the playhead in the game. (A light with no
		# key yet is off; a servo with none just stays where it is. Coils are
		# pulses: see _play_coils.)
		if row.type == ShowCues.TYPE_COIL or not _live or not _game_answering() or _sent.get(key, "") == id:
			continue
		if row.type == ShowCues.TYPE_SERVO and cue.is_empty():
			continue
		var line := ShowCues.fx_line(row.target, cue) if row.type == ShowCues.TYPE_LIGHT else ShowCues.preview_line(cue)
		if _send(line):
			_sent[key] = id


## While the editor plays, pulse the coils whose keys the playhead just passed
## (with "Fire coils" on). Never while scrubbing or after a jump.
func _play_coils(time: float, playing: bool) -> void:
	if not playing:
		_last_play_time = -1.0
		return
	var last := _last_play_time
	_last_play_time = time
	if last < 0.0 or not (_live and _fire_coils and _game_answering()):
		return
	var crossed: Array[Dictionary] = []
	if time >= last:
		if time - last <= MAX_PLAY_STEP:
			crossed = ShowCues.events_between(_cues, last, time)
	elif _anim.loop_mode != Animation.LOOP_NONE and _anim.length - last + time <= MAX_PLAY_STEP:
		crossed = ShowCues.events_between(_cues, last, _anim.length)   # it looped: the end, then the start
		crossed.append_array(ShowCues.events_between(_cues, -1.0, time))
	for cue in crossed:
		_send(ShowCues.preview_line(cue))


# ---------------------------------------------------------------- the link to the game

func _poll_udp() -> void:
	var now := Time.get_ticks_msec()
	while _udp.get_available_packet_count() > 0:
		var line := _udp.get_packet().get_string_from_utf8().strip_edges()
		if line.begins_with("PONG"):
			if not _game_answering():
				_sent.clear()   # the game (re)appeared: send everything again
			_last_answer_ms = now
			var names := ShowCues.parse_pong(line)
			if names != _game_names:
				_game_names = names
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
			_link_label.text = "Game answering at %s: %d lights, %d servos, %d coils." % [_address,
					_game_list(ShowCues.TYPE_LIGHT).size(), _game_list(ShowCues.TYPE_SERVO).size(), _game_list(ShowCues.TYPE_COIL).size()]
		else:
			_link_label.text = "No answer from %s:%d. Is the game running with Show preview on?" % [_address, port]


func _game_answering() -> bool:
	return Time.get_ticks_msec() - _last_answer_ms < ANSWER_TIMEOUT_MS


func _game_list(type: StringName) -> PackedStringArray:
	return _game_names.get(type, PackedStringArray())


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


## Pulse coils while playing (the "Fire coils" checkbox; tests call it directly).
func set_fire_coils(on: bool) -> void:
	_fire_coils = on
	if _coils_box and _coils_box.button_pressed != on:
		_coils_box.set_pressed_no_signal(on)


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

## Add (or replace) a key at a time on its target's track (a new Call Method
## track if it has none), with undo when in the editor. [param cue] has the
## fields ShowCues.read() gives: type, target and that type's settings.
func add_key(time: float, cue: Dictionary) -> void:
	var target: StringName = cue["target"]
	if _anim == null or target == &"":
		return
	var key := ShowCues.key_for(cue)
	var track := ShowCues.track_for(_anim, cue["type"], target)
	if track < 0:
		# A new Call Method track on the LightShow node for it.
		track = _anim.get_track_count()
		var path := _player.get_node(_player.root_node).get_path_to(_show)
		_do([["add_track", Animation.TYPE_METHOD, track], ["track_set_path", track, path],
				["track_insert_key", track, time, key]],
				[["remove_track", track]], "Add %s cue (new track for %s)" % [cue["type"], target])
	else:
		var old := _anim.track_find_key(track, time, Animation.FIND_MODE_APPROX)
		var undo: Array = [["track_remove_key_at_time", track, time]]
		if old >= 0:   # a key at this moment already: it gets replaced, undo puts it back
			undo = [["track_insert_key", track, _anim.track_get_key_time(track, old), _anim.track_get_key_value(track, old)]]
		_do([["track_insert_key", track, time, key]], undo, "Add %s cue for %s" % [cue["type"], target])
	_cues_dirty = true


## Add (or replace) a light cue at a time.
func add_cue(time: float, light: StringName, effect: String, color: Color, ms: int, color2: Color) -> void:
	add_key(time, {"type": ShowCues.TYPE_LIGHT, "target": light, "effect": effect, "color": color, "ms": ms, "color2": color2})


## "Key all": a new key at the playhead for every light and servo that's
## following a key, with the settings it has now (so nothing changes yet,
## ready to edit). Ones already on a key here, or with no key yet, are left
## alone; coils too (they're pulses, not states). One undo step.
func key_all_at_playhead() -> void:
	var time := playhead()
	if _anim == null or time < 0.0:
		return
	_reread_if_needed()
	var do_calls: Array = []
	var undo_calls: Array = []
	for type in [ShowCues.TYPE_LIGHT, ShowCues.TYPE_SERVO]:
		var state := ShowCues.state_at(_cues, time, type)
		for target: StringName in state:
			var cue: Dictionary = state[target]
			if absf(cue["time"] - time) < AT_KEY:
				continue   # already has a key here
			var track: int = cue["track"]   # the track its current key is on
			do_calls.append(["track_insert_key", track, time, ShowCues.key_for(cue)])
			undo_calls.append(["track_remove_key_at_time", track, time])
	if do_calls.is_empty():
		return
	_do(do_calls, undo_calls, "Key all at %.2f s" % time)
	_cues_dirty = true


## Change the key a target follows at the playhead to [param cue]'s settings
## (or add one at the playhead if it has none yet). Several changes in a row
## (dragging a color or a slider) are one undo step.
func edit_key_at_playhead(cue: Dictionary) -> void:
	var time := playhead()
	if _anim == null or time < 0.0:
		return
	_reread_if_needed()
	var current: Dictionary = ShowCues.state_at(_cues, time, cue["type"]).get(cue["target"], {})
	if current.is_empty():
		add_key(time, cue)
		return
	var track: int = current["track"]
	var index := _anim.track_find_key(track, current["time"], Animation.FIND_MODE_APPROX)
	if index < 0:
		return
	_do([["track_set_key_value", track, index, ShowCues.key_for(cue)]],
			[["track_set_key_value", track, index, _anim.track_get_key_value(track, index)]],
			"Edit %s cue for %s at %.2f s" % [cue["type"], cue["target"], current["time"]], true)
	_cues_dirty = true


## Edit (or add) the light key at the playhead.
func edit_at_playhead(light: StringName, effect: String, color: Color, ms: int, color2: Color) -> void:
	# No key yet: the first change makes one. Its effect still reads OFF if a
	# color or speed was changed first, which would light nothing.
	_reread_if_needed()
	if ShowCues.state_at(_cues, maxf(playhead(), 0.0)).get(light, {}).is_empty() and effect == "OFF":
		effect = "SOLID"
	edit_key_at_playhead({"type": ShowCues.TYPE_LIGHT, "target": light, "effect": effect, "color": color,
			"ms": ms, "color2": color2})


## Edit (or add) the servo key at the playhead.
func edit_servo_at_playhead(servo: StringName, position: float, ramp_ms: int, ease: String) -> void:
	edit_key_at_playhead({"type": ShowCues.TYPE_SERVO, "target": servo, "position": position,
			"ramp_ms": ramp_ms, "ease": ease})


## Edit (or add) the coil key at (or last before) the playhead.
func edit_coil_at_playhead(coil: StringName, ms: int, power: int) -> void:
	edit_key_at_playhead({"type": ShowCues.TYPE_COIL, "target": coil, "ms": ms, "power": power})


## Delete the key a target follows at the playhead.
func delete_at_playhead(target: StringName, type := ShowCues.TYPE_LIGHT) -> void:
	var time := playhead()
	if _anim == null or time < 0.0:
		return
	_reread_if_needed()
	var cue: Dictionary = ShowCues.state_at(_cues, time, type).get(target, {})
	if cue.is_empty():
		return
	var track: int = cue["track"]
	var index := _anim.track_find_key(track, cue["time"], Animation.FIND_MODE_APPROX)
	if index < 0:
		return
	_do([["track_remove_key", track, index]],
			[["track_insert_key", track, _anim.track_get_key_time(track, index), _anim.track_get_key_value(track, index)]],
			"Delete %s cue for %s at %.2f s" % [type, target, cue["time"]])
	_cues_dirty = true


## Rename a light, servo or coil in the show: every key of [param type] whose
## name (arg 0) is `old` gets `new_name` instead, on every track. One undo step.
func rename(type: StringName, old: StringName, new_name: String) -> void:
	var renamed := StringName(new_name.strip_edges().replace(" ", "_"))   # names have no spaces
	if _anim == null or renamed == &"" or renamed == old:
		return
	var do_calls: Array = []
	var undo_calls: Array = []
	for track in _anim.get_track_count():
		if _anim.track_get_type(track) != Animation.TYPE_METHOD:
			continue
		for key in _anim.track_get_key_count(track):
			if ShowCues.type_of_method(_anim.method_track_get_name(track, key)) != type:
				continue
			var value: Dictionary = _anim.track_get_key_value(track, key)
			var args: Array = value.get("args", [])
			if (StringName(args[0]) if args.size() > 0 else &"") != old:
				continue
			var new_value := value.duplicate(true)
			var new_args: Array = (new_value.get("args", []) as Array).duplicate()
			if new_args.is_empty():
				new_args.append(renamed)
			else:
				new_args[0] = renamed
			new_value["args"] = new_args
			do_calls.append(["track_set_key_value", track, key, new_value])
			undo_calls.append(["track_set_key_value", track, key, value])
	if do_calls.is_empty():
		_refresh_rows()   # nothing to rename (no keys yet): put its name back
		return
	if _live and type == ShowCues.TYPE_LIGHT:
		_send(ShowCues.fx_line(old, {}))   # the old light lets go; the new one gets its cue next frame
	_do(do_calls, undo_calls, "Rename %s %s to %s" % [type, old if old != &"" else &"(no name)", renamed])
	_cues_dirty = true


## Rename a light in the show (all its keys).
func rename_light(old: StringName, new_name: String) -> void:
	rename(ShowCues.TYPE_LIGHT, old, new_name)


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


## What a row's fields say, as cue fields.
func _row_cue(row: CueRow) -> Dictionary:
	match row.type:
		ShowCues.TYPE_SERVO:
			return {"type": row.type, "target": row.target, "position": row.position.value / 100.0,
					"ramp_ms": int(row.ramp.value), "ease": IoDefs.SERVO_EASES[maxi(row.ease.selected, 0)]}
		ShowCues.TYPE_COIL:
			return {"type": row.type, "target": row.target, "ms": int(row.ms.value), "power": int(row.power.value)}
	return {"type": row.type, "target": row.target, "effect": IoDefs.EFFECTS[maxi(row.effect.selected, 0)],
			"color": row.color1.color, "ms": int(row.ms.value), "color2": row.color2.color}


## A row's field changed: edit the key it follows.
func _on_row_changed(_value: Variant, key: String) -> void:
	var row: CueRow = _rows.get(key)
	if row == null:
		return
	var cue := _row_cue(row)
	if row.type == ShowCues.TYPE_LIGHT:
		edit_at_playhead(row.target, cue["effect"], cue["color"], cue["ms"], cue["color2"])
	else:
		edit_key_at_playhead(cue)


## "+": a new key at the playhead with the row's settings, ready to change.
func _on_row_add(key: String) -> void:
	var time := playhead()
	var row: CueRow = _rows.get(key)
	if time < 0.0 or row == null:
		return
	var cue := _row_cue(row)
	if row.type == ShowCues.TYPE_LIGHT and cue["effect"] == "OFF":
		cue["effect"] = "SOLID"   # a new key that does nothing isn't much use
	add_key(time, cue)


## A coil row's Fire: pulse it now with the row's settings.
func _on_row_fire(key: String) -> void:
	var row: CueRow = _rows.get(key)
	if row:
		_send(ShowCues.preview_line(_row_cue(row)))


# ---------------------------------------------------------------- the rows

## Names for a type: the game's (when it answers), else this PC's machine
## config, plus any already used in the show.
func _names(type: StringName) -> Array[StringName]:
	var names: Array[StringName] = []
	for n in _hardware_names(type):
		if not names.has(StringName(n)):
			names.append(StringName(n))
	for cue in _cues:
		if cue["type"] == type and not names.has(cue["target"]):
			names.append(cue["target"])
	return names


## The machine's lights / servos / coils: the game's (when it answers), else this PC's machine config.
func _hardware_names(type: StringName) -> PackedStringArray:
	return _game_list(type) if not _game_names.is_empty() else _config_names(type)


func _config_names(type: StringName) -> PackedStringArray:
	var path := "user://machine_config.json"
	if not FileAccess.file_exists(path):
		path = "res://config/machine_config.default.json"
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var names := PackedStringArray()
	if data is Dictionary:
		for item: Variant in (data as Dictionary).get(String(type) + "s", []):   # "lights", "servos", "coils"
			if item is Dictionary and (item as Dictionary).has("name"):
				names.append(str(item["name"]))
	return names


func _wanted_row_keys() -> Array[String]:
	var keys: Array[String] = []
	for type in ShowCues.TYPES:
		for n in _names(type):
			keys.append(row_key(type, n))
	return keys


## Build one row per light, servo and coil, under a heading per type.
func _refresh_rows() -> void:
	if _rows_box == null:
		return
	_row_keys = _wanted_row_keys()
	for child in _rows_box.get_children():
		child.queue_free()
	_rows.clear()
	_shown.clear()
	for type in ShowCues.TYPES:
		var names := _names(type)
		if names.is_empty():
			continue
		var heading := Label.new()
		heading.text = SECTION_TITLES[type]
		heading.modulate = Color(1, 1, 1, 0.75)
		_rows_box.add_child(heading)
		for n in names:
			var row := _make_row(type, n)
			_rows_box.add_child(row)
			_show_cue(_rows[row_key(type, n)], {})
		if not _game_names.is_empty():
			var missing: Array[String] = []
			for n in names:
				if not _game_list(type).has(String(n)):
					missing.append(String(n))
			if not missing.is_empty():
				var warn := Label.new()
				warn.text = "Not on the game machine: " + ", ".join(missing)
				warn.modulate = Color(1, 0.6, 0.5)
				warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				_rows_box.add_child(warn)


func _make_row(type: StringName, target: StringName) -> Control:
	var row := CueRow.new()
	row.type = type
	row.target = target
	var key := row_key(type, target)
	_rows[key] = row
	var panel := PanelContainer.new()   # a box around each row
	var lines := VBoxContainer.new()
	panel.add_child(lines)

	# Line 1: (swatch,) name + ▾, which key, + and ✕.
	var top := HBoxContainer.new()
	lines.add_child(top)
	if type == ShowCues.TYPE_LIGHT:
		row.swatch = TextureRect.new()
		row.swatch.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		row.swatch.custom_minimum_size = Vector2(20, 20)
		top.add_child(row.swatch)
	# The name: type a new one (Enter), or pick one of the machine's from ▾.
	# Renames every key of this one.
	row.name_edit = LineEdit.new()
	row.name_edit.text = String(target)
	row.name_edit.placeholder_text = "(no name)"
	row.name_edit.tooltip_text = "The %s these keys drive. Type a new name and press Enter, or pick one from ▾, to rename all of its keys." % type
	row.name_edit.size_flags_horizontal = SIZE_EXPAND_FILL
	row.name_edit.custom_minimum_size.x = 60
	row.name_edit.select_all_on_focus = true
	row.name_edit.text_submitted.connect(func(text: String) -> void: rename(type, target, text))
	row.name_edit.focus_exited.connect(func() -> void:
		if is_instance_valid(row.name_edit) and row.name_edit.text != String(target):
			rename(type, target, row.name_edit.text))
	top.add_child(row.name_edit)
	var pick := MenuButton.new()
	pick.text = "▾"
	pick.flat = false
	pick.tooltip_text = "Pick a %s from the machine" % type
	var popup := pick.get_popup()
	pick.about_to_popup.connect(func() -> void:
		popup.clear()
		for n in _hardware_names(type):
			popup.add_item(n))
	popup.index_pressed.connect(func(index: int) -> void: rename(type, target, popup.get_item_text(index)))
	top.add_child(pick)
	row.at = Label.new()
	row.at.modulate = Color(1, 1, 1, 0.6)
	top.add_child(row.at)
	row.add = Button.new()
	row.add.text = "+"
	row.add.tooltip_text = "New key at the playhead (a copy of these settings)"
	row.add.pressed.connect(_on_row_add.bind(key))
	top.add_child(row.add)
	row.delete = Button.new()
	row.delete.text = "✕"
	row.delete.tooltip_text = "Delete the key this row follows"
	row.delete.pressed.connect(delete_at_playhead.bind(target, type))
	top.add_child(row.delete)

	# Line 2: the type's settings. Changing any edits the key.
	var fields := HBoxContainer.new()
	lines.add_child(fields)
	match type:
		ShowCues.TYPE_LIGHT:
			row.effect = OptionButton.new()
			for effect in IoDefs.EFFECTS:
				row.effect.add_item(effect)
				row.effect.set_item_tooltip(row.effect.item_count - 1, IoDefs.EFFECT_HELP.get(effect, ""))
			row.effect.size_flags_horizontal = SIZE_EXPAND_FILL
			row.effect.fit_to_longest_item = false
			row.effect.item_selected.connect(_on_row_changed.bind(key))
			fields.add_child(row.effect)
			row.color1 = _color_button("Color")
			row.color1.color_changed.connect(_on_row_changed.bind(key))
			fields.add_child(row.color1)
			row.color2 = _color_button("Color 2 (BLINK, CHASE, WIPE, SPARKLE background)")
			row.color2.color_changed.connect(_on_row_changed.bind(key))
			fields.add_child(row.color2)
			row.ms = _spin(1, 600000, 50, "Speed in ms: the period, or the duration for FADE and WIPE")
			row.ms.value_changed.connect(_on_row_changed.bind(key))
			fields.add_child(row.ms)
		ShowCues.TYPE_SERVO:
			row.position = HSlider.new()
			row.position.min_value = 0
			row.position.max_value = 100
			row.position.step = 1
			row.position.size_flags_horizontal = SIZE_EXPAND_FILL
			row.position.size_flags_vertical = SIZE_SHRINK_CENTER
			row.position.tooltip_text = "Position, 0..100 % of the servo's range"
			row.position.value_changed.connect(_on_row_changed.bind(key))
			row.position.value_changed.connect(func(v: float) -> void: row.position_label.text = "%d%%" % v)
			fields.add_child(row.position)
			row.position_label = Label.new()
			row.position_label.custom_minimum_size.x = 40
			fields.add_child(row.position_label)
			row.ramp = _spin(0, 600000, 50, "Ramp: how long the move takes, in ms (0 = straight there)")
			row.ramp.suffix = "ms"
			row.ramp.value_changed.connect(_on_row_changed.bind(key))
			fields.add_child(row.ramp)
			row.ease = OptionButton.new()
			for ease in IoDefs.SERVO_EASES:
				row.ease.add_item(ease.capitalize())
			row.ease.tooltip_text = "Linear = steady speed; Smooth = eases in and out"
			row.ease.item_selected.connect(_on_row_changed.bind(key))
			fields.add_child(row.ease)
		ShowCues.TYPE_COIL:
			row.ms = _spin(0, 255, 5, "Pulse length in ms (0 = the coil's own pulse time; the board caps it at 255)")
			row.ms.suffix = "ms"
			row.ms.value_changed.connect(_on_row_changed.bind(key))
			fields.add_child(row.ms)
			row.power = _spin(1, 100, 5, "Power: below 100 % is a softer PWM pulse (needs a PWM pin)")
			row.power.suffix = "%"
			row.power.value_changed.connect(_on_row_changed.bind(key))
			fields.add_child(row.power)
			row.fire = Button.new()
			row.fire.text = "Fire"
			row.fire.tooltip_text = "Pulse the real coil now with these settings (needs Send to game)"
			row.fire.pressed.connect(_on_row_fire.bind(key))
			fields.add_child(row.fire)
	return panel


## Show a cue in its row: swatch and fields (without firing edits).
func _show_cue(row: CueRow, cue: Dictionary) -> void:
	if cue.is_empty():
		row.at.text = "no key"
	match row.type:
		ShowCues.TYPE_LIGHT:
			var effect: String = cue.get("effect", "OFF")
			var image := Image.create(18, 18, false, Image.FORMAT_RGBA8)
			image.fill(OFF_COLOR if effect == "OFF" else cue["color"])
			if effect == "RAINBOW":   # stripes of hue, since its color isn't a setting
				for x in 18:
					for y in 18:
						image.set_pixel(x, y, Color.from_hsv(x / 18.0, 0.9, 1.0))
			row.swatch.texture = ImageTexture.create_from_image(image)
			row.effect.select(maxi(IoDefs.EFFECTS.find(effect), 0))   # select() doesn't fire item_selected
			if cue.is_empty():
				return
			if not row.color1.color.is_equal_approx(cue["color"]):
				row.color1.color = cue["color"]       # setting it doesn't fire color_changed
			if not row.color2.color.is_equal_approx(cue["color2"]):
				row.color2.color = cue["color2"]
			row.ms.set_value_no_signal(cue["ms"])
		ShowCues.TYPE_SERVO:
			row.position.set_value_no_signal(roundf(float(cue.get("position", ShowCues.DEFAULT_POSITION)) * 100.0))
			row.position_label.text = "%d%%" % row.position.value
			row.ramp.set_value_no_signal(cue.get("ramp_ms", ShowCues.DEFAULT_RAMP_MS))
			row.ease.select(maxi(IoDefs.SERVO_EASES.find(cue.get("ease", ShowCues.DEFAULT_EASE)), 0))
		ShowCues.TYPE_COIL:
			row.ms.set_value_no_signal(cue.get("ms", 0))
			row.power.set_value_no_signal(cue.get("power", ShowCues.DEFAULT_POWER))


# ---------------------------------------------------------------- UI

func _build_ui() -> void:
	name = "Light Show"
	add_theme_constant_override("separation", 8)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	add_child(_heading("Send to game"))
	_live_box = CheckBox.new()
	_live_box.text = "Send to game (real hardware)"
	_live_box.toggled.connect(set_live)
	add_child(_live_box)
	_coils_box = CheckBox.new()
	_coils_box.text = "Fire coils while playing"
	_coils_box.tooltip_text = "Pulse the real coils when the playhead plays past their keys (never when scrubbing). Off each time the editor starts."
	_coils_box.toggled.connect(set_fire_coils)
	add_child(_coils_box)
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
	resend.tooltip_text = "Send every light and servo cue at the playhead again"
	resend.pressed.connect(func() -> void: _sent.clear())
	host_row.add_child(resend)
	add_child(host_row)
	_link_label = Label.new()
	_link_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_link_label.modulate = Color(1, 1, 1, 0.7)
	add_child(_link_label)

	var rows_head := HBoxContainer.new()
	var rows_title := _heading("At the playhead")
	rows_title.size_flags_horizontal = SIZE_EXPAND_FILL
	rows_head.add_child(rows_title)
	_key_all = Button.new()
	_key_all.text = "Key all"
	_key_all.tooltip_text = "New key at the playhead on every light and servo, with the settings it has now (one undo step)"
	_key_all.pressed.connect(key_all_at_playhead)
	rows_head.add_child(_key_all)
	add_child(rows_head)
	_rows_box = VBoxContainer.new()
	add_child(_rows_box)

	var help := Label.new()
	help.text = "Each row shows the key it follows at the playhead. Change a setting to edit that key (no key yet: one is added at the playhead). + adds a new key at the playhead, ✕ deletes the key, Key all keys every light and servo at once. Edit a name (or pick one from ▾) to rename all of its keys. Servo: position %, ramp ms, Linear/Smooth. Coil: pulse ms (0 = its own), power %. Ctrl+Z undoes. Move keys on the Animation timeline as usual."
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


func _spin(min_value: float, max_value: float, arrow_step: float, tip: String) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_value
	s.max_value = max_value
	s.step = 1   # any value; the arrows move arrow_step at a time
	s.custom_arrow_step = arrow_step
	s.tooltip_text = tip
	s.custom_minimum_size.x = 76
	return s


func _editor_settings() -> EditorSettings:
	return EditorInterface.get_editor_settings() if Engine.is_editor_hint() else null

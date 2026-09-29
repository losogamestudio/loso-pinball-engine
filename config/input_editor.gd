extends VBoxContainer
## InputEditor — one-page setup for one switch input, shown inside the Setup tab.
##
## Like the coil wizard it edits a draft: "Send to board" lets you press the
## real switch and watch its lamp, and nothing is written to disk until Save.
## Renaming an input also renames it in every coil that uses it.
##
## Usage: var e := InputEditorScript.new(); e.open(&"flipper_left_eos"); add_child(e)
## (an empty name adds a new input). Listen to `closed`.

signal closed(saved: bool)   ## the editor is done; the parent should free it

var _original_name: StringName = &""
var _original_board: StringName = &""
var _original_pin := -1
var _snapshot: Dictionary
var _draft := IoDefs.InputDef.new()
var _applied := false
var _finished := false

var _body: VBoxContainer
var _error_label: Label
var _save_button: Button
var _lamp: ColorRect
var _status_label: Label


## Call before adding to the tree. Empty name = add a new input.
func open(input_name: StringName = &"") -> void:
	_snapshot = MachineConfig.snapshot()
	var existing := MachineConfig.find_input(input_name)
	if existing:
		_original_name = input_name
		_original_board = existing.board
		_original_pin = existing.pin
		_draft = IoDefs.InputDef.from_dict(existing.to_dict())
	else:
		if not MachineConfig.boards.is_empty():
			_draft.board = MachineConfig.boards[0].id
		_draft.name = MachineConfig.unique_name("switch")


func _ready() -> void:
	add_theme_constant_override("separation", 12)
	size_flags_vertical = SIZE_EXPAND_FILL
	add_child(UiKit.heading("Edit switch '%s'" % _original_name if _original_name != &"" else "Add a switch", 24))

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 12)
	_body.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(_body)

	_error_label = UiKit.colored("", UiKit.BAD_COLOR)
	add_child(_error_label)

	var footer := HBoxContainer.new()
	add_child(footer)
	footer.add_child(UiKit.button("Cancel", _cancel))
	var spacer := Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	footer.add_child(spacer)
	footer.add_child(UiKit.button("Send to board to test", _try_on_board))
	_save_button = UiKit.button("Save", _save)
	footer.add_child(_save_button)

	PinballIO.switch_changed.connect(_on_switch_changed)
	PinballIO.board_ready.connect(_on_board_event)
	PinballIO.board_lost.connect(_on_board_event)
	_build()


func _exit_tree() -> void:
	if not _finished:
		_unapply()


func _build() -> void:
	UiKit.free_children(_body)

	var name_edit := LineEdit.new()
	name_edit.text = String(_draft.name)
	name_edit.custom_minimum_size.x = 280
	name_edit.text_changed.connect(_on_name_changed)
	_body.add_child(UiKit.field("Name (used by game code)", name_edit))

	if MachineConfig.boards.size() > 1:
		var board_pick := OptionButton.new()
		for b in MachineConfig.boards:
			board_pick.add_item("%s  (%s)" % [b.id, BoardTypes.display_name(b.type)])
			board_pick.set_item_metadata(board_pick.item_count - 1, b.id)
			if b.id == _draft.board:
				board_pick.select(board_pick.item_count - 1)
		board_pick.item_selected.connect(_on_board_picked.bind(board_pick))
		_body.add_child(UiKit.field("Board", board_pick))

	var pin_pick := OptionButton.new()
	var keep := _original_pin if _draft.board == _original_board else -1
	for pin in MachineConfig.free_pins(_draft.board, BoardTypes.CAP_IN, keep):
		pin_pick.add_item("Pin %d" % pin, pin)
	if pin_pick.item_count == 0:
		_draft.pin = -1
		_body.add_child(UiKit.colored("No free input pins left on board '%s'." % _draft.board, UiKit.BAD_COLOR))
	else:
		if pin_pick.get_item_index(_draft.pin) == -1:
			_draft.pin = pin_pick.get_item_id(0)
		pin_pick.select(pin_pick.get_item_index(_draft.pin))
		pin_pick.item_selected.connect(_on_pin_picked.bind(pin_pick))
		var row := UiKit.field("Input pin", pin_pick)
		_lamp = UiKit.lamp(PinballIO.is_switch_active(_draft.name) if _applied or _original_name != &"" else false)
		row.add_child(_lamp)
		_body.add_child(row)

	var nc := CheckBox.new()
	nc.text = "Normally closed (active when the switch opens)"
	nc.button_pressed = _draft.nc
	nc.toggled.connect(func(on: bool) -> void: _draft.nc = on)
	_body.add_child(UiKit.field("Contact", nc))

	_body.add_child(UiKit.field("Debounce", UiKit.spin(0, MachineConfig.MAX_DEBOUNCE_MS, _draft.debounce_ms, " ms",
			func(v: float) -> void: _draft.debounce_ms = int(v))))

	var users := MachineConfig.coils_using_input(_original_name) if _original_name != &"" else PackedStringArray()
	_body.add_child(UiKit.field("Used by", UiKit.note(", ".join(users) if not users.is_empty() else "nothing yet (pick it as a trigger or EOS in a coil's setup)")))

	_body.add_child(UiKit.note("Inputs are on the right header (USB port up), wired from the pin to GND (3.3 V only). Debounce: how long the switch must be steady before it counts; 5 ms suits most switches, 1–2 ms for EOS switches."))

	_status_label = UiKit.colored("", UiKit.WARN_COLOR)
	_body.add_child(_status_label)
	_update_status()
	_refresh()


func _on_name_changed(text: String) -> void:
	_draft.name = StringName(text.strip_edges())
	_refresh()


func _on_pin_picked(index: int, picker: OptionButton) -> void:
	_draft.pin = picker.get_item_id(index)


func _on_board_picked(index: int, picker: OptionButton) -> void:
	if not MachineConfig.coils_using_input(_original_name).is_empty():
		_error_label.text = "Coils use this switch, and their rules only work with switches on their own board. Change those coils first."
		for n in picker.item_count:
			if picker.get_item_metadata(n) == _draft.board:
				picker.select(n)   # put the picker back on the current board
		return
	_draft.board = picker.get_item_metadata(index)
	_draft.pin = -1
	_build()


func _name_error() -> String:
	var text := String(_draft.name)
	if text.is_empty():
		return "Give the switch a name, e.g. flipper_left_button."
	if text.contains(" "):
		return "Names can't contain spaces (use _ instead)."
	if MachineConfig.is_name_taken(_draft.name, _original_name):
		return "Something is already called '%s'." % text
	if _draft.pin == -1:
		return "Pick an input pin."
	return ""


func _refresh() -> void:
	var error := _name_error()
	_error_label.text = error
	_save_button.disabled = error != ""


func _update_status() -> void:
	if _status_label == null:
		return
	if PinballIO.get_port_for_board(_draft.board).is_empty():
		_status_label.text = "Board '%s' isn't connected, so the lamp can't show the switch. (Connect on the Diagnostics tab.)" % _draft.board
	elif _applied or _original_name != &"":
		_status_label.text = "Press the switch: the lamp next to the pin lights while it's active."
		_status_label.add_theme_color_override("font_color", UiKit.OK_COLOR)
	else:
		_status_label.text = "Press \"Send to board to test\", then press the switch and watch the lamp."


# ---------------------------------------------------------------- apply / save / cancel

## Put the draft into MachineConfig (from the layout as it was when opened),
## renaming it in any coil that uses it. Returns problems; empty = applied.
func _apply_draft() -> PackedStringArray:
	MachineConfig.restore(_snapshot, false)
	var input := IoDefs.InputDef.from_dict(_draft.to_dict())
	var index := -1
	for n in MachineConfig.inputs.size():
		if MachineConfig.inputs[n].name == _original_name:
			index = n
	if index == -1:
		MachineConfig.inputs.append(input)
	else:
		MachineConfig.inputs[index] = input
		for c in MachineConfig.coils:
			if c.trigger == _original_name:
				c.trigger = input.name
			if c.eos == _original_name:
				c.eos = input.name

	var problems := MachineConfig.validate()
	if problems.is_empty():
		MachineConfig.apply()
		_applied = true
	else:
		MachineConfig.restore(_snapshot, _applied)
		_applied = false
	return problems


func _try_on_board() -> void:
	if _name_error() != "":
		return
	var problems := _apply_draft()
	_error_label.text = "\n".join(problems)
	_build()


func _save() -> void:
	if _name_error() != "":
		return
	var problems := _apply_draft()
	if not problems.is_empty():
		_error_label.text = "\n".join(problems)
		return
	var err := MachineConfig.save_config()
	if err != OK:
		_error_label.text = "Couldn't save the machine config (error %d)." % err
		return
	_finished = true
	closed.emit(true)


func _cancel() -> void:
	_unapply()
	_finished = true
	closed.emit(false)


func _unapply() -> void:
	if _applied:
		MachineConfig.restore(_snapshot)
		_applied = false


func _on_switch_changed(switch_name: StringName, active: bool) -> void:
	if _lamp and switch_name == _draft.name:
		_lamp.color = UiKit.LAMP_ON if active else UiKit.LAMP_OFF


func _on_board_event(_board_id: StringName) -> void:
	_update_status()

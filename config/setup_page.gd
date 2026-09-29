extends MarginContainer
## SetupPage — the "Setup" tab of the service menu: the machine's coils and
## switches, with wizards to add/edit them, and "Burn to board".
##
## Everything here edits MachineConfig (the master copy on the Pi/PC) and
## saves it to user://machine_config.json. Linked boards pick up changes
## right away; "Burn to board" makes a board keep its layout at power-off.
## Lamps will become LED chains later, so they aren't edited here yet.

const CoilWizardScript := preload("res://config/coil_wizard.gd")
const InputEditorScript := preload("res://config/input_editor.gd")

var _list_scroll: ScrollContainer
var _list: VBoxContainer
var _editor_host: VBoxContainer
var _confirm: ConfirmationDialog
var _pending_confirm: Callable
var _switch_lamps := {}        ## switch name -> ColorRect in the list


func _ready() -> void:
	for side in ["left", "right", "top", "bottom"]:
		add_theme_constant_override("margin_" + side, 16)

	_list_scroll = UiKit.scroll_container()   # always-on, finger-wide scroll bar
	add_child(_list_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 12)
	_list_scroll.add_child(_list)

	_editor_host = VBoxContainer.new()
	_editor_host.visible = false
	add_child(_editor_host)

	_confirm = ConfirmationDialog.new()
	_confirm.confirmed.connect(_on_confirmed)
	add_child(_confirm)

	MachineConfig.changed.connect(_rebuild)
	PinballIO.board_ready.connect(_on_board_event)
	PinballIO.board_lost.connect(_on_board_event)
	PinballIO.board_burned.connect(_on_board_event)
	PinballIO.port_unlinked.connect(func(_port: String) -> void: _rebuild())
	PinballIO.switch_changed.connect(_on_switch_changed)
	_rebuild()


# ---------------------------------------------------------------- the list

func _rebuild() -> void:
	if _editor_host.visible:   # an editor is open: the list is rebuilt when it closes
		return
	UiKit.free_children(_list)
	_switch_lamps.clear()
	# Each is a gray section card; the things you change most come first.
	_build_boards()
	_build_coils()
	_build_switches()
	_build_screen()
	_build_footer()


## UI scale and fullscreen for this machine's display (saved in user://display.cfg).
func _build_screen() -> void:
	var screen := DisplaySettings.screen_size()
	var body := UiKit.section(_list, "Screen")
	var row := HFlowContainer.new()   # wraps onto a second line on a narrow screen
	row.add_theme_constant_override("h_separation", 12)
	row.add_theme_constant_override("v_separation", 8)
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
	_rebuild.call_deferred()   # headings set their own size, so build them again


func _build_boards() -> void:
	var body := UiKit.section(_list, "Boards")
	for b in MachineConfig.boards:
		var row := UiKit.row_card(body)
		var port := PinballIO.get_port_for_board(b.id)
		var status: Label
		if port.is_empty():
			status = UiKit.colored("Not connected (Diagnostics tab)", UiKit.WARN_COLOR)
		elif PinballIO.is_board_burned(b.id):
			status = UiKit.colored("On %s · burned ✓" % port, UiKit.OK_COLOR)
		else:
			status = UiKit.colored("On %s · NOT burned (lost at power-off)" % port, UiKit.WARN_COLOR)
		status.add_theme_font_size_override("font_size", DisplaySettings.font_size(UiKit.DETAIL_SIZE))
		var block := UiKit.name_block("%s · %s" % [b.id, BoardTypes.display_name(b.type)], "")
		block.add_child(status)
		row.add_child(block)
		if not port.is_empty() and not PinballIO.is_board_burned(b.id):
			row.add_child(UiKit.button("Burn", _burn.bind(b.id), UiKit.PRIMARY))


func _build_coils() -> void:
	var add: Array[Control] = [UiKit.button("+ Add coil", _open_coil_wizard.bind(&""), UiKit.PRIMARY)]
	var body := UiKit.section(_list, "Coils", add)
	if MachineConfig.coils.is_empty():
		body.add_child(UiKit.note("No coils yet. Add one to get started."))
	for c in MachineConfig.coils:
		var row := UiKit.row_card(body)
		row.add_child(UiKit.name_block("%s · pin %d" % [c.name, c.pin], _describe_coil(c)))
		row.add_child(UiKit.button("Fire", func() -> void: PinballIO.pulse_coil(c.name), UiKit.TEST))
		row.add_child(UiKit.button("Edit", _open_coil_wizard.bind(c.name)))
		row.add_child(UiKit.button("Delete", _ask_delete_coil.bind(c.name), UiKit.DANGER))


func _build_switches() -> void:
	var add: Array[Control] = [UiKit.button("+ Add switch", _open_input_editor.bind(&""), UiKit.PRIMARY)]
	var body := UiKit.section(_list, "Switches", add)
	for i in MachineConfig.inputs:
		var row := UiKit.row_card(body)
		var lamp := UiKit.lamp(PinballIO.is_switch_active(i.name))
		lamp.size_flags_vertical = SIZE_SHRINK_CENTER
		_switch_lamps[i.name] = lamp
		row.add_child(lamp)
		row.add_child(UiKit.name_block("%s · pin %d" % [i.name, i.pin], _describe_switch(i)))
		row.add_child(UiKit.button("Edit", _open_input_editor.bind(i.name)))
		row.add_child(UiKit.button("Delete", _ask_delete_input.bind(i.name), UiKit.DANGER))
	body.add_child(UiKit.note("The lamp shows the switch live while a board is running. A coil's setup can also create its switches."))


func _build_footer() -> void:
	var problems := MachineConfig.validate()
	if not problems.is_empty():
		var errors := UiKit.section(_list, "Problems")
		for problem in problems:
			errors.add_child(UiKit.colored(problem, UiKit.BAD_COLOR))
	var body := UiKit.section(_list, "Machine")
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 12)
	row.add_theme_constant_override("v_separation", 8)
	row.add_child(UiKit.button("Reset to default layout", _ask_reset, UiKit.DANGER))
	# On a touch screen with no keyboard, this is the only way out of fullscreen.
	row.add_child(UiKit.button("Quit to desktop", _ask_quit, UiKit.DANGER))
	body.add_child(row)
	body.add_child(UiKit.detail("Layout file: " + ProjectSettings.globalize_path(MachineConfig.loaded_from)))
	body.add_child(UiKit.detail("Lamps: all lighting will be WS2812B LED chains, set up in a later version."))


## A coil in a few words, e.g. "60 ms → hold 50% · trigger flipper_left_button · EOS flipper_left_eos".
func _describe_coil(c: IoDefs.CoilDef) -> String:
	var parts: PackedStringArray = []
	parts.append("%d ms → hold %d%%" % [c.full_ms, c.hold_pct] if c.hold_pct > 0 else "%d ms pulse" % c.full_ms)
	parts.append("trigger " + c.trigger if c.trigger != &"" else "fired by the game")
	if c.eos != &"":
		parts.append("EOS " + c.eos)
	if c.recycle_ms > 0:
		parts.append("recycle %d ms" % c.recycle_ms)
	return " · ".join(parts)


## A switch in a few words, e.g. "target 10 pts · NC · trigger of sling_left".
func _describe_switch(i: IoDefs.InputDef) -> String:
	var parts: PackedStringArray = []
	if IoDefs.kind_scores(i.kind):
		parts.append("%s %d pts" % [i.kind, i.points])
	elif i.kind != IoDefs.KIND_SWITCH:
		parts.append(i.kind)
	if i.nc:
		parts.append("NC")
	for c in MachineConfig.coils:
		if c.trigger == i.name:
			parts.append("trigger of " + c.name)
		if c.eos == i.name:
			parts.append("EOS of " + c.name)
	return " · ".join(parts)


# ---------------------------------------------------------------- editors

func _open_coil_wizard(coil_name: StringName) -> void:
	var wizard: Node = CoilWizardScript.new()
	wizard.open(coil_name)
	_show_editor(wizard)


func _open_input_editor(input_name: StringName) -> void:
	var editor: Node = InputEditorScript.new()
	editor.open(input_name)
	_show_editor(editor)


## Swap the list for an editor until it emits `closed`.
func _show_editor(editor: Node) -> void:
	UiKit.free_children(_editor_host)
	_editor_host.add_child(editor)
	editor.connect("closed", _on_editor_closed)
	_list_scroll.visible = false
	_editor_host.visible = true


func _on_editor_closed(_saved: bool) -> void:
	UiKit.free_children(_editor_host)
	_editor_host.visible = false
	_list_scroll.visible = true
	_rebuild()


# ---------------------------------------------------------------- delete / reset / burn

func _ask(text: String, on_yes: Callable) -> void:
	_confirm.dialog_text = text
	_pending_confirm = on_yes
	_confirm.popup_centered()


func _on_confirmed() -> void:
	if _pending_confirm.is_valid():
		_pending_confirm.call()


func _ask_delete_coil(coil_name: StringName) -> void:
	_ask("Delete coil '%s'? Its switches stay (delete them separately if you don't need them)." % coil_name,
			_delete_coil.bind(coil_name))


func _delete_coil(coil_name: StringName) -> void:
	MachineConfig.remove_coil(coil_name)
	_save_and_apply()


func _ask_delete_input(input_name: StringName) -> void:
	var users := MachineConfig.coils_using_input(input_name)
	if not users.is_empty():
		_ask("'%s' is used by %s. Edit those coils first (set the switch to none), then delete it." % [input_name, ", ".join(users)],
				Callable())   # nothing to do on OK
		return
	_ask("Delete switch '%s'?" % input_name, _delete_input.bind(input_name))


func _delete_input(input_name: StringName) -> void:
	MachineConfig.remove_input(input_name)
	_save_and_apply()


func _ask_reset() -> void:
	_ask("Throw away this machine's saved layout and go back to the project's default layout?",
			MachineConfig.reset_to_default)


func _ask_quit() -> void:
	_ask("Quit Loso Pinball and go back to the desktop?", _quit)


func _quit() -> void:
	get_tree().quit()


func _save_and_apply() -> void:
	MachineConfig.save_config()
	MachineConfig.apply()   # boards get the new layout; `changed` rebuilds this list


func _burn(board_id: StringName) -> void:
	PinballIO.burn_board(board_id)


# ---------------------------------------------------------------- live updates

func _on_board_event(_board_id: StringName) -> void:
	_rebuild()


func _on_switch_changed(switch_name: StringName, active: bool) -> void:
	var lamp: ColorRect = _switch_lamps.get(switch_name)
	if lamp:
		lamp.color = UiKit.LAMP_ON if active else UiKit.LAMP_OFF

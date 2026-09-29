extends MarginContainer
## HardwarePage — the "Hardware" tab of the service menu: connecting boards,
## burning layouts, and the machine's coils, switches and lamps, with wizards
## to add/edit them.
##
## Everything here edits MachineConfig (the master copy on the Pi/PC) and
## saves it to user://machine_config.json. Linked boards pick up changes
## right away; "Burn" makes a board keep its layout at power-off.
## Lamps will become WS2812B LED chains later; for now they just cycle.

const CoilWizardScript := preload("res://config/coil_wizard.gd")
const InputEditorScript := preload("res://config/input_editor.gd")

var _list_scroll: ScrollContainer
var _list: VBoxContainer
var _editor_host: VBoxContainer
var _confirm: ConfirmationDialog
var _pending_confirm: Callable
var _switch_lamps := {}        ## switch name -> ColorRect in the list
var _port_menu: OptionButton


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
	PinballIO.port_linked.connect(func(_p: String, _f: String, _t: String, _u: String) -> void: _rebuild())
	PinballIO.port_unlinked.connect(func(_port: String) -> void: _rebuild())
	PinballIO.board_ready.connect(_on_board_event)
	PinballIO.board_lost.connect(_on_board_event)
	PinballIO.board_burned.connect(_on_board_event)
	PinballIO.board_problem.connect(func(_p: String, _m: String) -> void: _rebuild())
	PinballIO.switch_changed.connect(_on_switch_changed)
	_rebuild()


func _input(event: InputEvent) -> void:
	# Keyboard stand-in for the first two coils' buttons: there's no keyboard
	# on the real cabinet, so this only exists for bench-testing on a desktop.
	# Only while this tab shows its list (_input runs even for hidden nodes).
	if not is_visible_in_tree() or _editor_host.visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var coil_index := -1
		match (event as InputEventKey).keycode:
			KEY_LEFT: coil_index = 0
			KEY_RIGHT: coil_index = 1
		if coil_index != -1 and coil_index < MachineConfig.coils.size():
			PinballIO.pulse_coil(MachineConfig.coils[coil_index].name)
			accept_event()


# ---------------------------------------------------------------- the list

func _rebuild() -> void:
	if _editor_host.visible:   # an editor is open: the list is rebuilt when it closes
		return
	UiKit.free_children(_list)
	_switch_lamps.clear()
	# Each is a gray section card, in the order you set a machine up.
	_build_connection()
	_build_boards()
	_build_coils()
	_build_switches()
	_build_lamps()
	_build_footer()


## Port picker and link status. PinballIO remembers the port for auto-connect.
func _build_connection() -> void:
	var body := UiKit.section(_list, "Connection")
	var row := _flow()
	body.add_child(row)
	_port_menu = OptionButton.new()
	_port_menu.custom_minimum_size.x = 220
	row.add_child(_port_menu)
	_refresh_ports()
	row.add_child(UiKit.button("Refresh", _refresh_ports))
	row.add_child(UiKit.button("Connect", _on_connect_pressed, UiKit.PRIMARY))
	row.add_child(UiKit.button("Disconnect all", func() -> void:
		PinballIO.close_port()
		_rebuild()))
	var auto := CheckButton.new()
	auto.text = "Auto-connect at startup"
	auto.button_pressed = PinballIO.auto_connect
	auto.toggled.connect(func(on: bool) -> void: PinballIO.set_auto_connect(on))
	row.add_child(auto)

	var status: Label
	if PinballIO.is_ready():
		status = UiKit.colored("Ready: every board is running its layout", UiKit.OK_COLOR)
	elif PinballIO.is_any_port_open():
		status = UiKit.colored("Port open on %s, waiting for the board… (details on the Monitor tab)" % ", ".join(PinballIO.get_open_ports()), UiKit.WARN_COLOR)
	else:
		status = UiKit.colored("Not connected", UiKit.BAD_COLOR)
	body.add_child(status)


func _refresh_ports() -> void:
	_port_menu.clear()
	var ports: Array[String] = PinballIO.list_ports()
	for p in ports:
		_port_menu.add_item(p)
	_port_menu.disabled = ports.is_empty()
	if ports.is_empty():
		_port_menu.add_item("(no ports)")
	elif ports.has(PinballIO.last_port):
		_port_menu.select(ports.find(PinballIO.last_port))


func _on_connect_pressed() -> void:
	if _port_menu.disabled:
		return
	PinballIO.open_port(_port_menu.get_item_text(_port_menu.selected))
	_rebuild()


func _build_boards() -> void:
	var body := UiKit.section(_list, "Boards")
	for b in MachineConfig.boards:
		var row := UiKit.row_card(body)
		var port := PinballIO.get_port_for_board(b.id)
		var status: Label
		if port.is_empty():
			status = UiKit.colored("Not connected", UiKit.WARN_COLOR)
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
	var head: Array[Control] = [
		UiKit.button("+ Add coil", _open_coil_wizard.bind(&""), UiKit.PRIMARY),
		UiKit.button("Arm all", _set_all_rules.bind(true), UiKit.TEST),
		UiKit.button("Disarm all", _set_all_rules.bind(false)),
	]
	var body := UiKit.section(_list, "Coils", head)
	if MachineConfig.coils.is_empty():
		body.add_child(UiKit.note("No coils yet. Add one to get started."))
	for c in MachineConfig.coils:
		var row := UiKit.row_card(body)
		row.add_child(UiKit.name_block("%s · pin %d" % [c.name, c.pin], _describe_coil(c)))
		row.add_child(UiKit.button("Fire", func() -> void: PinballIO.pulse_coil(c.name), UiKit.TEST))
		if c.trigger != &"":
			# Arms the rule on the board: then the trigger switch fires the coil
			# by itself (Godot never fires a rule).
			var armed := CheckButton.new()
			armed.text = "Armed"
			armed.button_pressed = PinballIO.get_coil_rule(c.name)
			armed.toggled.connect(func(on: bool) -> void: PinballIO.set_coil_rule(c.name, on))
			row.add_child(armed)
		row.add_child(UiKit.button("Edit", _open_coil_wizard.bind(c.name)))
		row.add_child(UiKit.button("Delete", _ask_delete_coil.bind(c.name), UiKit.DANGER))
	body.add_child(UiKit.note("Armed: the coil's trigger switch fires it on the board. ←/→ keys fire the first two coils."))


func _set_all_rules(on: bool) -> void:
	PinballIO.set_all_rules(on)
	_rebuild()   # so the Armed toggles show the new state


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


## One button per lamp that cycles OFF / ON / BLINK. A placeholder: lighting
## will become WS2812B LED chains.
func _build_lamps() -> void:
	if MachineConfig.lamps.is_empty():
		return
	var body := UiKit.section(_list, "Lamps")
	var row := _flow()
	body.add_child(row)
	for l in MachineConfig.lamps:
		var b := UiKit.button("", Callable(), UiKit.TEST)
		b.text = "%s · pin %d: %s" % [l.name, l.pin, PinballIO.get_lamp_mode(l.name)]
		b.pressed.connect(_cycle_lamp.bind(l, b))
		row.add_child(b)
	body.add_child(UiKit.detail("All lighting will be WS2812B LED chains, set up in a later version."))


func _cycle_lamp(l: IoDefs.LampDef, button: Button) -> void:
	var modes: Array[String] = PinballIO.LAMP_MODES
	var next: String = modes[(modes.find(PinballIO.get_lamp_mode(l.name)) + 1) % modes.size()]
	PinballIO.set_lamp(l.name, next)
	button.text = "%s · pin %d: %s" % [l.name, l.pin, next]


func _build_footer() -> void:
	var problems := MachineConfig.validate()
	if not problems.is_empty():
		var errors := UiKit.section(_list, "Problems")
		for problem in problems:
			errors.add_child(UiKit.colored(problem, UiKit.BAD_COLOR))
	var body := UiKit.section(_list, "Layout")
	body.add_child(UiKit.button("Reset to default layout", _ask_reset, UiKit.DANGER))
	body.add_child(UiKit.detail("Layout file: " + ProjectSettings.globalize_path(MachineConfig.loaded_from)))


func _flow() -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", 12)
	f.add_theme_constant_override("v_separation", 8)
	return f


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
	if i.sound != &"":
		parts.append("sound %s%s" % [i.sound, "" if Media.has_sound(i.sound) else " (file missing)"])
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

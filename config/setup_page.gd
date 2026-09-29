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

	_list_scroll = ScrollContainer.new()
	_list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_list_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 10)
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
	_build_boards()
	_build_coils()
	_build_switches()
	_build_footer()


func _build_boards() -> void:
	_list.add_child(UiKit.heading("Boards"))
	for b in MachineConfig.boards:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		var label := Label.new()
		label.text = "%s  —  %s" % [b.id, BoardTypes.display_name(b.type)]
		label.custom_minimum_size.x = 320
		row.add_child(label)
		var port := PinballIO.get_port_for_board(b.id)
		if port.is_empty():
			row.add_child(UiKit.colored("not connected (connect on the Diagnostics tab)", UiKit.WARN_COLOR))
		elif PinballIO.is_board_burned(b.id):
			row.add_child(UiKit.colored("running on %s  —  layout burned ✓" % port, UiKit.OK_COLOR))
		else:
			row.add_child(UiKit.colored("running on %s  —  NOT burned: lost at power-off" % port, UiKit.WARN_COLOR))
			row.add_child(UiKit.button("Burn to board", _burn.bind(b.id)))
		_list.add_child(row)


func _build_coils() -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	head.add_child(UiKit.heading("Coils"))
	head.add_child(UiKit.button("+ Add coil", _open_coil_wizard.bind(&"")))
	_list.add_child(head)
	if MachineConfig.coils.is_empty():
		_list.add_child(UiKit.note("No coils yet. Add one to get started."))
	for c in MachineConfig.coils:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var title := Label.new()
		title.text = "%s   (pin %d)" % [c.name, c.pin]
		title.custom_minimum_size.x = 260
		row.add_child(title)
		var about := UiKit.note(_describe_coil(c))
		about.size_flags_horizontal = SIZE_EXPAND_FILL
		row.add_child(about)
		row.add_child(UiKit.button("Fire once", func() -> void: PinballIO.pulse_coil(c.name)))
		row.add_child(UiKit.button("Edit", _open_coil_wizard.bind(c.name)))
		row.add_child(UiKit.button("Delete", _ask_delete_coil.bind(c.name)))
		_list.add_child(row)


func _build_switches() -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	head.add_child(UiKit.heading("Switches"))
	head.add_child(UiKit.button("+ Add switch", _open_input_editor.bind(&"")))
	_list.add_child(head)
	_list.add_child(UiKit.note("Switches can also be created from a coil's setup (as its trigger or EOS). Lamps show live state while a board is running."))
	for i in MachineConfig.inputs:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var lamp := UiKit.lamp(PinballIO.is_switch_active(i.name))
		_switch_lamps[i.name] = lamp
		row.add_child(lamp)
		var title := Label.new()
		title.text = "%s   (pin %d%s)" % [i.name, i.pin, ", NC" if i.nc else ""]
		title.custom_minimum_size.x = 332
		row.add_child(title)
		var users := MachineConfig.coils_using_input(i.name)
		var about := UiKit.note("used by " + ", ".join(users) if not users.is_empty() else "not used by a coil (game code can still read it)")
		about.size_flags_horizontal = SIZE_EXPAND_FILL
		row.add_child(about)
		row.add_child(UiKit.button("Edit", _open_input_editor.bind(i.name)))
		row.add_child(UiKit.button("Delete", _ask_delete_input.bind(i.name)))
		_list.add_child(row)


func _build_footer() -> void:
	_list.add_child(HSeparator.new())
	_list.add_child(UiKit.note("Lamps: all lighting will be WS2812B LED chains, set up in a later version."))
	var problems := MachineConfig.validate()
	for problem in problems:
		_list.add_child(UiKit.colored("Config problem: " + problem, UiKit.BAD_COLOR))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.add_child(UiKit.note("Machine config: " + ProjectSettings.globalize_path(MachineConfig.loaded_from)))
	row.add_child(UiKit.button("Reset to default layout", _ask_reset))
	_list.add_child(row)


## One line explaining what a coil does, in plain words.
func _describe_coil(c: IoDefs.CoilDef) -> String:
	var text := "%d ms full power" % c.full_ms
	if c.hold_pct > 0:
		text += " → hold %d%%" % c.hold_pct
	if c.trigger != &"":
		text += ", fired by %s" % c.trigger
	else:
		text += ", fired by the game"
	if c.eos != &"":
		text += ", EOS %s" % c.eos
	if c.recycle_ms > 0:
		text += ", %d ms recycle" % c.recycle_ms
	return text


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

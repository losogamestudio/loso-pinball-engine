extends Control
## Diagnostics panel: the Diagnostics tab of the service menu (P key). Attach to the root Control
## of a scene. Builds its own UI in code, so there's no .tscn wiring to get wrong.
##
## Everything machine-specific (which switches, coils and lamps exist) comes
## from MachineConfig, so this panel follows the config instead of assuming a
## fixed layout. Shows: port picker, link/board status, fake score, a live lamp
## per switch, a button per coil (plus a rule toggle for coils with a trigger),
## a mode button per lamp, ping, and a log of every line in and out.

const LAMP_OFF := UiKit.LAMP_OFF
const LAMP_ON := UiKit.LAMP_ON
const HB_LAMP_ON := Color(0.35, 1.0, 0.45)
const HB_FADE_SEC := 0.4                 ## boards send HB once/sec; fade fully before the next one
const LOG_MAX_LINES := 300

var _port_menu: OptionButton
var _status: Label
var _heartbeat_lamp: ColorRect
var _score_label: Label
var _config_label: Label
var _switch_row: HFlowContainer
var _coil_row: HFlowContainer
var _lamp_row: HFlowContainer
var _log: RichTextLabel
var _auto_connect_toggle: CheckButton
var _switch_lamps := {}                  ## switch name -> ColorRect
var _score := 0


func _ready() -> void:
	_build_ui()

	# Signals are Godot's event dispatchers: subscribe once, react forever.
	# (They disconnect by themselves when this panel is freed.)
	PinballIO.port_linked.connect(_on_port_linked)
	PinballIO.port_unlinked.connect(_on_port_unlinked)
	PinballIO.board_ready.connect(_on_board_ready)
	PinballIO.board_problem.connect(_on_board_problem)
	PinballIO.board_notice.connect(_on_board_notice)
	PinballIO.board_burned.connect(_on_board_burned)
	PinballIO.switch_changed.connect(_on_switch_changed)
	PinballIO.coil_fired.connect(_on_coil_fired)
	PinballIO.watchdog_changed.connect(_on_watchdog_changed)
	PinballIO.latency_measured.connect(_on_latency)
	PinballIO.heartbeat.connect(_on_heartbeat)
	PinballIO.line_received.connect(_on_line_received)
	PinballIO.line_sent.connect(_on_line_sent)
	MachineConfig.changed.connect(_build_io_rows)

	_refresh_ports()
	_build_io_rows()

	# PinballIO may already be connected (it lives on while this page opens
	# and closes, and may have auto-connected at startup) — reflect that.
	if PinballIO.is_ready():
		_set_status("Ready: all boards configured", Color.PALE_GREEN)
	elif PinballIO.is_any_port_open():
		_set_status("Port open, waiting for board…", Color.KHAKI)


func _input(event: InputEvent) -> void:
	# Keyboard stand-in for the first two coils' buttons — there's no keyboard
	# on the real cabinet, so this only ever exists for bench-testing.
	# Only while this tab is showing (_input runs even for hidden nodes).
	if not is_visible_in_tree():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key_event := event as InputEventKey
		var coil_index := -1
		if key_event.keycode == KEY_LEFT:
			coil_index = 0
		elif key_event.keycode == KEY_RIGHT:
			coil_index = 1
		if coil_index != -1 and coil_index < MachineConfig.coils.size():
			PinballIO.pulse_coil(MachineConfig.coils[coil_index].name)
			accept_event()


# ---------------------------------------------------------------- board events

func _on_port_linked(port: String, firmware: String, board_type: String, uid: String) -> void:
	_set_status("Linked on %s: %s, sending config…" % [port, firmware], Color.KHAKI)
	_log_line("[color=pale_green]%s answered: %s %s serial %s[/color]" % [port, firmware, board_type, uid])


func _on_port_unlinked(port: String) -> void:
	_set_status("Not linked", Color.SALMON)
	_log_line("[color=salmon]%s: link lost[/color]" % port)
	_heartbeat_lamp.color = LAMP_OFF   # don't leave it looking alive once the link is gone
	for lamp: ColorRect in _switch_lamps.values():
		lamp.color = LAMP_OFF


func _on_board_ready(board_id: StringName) -> void:
	var burned := "burned" if PinballIO.is_board_burned(board_id) else "NOT burned"
	_set_status("Ready: board '%s' configured (%s)" % [board_id, burned], Color.PALE_GREEN)
	_log_line("[color=pale_green]Board '%s' is running its layout[/color]" % board_id)


func _on_board_notice(port: String, message: String) -> void:
	_log_line("[color=khaki]%s: %s[/color]" % [port, message])


func _on_board_burned(board_id: StringName) -> void:
	_set_status("Ready: board '%s' configured (burned)" % board_id, Color.PALE_GREEN)
	_log_line("[color=pale_green]Board '%s' stored its layout: it now boots configured[/color]" % board_id)


func _burn_all_boards() -> void:
	for b in MachineConfig.boards:
		if not PinballIO.burn_board(b.id):
			_log_line("[color=salmon]Can't burn board '%s': it isn't connected and ready[/color]" % b.id)


func _on_board_problem(port: String, message: String) -> void:
	_set_status("Problem on %s (see log)" % port, Color.SALMON)
	_log_line("[color=salmon]%s: %s[/color]" % [port, message])


func _on_switch_changed(switch_name: StringName, active: bool) -> void:
	var lamp: ColorRect = _switch_lamps.get(switch_name)
	if lamp:
		lamp.color = LAMP_ON if active else LAMP_OFF
	if active:
		_add_score(10)


func _on_coil_fired(_coil_name: StringName) -> void:
	# The board already fired the coil. We just score it and make noise.
	_add_score(100)
	_flash(_score_label)


func _on_watchdog_changed(board_id: StringName, tripped: bool) -> void:
	if tripped:
		_set_status("Watchdog tripped on '%s': outputs off" % board_id, Color.ORANGE)
	else:
		# PinballIO re-sends the wanted rules and lamps by itself.
		_set_status("Watchdog cleared on '%s'" % board_id, Color.PALE_GREEN)


func _on_latency(port: String, ms: float) -> void:
	_log_line("[color=light_sky_blue]%s round trip: %.2f ms[/color]" % [port, ms])


func _on_heartbeat(_port: String, _millis: int) -> void:
	# Pulse and fade rather than just toggle, so a stalled link is obviously
	# different from a live one even if you glance away for a second.
	_heartbeat_lamp.color = HB_LAMP_ON
	var tween := create_tween()
	tween.tween_property(_heartbeat_lamp, "color", LAMP_OFF, HB_FADE_SEC)


func _on_line_received(_port: String, line: String) -> void:
	if not line.begins_with("HB"):   # heartbeats are noise in the log
		_log_line("<  " + line)


func _on_line_sent(_port: String, line: String) -> void:
	if line != "HB" and not line.begins_with("PING"):
		_log_line("[color=gray]>  %s[/color]" % line)


# ---------------------------------------------------------------- helpers

func _add_score(points: int) -> void:
	_score += points
	_score_label.text = "SCORE  %d" % _score


func _flash(node: CanvasItem) -> void:
	# Tweens are the quick way to animate anything without a timeline.
	var tween := create_tween()
	node.modulate = Color(2, 2, 0.5)
	tween.tween_property(node, "modulate", Color.WHITE, 0.3)


func _set_status(text: String, color: Color) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", color)


func _log_line(text: String) -> void:
	_log.append_text(text + "\n")
	while _log.get_paragraph_count() > LOG_MAX_LINES:
		_log.remove_paragraph(0)


func _refresh_ports() -> void:
	_port_menu.clear()
	var ports: Array[String] = PinballIO.list_ports()
	for p in ports:
		_port_menu.add_item(p)
	if _port_menu.item_count == 0:
		_port_menu.add_item("(no ports)")
		_port_menu.disabled = true
	else:
		_port_menu.disabled = false
		var last_index: int = ports.find(PinballIO.last_port)
		if last_index != -1:
			_port_menu.select(last_index)


func _on_connect_pressed() -> void:
	if _port_menu.disabled:
		return
	var port := _port_menu.get_item_text(_port_menu.selected)
	if PinballIO.open_port(port):
		_set_status("Port open, waiting for board…", Color.KHAKI)
	else:
		_set_status("Could not open " + port, Color.SALMON)


func _set_all_rules(on: bool) -> void:
	PinballIO.set_all_rules(on)
	_build_io_rows()   # so the rule checkboxes show the new state


func _cycle_lamp(lamp_name: StringName, button: Button) -> void:
	var modes: Array[String] = PinballIO.LAMP_MODES
	var next: String = modes[(modes.find(PinballIO.get_lamp_mode(lamp_name)) + 1) % modes.size()]
	PinballIO.set_lamp(lamp_name, next)
	button.text = "%s: %s" % [lamp_name, next]


# ---------------------------------------------------------------- UI building

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)

	# Everything scrolls (bar always shown), so a small screen or big text
	# never cuts anything off.
	var scroll := UiKit.scroll_container()   # always-on, finger-wide scroll bar
	margin.add_child(scroll)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(root)

	# Connection. HFlowContainer wraps onto a second line when it doesn't fit.
	var connection := UiKit.section(root, "Connection")
	var conn := _flow()
	connection.add_child(conn)
	_port_menu = OptionButton.new()
	_port_menu.custom_minimum_size.x = 220
	conn.add_child(_port_menu)
	conn.add_child(UiKit.button("Refresh", _refresh_ports))
	conn.add_child(UiKit.button("Connect", _on_connect_pressed, UiKit.PRIMARY))
	conn.add_child(UiKit.button("Disconnect all", func() -> void: PinballIO.close_port()))
	_auto_connect_toggle = CheckButton.new()
	_auto_connect_toggle.text = "Auto-connect at startup"
	_auto_connect_toggle.button_pressed = PinballIO.auto_connect
	_auto_connect_toggle.toggled.connect(func(on: bool) -> void: PinballIO.set_auto_connect(on))
	conn.add_child(_auto_connect_toggle)

	var status_row := _flow()
	connection.add_child(status_row)
	_status = Label.new()
	status_row.add_child(_status)
	_set_status("Not connected", Color.SALMON)
	# Heartbeat: pulses once a second on the board's HB line, so a frozen
	# board (or a link that's technically "linked" but gone quiet) is obvious.
	var hb_box := HBoxContainer.new()
	hb_box.add_theme_constant_override("separation", 6)
	status_row.add_child(hb_box)
	var hb_label := Label.new()
	hb_label.text = "Board HB"
	hb_box.add_child(hb_label)
	_heartbeat_lamp = ColorRect.new()
	_heartbeat_lamp.custom_minimum_size = Vector2(18, 18)
	_heartbeat_lamp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_heartbeat_lamp.color = LAMP_OFF
	hb_box.add_child(_heartbeat_lamp)
	_config_label = UiKit.detail("")
	connection.add_child(_config_label)

	# Machine I/O rows, filled from MachineConfig by _build_io_rows().
	# HFlowContainer wraps onto more lines when there are lots of items.
	var switches := UiKit.section(root, "Switches")
	_switch_row = _flow()
	switches.add_child(_switch_row)
	_score_label = Label.new()
	_score_label.add_theme_font_size_override("font_size", DisplaySettings.font_size(20))
	switches.add_child(_score_label)
	_add_score(0)

	var coils := UiKit.section(root, "Coils")
	coils.add_child(UiKit.detail("← / → keys pulse the first two."))
	_coil_row = _flow()
	coils.add_child(_coil_row)

	var lamps := UiKit.section(root, "Lamps")
	_lamp_row = _flow()
	lamps.add_child(_lamp_row)

	var tools := UiKit.section(root, "Tools")
	var tool_row := _flow()
	tools.add_child(tool_row)
	tool_row.add_child(UiKit.button("Arm all rules", _set_all_rules.bind(true), UiKit.TEST))
	tool_row.add_child(UiKit.button("Disarm all rules", _set_all_rules.bind(false)))
	tool_row.add_child(UiKit.button("Ping", PinballIO.ping))
	tool_row.add_child(UiKit.button("Burn layout to board", _burn_all_boards, UiKit.PRIMARY))

	# Log
	var log_section := UiKit.section(root, "Log")
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.custom_minimum_size.y = 200   # inside a scroll area it needs a real height
	_log.add_theme_font_size_override("normal_font_size", DisplaySettings.font_size(UiKit.NOTE_SIZE))
	log_section.add_child(_log)


## (Re)build the switch / coil / lamp rows from the current machine config.
func _build_io_rows() -> void:
	for row: Node in [_switch_row, _coil_row, _lamp_row]:
		for child in row.get_children():
			child.queue_free()
	_switch_lamps.clear()

	var problems: PackedStringArray = MachineConfig.validate()
	_config_label.text = "Config: %s · %d switches, %d coils, %d lamps%s" % [
		MachineConfig.loaded_from, MachineConfig.inputs.size(), MachineConfig.coils.size(),
		MachineConfig.lamps.size(), "" if problems.is_empty() else " · %d PROBLEM(S), see log" % problems.size()]
	for problem in problems:
		_log_line("[color=salmon]config: %s[/color]" % problem)

	for input in MachineConfig.inputs:
		var card := UiKit.row_card(_switch_row)
		var box := VBoxContainer.new()
		card.add_child(box)
		var lamp := ColorRect.new()
		lamp.custom_minimum_size = Vector2(56, 32)
		lamp.color = LAMP_ON if PinballIO.is_switch_active(input.name) else LAMP_OFF
		box.add_child(lamp)
		var label := UiKit.detail("%s\npin %d" % [input.name, input.pin])
		label.autowrap_mode = TextServer.AUTOWRAP_OFF
		label.custom_minimum_size.x = 0
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(label)
		_switch_lamps[input.name] = lamp

	for coil in MachineConfig.coils:
		var card := UiKit.row_card(_coil_row)
		var box := VBoxContainer.new()
		card.add_child(box)
		var coil_name := coil.name   # captured by the lambdas below
		box.add_child(UiKit.button("Pulse %s (pin %d)" % [coil_name, coil.pin],
				func() -> void: PinballIO.pulse_coil(coil_name), UiKit.TEST))
		if coil.trigger != &"":
			var rule := CheckButton.new()
			rule.text = "Rule from %s" % coil.trigger
			rule.add_theme_font_size_override("font_size", DisplaySettings.font_size(UiKit.DETAIL_SIZE))
			rule.button_pressed = PinballIO.get_coil_rule(coil_name)
			rule.toggled.connect(func(on: bool) -> void: PinballIO.set_coil_rule(coil_name, on))
			box.add_child(rule)

	for lamp_def in MachineConfig.lamps:
		var b := Button.new()
		b.text = "%s: %s" % [lamp_def.name, PinballIO.get_lamp_mode(lamp_def.name)]
		b.pressed.connect(_cycle_lamp.bind(lamp_def.name, b))
		_lamp_row.add_child(b)


## A row of items that wraps onto more lines when it doesn't fit.
func _flow() -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", 10)
	f.add_theme_constant_override("v_separation", 8)
	return f

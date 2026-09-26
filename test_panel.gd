extends Control
## Test panel for the Teensy link. Attach to the root Control of a new scene.
## Builds its own UI in code so there's no .tscn wiring to get wrong.
##
## Shows: port picker, link status, fake score, live switch lamps,
## coil/LED/rule buttons, ping latency, analog bar, and a message log.

const NUM_SWITCHES := 4
const LAMP_OFF := Color(0.18, 0.18, 0.2)
const LAMP_ON := Color(1.0, 0.75, 0.1)
const HB_LAMP_ON := Color(0.35, 1.0, 0.45)
const HB_FADE_SEC := 0.4                 ## Teensy sends HB once/sec; fade fully before the next one
const LOG_MAX_LINES := 300
const LED_MODES := ["OFF", "ON", "BLINK"]

## There's no keyboard on the real cabinet — Left/Right are a desktop-only
## stand-in for bench-testing coils 0 and 1, same as clicking the buttons.
const COIL_0_TEST_PULSE_MS := 40
const COIL_1_TEST_PULSE_MS := 150

var _port_menu: OptionButton
var _status: Label
var _heartbeat_lamp: ColorRect
var _score_label: Label
var _analog_bar: ProgressBar
var _log: RichTextLabel
var _sling_toggle: CheckButton
var _auto_connect_toggle: CheckButton
var _switch_lamps: Array[ColorRect] = []
var _led_modes := ["OFF", "OFF"]
var _score := 0


func _ready() -> void:
	_build_ui()

	# Signals are Godot's event dispatchers: subscribe once, react forever.
	PinballIO.linked.connect(_on_linked)
	PinballIO.unlinked.connect(_on_unlinked)
	PinballIO.switch_changed.connect(_on_switch_changed)
	PinballIO.rule_fired.connect(_on_rule_fired)
	PinballIO.analog_changed.connect(_on_analog_changed)
	PinballIO.watchdog_changed.connect(_on_watchdog_changed)
	PinballIO.latency_measured.connect(_on_latency)
	PinballIO.heartbeat.connect(_on_heartbeat)
	PinballIO.line_received.connect(_on_line)

	_refresh_ports()

	# PinballIO may already be auto-connecting by the time this scene is ready
	# (autoloads run their _ready before the main scene does) — reflect that.
	if PinballIO.is_port_open:
		_set_status("Port open, waiting for Teensy…", Color.KHAKI)


func _input(event: InputEvent) -> void:
	# Keyboard stand-in for coil buttons — there's no keyboard on the real
	# cabinet, so this only ever exists for bench-testing from a desktop.
	if event is InputEventKey and event.pressed and not event.echo:
		var key_event := event as InputEventKey
		if key_event.keycode == KEY_LEFT:
			PinballIO.pulse_coil(0, COIL_0_TEST_PULSE_MS)
			accept_event()
		elif key_event.keycode == KEY_RIGHT:
			PinballIO.pulse_coil(1, COIL_1_TEST_PULSE_MS)
			accept_event()


# ---------------------------------------------------------------- game events

func _on_linked(firmware: String) -> void:
	_set_status("Linked: " + firmware, Color.PALE_GREEN)
	_log_line("[color=pale_green]Linked to %s[/color]" % firmware)
	_resend_outputs()


func _on_unlinked() -> void:
	_set_status("Not linked", Color.SALMON)
	_log_line("[color=salmon]Link lost[/color]")
	_heartbeat_lamp.color = LAMP_OFF   # don't leave it looking alive once the link is gone


func _on_switch_changed(id: int, active: bool) -> void:
	if id < _switch_lamps.size():
		_switch_lamps[id].color = LAMP_ON if active else LAMP_OFF
	if active:
		_add_score(10)


func _on_rule_fired(rule_name: String) -> void:
	# The Teensy already fired the coil. We just score it and make noise.
	if rule_name == "SLING_L":
		_add_score(100)
		_flash(_score_label)


func _on_analog_changed(id: int, value: int) -> void:
	if id == 0:
		_analog_bar.value = value


func _on_watchdog_changed(tripped: bool) -> void:
	if tripped:
		_set_status("Watchdog tripped — outputs off", Color.ORANGE)
	else:
		_set_status("Watchdog cleared", Color.PALE_GREEN)
		_resend_outputs()   # Teensy turned everything off; restore our state


func _on_latency(ms: float) -> void:
	_log_line("[color=light_sky_blue]Round trip: %.2f ms[/color]" % ms)


func _on_heartbeat(_millis: int) -> void:
	# Pulse and fade rather than just toggle, so a stalled link is obviously
	# different from a live one even if you glance away for a second.
	_heartbeat_lamp.color = HB_LAMP_ON
	var tween := create_tween()
	tween.tween_property(_heartbeat_lamp, "color", LAMP_OFF, HB_FADE_SEC)


func _on_line(line: String) -> void:
	if not line.begins_with("HB"):   # heartbeats are noise in the log
		_log_line("<  " + line)


# ---------------------------------------------------------------- helpers

func _resend_outputs() -> void:
	PinballIO.set_rule("SLING_L", _sling_toggle.button_pressed)
	for i in _led_modes.size():
		PinballIO.set_led(i, _led_modes[i])


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
	var ports := PinballIO.list_ports()
	for p in ports:
		_port_menu.add_item(p)
	if _port_menu.item_count == 0:
		_port_menu.add_item("(no ports)")
		_port_menu.disabled = true
	else:
		_port_menu.disabled = false
		var last_index := ports.find(PinballIO.last_port)
		if last_index != -1:
			_port_menu.select(last_index)


func _on_connect_pressed() -> void:
	if _port_menu.disabled:
		return
	var port := _port_menu.get_item_text(_port_menu.selected)
	if PinballIO.open_port(port):
		_set_status("Port open, waiting for Teensy…", Color.KHAKI)
	else:
		_set_status("Could not open " + port, Color.SALMON)


func _cycle_led(id: int, button: Button) -> void:
	var next: String = LED_MODES[(LED_MODES.find(_led_modes[id]) + 1) % LED_MODES.size()]
	_led_modes[id] = next
	button.text = "LED %d: %s" % [id, next]
	PinballIO.set_led(id, next)


# ---------------------------------------------------------------- UI building

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)

	# Connection row
	var conn := HBoxContainer.new()
	root.add_child(conn)
	_port_menu = OptionButton.new()
	_port_menu.custom_minimum_size.x = 220
	conn.add_child(_port_menu)
	conn.add_child(_make_button("Refresh", _refresh_ports))
	conn.add_child(_make_button("Connect", _on_connect_pressed))
	conn.add_child(_make_button("Disconnect", PinballIO.close_port))
	_auto_connect_toggle = CheckButton.new()
	_auto_connect_toggle.text = "Auto-connect at startup"
	_auto_connect_toggle.button_pressed = PinballIO.auto_connect
	_auto_connect_toggle.toggled.connect(func(on: bool): PinballIO.set_auto_connect(on))
	conn.add_child(_auto_connect_toggle)
	_status = Label.new()
	conn.add_child(_status)
	_set_status("Not connected", Color.SALMON)

	# Heartbeat: pulses once a second on the Teensy's HB line, so a frozen
	# Teensy (or a link that's technically "linked" but gone quiet) is obvious.
	var hb_box := HBoxContainer.new()
	hb_box.add_theme_constant_override("separation", 6)
	conn.add_child(hb_box)
	var hb_label := Label.new()
	hb_label.text = "Teensy HB"
	hb_box.add_child(hb_label)
	_heartbeat_lamp = ColorRect.new()
	_heartbeat_lamp.custom_minimum_size = Vector2(18, 18)
	_heartbeat_lamp.color = LAMP_OFF
	hb_box.add_child(_heartbeat_lamp)

	# Score
	_score_label = Label.new()
	_score_label.add_theme_font_size_override("font_size", 36)
	root.add_child(_score_label)
	_add_score(0)

	# Switch lamps
	var sw_row := HBoxContainer.new()
	sw_row.add_theme_constant_override("separation", 16)
	root.add_child(sw_row)
	for i in NUM_SWITCHES:
		var box := VBoxContainer.new()
		var lamp := ColorRect.new()
		lamp.custom_minimum_size = Vector2(56, 56)
		lamp.color = LAMP_OFF
		var label := Label.new()
		label.text = "SW %d" % i
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(lamp)
		box.add_child(label)
		sw_row.add_child(box)
		_switch_lamps.append(lamp)

	# Outputs
	var out := HBoxContainer.new()
	root.add_child(out)
	out.add_child(_make_button("Pulse coil 0 (←)", func(): PinballIO.pulse_coil(0, COIL_0_TEST_PULSE_MS)))
	out.add_child(_make_button("Pulse coil 1 (→)", func(): PinballIO.pulse_coil(1, COIL_1_TEST_PULSE_MS)))
	for i in _led_modes.size():
		var b := Button.new()
		b.text = "LED %d: OFF" % i
		b.pressed.connect(_cycle_led.bind(i, b))
		out.add_child(b)
	_sling_toggle = CheckButton.new()
	_sling_toggle.text = "Sling rule (SW0 → coil 0)"
	_sling_toggle.toggled.connect(func(on: bool): PinballIO.set_rule("SLING_L", on))
	out.add_child(_sling_toggle)
	out.add_child(_make_button("Ping", PinballIO.ping))

	# Analog
	var ana_label := Label.new()
	ana_label.text = "Analog 0 (pot on A0)"
	root.add_child(ana_label)
	_analog_bar = ProgressBar.new()
	_analog_bar.max_value = 1023
	root.add_child(_analog_bar)

	# Log
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_log)


func _make_button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(on_press)
	return b

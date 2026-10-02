extends Control
## Monitor: the first tab of the service menu. Live machine state at a glance.
##
##   left third   - an LED per input, coil and lamp, grouped per board, with
##                  just the pin number on it (the Hardware tab has the details)
##   right 2/3    - the log: every line to and from the boards, plus events
##
## Built in code from MachineConfig, so it follows the layout. Connecting and
## testing things is on the Hardware tab.
##
## Coil LEDs: boards don't report their outputs, so a coil LED shows what
## Godot knows: lit while a pulse/hold it sent is running, when a rule reports
## FIRED, and while a flipper is held (rule armed + trigger switch closed).
## A cyan outline = that coil's rule is armed.

const LED_OFF := UiKit.LAMP_OFF
const LED_ON := UiKit.LAMP_ON
const HB_LED_ON := Color(0.35, 1.0, 0.45)
const HB_FADE_SEC := 0.4                 ## boards send HB once/sec; fade fully before the next one
const LED_SIZE := Vector2(46, 36)
const MIN_FLASH_MS := 150                ## short pulses still show long enough to see
const BLINK_MS := 250                    ## lamp BLINK shown at this half-period
const LOG_MAX_LINES := 300

var _status: Label
var _heartbeat_led: ColorRect
var _led_box: VBoxContainer
var _log: RichTextLabel
var _input_leds := {}      ## input name -> StyleBoxFlat
var _coil_leds := {}       ## coil name -> StyleBoxFlat
var _lamp_leds := {}       ## lamp name -> StyleBoxFlat
var _light_leds := {}      ## LED light name -> StyleBoxFlat (shows its color)
var _servo_leds := {}      ## servo name -> StyleBoxFlat (lit while a move Godot sent is running)
var _coil_lit_until := {}  ## coil name -> Time.get_ticks_msec() when a flash ends
var _coil_held := {}       ## coil name -> true while a HOLD ON is running


func _ready() -> void:
	_build_ui()

	# Signals are Godot's event dispatchers: subscribe once, react forever.
	# (They disconnect by themselves when this tab is freed.)
	PinballIO.port_linked.connect(_on_port_linked)
	PinballIO.port_unlinked.connect(_on_port_unlinked)
	PinballIO.board_ready.connect(_on_board_ready)
	PinballIO.board_problem.connect(_on_board_problem)
	PinballIO.board_notice.connect(_on_board_notice)
	PinballIO.board_burned.connect(_on_board_burned)
	PinballIO.coil_fired.connect(_on_coil_fired)
	PinballIO.coil_commanded.connect(_on_coil_commanded)
	PinballIO.watchdog_changed.connect(_on_watchdog_changed)
	PinballIO.latency_measured.connect(_on_latency)
	PinballIO.heartbeat.connect(_on_heartbeat)
	PinballIO.line_received.connect(_on_line_received)
	PinballIO.line_sent.connect(_on_line_sent)
	MachineConfig.changed.connect(_build_leds)
	_build_leds()

	# PinballIO lives on while this menu opens and closes, and may have
	# auto-connected at startup, so show where it is now.
	if PinballIO.is_ready():
		_set_status("Ready: all boards running", UiKit.OK_COLOR)
	elif PinballIO.is_any_port_open():
		_set_status("Port open, waiting for board…", UiKit.WARN_COLOR)
	else:
		_set_status("Not connected (Hardware tab)", UiKit.BAD_COLOR)


## LEDs follow state every frame while the tab shows: a handful of compares,
## simpler than keeping every event in step (and BLINK needs a clock anyway).
func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	var now := Time.get_ticks_msec()
	for input_name: StringName in _input_leds:
		_light(_input_leds[input_name], PinballIO.is_switch_active(input_name))
	for coil_name: StringName in _coil_leds:
		var style: StyleBoxFlat = _coil_leds[coil_name]
		var armed := PinballIO.get_coil_rule(coil_name)
		_light(style, _coil_held.has(coil_name) or now < int(_coil_lit_until.get(coil_name, 0))
				or (armed and _flipper_held(coil_name)))
		style.border_color = UiKit.ACCENT_COLOR if armed else Color(0, 0, 0, 0)
	for lamp_name: StringName in _lamp_leds:
		var mode := PinballIO.get_lamp_mode(lamp_name)
		_light(_lamp_leds[lamp_name], mode == "ON" or (mode == "BLINK" and (now / BLINK_MS) % 2 == 0))
	for light_name: StringName in _light_leds:
		(_light_leds[light_name] as StyleBoxFlat).bg_color = _light_preview(PinballIO.get_light(light_name), now)
	for servo_name: StringName in _servo_leds:
		_light(_servo_leds[servo_name], PinballIO.is_servo_moving(servo_name))


## Roughly what an LED light looks like right now, from what it was told to do.
## The board draws the real thing; this is a one-swatch summary of it.
func _light_preview(want: Dictionary, now: int) -> Color:
	var c1: Color = want["color"]
	var c2: Color = want["color2"]
	var ms: int = maxi(want["ms"], 1)
	match want["effect"]:
		"OFF":
			return LED_OFF
		"BLINK":
			return c2 if (now / ms) % 2 else c1
		"PULSE":
			return c1 * (0.3 + 0.7 * absf(sin(PI * float(now % ms) / ms)))
		"RAINBOW":
			return Color.from_hsv(float(now % ms) / ms, 1.0, 1.0)
		_:
			return c1   # SOLID, CHASE, WIPE, FADE, SPARKLE: their main color


## A holding coil (a flipper) stays on on the board while its trigger is closed.
func _flipper_held(coil_name: StringName) -> bool:
	var c := MachineConfig.find_coil(coil_name)
	return c != null and c.hold_pct > 0 and c.trigger != &"" and PinballIO.is_switch_active(c.trigger)


func _light(style: StyleBoxFlat, on: bool) -> void:
	style.bg_color = LED_ON if on else LED_OFF


# ---------------------------------------------------------------- board events

func _on_port_linked(port: String, firmware: String, board_type: String, uid: String) -> void:
	_set_status("Linked on %s, sending config…" % port, UiKit.WARN_COLOR)
	_log_line("[color=pale_green]%s answered: %s %s serial %s[/color]" % [port, firmware, board_type, uid])


func _on_port_unlinked(port: String) -> void:
	_set_status("Not linked", UiKit.BAD_COLOR)
	_log_line("[color=salmon]%s: link lost[/color]" % port)
	_heartbeat_led.color = LED_OFF   # don't leave it looking alive once the link is gone


func _on_board_ready(board_id: StringName) -> void:
	var burned := "burned" if PinballIO.is_board_burned(board_id) else "NOT burned"
	_set_status("Ready: '%s' running (%s)" % [board_id, burned], UiKit.OK_COLOR)
	_log_line("[color=pale_green]Board '%s' is running its layout[/color]" % board_id)


func _on_board_notice(port: String, message: String) -> void:
	_log_line("[color=khaki]%s: %s[/color]" % [port, message])


func _on_board_burned(board_id: StringName) -> void:
	_set_status("Ready: '%s' running (burned)" % board_id, UiKit.OK_COLOR)
	_log_line("[color=pale_green]Board '%s' stored its layout: it now boots configured[/color]" % board_id)


func _on_board_problem(port: String, message: String) -> void:
	_set_status("Problem on %s (see log)" % port, UiKit.BAD_COLOR)
	_log_line("[color=salmon]%s: %s[/color]" % [port, message])


func _on_coil_fired(coil_name: StringName) -> void:
	_flash_coil(coil_name)


func _on_coil_commanded(coil_name: StringName, on: bool, is_pulse: bool) -> void:
	if is_pulse:
		_flash_coil(coil_name)
	elif on:
		_coil_held[coil_name] = true
	else:
		_coil_held.erase(coil_name)


func _flash_coil(coil_name: StringName) -> void:
	var c := MachineConfig.find_coil(coil_name)
	var ms := maxi(c.full_ms if c else 0, MIN_FLASH_MS)
	_coil_lit_until[coil_name] = Time.get_ticks_msec() + ms


func _on_watchdog_changed(board_id: StringName, tripped: bool) -> void:
	if tripped:
		_set_status("Watchdog tripped on '%s': outputs off" % board_id, Color.ORANGE)
		_coil_held.clear()
	else:
		# PinballIO re-sends the wanted rules and lamps by itself.
		_set_status("Watchdog cleared on '%s'" % board_id, UiKit.OK_COLOR)


func _on_latency(port: String, ms: float) -> void:
	_log_line("[color=light_sky_blue]%s round trip: %.2f ms[/color]" % [port, ms])


func _on_heartbeat(_port: String, _millis: int) -> void:
	# Pulse and fade rather than just toggle, so a stalled link is obviously
	# different from a live one even if you glance away for a second.
	_heartbeat_led.color = HB_LED_ON
	var tween := create_tween()
	tween.tween_property(_heartbeat_led, "color", LED_OFF, HB_FADE_SEC)


func _on_line_received(_port: String, line: String) -> void:
	if not line.begins_with("HB"):   # heartbeats are noise in the log
		_log_line("<  " + line)


func _on_line_sent(_port: String, line: String) -> void:
	if line != "HB" and not line.begins_with("PING"):
		_log_line("[color=gray]>  %s[/color]" % line)


# ---------------------------------------------------------------- helpers

func _set_status(text: String, color: Color) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", color)


func _log_line(text: String) -> void:
	_log.append_text(text + "\n")
	while _log.get_paragraph_count() > LOG_MAX_LINES:
		_log.remove_paragraph(0)


# ---------------------------------------------------------------- UI building

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)

	# Left third LEDs, right two thirds log: both expand, in a 1 : 2 ratio.
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 12)
	margin.add_child(split)

	var left := UiKit.scroll_container()
	left.size_flags_horizontal = SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.0
	split.add_child(left)
	var left_box := VBoxContainer.new()
	left_box.size_flags_horizontal = SIZE_EXPAND_FILL
	left_box.add_theme_constant_override("separation", 10)
	left.add_child(left_box)

	var link := UiKit.section(left_box, "Link")
	var hb_row := HBoxContainer.new()
	hb_row.add_theme_constant_override("separation", 8)
	link.add_child(hb_row)
	_heartbeat_led = ColorRect.new()
	_heartbeat_led.custom_minimum_size = Vector2(22, 22)
	_heartbeat_led.size_flags_vertical = SIZE_SHRINK_CENTER
	_heartbeat_led.color = LED_OFF
	hb_row.add_child(_heartbeat_led)
	hb_row.add_child(UiKit.detail("heartbeat"))
	_status = UiKit.detail("")
	_status.modulate = Color.WHITE
	link.add_child(_status)

	_led_box = VBoxContainer.new()
	_led_box.add_theme_constant_override("separation", 10)
	left_box.add_child(_led_box)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 2.0
	split.add_child(right)
	var log_head: Array[Control] = [
		UiKit.button("Ping", PinballIO.ping),
		UiKit.button("Clear", func() -> void: _log.clear()),
	]
	var log_body := UiKit.section(right, "Log", log_head)
	(log_body.get_parent() as Control).size_flags_vertical = SIZE_EXPAND_FILL   # the card fills the height
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.size_flags_vertical = SIZE_EXPAND_FILL
	_log.add_theme_font_size_override("normal_font_size", DisplaySettings.font_size(UiKit.NOTE_SIZE))
	log_body.add_child(_log)


## (Re)build the LED groups from the current machine config.
func _build_leds() -> void:
	UiKit.free_children(_led_box)
	_input_leds.clear()
	_coil_leds.clear()
	_lamp_leds.clear()
	_light_leds.clear()
	_servo_leds.clear()
	var several := MachineConfig.boards.size() > 1
	for b in MachineConfig.boards:
		var body := UiKit.section(_led_box, b.id if several else "I/O")
		_led_group(body, "Inputs", MachineConfig.inputs.filter(func(i: IoDefs.InputDef) -> bool: return i.board == b.id), _input_leds)
		_led_group(body, "Coils", MachineConfig.coils.filter(func(c: IoDefs.CoilDef) -> bool: return c.board == b.id), _coil_leds)
		_led_group(body, "Lamps", MachineConfig.lamps.filter(func(l: IoDefs.LampDef) -> bool: return l.board == b.id), _lamp_leds)
		# LED lights show their first LED's number (they have no pin of their own).
		var lights_here := MachineConfig.lights.filter(func(l: IoDefs.LightDef) -> bool: return MachineConfig.light_board(l) == b.id)
		_led_group(body, "Lights", lights_here, _light_leds, "first")
		# Servos show their pin, or P<pca>:<channel> like the board's CFG line.
		var servos_here := MachineConfig.servos.filter(func(s: IoDefs.ServoDef) -> bool: return s.board == b.id)
		var addrs: Array[int] = MachineConfig.pca_addrs(b.id)
		_led_group(body, "Servos", servos_here, _servo_leds, "pin", func(s: IoDefs.ServoDef) -> String:
			return "P%d:%d" % [addrs.find(s.pca_addr), s.channel] if s.on_pca() else str(s.pin))


## A small heading and a wrapping row of LEDs, one per item, sorted by
## [param number_field] ("pin", or "first" for LED lights), which is also the
## number shown on each LED unless [param label_of] (item -> String) says otherwise.
func _led_group(parent: Control, title: String, items: Array, leds: Dictionary, number_field := "pin",
		label_of := Callable()) -> void:
	if items.is_empty():
		return
	var heading := UiKit.detail(title)
	heading.modulate = Color.WHITE
	heading.add_theme_color_override("font_color", UiKit.ACCENT_COLOR)
	parent.add_child(heading)
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 6)
	parent.add_child(row)
	items.sort_custom(func(a: Variant, b: Variant) -> bool: return a.get(number_field) < b.get(number_field))
	for item: Variant in items:
		var style := StyleBoxFlat.new()
		style.bg_color = LED_OFF
		style.set_corner_radius_all(4)
		style.set_border_width_all(2)
		style.border_color = Color(0, 0, 0, 0)
		var led := Panel.new()
		led.custom_minimum_size = LED_SIZE
		led.add_theme_stylebox_override("panel", style)
		led.tooltip_text = String(item.name)   # the name, for a mouse on the desktop
		var pin := Label.new()
		pin.text = label_of.call(item) if label_of.is_valid() else str(item.get(number_field))
		pin.set_anchors_preset(Control.PRESET_FULL_RECT)
		pin.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		pin.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		pin.add_theme_font_size_override("font_size", DisplaySettings.font_size(UiKit.DETAIL_SIZE))
		pin.add_theme_color_override("font_color", Color.WHITE)
		pin.add_theme_color_override("font_outline_color", Color.BLACK)
		pin.add_theme_constant_override("outline_size", 4)   # readable on a lit (amber) LED too
		led.add_child(pin)
		# Wider for longer labels (a servo's "P0:3"), so the text stays inside.
		led.custom_minimum_size.x = maxf(LED_SIZE.x, pin.text.length() * DisplaySettings.font_size(UiKit.DETAIL_SIZE) * 0.62 + 10.0)
		row.add_child(led)
		leds[item.name] = style

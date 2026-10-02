extends "res://config/draft_editor.gd"
## ServoEditor — one hobby servo: where it's wired (a board output pin, or a
## channel on a PCA9685 servo board), its pulse range and its home position,
## plus a "Try it" slider that moves the real servo. Shown inside the Hardware
## tab; see draft_editor.gd.

const OUT_PIN := 0
const OUT_PCA := 1

var _draft := IoDefs.ServoDef.new()
var _original_board: StringName = &""
var _original_pin := -1
var _try_ms := 500
var _try_ease := "SMOOTH"


## Call before adding to the tree. Empty name = add a new servo.
func open(servo_name: StringName = &"") -> void:
	var existing := MachineConfig.find_servo(servo_name)
	if existing:
		_original_board = existing.board
		_original_pin = existing.pin
		_draft = IoDefs.ServoDef.from_dict(existing.to_dict())
		_begin(servo_name)
	else:
		if not MachineConfig.boards.is_empty():
			_draft.board = MachineConfig.boards[0].id
		_draft.name = MachineConfig.unique_name("servo")
		_draft.pin = -1   # PCA9685 by default: that's where most servos go
		_draft.channel = _first_free_channel(_draft.pca_addr)
		_begin(&"")


func _title() -> String:
	return "Edit servo '%s'" % _original_name if _original_name != &"" else "Add a servo"


func _draft_board() -> StringName:
	return _draft.board


func _build_fields() -> void:
	var name_edit := LineEdit.new()
	name_edit.text = String(_draft.name)
	name_edit.custom_minimum_size.x = 280
	name_edit.text_changed.connect(func(text: String) -> void:
		_draft.name = StringName(text.strip_edges())
		_refresh())
	_body.add_child(UiKit.field("Name", name_edit))

	if MachineConfig.boards.size() > 1:
		var board_pick := OptionButton.new()
		for b in MachineConfig.boards:
			board_pick.add_item("%s  (%s)" % [b.id, BoardTypes.display_name(b.type)])
			board_pick.set_item_metadata(board_pick.item_count - 1, b.id)
			if b.id == _draft.board:
				board_pick.select(board_pick.item_count - 1)
		board_pick.item_selected.connect(func(index: int) -> void:
			_draft.board = board_pick.get_item_metadata(index)
			if not _draft.on_pca():
				_draft.pin = _first_free_pin()
			_build())
		_body.add_child(UiKit.field("Board", board_pick))

	# Where it's wired: a board pin, or a PCA9685 channel.
	var output_pick := OptionButton.new()
	output_pick.add_item("PCA9685 servo board", OUT_PCA)
	output_pick.add_item("Board output pin", OUT_PIN)
	output_pick.select(output_pick.get_item_index(OUT_PCA if _draft.on_pca() else OUT_PIN))
	output_pick.item_selected.connect(func(index: int) -> void:
		if output_pick.get_item_id(index) == OUT_PCA:
			_draft.pin = -1
			_draft.channel = _first_free_channel(_draft.pca_addr)
		else:
			_draft.pin = _first_free_pin()
		_build())
	_body.add_child(UiKit.field("Wired to", output_pick))

	if _draft.on_pca():
		var addr_pick := OptionButton.new()
		for addr in range(0x40, 0x80):
			addr_pick.add_item(_addr_text(addr), addr)
		addr_pick.select(addr_pick.get_item_index(_draft.pca_addr))
		addr_pick.item_selected.connect(func(index: int) -> void:
			_draft.pca_addr = addr_pick.get_item_id(index)
			_refresh())
		_body.add_child(UiKit.field("PCA address", addr_pick))
		var channel := UiKit.spin(0, 15, _draft.channel, "", func(v: float) -> void:
			_draft.channel = int(v)
			_refresh())
		_body.add_child(UiKit.field("Channel", channel))
	else:
		var pin_pick := OptionButton.new()
		var keep := _original_pin if _draft.board == _original_board else -1
		for pin in MachineConfig.free_pins(_draft.board, BoardTypes.CAP_OUT, keep):
			pin_pick.add_item("Pin %d" % pin, pin)
		if pin_pick.item_count == 0:
			_draft.pin = -1
			_body.add_child(UiKit.colored("No free output pins left on board '%s'. Use a PCA9685." % _draft.board, UiKit.BAD_COLOR))
		else:
			if pin_pick.get_item_index(_draft.pin) == -1:
				_draft.pin = pin_pick.get_item_id(0)
			pin_pick.select(pin_pick.get_item_index(_draft.pin))
			pin_pick.item_selected.connect(func(index: int) -> void: _draft.pin = pin_pick.get_item_id(index))
			_body.add_child(UiKit.field("Signal pin", pin_pick))

	var min_spin := UiKit.spin(IoDefs.SERVO_LOWEST_US, IoDefs.SERVO_HIGHEST_US, _draft.min_us, " µs", func(v: float) -> void:
		_draft.min_us = int(v)
		_refresh())
	min_spin.step = 10
	min_spin.custom_minimum_size.x = 200
	_body.add_child(UiKit.field("Pulse at 0%", min_spin))
	var max_spin := UiKit.spin(IoDefs.SERVO_LOWEST_US, IoDefs.SERVO_HIGHEST_US, _draft.max_us, " µs", func(v: float) -> void:
		_draft.max_us = int(v)
		_refresh())
	max_spin.step = 10
	max_spin.custom_minimum_size.x = 200
	_body.add_child(UiKit.field("Pulse at 100%", max_spin))
	var home := UiKit.spin(0, 100, roundf(_draft.home * 100.0), " %", func(v: float) -> void: _draft.home = v / 100.0)
	_body.add_child(UiKit.field("Home", home))
	_body.add_child(UiKit.note("1000-2000 µs is safe for most servos. Widen it a little at a time (e.g. 600-2400) for more travel; if the servo buzzes or strains at an end, that end is too far. Home is where it goes at power-up and when a new layout is sent."))

	_build_try_it()

	_body.add_child(UiKit.note("Power servos from their own 5-6 V supply (a PCA9685 has a V+ terminal for it), never from the Teensy, with the grounds joined. PCA9685: SDA to pin 18, SCL to pin 19, VCC to 3.3 V. See Docs/servos.md."))


## A slider that moves the real servo, plus quick Min / Home / Max.
func _build_try_it() -> void:
	_body.add_child(UiKit.heading("Try it", 18))
	var slider_row := HBoxContainer.new()
	slider_row.add_theme_constant_override("separation", 12)
	_body.add_child(slider_row)
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 1
	slider.value = roundf(_draft.home * 100.0)
	slider.size_flags_horizontal = SIZE_EXPAND_FILL
	slider.size_flags_vertical = SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(200, 40)
	slider_row.add_child(slider)
	var percent := Label.new()
	percent.text = "%d%%" % slider.value
	percent.custom_minimum_size.x = 90
	slider_row.add_child(percent)
	# While dragging it follows straight away (no ramp); let go to settle.
	slider.value_changed.connect(func(v: float) -> void:
		percent.text = "%d%%" % v
		_move(v / 100.0, 0, "LINEAR"))

	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 12)
	row.add_theme_constant_override("v_separation", 8)
	_body.add_child(row)
	for stop: Array in [["Min", 0.0], ["Home", -1.0], ["Max", 1.0]]:
		row.add_child(UiKit.button(stop[0], func() -> void:
			var target: float = _draft.home if stop[1] < 0.0 else stop[1]
			slider.set_value_no_signal(roundf(target * 100.0))
			percent.text = "%d%%" % slider.value
			_move(target, _try_ms, _try_ease), UiKit.TEST))
	var ramp := UiKit.spin(0, 10000, _try_ms, " ms", func(v: float) -> void: _try_ms = int(v))
	ramp.step = 50
	ramp.custom_minimum_size.x = 200
	row.add_child(ramp)
	var ease_pick := OptionButton.new()
	for ease in IoDefs.SERVO_EASES:
		ease_pick.add_item(ease.capitalize())
		if ease == _try_ease:
			ease_pick.select(ease_pick.item_count - 1)
	ease_pick.item_selected.connect(func(index: int) -> void: _try_ease = IoDefs.SERVO_EASES[index])
	row.add_child(ease_pick)
	_body.add_child(UiKit.detail("Min / Home / Max move over the ramp time; Smooth eases in and out."))


## Send the draft to the board if it isn't there yet, then move the servo.
func _move(position: float, ramp_ms: int, ease: String) -> void:
	if _draft_error() != "":
		return
	if not _applied:
		_try_on_board()
	if _applied:
		PinballIO.set_servo(_draft.name, position, ramp_ms, ease)


func _draft_error() -> String:
	var problem := _name_problem(_draft.name, "servo")
	if problem != "":
		return problem
	if not _draft.on_pca() and _draft.pin == -1:
		return "Pick a signal pin."
	if _draft.min_us >= _draft.max_us:
		return "The pulse at 0% must be shorter than at 100%."
	if _draft.on_pca():
		for s in MachineConfig.servos:
			if s.name != _original_name and s.board == _draft.board and s.on_pca() \
					and s.pca_addr == _draft.pca_addr and s.channel == _draft.channel:
				return "Servo '%s' already uses PCA %s channel %d." % [s.name, "0x%02X" % s.pca_addr, s.channel]
	return ""


func _put_draft() -> void:
	var servo := IoDefs.ServoDef.from_dict(_draft.to_dict())
	for n in MachineConfig.servos.size():
		if MachineConfig.servos[n].name == _original_name:
			MachineConfig.servos[n] = servo
			return
	MachineConfig.servos.append(servo)


func _first_free_pin() -> int:
	var keep := _original_pin if _draft.board == _original_board else -1
	var pins := MachineConfig.free_pins(_draft.board, BoardTypes.CAP_OUT, keep)
	return pins[0] if not pins.is_empty() else -1


func _first_free_channel(addr: int) -> int:
	var used := {}
	for s in MachineConfig.servos:
		if s.name != _original_name and s.board == _draft.board and s.on_pca() and s.pca_addr == addr:
			used[s.channel] = true
	for ch in 16:
		if not used.has(ch):
			return ch
	return 0


## "0x41 (A0 bridged)": which address jumpers on the PCA9685 give this address.
static func _addr_text(addr: int) -> String:
	var bits := addr - 0x40
	if bits == 0:
		return "0x40 (no jumpers)"
	var bridged: PackedStringArray = []
	for n in 6:
		if bits & (1 << n):
			bridged.append("A%d" % n)
	return "0x%02X (%s bridged)" % [addr, " ".join(bridged)]

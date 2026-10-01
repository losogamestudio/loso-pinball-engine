extends "res://config/draft_editor.gd"
## ChainEditor — one WS2812B LED chain: which output pin drives it, how many
## LEDs it has, and their color order. Renaming a chain also renames it in
## every light on it. Shown inside the Hardware tab; see draft_editor.gd.

var _draft := IoDefs.ChainDef.new()
var _original_board: StringName = &""
var _original_pin := -1


## Call before adding to the tree. Empty name = add a new chain.
func open(chain_name: StringName = &"") -> void:
	var existing := MachineConfig.find_chain(chain_name)
	if existing:
		_original_board = existing.board
		_original_pin = existing.pin
		_draft = IoDefs.ChainDef.from_dict(existing.to_dict())
		_begin(chain_name)
	else:
		if not MachineConfig.boards.is_empty():
			_draft.board = MachineConfig.boards[0].id
		_draft.name = MachineConfig.unique_name("led_chain")
		_begin(&"")


func _title() -> String:
	return "Edit LED chain '%s'" % _original_name if _original_name != &"" else "Add an LED chain"


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
			_draft.pin = -1
			_build())
		_body.add_child(UiKit.field("Board", board_pick))

	var pin_pick := OptionButton.new()
	var keep := _original_pin if _draft.board == _original_board else -1
	for pin in MachineConfig.free_pins(_draft.board, BoardTypes.CAP_OUT, keep):
		pin_pick.add_item("Pin %d" % pin, pin)
	if pin_pick.item_count == 0:
		_draft.pin = -1
		_body.add_child(UiKit.colored("No free output pins left on board '%s'." % _draft.board, UiKit.BAD_COLOR))
	else:
		if pin_pick.get_item_index(_draft.pin) == -1:
			_draft.pin = pin_pick.get_item_id(0)
		pin_pick.select(pin_pick.get_item_index(_draft.pin))
		pin_pick.item_selected.connect(func(index: int) -> void: _draft.pin = pin_pick.get_item_id(index))
		_body.add_child(UiKit.field("Data pin", pin_pick))

	var board := MachineConfig.find_board(_draft.board)
	var most := BoardTypes.limit(board.type, "max_leds_per_chain") if board else 300
	var count := UiKit.spin(1, most, _draft.count, " LEDs", func(v: float) -> void:
		_draft.count = int(v)
		_refresh())
	count.custom_minimum_size.x = 200   # room for "300 LEDs" at big text sizes
	_body.add_child(UiKit.field("LED count", count))

	var order_pick := OptionButton.new()
	for order in IoDefs.COLOR_ORDERS:
		order_pick.add_item(order)
		if order == _draft.order:
			order_pick.select(order_pick.item_count - 1)
	order_pick.item_selected.connect(func(index: int) -> void: _draft.order = IoDefs.COLOR_ORDERS[index])
	_body.add_child(UiKit.field("Color order", order_pick))

	var lights_on := MachineConfig.lights_on_chain(_original_name) if _original_name != &"" else PackedStringArray()
	_body.add_child(UiKit.field("Lights on it", UiKit.note(", ".join(lights_on) if not lights_on.is_empty() else "none yet (add them under Lights)")))

	_body.add_child(UiKit.note("Wire the Teensy pin through a 3.3 V → 5 V level shifter (e.g. 74AHCT125) and a 330 Ω resistor to the strip's DIN. Most WS2812B strips are GRB: if red and green come out swapped, try RGB. See Docs/lighting.md for power wiring."))


func _draft_error() -> String:
	var problem := _name_problem(_draft.name, "LED chain")
	if problem != "":
		return problem
	if _draft.pin == -1:
		return "Pick a data pin."
	# The lights on it must still fit if the chain got shorter.
	for l in MachineConfig.lights:
		if l.chain == _original_name and _original_name != &"" and l.first + l.count > _draft.count:
			return "Light '%s' uses LEDs up to %d: the chain needs at least %d LEDs." % [l.name, l.first + l.count - 1, l.first + l.count]
	return ""


func _put_draft() -> void:
	var chain := IoDefs.ChainDef.from_dict(_draft.to_dict())
	var index := -1
	for n in MachineConfig.chains.size():
		if MachineConfig.chains[n].name == _original_name:
			index = n
	if index == -1:
		MachineConfig.chains.append(chain)
	else:
		MachineConfig.chains[index] = chain
		for l in MachineConfig.lights:   # a rename follows into the lights on it
			if l.chain == _original_name:
				l.chain = chain.name

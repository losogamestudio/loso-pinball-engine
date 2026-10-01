extends "res://config/draft_editor.gd"
## LightEditor — one named light: a range of LEDs on a chain. count 1 = a
## single insert; more = a strip or a section of one. Game code and light
## shows use the name. Includes a test row to run any effect on the real LEDs.
## Shown inside the Hardware tab; see draft_editor.gd.

var _draft := IoDefs.LightDef.new()

# Test row settings (not saved: effects are chosen by game code and shows).
var _test_effect := "RAINBOW"
var _test_color := Color.WHITE
var _test_color2 := Color.BLACK
var _test_ms := 1000
var _effect_help: Label


## Call before adding to the tree. Empty name = add a new light.
func open(light_name: StringName = &"") -> void:
	var existing := MachineConfig.find_light(light_name)
	if existing:
		_draft = IoDefs.LightDef.from_dict(existing.to_dict())
		_begin(light_name)
	else:
		if not MachineConfig.chains.is_empty():
			_draft.chain = MachineConfig.chains[0].name
		_draft.name = MachineConfig.unique_name("light")
		_begin(&"")


func _title() -> String:
	return "Edit light '%s'" % _original_name if _original_name != &"" else "Add a light"


func _draft_board() -> StringName:
	var c := MachineConfig.find_chain(_draft.chain)
	return c.board if c else &""


func _chain_size() -> int:
	var c := MachineConfig.find_chain(_draft.chain)
	return c.count if c else 1


func _build_fields() -> void:
	var name_edit := LineEdit.new()
	name_edit.text = String(_draft.name)
	name_edit.custom_minimum_size.x = 280
	name_edit.text_changed.connect(func(text: String) -> void:
		_draft.name = StringName(text.strip_edges())
		_refresh())
	_body.add_child(UiKit.field("Name (used by game code)", name_edit))

	if MachineConfig.chains.is_empty():
		_body.add_child(UiKit.colored("Add an LED chain first (LED chains section).", UiKit.BAD_COLOR))
		return

	var chain_pick := OptionButton.new()
	for c in MachineConfig.chains:
		chain_pick.add_item("%s  (pin %d, %d LEDs)" % [c.name, c.pin, c.count])
		chain_pick.set_item_metadata(chain_pick.item_count - 1, c.name)
		if c.name == _draft.chain:
			chain_pick.select(chain_pick.item_count - 1)
	chain_pick.item_selected.connect(func(index: int) -> void:
		_draft.chain = chain_pick.get_item_metadata(index)
		_build())
	_body.add_child(UiKit.field("LED chain", chain_pick))

	var size := _chain_size()
	_body.add_child(UiKit.field("First LED", UiKit.spin(0, size - 1, _draft.first, "", func(v: float) -> void:
		_draft.first = int(v)
		_refresh())))
	_body.add_child(UiKit.field("Number of LEDs", UiKit.spin(1, size, _draft.count, "", func(v: float) -> void:
		_draft.count = int(v)
		_refresh())))
	_body.add_child(UiKit.note("LEDs count from 0 at the end where the data wire goes in. One LED = an insert; several = a strip or section. Lights may overlap: smaller ones draw on top, so an insert inside a strip still shows."))

	_build_test_row()


## Effect, colors and speed, plus buttons to run it on the real LEDs.
func _build_test_row() -> void:
	_body.add_child(UiKit.heading("Try it", 18))
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 12)
	row.add_theme_constant_override("v_separation", 8)
	_body.add_child(row)

	var effect_pick := OptionButton.new()
	for effect in IoDefs.EFFECTS:
		effect_pick.add_item(effect)
		if effect == _test_effect:
			effect_pick.select(effect_pick.item_count - 1)
	effect_pick.item_selected.connect(func(index: int) -> void:
		_test_effect = IoDefs.EFFECTS[index]
		_effect_help.text = IoDefs.EFFECT_HELP[_test_effect])
	row.add_child(effect_pick)
	row.add_child(_color_button(_test_color, func(c: Color) -> void: _test_color = c))
	row.add_child(_color_button(_test_color2, func(c: Color) -> void: _test_color2 = c))
	var speed := UiKit.spin(10, 10000, _test_ms, " ms", func(v: float) -> void: _test_ms = int(v))
	speed.custom_minimum_size.x = 200   # room for "10000 ms" at big text sizes
	row.add_child(speed)
	row.add_child(UiKit.button("Light it", _light_it, UiKit.TEST))
	row.add_child(UiKit.button("Off", func() -> void:
		if _applied:
			PinballIO.set_light(_draft.name, "OFF")))

	_effect_help = UiKit.detail(IoDefs.EFFECT_HELP[_test_effect])
	_body.add_child(_effect_help)


func _color_button(color: Color, on_change: Callable) -> ColorPickerButton:
	var b := ColorPickerButton.new()
	b.color = color
	b.edit_alpha = false
	b.custom_minimum_size = Vector2(96, 48)   # big enough to tap
	b.color_changed.connect(on_change)
	return b


## Send the draft to the board if it isn't there yet, then run the test effect.
func _light_it() -> void:
	if not _applied:
		_try_on_board()
	if _applied:
		PinballIO.set_light(_draft.name, _test_effect, _test_color, _test_ms, _test_color2)


func _draft_error() -> String:
	var problem := _name_problem(_draft.name, "light")
	if problem != "":
		return problem
	if MachineConfig.find_chain(_draft.chain) == null:
		return "Pick an LED chain."
	if _draft.first + _draft.count > _chain_size():
		return "LEDs %d-%d don't fit on a %d-LED chain." % [_draft.first, _draft.first + _draft.count - 1, _chain_size()]
	return ""


func _put_draft() -> void:
	var light := IoDefs.LightDef.from_dict(_draft.to_dict())
	for n in MachineConfig.lights.size():
		if MachineConfig.lights[n].name == _original_name:
			MachineConfig.lights[n] = light
			return
	MachineConfig.lights.append(light)

extends SceneTree
## Headless walk through the Setup screens, no hardware needed.
##
##     godot --headless --path . -s res://test/test_setup_ui.gd
##
## Drives the coil wizard and switch editor like a user would (picking items
## in their OptionButtons), checks what lands in MachineConfig, and always
## cancels, so it never writes user://machine_config.json.

# Loaded at runtime, not preloaded: in -s mode the autoload names these
# scripts use (MachineConfig, PinballIO) only exist once the tree is running.
var CoilWizardScript: GDScript
var InputEditorScript: GDScript
var SetupPageScript: GDScript

var _failures := 0
var _config: Node   # the MachineConfig autoload


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	_config = root.get_node("MachineConfig")
	CoilWizardScript = load("res://config/coil_wizard.gd")
	InputEditorScript = load("res://config/input_editor.gd")
	SetupPageScript = load("res://config/hardware_page.gd")
	var saved_layout: Dictionary = _config.snapshot()
	# Always start from the shipped default, whatever this machine has saved.
	var default_data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://config/machine_config.default.json"))
	_config.restore(default_data, false)

	await _test_hardware_page_lists_things()
	await _test_add_flipper_with_new_switches()
	await _test_name_and_pin_rules()
	await _test_rename_switch_follows_coils()
	await _test_switch_kind()
	await _test_light_editor()
	await _test_servo_editor()

	_config.restore(saved_layout, false)
	print("\n%s" % ("ALL PASSED" if _failures == 0 else "%d FAILURE(S)" % _failures))
	quit(1 if _failures > 0 else 0)


func _check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		_failures += 1


# ---------------------------------------------------------------- helpers

func _frames(n := 2) -> void:
	for i in n:
		await process_frame


## Every OptionButton under [param node], in tree order.
func _pickers(node: Node) -> Array[OptionButton]:
	var out: Array[OptionButton] = []
	for child in node.get_children():
		if child is OptionButton:
			out.append(child)
		out.append_array(_pickers(child))
	return out


## Select the item whose metadata matches, the way a click would.
func _pick(picker: OptionButton, match_meta: Dictionary) -> bool:
	for i in picker.item_count:
		var meta: Variant = picker.get_item_metadata(i)
		if meta is Dictionary and _matches(meta, match_meta):
			picker.select(i)
			picker.item_selected.emit(i)
			return true
	return false


func _matches(meta: Dictionary, wanted: Dictionary) -> bool:
	for key: String in wanted:
		if meta.get(key) != wanted[key]:
			return false
	return true


func _all_text(node: Node) -> String:
	var text := ""
	if node is Label:
		text += (node as Label).text + "\n"
	elif node is Button:
		text += (node as Button).text + "\n"
	for child in node.get_children():
		text += _all_text(child)
	return text


# ---------------------------------------------------------------- tests

func _test_hardware_page_lists_things() -> void:
	var page: Control = SetupPageScript.new()
	root.add_child(page)
	await _frames()
	var text := _all_text(page)
	_check(text.contains("flipper_left") and text.contains("sling_left_switch") and text.contains("+ Add coil") and text.contains("Connection"),
			"hardware page lists connection, coils, switches and the add buttons")
	page.queue_free()
	await _frames()


func _test_add_flipper_with_new_switches() -> void:
	var wizard: Control = CoilWizardScript.new()
	wizard.open(&"")
	root.add_child(wizard)
	await _frames()

	wizard._choose_kind(0)   # Kind.FLIPPER
	await _frames()
	_check(wizard._draft.name == &"flipper" and wizard._draft.hold_pct == 50,
			"flipper preset fills name and hold (%s, %d%%)" % [wizard._draft.name, wizard._draft.hold_pct])
	_check(wizard._draft.pin == 4, "first free PWM pin is picked (pins 2 and 3 are taken): %d" % wizard._draft.pin)

	wizard._go_next()   # -> trigger + EOS
	await _frames()
	var pickers := _pickers(wizard._body)
	_check(_pick(pickers[0], {"kind": "new", "pin": 36}), "trigger: pick 'New switch on pin 36'")
	await _frames()
	pickers = _pickers(wizard._body)
	var eos_offers_36 := false
	for i in pickers[1].item_count:
		var meta: Variant = pickers[1].get_item_metadata(i)
		if meta is Dictionary and meta.get("pin") == 36:
			eos_offers_36 = true
	_check(not eos_offers_36, "EOS list no longer offers pin 36")
	_check(_pick(pickers[1], {"kind": "new", "pin": 37}), "EOS: pick 'New switch on pin 37'")
	await _frames()

	wizard._go_next()   # -> power
	await _frames()
	wizard._go_next()   # -> review: the draft goes into the config
	await _frames()
	var coil: IoDefs.CoilDef = _config.find_coil(&"flipper")
	_check(wizard._applied and coil != null, "review page applies the draft to MachineConfig")
	if coil:
		var trig: IoDefs.InputDef = _config.find_input(coil.trigger)
		var eos: IoDefs.InputDef = _config.find_input(coil.eos)
		_check(trig != null and trig.pin == 36 and coil.trigger == &"flipper_button",
				"new trigger switch created: %s" % coil.trigger)
		_check(eos != null and eos.pin == 37 and eos.debounce_ms == 2 and coil.eos == &"flipper_eos",
				"new EOS switch created: %s" % coil.eos)
		var plan: IoDefs.BoardPlan = _config.build_plan(_config.boards[0])
		_check(plan.lines.has("CFG COIL 3 4 60 50 3 4 0"), "board would get: CFG COIL 3 4 60 50 3 4 0")
	_check((_config.validate() as PackedStringArray).is_empty(), "layout with the new flipper validates")

	wizard._cancel()
	await _frames()
	_check(_config.find_coil(&"flipper") == null and _config.find_input(&"flipper_button") == null
			and _config.coils.size() == 3 and _config.inputs.size() == 3,
			"Cancel puts the layout back exactly")
	wizard.queue_free()
	await _frames()


func _test_name_and_pin_rules() -> void:
	var wizard: Control = CoilWizardScript.new()
	wizard.open(&"")
	root.add_child(wizard)
	await _frames()
	wizard._choose_kind(3)   # Kind.HOLDER
	await _frames()
	_check(wizard._draft.pin in [4, 5, 6, 7, 8, 9, 10, 11, 12, 24, 25, 28, 29],
			"a holding coil only gets a PWM pin (%d)" % wizard._draft.pin)
	wizard._on_name_changed("kickout")
	_check(wizard._page_error().contains("already called"), "an existing name is refused")
	wizard._on_name_changed("my diverter")
	_check(wizard._page_error().contains("spaces"), "a name with spaces is refused")
	wizard._cancel()
	wizard.queue_free()
	await _frames()


func _test_rename_switch_follows_coils() -> void:
	var editor: Control = InputEditorScript.new()
	editor.open(&"sling_left_switch")
	root.add_child(editor)
	await _frames()
	editor._on_name_changed("sling_switch")
	editor._try_on_board()
	await _frames()
	var sling: IoDefs.CoilDef = _config.find_coil(&"sling_left")
	_check(sling.trigger == &"sling_switch", "renaming a switch renames it in the coils that use it")
	editor._cancel()
	await _frames()
	_check((_config.find_coil(&"sling_left") as IoDefs.CoilDef).trigger == &"sling_left_switch",
			"Cancel restores the old switch name")
	editor.queue_free()
	await _frames()


func _test_switch_kind() -> void:
	var before: String = _config.build_plan(_config.boards[0]).fingerprint
	var editor: Control = InputEditorScript.new()
	editor.open(&"flipper_left_eos")
	root.add_child(editor)
	await _frames()
	editor._on_kind_picked(IoDefs.KINDS.find(IoDefs.KIND_SPINNER))
	_check(editor._draft.kind == "spinner" and editor._draft.points == 100 and editor._draft.debounce_ms == 1,
			"picking Spinner suggests 100 points and 1 ms debounce")
	_check(_all_text(editor).contains("Points"), "a scoring kind shows the Points field")
	editor._on_kind_picked(IoDefs.KINDS.find(IoDefs.KIND_DRAIN))
	editor._draft.debounce_ms = 2   # back to the original, so only the kind differs
	editor._try_on_board()
	await _frames()
	var input: IoDefs.InputDef = _config.find_input(&"flipper_left_eos")
	_check(input.kind == "drain" and input.points == 0, "kind is stored on the switch (drain, 0 points)")
	_check(_config.build_plan(_config.boards[0]).fingerprint == before,
			"kind and points don't change the board layout fingerprint")
	editor._cancel()
	await _frames()
	_check((_config.find_input(&"flipper_left_eos") as IoDefs.InputDef).kind == "switch", "Cancel restores the kind")
	editor.queue_free()
	await _frames()

func _test_light_editor() -> void:
	var editor: Control = load("res://config/light_editor.gd").new()
	editor.open(&"")
	root.add_child(editor)
	await _frames()
	_check(editor._draft.chain == &"led_chain_0" and editor._draft.name == &"light", "new light starts on the first chain")
	editor._draft.name = &"insert_5"
	editor._draft.first = 5
	editor._refresh()
	_check(editor._draft_error() == "", "a 1-LED light at LED 5 is valid")
	editor._draft.first = 30
	_check(editor._draft_error().contains("don't fit"), "a light past the end of the chain is refused")
	editor._draft.first = 5
	editor._try_on_board()
	await _frames()
	var plan: IoDefs.BoardPlan = _config.build_plan(_config.boards[0])
	_check(_config.find_light(&"insert_5") != null and plan.lines.has("CFG ZONE 2 0 5 1"),
			"the new light goes to the board as zone 2 (after the bigger lights)")
	editor._cancel()
	await _frames()
	_check(_config.find_light(&"insert_5") == null and _config.lights.size() == 2, "Cancel removes the new light again")
	editor.queue_free()
	await _frames()


func _test_servo_editor() -> void:
	var editor: Control = load("res://config/servo_editor.gd").new()
	editor.open(&"")
	root.add_child(editor)
	await _frames()
	_check(editor._draft.on_pca() and editor._draft.pca_addr == 0x40 and editor._draft.channel == 0 and editor._draft.name == &"servo",
			"a new servo starts on PCA 0x40 channel 0")
	_check(editor._draft_error() == "", "the new servo is valid as it is")
	_check(editor._addr_text(0x40) == "0x40 (no jumpers)" and editor._addr_text(0x45) == "0x45 (A0 A2 bridged)",
			"the address picker says which jumpers make each address")
	editor._draft.min_us = 2000
	editor._draft.max_us = 1500
	_check(editor._draft_error().contains("shorter"), "a backwards pulse range is refused")
	editor._draft.min_us = 1000
	editor._draft.max_us = 2000
	editor._draft.pin = editor._first_free_pin()   # switch to a board pin
	editor._build()
	await _frames()
	_check(editor._draft.pin >= 0 and _config.free_pins(&"main", BoardTypes.CAP_OUT).has(editor._draft.pin),
			"on a board pin it picks a free output (pin %d)" % editor._draft.pin)
	editor._try_on_board()
	await _frames()
	var plan: IoDefs.BoardPlan = _config.build_plan(_config.boards[0])
	_check(plan.lines.has("CFG SERVO 0 %d 1000 2000 500" % editor._draft.pin), "Send to board puts it in the CFG lines")
	editor._cancel()
	await _frames()
	_check(_config.servos.is_empty(), "Cancel removes the new servo again")
	editor.queue_free()
	await _frames()

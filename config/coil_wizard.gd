extends VBoxContainer
## CoilWizard — step-by-step setup for one coil, shown inside the Setup tab.
##
## Pages: kind (new coils only) → name + output pin → trigger + EOS switches
## → power → review + live test. The wizard edits a draft; on the review page
## it sends the draft to the board so it can be test-fired, but nothing is
## written to disk until Save. Cancel (or closing the service menu) puts the
## layout back exactly as it was.
##
## Usage: var w := CoilWizardScene.new(); w.open(&"flipper_left"); add_child(w)
## (an empty name adds a new coil). Listen to `closed`.

signal closed(saved: bool)   ## the wizard is done; the parent should free it

enum Kind { FLIPPER, SLING, KICKER, HOLDER }
enum Page { KIND, NAME_PIN, INPUTS, POWER, REVIEW }

const PAGE_TITLES: Array[String] = [
	"What kind of coil?",
	"Name and output pin",
	"Trigger and end-of-stroke switches",
	"Power",
	"Review and test",
]

## Starting values for each kind of coil. Everything can be changed later.
const PRESETS := {
	Kind.FLIPPER: {
		"title": "Flipper",
		"about": "The flipper button fires it at full power; the end-of-stroke (EOS) switch, or the time limit, drops it to a PWM hold until the button is released. Needs a PWM pin.",
		"base": "flipper", "trigger": "button",
		"full_ms": 60, "hold_pct": 50, "recycle_ms": 0,
	},
	Kind.SLING: {
		"title": "Slingshot / pop bumper",
		"about": "Its switch fires one short full-power kick right on the board, then Godot is told so it can score.",
		"base": "sling", "trigger": "switch",
		"full_ms": 40, "hold_pct": 0, "recycle_ms": 150,
	},
	Kind.KICKER: {
		"title": "Kicker / eject / drop-target reset",
		"about": "Fired only by Godot, when the game rules decide: one full-power pulse.",
		"base": "kicker", "trigger": "",
		"full_ms": 30, "hold_pct": 0, "recycle_ms": 500,
	},
	Kind.HOLDER: {
		"title": "Diverter / magnet (hold)",
		"about": "Turned on and off by Godot: full power to pull in, then a PWM hold until Godot turns it off. Needs a PWM pin.",
		"base": "diverter", "trigger": "",
		"full_ms": 50, "hold_pct": 30, "recycle_ms": 0,
	},
}

var _original_name: StringName = &""   ## coil being edited, or empty when adding
var _original_board: StringName = &""
var _original_pin := -1                ## its pin, which stays available to it
var _snapshot: Dictionary              ## the layout before this wizard touched it
var _draft := IoDefs.CoilDef.new()
var _kind := Kind.FLIPPER
var _page := Page.KIND
var _new_inputs := {}                  ## "trigger"/"eos" -> IoDefs.InputDef ("new switch on pin N")
var _applied := false                  ## the draft is in MachineConfig (and on the board)
var _apply_problems: PackedStringArray = []
var _finished := false
var _rule_touched := false             ## the test page armed/disarmed this coil's rule
var _rule_before := false

var _title: Label
var _body: VBoxContainer
var _error_label: Label
var _back_button: Button
var _next_button: Button
var _status_label: Label
var _live_lamps := {}                  ## input name -> ColorRect, on the pages that show them


## Call before adding the wizard to the tree. Empty name = add a new coil.
func open(coil_name: StringName = &"") -> void:
	_snapshot = MachineConfig.snapshot()
	var existing := MachineConfig.find_coil(coil_name)
	if existing:
		_original_name = coil_name
		_original_board = existing.board
		_original_pin = existing.pin
		_draft = IoDefs.CoilDef.from_dict(existing.to_dict())
		_kind = _guess_kind(_draft)
		_page = Page.NAME_PIN
	else:
		if not MachineConfig.boards.is_empty():
			_draft.board = MachineConfig.boards[0].id
		_page = Page.KIND


func _ready() -> void:
	add_theme_constant_override("separation", 12)
	size_flags_vertical = SIZE_EXPAND_FILL

	_title = UiKit.heading("", 24)
	add_child(_title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 12)
	scroll.add_child(_body)

	_error_label = UiKit.colored("", UiKit.BAD_COLOR)
	add_child(_error_label)

	var footer := HBoxContainer.new()
	add_child(footer)
	footer.add_child(UiKit.button("Cancel", _cancel))
	var spacer := Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	footer.add_child(spacer)
	_back_button = UiKit.button("◀ Back", _go_back)
	footer.add_child(_back_button)
	_next_button = UiKit.button("Next ▶", _go_next)
	footer.add_child(_next_button)

	PinballIO.switch_changed.connect(_on_switch_changed)
	PinballIO.board_ready.connect(_on_board_event)
	PinballIO.board_lost.connect(_on_board_event)

	_show_page(_page)


func _exit_tree() -> void:
	# Closed without Save/Cancel (e.g. P closed the service menu): discard the draft.
	if not _finished:
		_end_test_rule()
		_unapply()


# ---------------------------------------------------------------- navigation

func _first_page() -> Page:
	return Page.NAME_PIN if _original_name != &"" else Page.KIND


func _show_page(page: Page) -> void:
	_page = page
	UiKit.free_children(_body)
	_live_lamps.clear()
	_status_label = null
	var verb := "Edit coil '%s'" % _original_name if _original_name != &"" else "Add a coil"
	_title.text = "%s  —  step %d: %s" % [verb, page - _first_page() + 1, PAGE_TITLES[page]]

	match page:
		Page.KIND:
			_build_kind_page()
		Page.NAME_PIN:
			_build_name_pin_page()
		Page.INPUTS:
			_build_inputs_page()
		Page.POWER:
			_build_power_page()
		Page.REVIEW:
			_build_review_page()

	_back_button.visible = page > _first_page()
	_next_button.visible = page != Page.KIND   # the kind buttons move on by themselves
	_next_button.text = "Save" if page == Page.REVIEW else "Next ▶"
	_refresh_next()


func _go_next() -> void:
	if _page_error() != "":
		return
	if _page == Page.REVIEW:
		_save()
	else:
		_show_page((_page + 1) as Page)


func _go_back() -> void:
	if _page == Page.REVIEW:
		_end_test_rule()
		_unapply()   # back to editing: the board goes back to the saved layout
	_show_page((_page - 1) as Page)


## What's stopping the user from moving on, or "" if nothing.
func _page_error() -> String:
	match _page:
		Page.NAME_PIN:
			var text := String(_draft.name)
			if text.is_empty():
				return "Give the coil a name, e.g. flipper_left."
			if text.contains(" "):
				return "Names can't contain spaces (use _ instead)."
			if MachineConfig.is_name_taken(_draft.name, _original_name):
				return "Something is already called '%s'." % text
			if _draft.pin == -1:
				return "Pick an output pin."
		Page.INPUTS:
			var same_existing := _draft.trigger != &"" and _draft.trigger == _draft.eos \
					and not _new_inputs.has("trigger") and not _new_inputs.has("eos")
			if same_existing:
				return "The trigger and the EOS must be different switches."
		Page.REVIEW:
			if not _applied:
				return "Fix the problems above before saving."
	return ""


func _refresh_next() -> void:
	var error := _page_error()
	_error_label.text = error
	_next_button.disabled = error != ""


# ---------------------------------------------------------------- page: kind

func _build_kind_page() -> void:
	_body.add_child(UiKit.note("Pick the closest match. It only sets starting values; you can change everything on the next pages."))
	for kind: int in PRESETS:
		var preset: Dictionary = PRESETS[kind]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		var b := UiKit.button(preset["title"], _choose_kind.bind(kind))
		b.custom_minimum_size = Vector2(280, 56)
		row.add_child(b)
		var about := UiKit.note(preset["about"])
		about.size_flags_horizontal = SIZE_EXPAND_FILL
		row.add_child(about)
		_body.add_child(row)


func _choose_kind(kind: int) -> void:
	_kind = kind as Kind
	var preset: Dictionary = PRESETS[kind]
	_draft.full_ms = preset["full_ms"]
	_draft.hold_pct = preset["hold_pct"]
	_draft.recycle_ms = preset["recycle_ms"]
	_draft.name = MachineConfig.unique_name(preset["base"])
	_draft.pin = -1
	_show_page(Page.NAME_PIN)


# ---------------------------------------------------------------- page: name + pin

func _build_name_pin_page() -> void:
	_body.add_child(UiKit.note(PRESETS[_kind]["about"]))

	var name_edit := LineEdit.new()
	name_edit.text = String(_draft.name)
	name_edit.custom_minimum_size.x = 280
	name_edit.text_changed.connect(_on_name_changed)
	_body.add_child(UiKit.field("Name (used by game code)", name_edit))

	if MachineConfig.boards.size() > 1:
		var board_pick := OptionButton.new()
		for b in MachineConfig.boards:
			board_pick.add_item("%s  (%s)" % [b.id, BoardTypes.display_name(b.type)])
			board_pick.set_item_metadata(board_pick.item_count - 1, b.id)
			if b.id == _draft.board:
				board_pick.select(board_pick.item_count - 1)
		board_pick.item_selected.connect(_on_board_picked.bind(board_pick))
		_body.add_child(UiKit.field("Board", board_pick))

	var board := MachineConfig.find_board(_draft.board)
	if board == null:
		_body.add_child(UiKit.colored("There's no board '%s' in the layout." % _draft.board, UiKit.BAD_COLOR))
		return
	var needs_pwm := _draft.hold_pct > 0 and _draft.hold_pct < 100
	var keep := _original_pin if _draft.board == _original_board else -1
	var pin_pick := OptionButton.new()
	var first_ok := -1
	for pin in MachineConfig.free_pins(board.id, BoardTypes.CAP_OUT, keep):
		var pwm := BoardTypes.pin_has(board.type, pin, BoardTypes.OUT_PWM)
		pin_pick.add_item("Pin %d  —  %s" % [pin, "PWM, can hold" if pwm else "pulse only (no PWM)"], pin)
		if needs_pwm and not pwm:
			pin_pick.set_item_disabled(pin_pick.item_count - 1, true)
		elif first_ok == -1:
			first_ok = pin
	if pin_pick.item_count == 0 or first_ok == -1:
		_draft.pin = -1
		_body.add_child(UiKit.colored("No suitable free output pin left on board '%s'." % board.id, UiKit.BAD_COLOR))
		return
	# Keep the current pin if it's still allowed, otherwise take the first good one.
	var index := pin_pick.get_item_index(_draft.pin)
	if index == -1 or pin_pick.is_item_disabled(index):
		_draft.pin = first_ok
		index = pin_pick.get_item_index(first_ok)
	pin_pick.select(index)
	pin_pick.item_selected.connect(_on_pin_picked.bind(pin_pick))
	_body.add_child(UiKit.field("Output pin", pin_pick))

	var hint := "Outputs are on the %s's left header (USB port up)." % BoardTypes.display_name(board.type)
	if needs_pwm:
		hint += " This coil holds, so only PWM pins can be picked."
	_body.add_child(UiKit.note(hint))


func _on_name_changed(text: String) -> void:
	_draft.name = StringName(text.strip_edges())
	_refresh_next()


func _on_pin_picked(index: int, picker: OptionButton) -> void:
	_draft.pin = picker.get_item_id(index)
	_refresh_next()


func _on_board_picked(index: int, picker: OptionButton) -> void:
	_draft.board = picker.get_item_metadata(index)
	# Pins and switches belong to a board, so start those over.
	_draft.pin = -1
	_draft.trigger = &""
	_draft.eos = &""
	_new_inputs.clear()
	_show_page(Page.NAME_PIN)


# ---------------------------------------------------------------- page: trigger + EOS

func _build_inputs_page() -> void:
	_body.add_child(UiKit.note(
			"The TRIGGER is the switch that fires this coil. The board reacts to it by itself, with no Godot delay (flipper button, sling switch, pop bumper skirt). Leave it at (none) for coils only the game fires."))
	_build_input_choice("trigger", "Trigger switch")
	_body.add_child(UiKit.note(
			"The END-OF-STROKE (EOS) switch closes when the coil has pulled all the way in. It ends full power early, so the coil drops to its hold % sooner and runs cooler. Optional: without it, full power simply lasts its time limit."))
	_build_input_choice("eos", "End-of-stroke (EOS)")
	_body.add_child(UiKit.note("Inputs are on the right header (USB port up), wired from the pin to GND. Lamps show switches that are already running on the board; press one to check your wiring."))


## One "pick a switch" row: none, an existing input on this board, or a new
## switch on a free input pin.
func _build_input_choice(role: String, label_text: String) -> void:
	var current: StringName = _draft.trigger if role == "trigger" else _draft.eos
	var other_role := "eos" if role == "trigger" else "trigger"
	var picker := OptionButton.new()
	picker.custom_minimum_size.x = 320

	picker.add_item("(none)")
	picker.set_item_metadata(0, {"kind": "none"})
	var selected := 0

	for i in MachineConfig.inputs_on(_draft.board):
		picker.add_item("%s  (pin %d%s)" % [i.name, i.pin, ", NC" if i.nc else ""])
		picker.set_item_metadata(picker.item_count - 1, {"kind": "existing", "name": i.name})
		if not _new_inputs.has(role) and i.name == current:
			selected = picker.item_count - 1

	# A new switch can't take the pin the other role just claimed as new.
	var other_new_pin := -1
	if _new_inputs.has(other_role):
		other_new_pin = (_new_inputs[other_role] as IoDefs.InputDef).pin
	for pin in MachineConfig.free_pins(_draft.board, BoardTypes.CAP_IN):
		if pin == other_new_pin:
			continue
		picker.add_item("New switch on pin %d" % pin)
		picker.set_item_metadata(picker.item_count - 1, {"kind": "new", "pin": pin})
		if _new_inputs.has(role) and (_new_inputs[role] as IoDefs.InputDef).pin == pin:
			selected = picker.item_count - 1

	picker.select(selected)
	picker.item_selected.connect(_on_input_picked.bind(role, picker))

	var row := UiKit.field(label_text, picker)
	if not _new_inputs.has(role) and current != &"":
		var lamp := UiKit.lamp(PinballIO.is_switch_active(current))
		_live_lamps[current] = lamp
		row.add_child(lamp)
	_body.add_child(row)

	if _new_inputs.has(role):
		var new_input: IoDefs.InputDef = _new_inputs[role]
		var nc := CheckBox.new()
		nc.text = "Normally closed (active when the switch opens)"
		nc.button_pressed = new_input.nc
		nc.toggled.connect(func(on: bool) -> void: new_input.nc = on)
		var options := HBoxContainer.new()
		options.add_theme_constant_override("separation", 16)
		var indent := Control.new()
		indent.custom_minimum_size.x = 212
		options.add_child(indent)
		options.add_child(nc)
		options.add_child(UiKit.spin(0, MachineConfig.MAX_DEBOUNCE_MS, new_input.debounce_ms, " ms debounce",
				func(v: float) -> void: new_input.debounce_ms = int(v)))
		_body.add_child(options)


func _on_input_picked(index: int, role: String, picker: OptionButton) -> void:
	var choice: Dictionary = picker.get_item_metadata(index)
	var picked_name: StringName = &""
	_new_inputs.erase(role)
	match choice["kind"]:
		"existing":
			picked_name = choice["name"]
		"new":
			var i := IoDefs.InputDef.new()
			i.board = _draft.board
			i.pin = choice["pin"]
			i.debounce_ms = 2 if role == "eos" else 5   # EOS switches are fast and clean
			_new_inputs[role] = i   # gets its name when the draft is applied
	if role == "trigger":
		_draft.trigger = picked_name
	else:
		_draft.eos = picked_name
	_show_page(Page.INPUTS)   # rebuild so the other list and the options follow


# ---------------------------------------------------------------- page: power

func _build_power_page() -> void:
	var board := MachineConfig.find_board(_draft.board)
	var pwm := board != null and BoardTypes.pin_has(board.type, _draft.pin, BoardTypes.OUT_PWM)
	var has_eos := _draft.eos != &"" or _new_inputs.has("eos")

	var full := UiKit.spin(1, MachineConfig.MAX_FULL_MS, _draft.full_ms, " ms",
			func(v: float) -> void: _draft.full_ms = int(v))
	_body.add_child(UiKit.field("Full power", full))
	_body.add_child(UiKit.note(
			"How long the coil gets full power when it fires (max %d ms). %s" % [MachineConfig.MAX_FULL_MS,
			"With an EOS switch this is only the safety limit: the EOS normally ends full power sooner." if has_eos
			else "Start short and go up a little at a time: too long just heats the coil."]))

	if not pwm and _draft.hold_pct > 0 and _draft.hold_pct < 100:
		_draft.hold_pct = 0   # can't hold on this pin
	var hold := UiKit.spin(0, 100, _draft.hold_pct, " %", func(v: float) -> void: _draft.hold_pct = int(v))
	hold.editable = pwm
	_body.add_child(UiKit.field("Hold power", hold))
	if pwm:
		_body.add_child(UiKit.note(
				"After full power, stay on at this PWM duty until the trigger is released (or Godot says so). 0 = just a pulse. Flippers usually hold around 50%%. PWM frequency on board '%s' is %d Hz." % [_draft.board, board.pwm_hz]))
	else:
		_body.add_child(UiKit.note("Pin %d can't do PWM, so this coil can only pulse. Pick a PWM pin on step 1 if it needs to hold." % _draft.pin))

	var recycle := UiKit.spin(0, MachineConfig.MAX_RECYCLE_MS, _draft.recycle_ms, " ms",
			func(v: float) -> void: _draft.recycle_ms = int(v))
	_body.add_child(UiKit.field("Recycle time", recycle))
	_body.add_child(UiKit.note("After turning off, ignore new fires for this long, so a chattering switch can't machine-gun the coil. 0 for flippers; around 100–200 ms for slings and pops."))


# ---------------------------------------------------------------- page: review + test

func _build_review_page() -> void:
	_apply_draft()
	if not _apply_problems.is_empty():
		_body.add_child(UiKit.colored("This coil can't be used yet:", UiKit.BAD_COLOR))
		for problem in _apply_problems:
			_body.add_child(UiKit.colored("  •  " + problem, UiKit.BAD_COLOR))
		return

	var coil := MachineConfig.find_coil(_draft.name)
	var board := MachineConfig.find_board(coil.board)
	_body.add_child(UiKit.field("Name", _value_label(String(coil.name))))
	_body.add_child(UiKit.field("Output", _value_label("board '%s', pin %d" % [coil.board, coil.pin])))
	var power := "%d ms full power" % coil.full_ms
	if coil.hold_pct > 0:
		power += ", then hold at %d%%" % coil.hold_pct
	if coil.recycle_ms > 0:
		power += ", %d ms recycle" % coil.recycle_ms
	_body.add_child(UiKit.field("Power", _value_label(power)))
	_add_input_summary("Trigger", coil.trigger, "trigger")
	_add_input_summary("EOS", coil.eos, "eos")

	_status_label = UiKit.colored("", UiKit.WARN_COLOR)
	_body.add_child(_status_label)
	_update_status()

	var tests := HBoxContainer.new()
	tests.add_theme_constant_override("separation", 12)
	_body.add_child(tests)
	tests.add_child(UiKit.button("Fire once", _test_fire))
	if coil.hold_pct > 0:
		tests.add_child(UiKit.button("Hold for 1 second", _test_hold))
	if coil.trigger != &"":
		var arm := CheckButton.new()
		arm.text = "Arm the rule, then press the real switch"
		arm.button_pressed = PinballIO.get_coil_rule(coil.name)
		arm.toggled.connect(_test_arm)
		tests.add_child(arm)

	_body.add_child(UiKit.note(
			"Save writes this into the machine config. Board '%s' then runs it until power-off; press \"Burn to board\" on the Setup page so it keeps it." % board.id))


func _add_input_summary(label_text: String, input_name: StringName, role: String) -> void:
	if input_name == &"":
		_body.add_child(UiKit.field(label_text, _value_label("(none)")))
		return
	var input := MachineConfig.find_input(input_name)
	var text := "%s  (pin %d%s)" % [input_name, input.pin, ", NC" if input.nc else ""]
	if _new_inputs.has(role):
		text += "  — new"
	var row := UiKit.field(label_text, _value_label(text))
	var lamp := UiKit.lamp(PinballIO.is_switch_active(input_name))
	_live_lamps[input_name] = lamp
	row.add_child(lamp)
	_body.add_child(row)


func _value_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _update_status() -> void:
	if _status_label == null:
		return
	if not PinballIO.get_port_for_board(_draft.board).is_empty():
		_status_label.text = "Board '%s' is running this draft now. Test it below (nothing is saved yet)." % _draft.board
		_status_label.add_theme_color_override("font_color", UiKit.OK_COLOR)
	else:
		_status_label.text = "Board '%s' isn't connected, so this can't be tested right now. You can still save it. (Connect on the Diagnostics tab.)" % _draft.board
		_status_label.add_theme_color_override("font_color", UiKit.WARN_COLOR)


func _test_fire() -> void:
	PinballIO.pulse_coil(_draft.name)


func _test_hold() -> void:
	var coil_name := _draft.name
	PinballIO.hold_coil(coil_name, true)
	get_tree().create_timer(1.0).timeout.connect(func() -> void: PinballIO.hold_coil(coil_name, false))


func _test_arm(on: bool) -> void:
	if not _rule_touched:
		_rule_touched = true
		_rule_before = PinballIO.get_coil_rule(_draft.name)
	PinballIO.set_coil_rule(_draft.name, on)


# ---------------------------------------------------------------- applying, saving, cancelling

## Put the draft (and any new switches) into MachineConfig, starting from the
## layout as it was when the wizard opened. If it validates, apply it, so the
## board runs it right away; otherwise put everything back.
func _apply_draft() -> void:
	MachineConfig.restore(_snapshot, false)
	for role: String in ["trigger", "eos"]:
		if not _new_inputs.has(role):
			continue
		var i := IoDefs.InputDef.from_dict((_new_inputs[role] as IoDefs.InputDef).to_dict())
		i.board = _draft.board
		i.name = MachineConfig.unique_name("%s_%s" % [_draft.name, _input_suffix(role)])
		MachineConfig.inputs.append(i)
		if role == "trigger":
			_draft.trigger = i.name
		else:
			_draft.eos = i.name

	var coil := IoDefs.CoilDef.from_dict(_draft.to_dict())
	var index := -1
	for n in MachineConfig.coils.size():
		if MachineConfig.coils[n].name == _original_name:
			index = n
	if index == -1:
		MachineConfig.coils.append(coil)
	else:
		MachineConfig.coils[index] = coil

	_apply_problems = MachineConfig.validate()
	if _apply_problems.is_empty():
		MachineConfig.apply()
		_applied = true
	else:
		MachineConfig.restore(_snapshot, _applied)   # tell the board only if it had a draft
		_applied = false


## Take the draft back out, so the layout (and the board) is as it was.
func _unapply() -> void:
	if _applied:
		MachineConfig.restore(_snapshot)
		_applied = false


func _save() -> void:
	if not _applied:
		return
	var err := MachineConfig.save_config()
	if err != OK:
		_error_label.text = "Couldn't save the machine config (error %d)." % err
		return
	_end_test_rule()
	_finished = true
	closed.emit(true)


func _cancel() -> void:
	_end_test_rule()   # before _unapply, while the coil still exists
	_unapply()
	_finished = true
	closed.emit(false)


## Put the coil's rule back the way it was before the test page touched it.
func _end_test_rule() -> void:
	if not _rule_touched:
		return
	_rule_touched = false
	var coil := MachineConfig.find_coil(_draft.name)
	if coil and coil.trigger != &"":
		PinballIO.set_coil_rule(_draft.name, _rule_before)


# ---------------------------------------------------------------- live updates

func _on_switch_changed(switch_name: StringName, active: bool) -> void:
	var lamp: ColorRect = _live_lamps.get(switch_name)
	if lamp:
		lamp.color = UiKit.LAMP_ON if active else UiKit.LAMP_OFF


func _on_board_event(_board_id: StringName) -> void:
	_update_status()


# ---------------------------------------------------------------- helpers

func _input_suffix(role: String) -> String:
	if role == "eos":
		return "eos"
	var preset_suffix: String = PRESETS[_kind]["trigger"]
	return preset_suffix if preset_suffix != "" else "trigger"


## Which preset an existing coil looks most like (only used for wording).
func _guess_kind(c: IoDefs.CoilDef) -> Kind:
	if c.hold_pct > 0:
		return Kind.FLIPPER if c.trigger != &"" else Kind.HOLDER
	return Kind.SLING if c.trigger != &"" else Kind.KICKER

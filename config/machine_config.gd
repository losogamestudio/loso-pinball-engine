extends Node
## MachineConfig — autoload holding this machine's I/O layout.
##
## Which boards exist, and which pin on which board is which switch, coil, or
## lamp. PinballIO turns this into CFG lines for each board after it links.
## Game code never needs pin numbers: it uses the names defined here.
##
## Loaded from user://machine_config.json if it exists (saved by the config
## page), otherwise from the default that ships with the project:
## res://config/machine_config.default.json.
##
## Register under Project Settings > Globals > Autoload as "MachineConfig",
## ABOVE PinballIO (autoloads start in list order, and PinballIO needs this).

signal changed   ## the layout was loaded or replaced; linked boards get re-configured

const USER_PATH := "user://machine_config.json"
const DEFAULT_PATH := "res://config/machine_config.default.json"

## Limits the firmware enforces (keep in sync with Firmware/pinio/pinio.ino).
const MAX_FULL_MS := 255
const MAX_RECYCLE_MS := 5000
const MAX_DEBOUNCE_MS := 100
const MIN_PWM_HZ := 100
const MAX_PWM_HZ := 100000

## Game-side limit (not the firmware's): most points one switch can score per close.
const MAX_POINTS := 1000000

var boards: Array[IoDefs.BoardDef] = []
var inputs: Array[IoDefs.InputDef] = []
var coils: Array[IoDefs.CoilDef] = []
var lamps: Array[IoDefs.LampDef] = []
var chains: Array[IoDefs.ChainDef] = []   ## WS2812B LED chains
var lights: Array[IoDefs.LightDef] = []   ## named LED ranges on those chains
var loaded_from := ""   ## which file the current layout came from


func _ready() -> void:
	load_config()


# ---------------------------------------------------------------- load / save

## Load the saved layout, or the project default if nothing is saved yet.
func load_config() -> void:
	var path := USER_PATH if FileAccess.file_exists(USER_PATH) else DEFAULT_PATH
	var text := FileAccess.get_file_as_string(path)
	var data: Variant = JSON.parse_string(text)
	if not data is Dictionary:
		push_error("MachineConfig: could not read %s, starting empty" % path)
		data = {}
	_apply_dict(data)
	loaded_from = path
	for problem in validate():
		push_warning("MachineConfig (%s): %s" % [path, problem])
	changed.emit()


## Save the current layout to user:// so it survives restarts.
func save_config() -> Error:
	var file := FileAccess.open(USER_PATH, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(to_dict(), "\t"))
	loaded_from = USER_PATH
	return OK


## Forget the saved layout and go back to the project default.
func reset_to_default() -> void:
	if FileAccess.file_exists(USER_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(USER_PATH))
	load_config()


func to_dict() -> Dictionary:
	return {
		"version": 1,
		"boards": boards.map(func(b: IoDefs.BoardDef) -> Dictionary: return b.to_dict()),
		"inputs": inputs.map(func(i: IoDefs.InputDef) -> Dictionary: return i.to_dict()),
		"coils": coils.map(func(c: IoDefs.CoilDef) -> Dictionary: return c.to_dict()),
		"lamps": lamps.map(func(l: IoDefs.LampDef) -> Dictionary: return l.to_dict()),
		"chains": chains.map(func(c: IoDefs.ChainDef) -> Dictionary: return c.to_dict()),
		"lights": lights.map(func(l: IoDefs.LightDef) -> Dictionary: return l.to_dict()),
	}


func _apply_dict(data: Dictionary) -> void:
	boards.clear()
	inputs.clear()
	coils.clear()
	lamps.clear()
	chains.clear()
	lights.clear()
	for d: Dictionary in data.get("boards", []):
		boards.append(IoDefs.BoardDef.from_dict(d))
	for d: Dictionary in data.get("inputs", []):
		inputs.append(IoDefs.InputDef.from_dict(d))
	for d: Dictionary in data.get("coils", []):
		coils.append(IoDefs.CoilDef.from_dict(d))
	for d: Dictionary in data.get("lamps", []):
		lamps.append(IoDefs.LampDef.from_dict(d))
	for d: Dictionary in data.get("chains", []):   # older config files have none
		chains.append(IoDefs.ChainDef.from_dict(d))
	for d: Dictionary in data.get("lights", []):
		lights.append(IoDefs.LightDef.from_dict(d))


# ---------------------------------------------------------------- lookups

func find_board(id: StringName) -> IoDefs.BoardDef:
	for b in boards:
		if b.id == id:
			return b
	return null


func find_input(input_name: StringName) -> IoDefs.InputDef:
	for i in inputs:
		if i.name == input_name:
			return i
	return null


func find_coil(coil_name: StringName) -> IoDefs.CoilDef:
	for c in coils:
		if c.name == coil_name:
			return c
	return null


func find_lamp(lamp_name: StringName) -> IoDefs.LampDef:
	for l in lamps:
		if l.name == lamp_name:
			return l
	return null


func find_chain(chain_name: StringName) -> IoDefs.ChainDef:
	for c in chains:
		if c.name == chain_name:
			return c
	return null


func find_light(light_name: StringName) -> IoDefs.LightDef:
	for l in lights:
		if l.name == light_name:
			return l
	return null


## The board a light is on (its chain's board), or &"" if its chain is missing.
func light_board(l: IoDefs.LightDef) -> StringName:
	var c := find_chain(l.chain)
	return c.board if c else &""


# ---------------------------------------------------------------- editing (used by the setup page)

## A copy of the whole layout, to put back with restore() if an edit is cancelled.
func snapshot() -> Dictionary:
	return to_dict()


## Replace the layout with an earlier snapshot. Emits `changed` (so linked
## boards get it) unless [param emit] is false.
func restore(data: Dictionary, emit := true) -> void:
	_apply_dict(data)
	if emit:
		changed.emit()


## Tell everyone (PinballIO in particular) that the layout was edited, so
## linked boards run the new layout right away. Doesn't save to disk.
func apply() -> void:
	changed.emit()


## Pins on [param board_id] that have [param caps] and aren't used by anything
## (except [param keep_pin], so an item being edited can keep its own pin).
func free_pins(board_id: StringName, caps: int, keep_pin := -1) -> Array[int]:
	var b := find_board(board_id)
	var out: Array[int] = []
	if b == null:
		return out
	var used := {}
	for i in inputs:
		if i.board == board_id:
			used[i.pin] = true
	for c in coils:
		if c.board == board_id:
			used[c.pin] = true
	for l in lamps:
		if l.board == board_id:
			used[l.pin] = true
	for c in chains:
		if c.board == board_id:
			used[c.pin] = true
	for pin in BoardTypes.pins_with(b.type, caps):
		if pin == keep_pin or not used.has(pin):
			out.append(pin)
	return out


## Inputs on [param board_id], in config order.
func inputs_on(board_id: StringName) -> Array[IoDefs.InputDef]:
	var out: Array[IoDefs.InputDef] = []
	for i in inputs:
		if i.board == board_id:
			out.append(i)
	return out


## Descriptions of every coil that uses [param input_name], e.g. "flipper_left (trigger)".
func coils_using_input(input_name: StringName) -> PackedStringArray:
	var out: PackedStringArray = []
	for c in coils:
		if c.trigger == input_name:
			out.append("%s (trigger)" % c.name)
		if c.eos == input_name:
			out.append("%s (EOS)" % c.name)
	return out


## True if some input, coil, lamp, chain or light other than [param except] already has this name.
func is_name_taken(item_name: StringName, except: StringName = &"") -> bool:
	if item_name == except:
		return false
	return find_input(item_name) != null or find_coil(item_name) != null or find_lamp(item_name) != null \
			or find_chain(item_name) != null or find_light(item_name) != null


## [param base] if it's free, otherwise base_2, base_3, ...
func unique_name(base: String) -> StringName:
	var candidate := base
	var n := 2
	while is_name_taken(StringName(candidate)):
		candidate = "%s_%d" % [base, n]
		n += 1
	return StringName(candidate)


func remove_coil(coil_name: StringName) -> void:
	coils.assign(coils.filter(func(c: IoDefs.CoilDef) -> bool: return c.name != coil_name))


## Remove an input. Refuses (returns false) while a coil still uses it.
func remove_input(input_name: StringName) -> bool:
	if not coils_using_input(input_name).is_empty():
		return false
	inputs.assign(inputs.filter(func(i: IoDefs.InputDef) -> bool: return i.name != input_name))
	return true


## Names of the lights on [param chain_name].
func lights_on_chain(chain_name: StringName) -> PackedStringArray:
	var out: PackedStringArray = []
	for l in lights:
		if l.chain == chain_name:
			out.append(String(l.name))
	return out


## Remove a chain. Refuses (returns false) while lights are on it.
func remove_chain(chain_name: StringName) -> bool:
	if not lights_on_chain(chain_name).is_empty():
		return false
	chains.assign(chains.filter(func(c: IoDefs.ChainDef) -> bool: return c.name != chain_name))
	return true


func remove_light(light_name: StringName) -> void:
	lights.assign(lights.filter(func(l: IoDefs.LightDef) -> bool: return l.name != light_name))


# ---------------------------------------------------------------- validation

## Everything wrong with the current layout, in plain words. Empty = good.
## Mirrors the checks the firmware does, so problems show up in Godot with
## names attached instead of as "ERR CFG bad pin" from a board.
func validate() -> PackedStringArray:
	var errors: PackedStringArray = []
	var names := {}                    # every name in use -> true (names must be unique)
	var used_pins := {}                # "board:pin" -> name using it

	var board_ids := {}
	for b in boards:
		if board_ids.has(b.id):
			errors.append("board '%s' is defined twice" % b.id)
		board_ids[b.id] = true
		if not BoardTypes.has_type(b.type):
			errors.append("board '%s' has unknown type '%s'" % [b.id, b.type])
		if b.pwm_hz < MIN_PWM_HZ or b.pwm_hz > MAX_PWM_HZ:
			errors.append("board '%s' PWM must be %d..%d Hz" % [b.id, MIN_PWM_HZ, MAX_PWM_HZ])

	for i in inputs:
		_check_name(i.name, "input", names, errors)
		var b := _check_board(i.board, i.name, errors)
		if b:
			_check_pin(b, i.pin, BoardTypes.CAP_IN, i.name, used_pins, errors)
		if i.debounce_ms < 0 or i.debounce_ms > MAX_DEBOUNCE_MS:
			errors.append("input '%s' debounce must be 0..%d ms" % [i.name, MAX_DEBOUNCE_MS])
		if not IoDefs.KINDS.has(i.kind):
			errors.append("input '%s' has unknown kind '%s'" % [i.name, i.kind])
		if i.points < 0 or i.points > MAX_POINTS:
			errors.append("input '%s' points must be 0..%d" % [i.name, MAX_POINTS])

	for c in coils:
		_check_name(c.name, "coil", names, errors)
		var b := _check_board(c.board, c.name, errors)
		if b:
			_check_pin(b, c.pin, BoardTypes.CAP_OUT, c.name, used_pins, errors)
			if c.hold_pct > 0 and c.hold_pct < 100 and not BoardTypes.pin_has(b.type, c.pin, BoardTypes.OUT_PWM):
				errors.append("coil '%s' has a hold %% but pin %d can't do PWM" % [c.name, c.pin])
		if c.full_ms < 1 or c.full_ms > MAX_FULL_MS:
			errors.append("coil '%s' full power must be 1..%d ms" % [c.name, MAX_FULL_MS])
		if c.hold_pct < 0 or c.hold_pct > 100:
			errors.append("coil '%s' hold must be 0..100 %%" % c.name)
		if c.recycle_ms < 0 or c.recycle_ms > MAX_RECYCLE_MS:
			errors.append("coil '%s' recycle must be 0..%d ms" % [c.name, MAX_RECYCLE_MS])
		_check_coil_input(c, c.trigger, "trigger", errors)
		_check_coil_input(c, c.eos, "EOS", errors)
		if c.trigger != &"" and c.trigger == c.eos:
			errors.append("coil '%s' uses the same input for trigger and EOS" % c.name)

	for l in lamps:
		_check_name(l.name, "lamp", names, errors)
		var b := _check_board(l.board, l.name, errors)
		if b:
			_check_pin(b, l.pin, BoardTypes.CAP_OUT, l.name, used_pins, errors)

	for c in chains:
		_check_name(c.name, "LED chain", names, errors)
		var b := _check_board(c.board, c.name, errors)
		if b:
			_check_pin(b, c.pin, BoardTypes.CAP_OUT, c.name, used_pins, errors)
			var most := BoardTypes.limit(b.type, "max_leds_per_chain")
			if c.count < 1 or c.count > most:
				errors.append("LED chain '%s' must have 1..%d LEDs" % [c.name, most])
		if not IoDefs.COLOR_ORDERS.has(c.order):
			errors.append("LED chain '%s' has unknown color order '%s'" % [c.name, c.order])

	for l in lights:
		_check_name(l.name, "light", names, errors)
		var c := find_chain(l.chain)
		if c == null:
			errors.append("light '%s' is on LED chain '%s', which doesn't exist" % [l.name, l.chain])
		elif l.first < 0 or l.count < 1 or l.first + l.count > c.count:
			errors.append("light '%s' (LEDs %d-%d) doesn't fit on '%s' (%d LEDs)" % [
					l.name, l.first, l.first + l.count - 1, c.name, c.count])

	for b in boards:
		if not BoardTypes.has_type(b.type):
			continue
		var plan := build_plan(b)
		var counts := {
			"inputs": plan.input_names.size(),
			"coils": plan.coil_names.size(),
			"lamps": plan.lamp_names.size(),
			"chains": plan.chain_names.size(),
			"zones": plan.light_names.size(),
		}
		for kind: String in counts:
			var count: int = counts[kind]
			var most := BoardTypes.limit(b.type, "max_" + kind)
			if count > most:
				errors.append("board '%s' has %d %s, its limit is %d" % [b.id, count, kind, most])
	return errors


func _check_name(item_name: StringName, kind: String, names: Dictionary, errors: PackedStringArray) -> void:
	if item_name == &"":
		errors.append("a %s has no name" % kind)
	elif String(item_name).contains(" "):
		errors.append("%s '%s': names can't contain spaces" % [kind, item_name])
	elif names.has(item_name):
		errors.append("the name '%s' is used more than once" % item_name)
	names[item_name] = true


func _check_board(board_id: StringName, item_name: StringName, errors: PackedStringArray) -> IoDefs.BoardDef:
	var b := find_board(board_id)
	if b == null:
		errors.append("'%s' is on board '%s', which doesn't exist" % [item_name, board_id])
	return b


func _check_pin(b: IoDefs.BoardDef, pin: int, cap: int, item_name: StringName,
		used_pins: Dictionary, errors: PackedStringArray) -> void:
	var reason := BoardTypes.reserved_reason(b.type, pin)
	if reason != "":
		errors.append("'%s': pin %d is reserved (%s)" % [item_name, pin, reason])
	elif not BoardTypes.pin_has(b.type, pin, cap):
		var role := "an input" if cap == BoardTypes.CAP_IN else "an output"
		errors.append("'%s': pin %d can't be %s on a %s" % [item_name, pin, role, b.type])
	var key := "%s:%d" % [b.id, pin]
	if used_pins.has(key):
		errors.append("'%s' and '%s' both use pin %d on board '%s'" % [used_pins[key], item_name, pin, b.id])
	used_pins[key] = item_name


func _check_coil_input(c: IoDefs.CoilDef, input_name: StringName, role: String, errors: PackedStringArray) -> void:
	if input_name == &"":
		return
	var i := find_input(input_name)
	if i == null:
		errors.append("coil '%s' %s '%s' isn't a defined input" % [c.name, role, input_name])
	elif i.board != c.board:
		# The board runs the rule on its own, so it can only see its own switches.
		errors.append("coil '%s' %s '%s' is on a different board" % [c.name, role, input_name])


# ---------------------------------------------------------------- per-board plan

## Work out what [param board] gets told: local numbers for each of its
## inputs/coils/lamps/chains (in config order) and lights (biggest first),
## and the CFG lines to send.
## Doesn't validate; call validate() first.
func build_plan(board: IoDefs.BoardDef) -> IoDefs.BoardPlan:
	var plan := IoDefs.BoardPlan.new()
	plan.board = board
	plan.lines.append("CFG PWM %d" % board.pwm_hz)

	for i in inputs:
		if i.board != board.id:
			continue
		plan.lines.append("CFG IN %d %d %s %d" % [plan.input_names.size(), i.pin, "NC" if i.nc else "NO", i.debounce_ms])
		plan.input_names.append(i.name)

	for c in coils:
		if c.board != board.id:
			continue
		plan.lines.append("CFG COIL %d %d %d %d %s %s %d" % [
			plan.coil_names.size(), c.pin, c.full_ms, c.hold_pct,
			_input_ref(plan, c.trigger), _input_ref(plan, c.eos), c.recycle_ms])
		plan.coil_names.append(c.name)

	for l in lamps:
		if l.board != board.id:
			continue
		plan.lines.append("CFG LAMP %d %d" % [plan.lamp_names.size(), l.pin])
		plan.lamp_names.append(l.name)

	for c in chains:
		if c.board != board.id:
			continue
		plan.lines.append("CFG CHAIN %d %d %d %s" % [plan.chain_names.size(), c.pin, c.count, c.order])
		plan.chain_names.append(c.name)

	# The board draws zones in number order, later ones on top. Bigger lights
	# first, so single inserts always draw over the strips they sit on.
	for l in _lights_in_draw_order(board.id):
		var chain_index := plan.chain_names.find(l.chain)
		if chain_index == -1:
			continue   # chain missing; validate() reports it
		plan.lines.append("CFG ZONE %d %d %d %d" % [plan.light_names.size(), chain_index, l.first, l.count])
		plan.light_names.append(l.name)

	plan.fingerprint = layout_hash(plan.lines)
	plan.lines.append("CFG DONE")
	return plan


## The board's fingerprint for a layout: 32-bit FNV-1a over every CFG line
## (not CLEAR or DONE), each followed by "\n", as 8 hex digits. The firmware
## computes the same thing, so equal hashes mean the board already runs this
## exact layout and doesn't need it sent again.
static func layout_hash(lines: PackedStringArray) -> String:
	var bytes := PackedByteArray()
	for line in lines:
		if line == "CFG DONE" or line == "CFG CLEAR":
			continue
		bytes.append_array((line + "\n").to_utf8_buffer())
	return "%08X" % fnv1a(bytes)


## 32-bit FNV-1a hash (a tiny, well-known checksum; easy to match in C).
static func fnv1a(data: PackedByteArray) -> int:
	var h := 2166136261
	for b in data:
		h = ((h ^ b) * 16777619) & 0xFFFFFFFF
	return h


## Lights on [param board_id], biggest first; equal sizes keep config order.
func _lights_in_draw_order(board_id: StringName) -> Array[IoDefs.LightDef]:
	var on_board: Array[IoDefs.LightDef] = []
	for l in lights:
		if light_board(l) == board_id:
			on_board.append(l)
	var order := {}   # light -> position in the config, so the sort is stable
	for n in on_board.size():
		order[on_board[n]] = n
	on_board.sort_custom(func(a: IoDefs.LightDef, b: IoDefs.LightDef) -> bool:
		return a.count > b.count or (a.count == b.count and order[a] < order[b]))
	return on_board


## The board's number for an input, or "-" for none.
func _input_ref(plan: IoDefs.BoardPlan, input_name: StringName) -> String:
	if input_name == &"":
		return "-"
	var index := plan.input_names.find(input_name)
	return str(index) if index != -1 else "-"

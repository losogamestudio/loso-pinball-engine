extends Node
## PinballIO — autoload that owns every serial link to the boards and turns
## the whole machine into names and signals.
##
## Game code only ever uses names from the machine config:
##     PinballIO.switch_changed.connect(_on_switch)     # (name, active)
##     PinballIO.set_coil_rule(&"flipper_left", true)   # arm a flipper
##     PinballIO.pulse_coil(&"kickout")                 # fire a coil once
##     PinballIO.set_light(&"shoot_again", "BLINK", Color.ORANGE, 250)   # LED effect
##     PinballIO.set_servo(&"ramp_gate", 1.0, 600, "SMOOTH")            # servo move (board runs the ramp)
##
## What happens underneath: open a port → the board answers HELLO with its
## type and serial number → we match it to a board in MachineConfig → push that
## board's CFG lines → once it accepts, its switches/coils/lamps become usable
## by name, and whatever rules/lamps game code asked for are sent to it.
##
## Requires the GdSerial plugin, and the MachineConfig autoload listed ABOVE
## this one in Project Settings > Globals > Autoload.
## This is the only script allowed to use GdSerial.

signal port_linked(port: String, firmware: String, board_type: String, uid: String)  ## a board answered HELLO
signal port_unlinked(port: String)              ## a linked board went quiet or its port closed
signal board_ready(board_id: StringName)        ## board accepted its config; its I/O is live
signal board_lost(board_id: StringName)         ## a ready board went away
signal board_problem(port: String, message: String)   ## wrong firmware, no matching board, bad config...
signal board_notice(port: String, message: String)    ## worth knowing, not an error (e.g. layout not burned)
signal board_burned(board_id: StringName)       ## board stored its layout in EEPROM
signal switch_changed(switch_name: StringName, active: bool)
signal coil_fired(coil_name: StringName)        ## a coil rule fired on its board (slings, pops...)
## Godot sent a coil command: a PULSE (on = true, it ends by itself) or HOLD ON/OFF.
## For displays like the Monitor tab; the board doesn't report coil outputs.
signal coil_commanded(coil_name: StringName, on: bool, is_pulse: bool)
## A light's wanted effect changed (set_light / all_lights_off). For displays like the Monitor tab.
signal light_changed(light_name: StringName)
## A servo was told to move (set_servo). For displays like the Monitor tab.
signal servo_changed(servo_name: StringName)
signal watchdog_changed(board_id: StringName, tripped: bool)
signal latency_measured(port: String, ms: float)
signal heartbeat(port: String, millis: int)     ## board's HB, once per second while linked
signal line_received(port: String, line: String)   ## every raw line in, for logging
signal line_sent(port: String, line: String)       ## every raw line out, for logging

const BAUD := 115200                     ## ignored by Teensy USB, required by the API (and real on an Uno)
const SETTINGS_PATH := "user://pinball_settings.cfg"   ## persisted across restarts, not under res://
const LAMP_MODES: Array[String] = ["OFF", "ON", "BLINK"]

## Current known state of every switch on a ready board: name -> bool.
var switches := {}

## Persisted settings (loaded in _ready, saved via set_auto_connect / on first link).
var auto_connect := false                ## if true, try last_port automatically at startup
var last_port := ""                      ## most recent port a board answered on
var remember_port := true                ## save last_port when a board answers; tests turn it off for fake boards
var light_brightness := 0.5              ## LED chain brightness 0..1 (a power cap), see set_light_brightness

var _serial: GdSerialManager
var _links := {}                         ## port -> BoardLink, for every open port
var _plans := {}                         ## port -> IoDefs.BoardPlan, once matched to a board
var _ready_ports := {}                   ## port -> true, once its board accepted the config
var _coil_routes := {}                   ## coil name -> Route (only while its board is ready)
var _lamp_routes := {}                   ## lamp name -> Route
var _rule_wanted := {}                   ## coil name -> bool, what game code asked for
var _lamp_wanted := {}                   ## lamp name -> "ON"/"OFF"/"BLINK"
var _light_routes := {}                  ## light name -> Route (index = the board's zone number)
var _light_wanted := {}                  ## light name -> {effect, color, ms, color2}
var _servo_routes := {}                  ## servo name -> Route (index = the board's servo number)
var _servo_wanted := {}                  ## servo name -> {position, ramp_ms, ease, until_ms}

## How a servo gets back to where Godot wants it after its board turned
## everything off (watchdog) or took a new layout (servos go home): a gentle move.
const SERVO_RESTORE_MS := 500


## Where a coil or lamp lives: which link, and its number on that board.
class Route:
	var link: BoardLink
	var index: int

	func _init(l: BoardLink, i: int) -> void:
		link = l
		index = i


func _ready() -> void:
	_serial = GdSerialManager.new()
	_serial.data_received.connect(_on_data)
	_serial.port_disconnected.connect(_on_port_lost)
	MachineConfig.changed.connect(_on_config_changed)
	_load_settings()
	if auto_connect and not last_port.is_empty():
		open_port(last_port)


func _exit_tree() -> void:
	close_port()


# ---------------------------------------------------------------- port control

func list_ports() -> Array[String]:
	var out: Array[String] = []
	var ports: Dictionary = _serial.list_ports()
	for key in ports:
		out.append(str(ports[key]["port_name"]))
	return out


## Open a port and start saying HELLO on it. Several ports can be open at once.
func open_port(port: String) -> bool:
	close_port(port)
	if not _serial.open(port, BAUD, 100):   # MODE_RAW: BoardLink does its own line splitting
		push_warning("PinballIO: could not open " + port)
		return false
	_attach_link(BoardLink.new(port, _write.bind(port)))
	return true


## Hook up a link's signals and start it. (Tests use this with a fake board.)
func _attach_link(link: BoardLink) -> void:
	var port := link.port_name
	# bind() tacks the link onto each signal's arguments, so one handler
	# can serve every board.
	link.linked.connect(_on_link_linked.bind(link))
	link.unlinked.connect(_on_link_unlinked.bind(link))
	link.configured.connect(_on_link_configured.bind(link))
	link.burned.connect(_on_link_burned.bind(link))
	link.config_failed.connect(_on_link_config_failed.bind(link))
	link.switches_synced.connect(_on_link_switches_synced.bind(link))
	link.switch_changed.connect(_on_link_switch_changed.bind(link))
	link.coil_fired.connect(_on_link_coil_fired.bind(link))
	link.watchdog_changed.connect(_on_link_watchdog_changed.bind(link))
	link.latency_measured.connect(func(ms: float) -> void: latency_measured.emit(port, ms))
	link.heartbeat.connect(func(millis: int) -> void: heartbeat.emit(port, millis))
	link.line_received.connect(func(line: String) -> void: line_received.emit(port, line))
	_links[port] = link
	link.start()


## Close one port, or every port if [param port] is empty.
func close_port(port := "") -> void:
	if port.is_empty():
		for p: String in _links.keys():
			close_port(p)
		return
	if not _links.has(port):
		return
	_serial.close(port)
	_drop_link(port)


func get_open_ports() -> Array[String]:
	var out: Array[String] = []
	out.assign(_links.keys())
	return out


## True if at least one port is open.
func is_any_port_open() -> bool:
	return not _links.is_empty()


## True when every board in the machine config is linked and configured.
func is_ready() -> bool:
	for b in MachineConfig.boards:
		if get_port_for_board(b.id).is_empty():
			return false
	return not MachineConfig.boards.is_empty()


## Store a ready board's layout in its EEPROM so it boots already configured.
## Rules and lamps are re-sent afterwards (the board turns outputs off while
## writing). Returns false if the board isn't ready.
func burn_board(board_id: StringName) -> bool:
	var port := get_port_for_board(board_id)
	if port.is_empty():
		push_warning("PinballIO: can't burn board '%s', it isn't ready" % board_id)
		return false
	(_links[port] as BoardLink).burn()
	return true


## True if a ready board's EEPROM holds exactly the layout it's running.
func is_board_burned(board_id: StringName) -> bool:
	var port := get_port_for_board(board_id)
	if port.is_empty():
		return false
	var plan: IoDefs.BoardPlan = _plans[port]
	return (_links[port] as BoardLink).saved_fingerprint == plan.fingerprint


## The port a ready board is on, or "" if it isn't ready.
func get_port_for_board(board_id: StringName) -> String:
	for port: String in _ready_ports:
		var plan: IoDefs.BoardPlan = _plans[port]
		if plan.board.id == board_id:
			return port
	return ""


# ---------------------------------------------------------------- settings

## Turn auto-connect-at-startup on or off and persist the choice immediately.
func set_auto_connect(enabled: bool) -> void:
	auto_connect = enabled
	_save_settings()


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return   # no settings file yet (first run) — defaults stand
	auto_connect = cfg.get_value("serial", "auto_connect", false)
	last_port = cfg.get_value("serial", "last_port", "")
	light_brightness = cfg.get_value("lights", "brightness", 0.5)


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("serial", "auto_connect", auto_connect)
	cfg.set_value("serial", "last_port", last_port)
	cfg.set_value("lights", "brightness", light_brightness)
	cfg.save(SETTINGS_PATH)


# ---------------------------------------------------------------- game-facing commands

## Fire a coil once. [param ms] defaults to the coil's full_ms. [param power]
## below 100 % pulses with PWM (a softer kick, like MPF's pulse_power); that
## needs a PWM-capable pin, so the board refuses it on pulse-only pins.
func pulse_coil(coil_name: StringName, ms := -1, power := 100) -> void:
	var r := _route(_coil_routes, coil_name, "coil")
	if r == null:
		return
	if power < 100:
		var def := MachineConfig.find_coil(coil_name)
		var full_ms: int = def.full_ms if def else 30
		r.link.send("PULSE %d %d %d" % [r.index, ms if ms > 0 else full_ms, clampi(power, 1, 100)])
	else:
		r.link.send("PULSE %d" % r.index if ms < 0 else "PULSE %d %d" % [r.index, ms])
	coil_commanded.emit(coil_name, true, true)


## Hold a coil on (full power, then its hold %) until told off. For diverters,
## magnets and the like; the coil needs a hold % in the config.
func hold_coil(coil_name: StringName, on: bool) -> void:
	var r := _route(_coil_routes, coil_name, "coil")
	if r:
		r.link.send("HOLD %d %s" % [r.index, "ON" if on else "OFF"])
		coil_commanded.emit(coil_name, on, false)


## Arm or disarm a coil's trigger rule (flippers, slings, pops). Remembered,
## so it's re-sent whenever the board (re)connects or recovers from a watchdog trip.
func set_coil_rule(coil_name: StringName, on: bool) -> void:
	var def := MachineConfig.find_coil(coil_name)
	if def == null:
		push_warning("PinballIO: no coil named '%s'" % coil_name)
		return
	if def.trigger == &"":
		push_warning("PinballIO: coil '%s' has no trigger input, so it has no rule" % coil_name)
		return
	_rule_wanted[coil_name] = on
	var r: Route = _coil_routes.get(coil_name)
	if r:
		r.link.send("RULE %d %s" % [r.index, "ON" if on else "OFF"])


## Arm or disarm every coil that has a trigger (e.g. all off on tilt or game over).
func set_all_rules(on: bool) -> void:
	for c in MachineConfig.coils:
		if c.trigger != &"":
			set_coil_rule(c.name, on)


func get_coil_rule(coil_name: StringName) -> bool:
	return _rule_wanted.get(coil_name, false)


## Set a lamp to "ON", "OFF" or "BLINK". Remembered like coil rules.
func set_lamp(lamp_name: StringName, mode: String) -> void:
	if mode not in LAMP_MODES:
		push_warning("PinballIO: bad lamp mode '%s'" % mode)
		return
	if MachineConfig.find_lamp(lamp_name) == null:
		push_warning("PinballIO: no lamp named '%s'" % lamp_name)
		return
	_lamp_wanted[lamp_name] = mode
	var r: Route = _lamp_routes.get(lamp_name)
	if r:
		r.link.send("LED %d %s" % [r.index, mode])


func get_lamp_mode(lamp_name: StringName) -> String:
	return _lamp_wanted.get(lamp_name, "OFF")


## Run an effect on a light (an LED range from the machine config). The board
## draws it by itself until told otherwise. Remembered like lamps.
##   effect: one of IoDefs.EFFECTS ("SOLID", "BLINK", "PULSE", "CHASE", ...)
##   ms:     period, or the duration for FADE / WIPE
##   color2: the second color for BLINK / CHASE / WIPE / SPARKLE
## Example: PinballIO.set_light(&"shoot_again", "BLINK", Color.ORANGE, 250)
func set_light(light_name: StringName, effect: String, color := Color.WHITE, ms := 500, color2 := Color.BLACK) -> void:
	if effect not in IoDefs.EFFECTS:
		push_warning("PinballIO: bad light effect '%s'" % effect)
		return
	if MachineConfig.find_light(light_name) == null:
		push_warning("PinballIO: no light named '%s'" % light_name)
		return
	_light_wanted[light_name] = {"effect": effect, "color": color, "ms": clampi(ms, 1, 600000), "color2": color2}
	var r: Route = _light_routes.get(light_name)
	if r:
		r.link.send(_fx_line(r.index, _light_wanted[light_name]))
	light_changed.emit(light_name)


## What a light was last told: {effect, color, ms, color2}. Effect "OFF" if never set.
func get_light(light_name: StringName) -> Dictionary:
	return _light_wanted.get(light_name, {"effect": "OFF", "color": Color.BLACK, "ms": 500, "color2": Color.BLACK})


## Every light off (e.g. when a light show stops).
func all_lights_off() -> void:
	for l in MachineConfig.lights:
		if get_light(l.name)["effect"] != "OFF":
			set_light(l.name, "OFF")


## LED brightness for every chain, 0..1. It's a power cap as much as a look:
## a strip at full white draws about 60 mA per LED. Saved on this machine.
func set_light_brightness(level: float) -> void:
	light_brightness = clampf(level, 0.0, 1.0)
	_save_settings()
	for port: String in _ready_ports:
		(_links[port] as BoardLink).send(_bright_line())


## Move a servo to [param position] (0..1 of its min..max range) over
## [param ramp_ms] (0 = straight there). ease: "LINEAR" (steady speed) or
## "SMOOTH" (eases in and out). The board runs the ramp. Remembered, so it's
## restored after a watchdog trip or a new layout.
## Example: PinballIO.set_servo(&"ramp_gate", 1.0, 600, "SMOOTH")
func set_servo(servo_name: StringName, position: float, ramp_ms := 0, ease := "LINEAR") -> void:
	if ease not in IoDefs.SERVO_EASES:
		push_warning("PinballIO: bad servo ease '%s' (use LINEAR or SMOOTH)" % ease)
		return
	if MachineConfig.find_servo(servo_name) == null:
		push_warning("PinballIO: no servo named '%s'" % servo_name)
		return
	ramp_ms = clampi(ramp_ms, 0, 600000)
	_servo_wanted[servo_name] = {"position": clampf(position, 0.0, 1.0), "ramp_ms": ramp_ms, "ease": ease,
			"until_ms": Time.get_ticks_msec() + ramp_ms}
	var r: Route = _servo_routes.get(servo_name)
	if r:
		r.link.send(_servo_line(r.index, _servo_wanted[servo_name]))
	servo_changed.emit(servo_name)


## What a servo was last told: {position, ramp_ms, ease, until_ms}
## (until_ms = when its move ends, in Time.get_ticks_msec()). Its home if never moved.
func get_servo(servo_name: StringName) -> Dictionary:
	if _servo_wanted.has(servo_name):
		return _servo_wanted[servo_name]
	var def := MachineConfig.find_servo(servo_name)
	return {"position": def.home if def else 0.5, "ramp_ms": 0, "ease": "LINEAR", "until_ms": 0}


## Is a servo in the middle of a move Godot sent? (The board doesn't report it.)
func is_servo_moving(servo_name: StringName) -> bool:
	return Time.get_ticks_msec() < int(get_servo(servo_name)["until_ms"])


func _servo_line(index: int, want: Dictionary, ramp_ms := -1, ease := "") -> String:
	return "SERVO %d %d %d %s" % [index, roundi(float(want["position"]) * 1000.0),
			want["ramp_ms"] if ramp_ms < 0 else ramp_ms, want["ease"] if ease == "" else ease]


func _fx_line(index: int, want: Dictionary) -> String:
	return "FX %d %s %s %d %s" % [index, want["effect"], (want["color"] as Color).to_html(false).to_upper(),
			want["ms"], (want["color2"] as Color).to_html(false).to_upper()]


func _bright_line() -> String:
	return "BRIGHT %d" % roundi(light_brightness * 255.0)


func is_switch_active(switch_name: StringName) -> bool:
	return switches.get(switch_name, false)


## Round-trip latency test on every linked board.
func ping() -> void:
	for link: BoardLink in _links.values():
		if link.is_linked:
			link.ping()


## Send a raw protocol line to one port (debugging only).
func send_raw(port: String, line: String) -> void:
	if _links.has(port):
		_write(line, port)


# ---------------------------------------------------------------- per frame

func _process(delta: float) -> void:
	if _links.is_empty():
		return
	_serial.poll_events()   # fires data_received / port_disconnected
	for link: BoardLink in _links.values():
		link.tick(delta)


# ---------------------------------------------------------------- serial plumbing

func _write(line: String, port: String) -> void:
	_serial.write(port, (line + "\n").to_utf8_buffer())
	line_sent.emit(port, line)


func _on_data(port: String, data: PackedByteArray) -> void:
	var link: BoardLink = _links.get(port)
	if link:
		link.feed(data)


func _on_port_lost(port: String) -> void:
	_drop_link(port)


func _drop_link(port: String) -> void:
	var link: BoardLink = _links.get(port)
	if link == null:
		return
	var was_linked := link.is_linked
	link.mark_unlinked()   # emits unlinked (→ _on_link_unlinked) if it was linked
	_links.erase(port)
	if not was_linked:
		port_unlinked.emit(port)   # still tell listeners the port is gone


# ---------------------------------------------------------------- board events

func _on_link_linked(firmware: String, board_type: String, uid: String, link: BoardLink) -> void:
	var port := link.port_name
	if remember_port and last_port != port:   # remember a working port, but don't hit disk every link
		last_port = port
		_save_settings()
	port_linked.emit(port, firmware, board_type, uid)
	_try_bind(link)


## Match a linked board to one in the machine config and send it its config.
func _try_bind(link: BoardLink) -> void:
	var port := link.port_name
	_unbind(port)
	if link.firmware != BoardTypes.FIRMWARE:
		board_problem.emit(port, "board runs %s but this Godot build needs %s: flash Firmware/pinio" % [link.firmware, BoardTypes.FIRMWARE])
		return
	var board := _match_board(link)
	if board == null:
		board_problem.emit(port, "no board in the machine config matches this %s (serial %s)" % [link.board_type, link.uid])
		return
	var errors := MachineConfig.validate()
	if not errors.is_empty():
		board_problem.emit(port, "machine config has %d problem(s), first: %s" % [errors.size(), errors[0]])
		return
	var plan := MachineConfig.build_plan(board)
	_plans[port] = plan
	if link.running_fingerprint == plan.fingerprint:
		link.adopt_config()   # already running exactly this layout (e.g. burned): nothing to send
		return
	if link.running_fingerprint != "-":
		board_notice.emit(port, "board '%s' was running a different layout; sending this machine's layout" % board.id)
	var lines: PackedStringArray = ["CFG CLEAR"]
	lines.append_array(plan.lines)
	link.send_config(lines)


## First board in the config with the right type and serial number (or no
## serial number set) that isn't already taken by another port.
func _match_board(link: BoardLink) -> IoDefs.BoardDef:
	for b in MachineConfig.boards:
		if b.type != link.board_type:
			continue
		if b.uid != "" and b.uid != link.uid:
			continue
		var taken := false
		for port: String in _plans:
			if port != link.port_name and (_plans[port] as IoDefs.BoardPlan).board.id == b.id:
				taken = true
		if not taken:
			return b
	return null


func _on_link_configured(link: BoardLink) -> void:
	var plan: IoDefs.BoardPlan = _plans.get(link.port_name)
	if plan == null:
		return
	for i in plan.coil_names.size():
		_coil_routes[plan.coil_names[i]] = Route.new(link, i)
	for i in plan.lamp_names.size():
		_lamp_routes[plan.lamp_names[i]] = Route.new(link, i)
	for i in plan.light_names.size():
		_light_routes[plan.light_names[i]] = Route.new(link, i)
	for i in plan.servo_names.size():
		_servo_routes[plan.servo_names[i]] = Route.new(link, i)
	_ready_ports[link.port_name] = true
	_resend_outputs(link)
	if link.running_fingerprint != plan.fingerprint:
		# Should never happen: Godot and the firmware hash the layout differently.
		board_problem.emit(link.port_name, "layout fingerprint mismatch (board %s, Godot %s): hash code out of sync" % [link.running_fingerprint, plan.fingerprint])
	board_ready.emit(plan.board.id)
	if not is_board_burned(plan.board.id):
		board_notice.emit(link.port_name, "board '%s' layout is NOT burned: it will be lost at power-off (use Burn to board)" % plan.board.id)


func _on_link_burned(_fingerprint: String, link: BoardLink) -> void:
	var plan: IoDefs.BoardPlan = _plans.get(link.port_name)
	_resend_outputs(link)   # the board turned everything off while writing
	if plan:
		board_burned.emit(plan.board.id)


func _on_link_config_failed(message: String, link: BoardLink) -> void:
	board_problem.emit(link.port_name, "board rejected its config: " + message)


func _on_link_unlinked(link: BoardLink) -> void:
	var plan: IoDefs.BoardPlan = _plans.get(link.port_name)
	var was_ready := _ready_ports.has(link.port_name)
	_unbind(link.port_name)
	port_unlinked.emit(link.port_name)
	if was_ready:
		board_lost.emit(plan.board.id)


func _on_link_switches_synced(states: Array[bool], link: BoardLink) -> void:
	var plan: IoDefs.BoardPlan = _plans.get(link.port_name)
	if plan == null:
		return
	for i in mini(states.size(), plan.input_names.size()):
		_set_switch(plan.input_names[i], states[i], true)


func _on_link_switch_changed(index: int, active: bool, link: BoardLink) -> void:
	var plan: IoDefs.BoardPlan = _plans.get(link.port_name)
	if plan and index < plan.input_names.size():
		_set_switch(plan.input_names[index], active)


func _on_link_coil_fired(index: int, link: BoardLink) -> void:
	var plan: IoDefs.BoardPlan = _plans.get(link.port_name)
	if plan and index < plan.coil_names.size():
		coil_fired.emit(plan.coil_names[index])


func _on_link_watchdog_changed(tripped: bool, link: BoardLink) -> void:
	var plan: IoDefs.BoardPlan = _plans.get(link.port_name)
	var board_id: StringName = plan.board.id if plan else &""
	watchdog_changed.emit(board_id, tripped)
	if not tripped:
		_resend_outputs(link)   # the board turned everything off; restore what we want


## Config was loaded or edited: re-configure every linked board from scratch.
func _on_config_changed() -> void:
	for link: BoardLink in _links.values():
		if link.is_linked:
			_try_bind(link)


# ---------------------------------------------------------------- helpers

## After a (re)config or watchdog recovery the board has every rule disarmed
## and every lamp and light off. Re-send whatever game code currently wants.
func _resend_outputs(link: BoardLink) -> void:
	var plan: IoDefs.BoardPlan = _plans.get(link.port_name)
	if plan == null or not link.is_configured:
		return
	for i in plan.coil_names.size():
		if _rule_wanted.get(plan.coil_names[i], false):
			link.send("RULE %d ON" % i)
	for i in plan.lamp_names.size():
		var mode: String = _lamp_wanted.get(plan.lamp_names[i], "OFF")
		if mode != "OFF":
			link.send("LED %d %s" % [i, mode])
	if not plan.chain_names.is_empty():
		link.send(_bright_line())
	for i in plan.light_names.size():
		var want := get_light(plan.light_names[i])
		if want["effect"] != "OFF":
			link.send(_fx_line(i, want))
	# Servos held still (watchdog) or went home (new layout): a gentle move back.
	for i in plan.servo_names.size():
		if _servo_wanted.has(plan.servo_names[i]):
			link.send(_servo_line(i, _servo_wanted[plan.servo_names[i]], SERVO_RESTORE_MS, "SMOOTH"))


func _unbind(port: String) -> void:
	var plan: IoDefs.BoardPlan = _plans.get(port)
	if plan == null:
		return
	for coil_name in plan.coil_names:
		_coil_routes.erase(coil_name)
	for lamp_name in plan.lamp_names:
		_lamp_routes.erase(lamp_name)
	for light_name in plan.light_names:
		_light_routes.erase(light_name)
	for servo_name in plan.servo_names:
		_servo_routes.erase(servo_name)
	for input_name in plan.input_names:
		switches.erase(input_name)
	_plans.erase(port)
	_ready_ports.erase(port)


func _route(routes: Dictionary, item_name: StringName, kind: String) -> Route:
	var r: Route = routes.get(item_name)
	if r == null:
		push_warning("PinballIO: %s '%s' isn't available (unknown name, or its board isn't ready)" % [kind, item_name])
	return r


func _set_switch(switch_name: StringName, active: bool, force_emit := false) -> void:
	if force_emit or switches.get(switch_name, false) != active:
		switches[switch_name] = active
		switch_changed.emit(switch_name, active)

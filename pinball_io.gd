extends Node
## PinballIO — autoload that talks to the Teensy and turns lines into signals.
##
## Add it under Project > Project Settings > Globals > Autoload with the name
## "PinballIO". Any scene can then do:
##     PinballIO.switch_changed.connect(_on_switch)
##     PinballIO.pulse_coil(0, 40)
##
## Requires the GdSerial plugin (addons/gdserial) to be installed and enabled.

signal linked(firmware: String)          ## Teensy answered HELLO
signal unlinked                          ## port closed or Teensy went quiet
signal switch_changed(id: int, active: bool)
signal rule_fired(rule_name: String)
signal analog_changed(id: int, value: int)
signal watchdog_changed(tripped: bool)
signal latency_measured(ms: float)
signal heartbeat(millis: int)            ## Teensy's HB <millis>, once per second while linked
signal line_received(line: String)       ## every raw line, for logging

const BAUD := 115200                     ## ignored by Teensy USB, required by the API
const HEARTBEAT_SEC := 0.1               ## we send HB 10x/sec; Teensy trips at 0.5 s
const HELLO_RETRY_SEC := 1.0             ## while unlinked, keep saying HELLO
const TEENSY_TIMEOUT_SEC := 3.0          ## Teensy sends HB every 1 s
const SETTINGS_PATH := "user://pinball_settings.cfg"   ## persisted across restarts, not under res://

var port_name := ""
var is_port_open := false
var is_linked := false
var switches := {}                       ## id -> bool, current known state

## Persisted settings (loaded in _ready, saved via set_auto_connect / on first link).
var auto_connect := false                ## if true, try last_port automatically at startup
var last_port := ""                      ## most recent port we successfully linked to

var _serial: GdSerialManager
var _rx_buffer := ""
var _send_timer := 0.0
var _since_rx := 0.0
var _ping_id := 0
var _ping_sent := {}                     ## ping id -> send time (usec)


func _ready() -> void:
	_serial = GdSerialManager.new()
	_serial.data_received.connect(_on_data)
	_serial.port_disconnected.connect(_on_port_lost)
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


func open_port(name: String) -> bool:
	close_port()
	if not _serial.open(name, BAUD, 100):   # MODE_RAW: we do our own line splitting
		push_warning("PinballIO: could not open " + name)
		return false
	port_name = name
	is_port_open = true
	_rx_buffer = ""
	_since_rx = 0.0
	send("HELLO")
	return true


func close_port() -> void:
	if not is_port_open:
		return
	_serial.close(port_name)
	is_port_open = false
	_set_unlinked(true)


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


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("serial", "auto_connect", auto_connect)
	cfg.set_value("serial", "last_port", last_port)
	cfg.save(SETTINGS_PATH)


# ---------------------------------------------------------------- commands out

func send(line: String) -> void:
	if is_port_open:
		_serial.write(port_name, (line + "\n").to_utf8_buffer())


func pulse_coil(id: int, ms: int) -> void:
	send("PULSE %d %d" % [id, ms])


func set_led(id: int, mode: String) -> void:   ## mode: "ON", "OFF", "BLINK"
	send("LED %d %s" % [id, mode])


func set_rule(rule_name: String, enabled: bool) -> void:
	send("RULE %s %s" % [rule_name, "ON" if enabled else "OFF"])


func ping() -> void:
	_ping_id += 1
	_ping_sent[_ping_id] = Time.get_ticks_usec()
	send("PING %d" % _ping_id)


# ---------------------------------------------------------------- per frame

func _process(delta: float) -> void:
	if not is_port_open:
		return

	_serial.poll_events()   # fires data_received / port_disconnected

	# Heartbeat while linked, HELLO retries while not.
	_send_timer += delta
	var interval := HEARTBEAT_SEC if is_linked else HELLO_RETRY_SEC
	if _send_timer >= interval:
		_send_timer = 0.0
		send("HB" if is_linked else "HELLO")

	# Teensy went quiet (unplugged, crashed, reflashing).
	_since_rx += delta
	if is_linked and _since_rx > TEENSY_TIMEOUT_SEC:
		_set_unlinked()


# ---------------------------------------------------------------- incoming

func _on_data(_port: String, data: PackedByteArray) -> void:
	_since_rx = 0.0
	_rx_buffer += data.get_string_from_utf8()
	# Serial arrives in arbitrary chunks: only act on complete lines.
	var nl := _rx_buffer.find("\n")
	while nl != -1:
		var line := _rx_buffer.substr(0, nl).strip_edges()
		_rx_buffer = _rx_buffer.substr(nl + 1)
		if not line.is_empty():
			_handle_line(line)
		nl = _rx_buffer.find("\n")
	if _rx_buffer.length() > 1024:   # garbage with no newline; don't grow forever
		_rx_buffer = ""


func _handle_line(line: String) -> void:
	line_received.emit(line)
	var parts := line.split(" ", false)
	var arg_count := parts.size() - 1

	match parts[0]:
		"HELLO":
			is_linked = true
			_send_timer = 0.0
			if last_port != port_name:   # remember a working port, but don't hit disk every link
				last_port = port_name
				_save_settings()
			linked.emit(" ".join(parts.slice(1)))
		"SWS":
			if arg_count >= 1:
				var bits: String = parts[1]
				for i in bits.length():
					_set_switch(i, bits[i] == "1", true)
		"SW":
			if arg_count >= 2:
				_set_switch(parts[1].to_int(), parts[2] == "1")
		"FIRED":
			if arg_count >= 1:
				rule_fired.emit(parts[1])
		"ANA":
			if arg_count >= 2:
				analog_changed.emit(parts[1].to_int(), parts[2].to_int())
		"WD":
			if arg_count >= 1:
				watchdog_changed.emit(parts[1] == "TRIP")
		"PONG":
			if arg_count >= 1:
				var id := parts[1].to_int()
				if _ping_sent.has(id):
					var ms := (Time.get_ticks_usec() - int(_ping_sent[id])) / 1000.0
					_ping_sent.erase(id)
					latency_measured.emit(ms)
		"HB":
			if arg_count >= 1:
				heartbeat.emit(parts[1].to_int())
		"ACK":
			pass
		"ERR":
			push_warning("Teensy: " + line)
		_:
			push_warning("PinballIO: unknown message: " + line)


func _set_switch(id: int, active: bool, force_emit := false) -> void:
	if force_emit or switches.get(id, false) != active:
		switches[id] = active
		switch_changed.emit(id, active)


func _on_port_lost(_port: String) -> void:
	is_port_open = false
	_set_unlinked(true)


func _set_unlinked(always_emit := false) -> void:
	if is_linked or always_emit:
		is_linked = false
		unlinked.emit()

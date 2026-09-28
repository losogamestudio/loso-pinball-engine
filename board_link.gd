class_name BoardLink
extends RefCounted
## One serial connection to one board, speaking the PINIO 0.2 protocol.
##
## Handles the link itself: HELLO retries, heartbeats, timeouts, splitting
## serial bytes into lines, pushing a config one line at a time, and turning
## replies into signals. It knows nothing about names or the machine layout —
## that's PinballIO's job — and it never touches GdSerial directly: PinballIO
## passes in bytes with feed() and gives it a writer Callable for output.
##
## RefCounted = a plain object that frees itself when nothing references it
## (no scene tree node needed), a bit like a UObject that isn't an Actor.

signal linked(firmware: String, board_type: String, uid: String)   ## board answered HELLO
signal unlinked                                  ## board went quiet, or the link was closed
signal configured                                ## board is running its layout (switches synced first)
signal config_failed(message: String)            ## board rejected a CFG line
signal burned(fingerprint: String)               ## board stored its layout in EEPROM (CFG SAVE)
signal switches_synced(states: Array[bool])      ## SWS: every input, by board index
signal switch_changed(index: int, active: bool)  ## SW: one input changed
signal coil_fired(index: int)                    ## FIRED: a coil rule fired on the board
signal watchdog_changed(tripped: bool)
signal latency_measured(ms: float)
signal heartbeat(millis: int)                    ## board's HB, once per second
signal line_received(line: String)               ## every raw line, for logging

const HEARTBEAT_SEC := 0.1       ## we send HB 10x/sec; the board trips at 0.5 s
const HELLO_RETRY_SEC := 1.0     ## while unlinked, keep saying HELLO
const TIMEOUT_SEC := 3.0         ## the board sends HB every 1 s

var port_name := ""
var is_linked := false
var is_configured := false
var firmware := ""               ## e.g. "PINIO 0.2"
var board_type := ""             ## e.g. "TEENSY41"
var uid := ""                    ## board serial number from HELLO
var running_fingerprint := "-"   ## hash of the layout the board is running ("-" = none)
var saved_fingerprint := "-"     ## hash of the layout burned into its EEPROM ("-" = none)

var _write: Callable             ## func(line: String) -> void, provided by PinballIO
var _rx_buffer := ""
var _send_timer := 0.0
var _since_rx := 0.0
var _ping_id := 0
var _ping_sent := {}             ## ping id -> send time (usec)
var _cfg_queue: PackedStringArray = []
var _cfg_in_progress := false
var _cfg_waiting_sws := false


func _init(port: String, writer: Callable) -> void:
	port_name = port
	_write = writer


## Say HELLO right away (after that, tick() keeps retrying until linked).
func start() -> void:
	_rx_buffer = ""
	_since_rx = 0.0
	_send_timer = 0.0
	send("HELLO")


func send(line: String) -> void:
	_write.call(line)


func ping() -> void:
	_ping_id += 1
	_ping_sent[_ping_id] = Time.get_ticks_usec()
	send("PING %d" % _ping_id)


## Send a whole layout (starting with CFG CLEAR) one line at a time: each line waits for its ACK, so a slow
## board with a small serial buffer (an Uno) never gets flooded.
func send_config(lines: PackedStringArray) -> void:
	is_configured = false
	_cfg_queue = lines.duplicate()
	_cfg_in_progress = true
	_cfg_waiting_sws = false
	_send_next_cfg()


## The board already runs the right layout (its fingerprint matched): just
## ask for the switch states, and count it as configured once they arrive.
func adopt_config() -> void:
	is_configured = false
	_cfg_queue.clear()
	_cfg_in_progress = true
	_cfg_waiting_sws = true
	send("SWS")


## Store the running layout in the board's EEPROM, so it boots configured.
## The board turns its outputs off while writing; `burned` fires when done.
func burn() -> void:
	send("CFG SAVE")


## Call every frame while the port is open.
func tick(delta: float) -> void:
	# Heartbeat while linked, HELLO retries while not.
	_send_timer += delta
	var interval := HEARTBEAT_SEC if is_linked else HELLO_RETRY_SEC
	if _send_timer >= interval:
		_send_timer = 0.0
		send("HB" if is_linked else "HELLO")

	# Board went quiet (unplugged, crashed, reflashing).
	_since_rx += delta
	if is_linked and _since_rx > TIMEOUT_SEC:
		mark_unlinked()


## Raw bytes from the serial port. Serial arrives in arbitrary chunks, so
## only complete lines are acted on.
func feed(data: PackedByteArray) -> void:
	_since_rx = 0.0
	_rx_buffer += data.get_string_from_utf8()
	var nl := _rx_buffer.find("\n")
	while nl != -1:
		var line := _rx_buffer.substr(0, nl).strip_edges()
		_rx_buffer = _rx_buffer.substr(nl + 1)
		if not line.is_empty():
			_handle_line(line)
		nl = _rx_buffer.find("\n")
	if _rx_buffer.length() > 1024:   # garbage with no newline; don't grow forever
		_rx_buffer = ""


func mark_unlinked() -> void:
	_cfg_queue.clear()
	_cfg_in_progress = false
	_cfg_waiting_sws = false
	is_configured = false
	if is_linked:
		is_linked = false
		unlinked.emit()


# ---------------------------------------------------------------- incoming

func _handle_line(line: String) -> void:
	line_received.emit(line)
	var parts := line.split(" ", false)
	var arg_count := parts.size() - 1

	match parts[0]:
		"HELLO":
			# HELLO PINIO 0.2 TEENSY41 12345670 <running|-> <saved|->
			# (0.1 firmware only sends HELLO PINIO 0.1)
			firmware = " ".join(parts.slice(1, 3))
			board_type = parts[3] if arg_count >= 3 else ""
			uid = parts[4] if arg_count >= 4 else ""
			running_fingerprint = parts[5] if arg_count >= 5 else "-"
			saved_fingerprint = parts[6] if arg_count >= 6 else "-"
			is_linked = true
			is_configured = false
			_cfg_queue.clear()
			_cfg_in_progress = false
			_send_timer = 0.0
			linked.emit(firmware, board_type, uid)
		"ACK":
			if arg_count >= 3 and parts[1] == "CFG" and parts[2] == "SAVE":
				saved_fingerprint = parts[3]   # "ACK CFG SAVE <hash>"
				burned.emit(saved_fingerprint)
			elif arg_count >= 1 and parts[1] == "CFG" and _cfg_in_progress:
				if arg_count >= 4 and parts[2].is_valid_int():
					# "ACK CFG <in> <coil> <lamp> <hash>": whole layout accepted, SWS comes next
					running_fingerprint = parts[5] if arg_count >= 5 else "-"
					_cfg_waiting_sws = true
				else:
					_send_next_cfg()           # one CFG line accepted, send the next
		"ERR":
			var message := " ".join(parts.slice(1))
			push_warning("Board %s: %s" % [port_name, line])
			if _cfg_in_progress:
				_cfg_queue.clear()
				_cfg_in_progress = false
				_cfg_waiting_sws = false
				config_failed.emit(message)
		"SWS":
			var states: Array[bool] = []
			if arg_count >= 1:
				for ch in parts[1]:
					states.append(ch == "1")
			switches_synced.emit(states)
			if _cfg_waiting_sws:
				_cfg_waiting_sws = false
				_cfg_in_progress = false
				is_configured = true
				configured.emit()
		"SW":
			if arg_count >= 2 and parts[1].is_valid_int():
				switch_changed.emit(parts[1].to_int(), parts[2] == "1")
		"FIRED":
			if arg_count >= 1 and parts[1].is_valid_int():
				coil_fired.emit(parts[1].to_int())
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
		_:
			push_warning("Board %s: unknown message: %s" % [port_name, line])


func _send_next_cfg() -> void:
	if _cfg_queue.is_empty():
		return
	var line := _cfg_queue[0]
	_cfg_queue.remove_at(0)
	send(line)

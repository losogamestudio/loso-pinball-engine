class_name IoDefs
## Plain data records for one machine's I/O layout, used by MachineConfig.
##
## Each record is a small typed class (like a USTRUCT in Unreal) with
## to_dict()/from_dict() so it can round-trip through the JSON config file.
## Use them as IoDefs.CoilDef etc.


## One controller board (a Teensy, an Uno, ...).
class BoardDef:
	var id: StringName = &"main"     ## name used by inputs/coils/lamps to say which board they're on
	var type: String = "TEENSY41"    ## key in BoardTypes.TYPES
	## Serial number reported in HELLO. Empty = accept any board of this type
	## (fine with one board; set it once you have several of the same type).
	var uid: String = ""
	var pwm_hz: int = 20000

	func to_dict() -> Dictionary:
		return {"id": String(id), "type": type, "uid": uid, "pwm_hz": pwm_hz}

	static func from_dict(d: Dictionary) -> BoardDef:
		var b := BoardDef.new()
		b.id = StringName(d.get("id", "main"))
		b.type = str(d.get("type", "TEENSY41"))
		b.uid = str(d.get("uid", ""))
		b.pwm_hz = int(d.get("pwm_hz", 20000))
		return b


## One switch input.
class InputDef:
	var name: StringName             ## what game code calls it, e.g. &"flipper_left_button"
	var board: StringName = &"main"
	var pin: int = -1
	var nc: bool = false             ## normally closed: active when the switch OPENS
	var debounce_ms: int = 5

	func to_dict() -> Dictionary:
		return {"name": String(name), "board": String(board), "pin": pin,
				"nc": nc, "debounce_ms": debounce_ms}

	static func from_dict(d: Dictionary) -> InputDef:
		var i := InputDef.new()
		i.name = StringName(d.get("name", ""))
		i.board = StringName(d.get("board", "main"))
		i.pin = int(d.get("pin", -1))
		i.nc = bool(d.get("nc", false))
		i.debounce_ms = int(d.get("debounce_ms", 5))
		return i


## One coil. The board runs its trigger/EOS/hold rule locally; see
## Firmware/pinio/pinio.ino for the exact behavior.
class CoilDef:
	var name: StringName             ## e.g. &"flipper_left"
	var board: StringName = &"main"
	var pin: int = -1
	var full_ms: int = 30            ## full power time (the failsafe limit when EOS is set)
	var hold_pct: int = 0            ## 0 = pulse only, 1..100 = PWM hold after full power
	var trigger: StringName = &""    ## input that fires it on the board, or empty
	var eos: StringName = &""        ## end-of-stroke input that ends full power, or empty
	var recycle_ms: int = 0          ## dead time after turning off

	func to_dict() -> Dictionary:
		return {"name": String(name), "board": String(board), "pin": pin,
				"full_ms": full_ms, "hold_pct": hold_pct,
				"trigger": String(trigger), "eos": String(eos), "recycle_ms": recycle_ms}

	static func from_dict(d: Dictionary) -> CoilDef:
		var c := CoilDef.new()
		c.name = StringName(d.get("name", ""))
		c.board = StringName(d.get("board", "main"))
		c.pin = int(d.get("pin", -1))
		c.full_ms = int(d.get("full_ms", 30))
		c.hold_pct = int(d.get("hold_pct", 0))
		c.trigger = StringName(d.get("trigger", ""))
		c.eos = StringName(d.get("eos", ""))
		c.recycle_ms = int(d.get("recycle_ms", 0))
		return c


## One lamp output.
class LampDef:
	var name: StringName
	var board: StringName = &"main"
	var pin: int = -1

	func to_dict() -> Dictionary:
		return {"name": String(name), "board": String(board), "pin": pin}

	static func from_dict(d: Dictionary) -> LampDef:
		var l := LampDef.new()
		l.name = StringName(d.get("name", ""))
		l.board = StringName(d.get("board", "main"))
		l.pin = int(d.get("pin", -1))
		return l


## What one board gets told: its CFG lines, plus which name sits at each
## local index (the board only knows numbers, game code only knows names).
class BoardPlan:
	var board: BoardDef
	var input_names: Array[StringName] = []   ## index = board's input number
	var coil_names: Array[StringName] = []    ## index = board's coil number
	var lamp_names: Array[StringName] = []    ## index = board's lamp number
	var lines: PackedStringArray = []         ## CFG lines, in order, ending with CFG DONE
	var fingerprint: String = ""              ## layout hash, same as the board reports

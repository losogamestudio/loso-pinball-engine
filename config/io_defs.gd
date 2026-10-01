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


## What a switch means to the game (Godot only; the board never sees this,
## so changing it doesn't change the layout fingerprint).
const KIND_SWITCH := "switch"     ## plain: flipper buttons, EOS, anything read by name
const KIND_TARGET := "target"     ## scores its points every time it closes
const KIND_SPINNER := "spinner"   ## scores its points every close (once per spin)
const KIND_DRAIN := "drain"       ## outhole/trough: ends the current ball
const KIND_START := "start"       ## cabinet Start button: starts a game
const KINDS: Array[String] = [KIND_SWITCH, KIND_TARGET, KIND_SPINNER, KIND_DRAIN, KIND_START]
const KIND_LABELS := {
	KIND_SWITCH: "Plain switch",
	KIND_TARGET: "Point target",
	KIND_SPINNER: "Spinner",
	KIND_DRAIN: "Drain (ends the ball)",
	KIND_START: "Start button",
}
## Suggested points and debounce when a switch is given a scoring kind.
const KIND_DEFAULT_POINTS := {KIND_TARGET: 500, KIND_SPINNER: 100}
const KIND_DEFAULT_DEBOUNCE_MS := {KIND_TARGET: 5, KIND_SPINNER: 1}


## True for kinds that add points when they close.
static func kind_scores(kind: String) -> bool:
	return kind == KIND_TARGET or kind == KIND_SPINNER


## One switch input.
class InputDef:
	var name: StringName             ## what game code calls it, e.g. &"flipper_left_button"
	var board: StringName = &"main"
	var pin: int = -1
	var nc: bool = false             ## normally closed: active when the switch OPENS
	var debounce_ms: int = 5
	var kind: String = "switch"      ## one of IoDefs.KINDS (Godot only)
	var points: int = 0              ## for target/spinner: points per close
	var sound: StringName = &""      ## optional Media sound played when it closes during a game (Godot only)

	func to_dict() -> Dictionary:
		return {"name": String(name), "board": String(board), "pin": pin,
				"nc": nc, "debounce_ms": debounce_ms, "kind": kind, "points": points,
				"sound": String(sound)}

	static func from_dict(d: Dictionary) -> InputDef:
		var i := InputDef.new()
		i.name = StringName(d.get("name", ""))
		i.board = StringName(d.get("board", "main"))
		i.pin = int(d.get("pin", -1))
		i.nc = bool(d.get("nc", false))
		i.debounce_ms = int(d.get("debounce_ms", 5))
		i.kind = str(d.get("kind", "switch"))   # older config files have no kind
		i.points = int(d.get("points", 0))
		i.sound = StringName(d.get("sound", ""))
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


## LED effects the board can run on a light (Firmware/pinio/leds.h).
## `ms` is the period, or the duration for FADE and WIPE.
const EFFECTS: Array[String] = ["OFF", "SOLID", "BLINK", "PULSE", "CHASE", "WIPE", "FADE", "RAINBOW", "SPARKLE"]
const EFFECT_HELP := {
	"OFF": "nothing (anything underneath shows through)",
	"SOLID": "color 1",
	"BLINK": "color 1 / color 2, ms each",
	"PULSE": "color 1 breathing, one breath every ms",
	"CHASE": "every 3rd LED in color 1 over color 2, one step every ms",
	"WIPE": "fills with color 1 over color 2 across ms",
	"FADE": "fades from the previous color to color 1 across ms",
	"RAINBOW": "rainbow along the light, one cycle every ms",
	"SPARKLE": "random color 1 flashes over color 2, new pattern every ms",
}
## Byte order of an LED chain. Most WS2812B strips are GRB.
const COLOR_ORDERS: Array[String] = ["GRB", "RGB", "BRG", "RBG", "GBR", "BGR"]


## One WS2812B LED chain: a strip (or several soldered in a row) on one output pin.
class ChainDef:
	var name: StringName             ## e.g. &"playfield_chain"
	var board: StringName = &"main"
	var pin: int = -1
	var count: int = 30              ## LEDs on the chain
	var order: String = "GRB"        ## one of IoDefs.COLOR_ORDERS

	func to_dict() -> Dictionary:
		return {"name": String(name), "board": String(board), "pin": pin, "count": count, "order": order}

	static func from_dict(d: Dictionary) -> ChainDef:
		var c := ChainDef.new()
		c.name = StringName(d.get("name", ""))
		c.board = StringName(d.get("board", "main"))
		c.pin = int(d.get("pin", -1))
		c.count = int(d.get("count", 30))
		c.order = str(d.get("order", "GRB"))
		return c


## One named light: a range of LEDs on a chain. count 1 = a single insert;
## more = a strip or a section of one. Lights may overlap; smaller ones draw on top.
class LightDef:
	var name: StringName             ## what game code and shows call it, e.g. &"shoot_again"
	var chain: StringName            ## the ChainDef it's on (its board is the chain's board)
	var first: int = 0               ## first LED, counting from 0 at the chain's input end
	var count: int = 1

	func to_dict() -> Dictionary:
		return {"name": String(name), "chain": String(chain), "first": first, "count": count}

	static func from_dict(d: Dictionary) -> LightDef:
		var l := LightDef.new()
		l.name = StringName(d.get("name", ""))
		l.chain = StringName(d.get("chain", ""))
		l.first = int(d.get("first", 0))
		l.count = int(d.get("count", 1))
		return l


## What one board gets told: its CFG lines, plus which name sits at each
## local index (the board only knows numbers, game code only knows names).
class BoardPlan:
	var board: BoardDef
	var input_names: Array[StringName] = []   ## index = board's input number
	var coil_names: Array[StringName] = []    ## index = board's coil number
	var lamp_names: Array[StringName] = []    ## index = board's lamp number
	var chain_names: Array[StringName] = []   ## index = board's LED chain number
	var light_names: Array[StringName] = []   ## index = board's zone number
	var lines: PackedStringArray = []         ## CFG lines, in order, ending with CFG DONE
	var fingerprint: String = ""              ## layout hash, same as the board reports

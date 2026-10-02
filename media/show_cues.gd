@tool
class_name ShowCues
extends RefCounted
## ShowCues — reading cues out of a show's animation, shared by the game (the
## Shows autoload) and the editor (addons/loso_show_tools, the Light Show
## dock). It's a @tool script so the editor can run it too; it never touches
## autoloads, which don't exist inside the editor.
##
## Each key on a show's Call Method tracks calls a method named for its cue
## TYPE, so the timeline reads what it does:
##   light(light_name, effect, color, ms, color2)   an LED light's effect (old name: cue)
##   servo(servo_name, position, ramp_ms, ease)     move a servo (position 0..1, LINEAR or SMOOTH)
##   coil(coil_name, ms, power)                     pulse a coil (ms 0 = its own pulse time, power 1..100 %)
## Lights and servos are STATE: at any moment each one follows its latest key.
## Coils are EVENTS: a pulse happens once, when the clock passes its key.
##
## Also the tiny "show preview" text protocol: while you scrub or play a show
## in the editor, the dock sends one UDP line per change to the running game,
## which passes it to PinballIO, so the real hardware follows the timeline.
##
##   editor -> game   PING                                   (once a second)
##   game -> editor   PONG L:<light>... S:<servo>... C:<coil>...   (the game's names)
##   editor -> game   FX <light> <effect> <RRGGBB> <ms> <RRGGBB2>
##   editor -> game   SERVO <servo> <position 0..1000> <ramp_ms> <LINEAR|SMOOTH>
##   editor -> game   COIL <coil> <ms> <power>
##   editor -> game   OFF                                    (every light off)

const TYPE_LIGHT := &"light"
const TYPE_SERVO := &"servo"
const TYPE_COIL := &"coil"
const TYPES: Array[StringName] = [TYPE_LIGHT, TYPE_SERVO, TYPE_COIL]

## The method each cue type's keys call (on LightShow).
const METHOD := &"light"
const METHOD_SERVO := &"servo"
const METHOD_COIL := &"coil"
## The old name of light cues (before cue types). Still read, never written.
const OLD_METHOD := &"cue"

const ANIMATION_NAME := &"show"
const PREVIEW_PORT := 4777

## Defaults for anything a key leaves out (same as LightShow's methods).
const DEFAULT_EFFECT := "SOLID"
const DEFAULT_MS := 500
const DEFAULT_POSITION := 0.5
const DEFAULT_RAMP_MS := 500
const DEFAULT_EASE := "SMOOTH"
const DEFAULT_POWER := 100


## The cue type of a key's method name, or &"" if it isn't a cue.
static func type_of_method(method: StringName) -> StringName:
	match method:
		METHOD, OLD_METHOD:
			return TYPE_LIGHT
		METHOD_SERVO:
			return TYPE_SERVO
		METHOD_COIL:
			return TYPE_COIL
	return &""


## Does a method key with this method name hold a light cue?
static func is_light_method(method: StringName) -> bool:
	return type_of_method(method) == TYPE_LIGHT


## Every cue key on the animation's enabled Call Method tracks, sorted by time.
## Each is {type, time, target, track, ...}: target = the light/servo/coil
## name, track = which animation track the key is on (for editors), plus
##   light: effect, color, ms, color2 (and "light" = target)
##   servo: position, ramp_ms, ease
##   coil:  ms, power
static func read(anim: Animation) -> Array[Dictionary]:
	var cues: Array[Dictionary] = []
	if anim == null:
		return cues
	for track in anim.get_track_count():
		if anim.track_get_type(track) != Animation.TYPE_METHOD or not anim.track_is_enabled(track):
			continue
		for key in anim.track_get_key_count(track):
			var type := type_of_method(anim.method_track_get_name(track, key))
			if type == &"":
				continue
			var cue := _fields(type, anim.method_track_get_params(track, key))
			cue["time"] = anim.track_get_key_time(track, key)
			cue["track"] = track
			cues.append(cue)
	# Stable by time, so two cues at the same moment keep their track order.
	cues.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["time"] < b["time"])
	return cues


## A key's arguments as named fields, with defaults for anything left out.
static func _fields(type: StringName, args: Array) -> Dictionary:
	var target := StringName(args[0]) if args.size() > 0 else &""
	match type:
		TYPE_SERVO:
			return {"type": type, "target": target,
				"position": clampf(float(args[1]), 0.0, 1.0) if args.size() > 1 else DEFAULT_POSITION,
				"ramp_ms": maxi(int(args[2]), 0) if args.size() > 2 else DEFAULT_RAMP_MS,
				"ease": str(args[3]) if args.size() > 3 and str(args[3]) in ["LINEAR", "SMOOTH"] else DEFAULT_EASE}
		TYPE_COIL:
			return {"type": type, "target": target,
				"ms": maxi(int(args[1]), 0) if args.size() > 1 else 0,
				"power": clampi(int(args[2]), 1, 100) if args.size() > 2 else DEFAULT_POWER}
		_:
			return {"type": TYPE_LIGHT, "target": target, "light": target,
				"effect": str(args[1]) if args.size() > 1 and str(args[1]) != "" else DEFAULT_EFFECT,
				"color": args[2] if args.size() > 2 and args[2] is Color else Color.WHITE,
				"ms": int(args[3]) if args.size() > 3 and int(args[3]) > 0 else DEFAULT_MS,
				"color2": args[4] if args.size() > 4 and args[4] is Color else Color.BLACK}


## What each light (or servo) is doing at a moment: target name -> its latest
## cue of [param type] at or before `time`. One without a cue yet isn't in the
## result (a light is off; a servo stays where it is). For coils it's the
## latest pulse key, which editors use to show "the key it follows".
static func state_at(cues: Array[Dictionary], time: float, type := TYPE_LIGHT) -> Dictionary:
	var state := {}
	for cue in cues:
		if cue["time"] > time + 0.0001:
			break
		if cue["type"] == type:
			state[cue["target"]] = cue
	return state


## The [param type] cues (coil pulses, normally) with after < time <= until.
static func events_between(cues: Array[Dictionary], after: float, until: float, type := TYPE_COIL) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for cue in cues:
		if cue["type"] == type and cue["time"] > after and cue["time"] <= until:
			found.append(cue)
	return found


## A short string that changes whenever a cue changes (another key, or the
## same key with new settings), so a cue is only sent once.
static func cue_id(cue: Dictionary) -> String:
	if cue.is_empty():
		return "OFF"
	return "%.4f %s" % [cue["time"], preview_line(cue)]


## The preview line for a cue: FX, SERVO or COIL.
static func preview_line(cue: Dictionary) -> String:
	match cue.get("type", TYPE_LIGHT):
		TYPE_SERVO:
			return "SERVO %s %d %d %s" % [cue["target"], roundi(float(cue["position"]) * 1000.0), cue["ramp_ms"], cue["ease"]]
		TYPE_COIL:
			return "COIL %s %d %d" % [cue["target"], cue["ms"], cue["power"]]
	return fx_line(cue.get("target", cue.get("light", &"")), cue)


## The preview line for one light: its cue, or OFF for an empty cue.
static func fx_line(light: StringName, cue: Dictionary) -> String:
	if cue.is_empty():
		return "FX %s OFF 000000 %d 000000" % [light, DEFAULT_MS]
	return "FX %s %s %s %d %s" % [light, cue["effect"], (cue["color"] as Color).to_html(false).to_upper(),
			cue["ms"], (cue["color2"] as Color).to_html(false).to_upper()]


## Read an FX preview line back: {light, effect, color, ms, color2}, or {} if it's bad.
static func parse_fx(line: String) -> Dictionary:
	var parts := line.strip_edges().split(" ", false)
	if parts.size() != 6 or parts[0] != "FX" or not parts[4].is_valid_int():
		return {}
	if not Color.html_is_valid(parts[3]) or not Color.html_is_valid(parts[5]):
		return {}
	return {"type": TYPE_LIGHT, "target": StringName(parts[1]), "light": StringName(parts[1]), "effect": parts[2],
			"color": Color.html(parts[3]), "ms": parts[4].to_int(), "color2": Color.html(parts[5])}


## Read any cue preview line back (FX, SERVO or COIL) as cue fields, or {} if it's bad.
static func parse_preview(line: String) -> Dictionary:
	var parts := line.strip_edges().split(" ", false)
	if parts.is_empty():
		return {}
	match parts[0]:
		"FX":
			return parse_fx(line)
		"SERVO":
			if parts.size() != 5 or not parts[2].is_valid_int() or not parts[3].is_valid_int() \
					or parts[4] not in ["LINEAR", "SMOOTH"]:
				return {}
			return {"type": TYPE_SERVO, "target": StringName(parts[1]), "position": clampf(parts[2].to_int() / 1000.0, 0.0, 1.0),
					"ramp_ms": maxi(parts[3].to_int(), 0), "ease": parts[4]}
		"COIL":
			if parts.size() != 4 or not parts[2].is_valid_int() or not parts[3].is_valid_int():
				return {}
			return {"type": TYPE_COIL, "target": StringName(parts[1]), "ms": maxi(parts[2].to_int(), 0),
					"power": clampi(parts[3].to_int(), 1, 100)}
	return {}


## The game's answer to PING: its light, servo and coil names.
static func pong_line(lights: Array, servos: Array, coils: Array) -> String:
	var words := PackedStringArray(["PONG"])
	for n: Variant in lights:
		words.append("L:" + String(n))
	for n: Variant in servos:
		words.append("S:" + String(n))
	for n: Variant in coils:
		words.append("C:" + String(n))
	return " ".join(words)


## A PONG line's names by type: {light: [...], servo: [...], coil: [...]}
## (as PackedStringArrays). A word without a type prefix is a light (older games).
static func parse_pong(line: String) -> Dictionary:
	var names := {TYPE_LIGHT: PackedStringArray(), TYPE_SERVO: PackedStringArray(), TYPE_COIL: PackedStringArray()}
	var words := line.strip_edges().split(" ", false)
	for n in range(1, words.size()):
		var word := words[n]
		if word.begins_with("S:"):
			names[TYPE_SERVO].append(word.substr(2))
		elif word.begins_with("C:"):
			names[TYPE_COIL].append(word.substr(2))
		else:
			names[TYPE_LIGHT].append(word.trim_prefix("L:"))
	return names


## The Call Method track that holds a target's cues of [param type] (one track
## per light / servo / coil), or -1. A track belongs to the target of its first cue.
static func track_for(anim: Animation, type: StringName, target: StringName) -> int:
	for track in anim.get_track_count():
		if anim.track_get_type(track) != Animation.TYPE_METHOD:
			continue
		for key in anim.track_get_key_count(track):
			if type_of_method(anim.method_track_get_name(track, key)) != type:
				continue
			var args: Array = anim.method_track_get_params(track, key)
			if args.size() > 0 and StringName(args[0]) == target:
				return track
			break
	return -1


## The Call Method track that holds a light's cues, or -1.
static func track_for_light(anim: Animation, light: StringName) -> int:
	return track_for(anim, TYPE_LIGHT, light)


## A method key's value for a light(...) call.
static func cue_key(light: StringName, effect: String, color: Color, ms: int, color2: Color) -> Dictionary:
	return {"method": METHOD, "args": [light, effect, color, ms, color2]}


## A method key's value for a servo(...) call.
static func servo_key(servo: StringName, position: float, ramp_ms: int, ease: String) -> Dictionary:
	return {"method": METHOD_SERVO, "args": [servo, clampf(position, 0.0, 1.0), maxi(ramp_ms, 0), ease]}


## A method key's value for a coil(...) call.
static func coil_key(coil: StringName, ms: int, power: int) -> Dictionary:
	return {"method": METHOD_COIL, "args": [coil, maxi(ms, 0), clampi(power, 1, 100)]}


## A method key's value for a cue of any type, from its fields (as read() returns them).
static func key_for(cue: Dictionary) -> Dictionary:
	match cue["type"]:
		TYPE_SERVO:
			return servo_key(cue["target"], cue["position"], cue["ramp_ms"], cue["ease"])
		TYPE_COIL:
			return coil_key(cue["target"], cue["ms"], cue["power"])
	return cue_key(cue["target"], cue["effect"], cue["color"], cue["ms"], cue["color2"])

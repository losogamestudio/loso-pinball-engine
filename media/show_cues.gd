@tool
class_name ShowCues
extends RefCounted
## ShowCues — reading light cues out of a show's animation, shared by the game
## (the Shows autoload) and the editor (addons/loso_show_tools, the Light Show
## dock). It's a @tool script so the editor can run it too; it never touches
## autoloads, which don't exist inside the editor.
##
## Also the tiny "show preview" text protocol: while you scrub or play a show
## in the editor, the dock sends one UDP line per light change to the running
## game, which passes it to PinballIO, so the real LEDs follow the timeline.
##
##   editor -> game   PING                                   (once a second)
##   game -> editor   PONG <light> <light> ...               (the game's light names)
##   editor -> game   FX <light> <effect> <RRGGBB> <ms> <RRGGBB2>
##   editor -> game   OFF                                    (every light off)

## Each key on a show's Call Method tracks calls a method named for its cue
## type, so the timeline reads light(...). Only light cues exist so far; coil
## and servo cues will be more methods (and types) next to it.
const METHOD := &"light"
## The old name of light cues (before cue types). Still read, never written.
const OLD_METHOD := &"cue"
const TYPE_LIGHT := &"light"
const ANIMATION_NAME := &"show"
const PREVIEW_PORT := 4777

## Defaults for anything a cue key leaves out (same as LightShow.light()).
const DEFAULT_EFFECT := "SOLID"
const DEFAULT_MS := 500


## Every light(...) key (or old cue(...) key) on the animation's enabled Call
## Method tracks, sorted by time: [{type, time, light, effect, color, ms,
## color2, track}] (type = &"light"; track = which animation track the key is
## on, for editors).
static func read(anim: Animation) -> Array[Dictionary]:
	var cues: Array[Dictionary] = []
	if anim == null:
		return cues
	for track in anim.get_track_count():
		if anim.track_get_type(track) != Animation.TYPE_METHOD or not anim.track_is_enabled(track):
			continue
		for key in anim.track_get_key_count(track):
			if not is_light_method(anim.method_track_get_name(track, key)):
				continue
			var args: Array = anim.method_track_get_params(track, key)
			cues.append({
				"type": TYPE_LIGHT,
				"time": anim.track_get_key_time(track, key),
				"light": StringName(args[0]) if args.size() > 0 else &"",
				"effect": str(args[1]) if args.size() > 1 and str(args[1]) != "" else DEFAULT_EFFECT,
				"color": args[2] if args.size() > 2 and args[2] is Color else Color.WHITE,
				"ms": int(args[3]) if args.size() > 3 and int(args[3]) > 0 else DEFAULT_MS,
				"color2": args[4] if args.size() > 4 and args[4] is Color else Color.BLACK,
				"track": track,
			})
	# Stable by time, so two cues at the same moment keep their track order.
	cues.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["time"] < b["time"])
	return cues


## What each light is doing at a moment: light name -> its latest cue at or
## before `time`. A light with no cue yet isn't in the result (it's off).
static func state_at(cues: Array[Dictionary], time: float) -> Dictionary:
	var state := {}
	for cue in cues:
		if cue["time"] > time + 0.0001:
			break
		state[cue["light"]] = cue
	return state


## A short string that changes whenever a light's cue changes (another key, or
## the same key with new settings), so a cue is only sent once.
static func cue_id(cue: Dictionary) -> String:
	if cue.is_empty():
		return "OFF"
	return "%.4f %s" % [cue["time"], fx_line(cue["light"], cue)]


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
	return {"light": StringName(parts[1]), "effect": parts[2], "color": Color.html(parts[3]),
			"ms": parts[4].to_int(), "color2": Color.html(parts[5])}


## The Call Method track that holds a light's cues (one track per light), or -1.
static func track_for_light(anim: Animation, light: StringName) -> int:
	for track in anim.get_track_count():
		if anim.track_get_type(track) != Animation.TYPE_METHOD:
			continue
		for key in anim.track_get_key_count(track):
			if not is_light_method(anim.method_track_get_name(track, key)):
				continue
			var args: Array = anim.method_track_get_params(track, key)
			if args.size() > 0 and StringName(args[0]) == light:
				return track
			break   # a track belongs to the light of its first cue
	return -1


## Does a method key with this method name hold a light cue?
static func is_light_method(method: StringName) -> bool:
	return method == METHOD or method == OLD_METHOD


## A method key's value for a light(...) call.
static func cue_key(light: StringName, effect: String, color: Color, ms: int, color2: Color) -> Dictionary:
	return {"method": METHOD, "args": [light, effect, color, ms, color2]}

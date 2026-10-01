class_name BoardTypes
## What each supported board type can do, pin by pin.
##
## This is the Godot-side mirror of Firmware/pinio/board_<type>.h. The board
## checks every CFG line against its own table anyway, but keeping a copy here
## lets the config page offer only valid pins and explain why a pin is off-limits.
## **Keep the two in sync** when a board's pin table changes.
##
## Everything here is static: use it as BoardTypes.pin_caps("TEENSY41", 2)
## without creating an instance (like a static function library in Unreal).

const CAP_IN := 1    ## pin may be a switch input
const CAP_OUT := 2   ## pin may be a coil, lamp or LED chain output
const CAP_PWM := 4   ## output pin that can do a PWM hold
const OUT_PWM := CAP_OUT | CAP_PWM

## Firmware version this Godot build speaks. The board's HELLO must match.
const FIRMWARE := "PINIO 0.3"

const TYPES := {
	"TEENSY41": {
		"display_name": "Teensy 4.1 (recommended)",
		# USB port up: left header = outputs, right header = inputs.
		"pins": {
			2: OUT_PWM, 3: OUT_PWM, 4: OUT_PWM, 5: OUT_PWM, 6: OUT_PWM, 7: OUT_PWM,
			8: OUT_PWM, 9: OUT_PWM, 10: OUT_PWM, 11: OUT_PWM, 12: OUT_PWM,
			24: OUT_PWM, 25: OUT_PWM, 26: CAP_OUT, 27: CAP_OUT,
			28: OUT_PWM, 29: OUT_PWM, 30: CAP_OUT, 31: CAP_OUT, 32: CAP_OUT,
			14: CAP_IN, 15: CAP_IN, 16: CAP_IN, 17: CAP_IN,
			20: CAP_IN, 21: CAP_IN, 22: CAP_IN, 23: CAP_IN,
			33: CAP_IN, 34: CAP_IN, 35: CAP_IN, 36: CAP_IN, 37: CAP_IN,
			38: CAP_IN, 39: CAP_IN, 40: CAP_IN, 41: CAP_IN,
		},
		# Pins that exist but are kept free, and why (shown in the config page).
		"reserved": {
			0: "Serial1", 1: "Serial1",
			13: "status LED",
			18: "I2C SDA", 19: "I2C SCL",
		},
		"max_inputs": 24,
		"max_coils": 24,
		"max_lamps": 24,
		"max_chains": 4,            # WS2812B LED chains (leds.h)
		"max_leds_per_chain": 300,
		"max_zones": 96,            # lights: strips, sections and single inserts
		"default_pwm_hz": 20000,
	},
}


static func has_type(type: String) -> bool:
	return TYPES.has(type)


static func type_names() -> Array[String]:
	var out: Array[String] = []
	for key: String in TYPES:
		out.append(key)
	return out


static func display_name(type: String) -> String:
	return TYPES[type]["display_name"] if has_type(type) else type


## Capability bits for [param pin] on a board of [param type] (0 if unusable).
static func pin_caps(type: String, pin: int) -> int:
	if not has_type(type):
		return 0
	return TYPES[type]["pins"].get(pin, 0)


## True if [param pin] has every bit in [param caps].
static func pin_has(type: String, pin: int, caps: int) -> bool:
	return (pin_caps(type, pin) & caps) == caps


## All pins on [param type] that have every bit in [param caps], sorted.
static func pins_with(type: String, caps: int) -> Array[int]:
	var out: Array[int] = []
	if has_type(type):
		for pin: int in TYPES[type]["pins"]:
			if pin_has(type, pin, caps):
				out.append(pin)
	out.sort()
	return out


## Why a pin is reserved, or "" if it isn't.
static func reserved_reason(type: String, pin: int) -> String:
	if not has_type(type):
		return ""
	return TYPES[type]["reserved"].get(pin, "")


static func limit(type: String, key: String) -> int:
	return TYPES[type][key] if has_type(type) else 0

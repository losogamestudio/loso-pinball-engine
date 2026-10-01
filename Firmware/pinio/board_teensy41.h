// Board definition: Teensy 4.1
// ------------------------------------------------------------
// Everything that differs between board types lives in a file like this one.
// pinio.ino picks the right file at compile time from the board you select
// in the Arduino IDE (Tools > Board).
//
// Pin plan, looking at the Teensy with the USB port at the top:
//
//   LEFT side  (0..12, then 24..32)  = OUTPUTS (coils, lamps, WS2812B LED chains)
//   RIGHT side (23..13, then 41..33) = INPUTS  (switches)
//
//   Pin(s)                     Role
//   0, 1                       reserved  - Serial1, kept free for future expansion
//   2-12, 24, 25, 28, 29       output, PWM capable  (flippers, anything that holds)
//   26, 27, 30, 31, 32         output, NO PWM       (pulse-only: slings, pops, kickers, lamps)
//   13                         reserved  - onboard LED, used as the status LED.
//                              Can't be an input: the LED drags the pull-up down.
//   14-17, 20-23, 33-41        input (INPUT_PULLUP, switch to GND)
//   18, 19                     reserved  - I2C (Wire: 18 = SDA, 19 = SCL)
//
// Notes for later:
//   - 24/25 are also the Wire2 I2C bus and 16/17 are Wire1. They're in use as
//     coil/input pins here; take them out of the table below if you ever need
//     a second or third I2C bus.
//   - 10-13 are the SPI bus. Fine as coils now; matters if SPI is added later.
//   - Inputs are 3.3 V ONLY. Switches go to GND, never to 5 V or 12 V.
//   - Every MOSFET gate needs a pulldown resistor: pins float from reset until
//     setup() runs and while the Teensy is being reprogrammed.

#pragma once

#define BOARD_TYPE "TEENSY41"

const uint8_t STATUS_LED_PIN = 13;

// How many of each thing Godot may configure. Fixed arrays, no dynamic allocation.
const uint8_t MAX_INPUTS = 24;
const uint8_t MAX_COILS  = 24;
const uint8_t MAX_LAMPS  = 24;

// WS2812B LED chains (see leds.h). Any output pin can drive a chain: the
// OctoWS2811 library sends all chains at once by DMA, so drawing LEDs never
// delays switch scanning or coil timing.
#define BOARD_HAS_LEDS 1
const uint8_t  MAX_CHAINS         = 4;
const uint16_t MAX_LEDS_PER_CHAIN = 300;
const uint8_t  MAX_ZONES          = 96;   // named lights: strips, sections, single inserts

// Room for the layout text that CFG SAVE burns into EEPROM: the Teensy 4.1
// has 4284 bytes of EEPROM, minus the 10-byte header in front of the text.
// Roughly 24 inputs + 24 coils + 4 chains + 96 lights fit.
const uint16_t CFG_TEXT_MAX = 4200;

// Board-wide PWM frequency for coil hold. 20 kHz is above hearing range, so
// holding flippers don't whine. Godot can change it with CFG PWM <hz>.
const uint32_t DEFAULT_PWM_HZ = 20000;

// What each pin is allowed to do. Godot's CFG lines are checked against this.
enum PinCap : uint8_t {
  CAP_NONE = 0,
  CAP_IN   = 1,   // may be a switch input
  CAP_OUT  = 2,   // may be a coil or lamp output
  CAP_PWM  = 4,   // output that can do a PWM hold (only meaningful with CAP_OUT)
};

const uint8_t NUM_PINS = 42;   // pins 0..41 (the ones on the headers)

#define OUT_PWM (CAP_OUT | CAP_PWM)

const uint8_t PIN_CAPS[NUM_PINS] = {
  /*  0 */ CAP_NONE, /*  1 */ CAP_NONE,                                  // Serial1
  /*  2 */ OUT_PWM,  /*  3 */ OUT_PWM,  /*  4 */ OUT_PWM,  /*  5 */ OUT_PWM,
  /*  6 */ OUT_PWM,  /*  7 */ OUT_PWM,  /*  8 */ OUT_PWM,  /*  9 */ OUT_PWM,
  /* 10 */ OUT_PWM,  /* 11 */ OUT_PWM,  /* 12 */ OUT_PWM,
  /* 13 */ CAP_NONE,                                                   // status LED
  /* 14 */ CAP_IN,   /* 15 */ CAP_IN,   /* 16 */ CAP_IN,   /* 17 */ CAP_IN,
  /* 18 */ CAP_NONE, /* 19 */ CAP_NONE,                                // I2C
  /* 20 */ CAP_IN,   /* 21 */ CAP_IN,   /* 22 */ CAP_IN,   /* 23 */ CAP_IN,
  /* 24 */ OUT_PWM,  /* 25 */ OUT_PWM,  /* 26 */ CAP_OUT,  /* 27 */ CAP_OUT,
  /* 28 */ OUT_PWM,  /* 29 */ OUT_PWM,  /* 30 */ CAP_OUT,  /* 31 */ CAP_OUT,
  /* 32 */ CAP_OUT,
  /* 33 */ CAP_IN,   /* 34 */ CAP_IN,   /* 35 */ CAP_IN,   /* 36 */ CAP_IN,
  /* 37 */ CAP_IN,   /* 38 */ CAP_IN,   /* 39 */ CAP_IN,   /* 40 */ CAP_IN,
  /* 41 */ CAP_IN,
};

// Set the PWM frequency on every PWM-capable output pin. Pins that share a
// hardware timer always share a frequency, which is why this is board-wide.
void boardSetPwmFrequency(uint32_t hz) {
  for (uint8_t pin = 0; pin < NUM_PINS; pin++) {
    if (PIN_CAPS[pin] & CAP_PWM) analogWriteFrequency(pin, hz);
  }
}

// A number that identifies this particular board, so Godot can tell several
// boards apart no matter which USB port each one lands on. This is the same
// serial number Teensy Loader shows (it's burned into the chip at the factory).
uint32_t boardUid() {
  uint32_t num = HW_OCOTP_MAC0 & 0xFFFFFF;
  if (num < 10000000) num *= 10;
  return num;
}

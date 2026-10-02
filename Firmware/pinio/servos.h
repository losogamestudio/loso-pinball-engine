// Servo engine: hobby servos on board pins and on PCA9685 I2C boards
// ------------------------------------------------------------
// Godot names the servos; the board only knows numbers:
//
//   pca   = a PCA9685 16-channel PWM board on the I2C bus   (CFG PCA <pca> <addr>)
//   servo = one servo on an output pin or a PCA channel     (CFG SERVO <servo> <out> <min_us> <max_us> <home>)
//           <out> is a pin number ("5") or "P<pca>:<channel>" ("P0:3")
//   move  = go to a position, optionally over time          (SERVO <servo> <pos> [ms] [LINEAR|SMOOTH])
//
// Positions are per mille (0..1000) of the servo's min..max pulse width, so
// Godot can work in 0..100% without knowing the pulse widths. The board runs
// every ramp itself, updating each servo every 10 ms, so moves stay smooth
// no matter how busy Godot or the USB link is.
//
// Pin servos get their 50 Hz pulses from one IntervalTimer (an interrupt),
// one servo after another: pin A high for its pulse width, then pin B, ...,
// then a gap to the end of the 20 ms frame. It's the same idea as Teensy's own
// Servo library, written out here so there's no library to clash with (a
// generic "Servo" library in the Arduino sketchbook would win over Teensy's
// and fails to compile). It works on any output pin and never touches the
// hardware PWM timers that coil holds use.
//
// PCA9685 boards share the I2C bus on pins 18 (SDA) and 19 (SCL). A write
// takes about 0.15 ms, and loop() also runs coils and flippers, so at most
// ONE changed PCA channel is written per loop() pass. If a PCA stops
// answering (unplugged, no power), it's marked lost and skipped, so a broken
// I2C cable can never slow the rest of the board down.
//
// Safety: servosHold() (watchdog trip, HELLO, CFG SAVE) stops every ramp and
// leaves each servo holding where it is. Nothing moves while nobody's in control.
// At CFG DONE every servo goes to its home position.
//
// The PCA9685 setup follows the user's animatronics firmware
// (ESP_Animatronic_RX_PCA9685): 50 Hz, ticks = us * 4096 / 20000.

#pragma once

#include <Wire.h>
#include <IntervalTimer.h>

extern Print* out;   // where replies go (pinio.ino)

enum ServoEase : uint8_t { EASE_LINEAR, EASE_SMOOTH };

const uint32_t SERVO_TICK_MS   = 10;     // ramp update rate
const uint16_t SERVO_LOWEST_US = 500;    // hard limits for any servo pulse
const uint16_t SERVO_HIGHEST_US = 2500;
const uint32_t PCA_I2C_HZ      = 400000; // 1 MHz works too, but 400 kHz is kinder to long cabinet wires
const uint8_t  SERVO_NO_PIN    = 255;

// PCA9685 registers
const uint8_t PCA_MODE1    = 0x00;
const uint8_t PCA_MODE2    = 0x01;
const uint8_t PCA_LED0     = 0x06;   // 4 bytes per channel: ON_L, ON_H, OFF_L, OFF_H
const uint8_t PCA_PRESCALE = 0xFE;
const uint8_t PCA_PRESCALE_50HZ = 121;   // 25 MHz / (4096 * 50 Hz) - 1

struct ServoOut {
  bool      defined;
  uint8_t   pin;        // board pin, or SERVO_NO_PIN if it's on a PCA
  uint8_t   slot;       // which pin-pulse slot drives the pin
  uint8_t   pca;        // PCA board index and channel (when pin == SERVO_NO_PIN)
  uint8_t   ch;
  uint16_t  minUs, maxUs;
  uint16_t  homePm;     // home position, per mille of min..max
  float     curUs;      // where it is now (the last value sent out)
  float     fromUs;     // where the running ramp started
  float     toUs;       // where it's going
  uint32_t  startMs;
  uint32_t  rampMs;     // 0 = not moving
  ServoEase ease;
  bool      dirty;      // PCA: a new value is waiting to be written
};

struct Pca {
  bool    defined;
  uint8_t addr;
  bool    ok;           // answering; false = lost, skipped until the next CFG DONE
};

ServoOut servos[MAX_SERVO_COUNT];
Pca      pcas[MAX_PCAS];
uint8_t  pinServoCount  = 0;          // pin servos defined (slots 0..count-1)
bool     wireStarted    = false;
uint32_t lastServoTick  = 0;
uint8_t  nextPcaServo   = 0;          // round robin: which servo to check for a PCA write next

// ---------------- Pin servo pulses ----------------
// The interrupt reads these; loop() writes pinServoUs (a 16-bit write is atomic).
const uint32_t SERVO_FRAME_US = 20000;   // 50 Hz
uint8_t           pinServoPin[MAX_PIN_SERVOS];
volatile uint16_t pinServoUs[MAX_PIN_SERVOS];
volatile uint8_t  pinServoRunning = 0;   // slots the interrupt pulses (0 = timer stopped)
IntervalTimer     servoTimer;

// Each interrupt starts one "period": a servo's pulse (pin high), or the gap
// at the end of the frame. IntervalTimer's update() only takes effect from the
// NEXT period, so each interrupt lines up the length of the one after it.
void servoPulseIsr() {
  static uint8_t slot    = 0;              // period starting now: < count = that servo's pulse, == count = the gap
  static uint8_t highPin = SERVO_NO_PIN;
  if (highPin != SERVO_NO_PIN) {
    digitalWrite(highPin, LOW);            // end of the previous pulse
    highPin = SERVO_NO_PIN;
  }
  uint8_t count = pinServoRunning;
  if (slot < count) {
    highPin = pinServoPin[slot];
    digitalWrite(highPin, HIGH);
  }
  uint8_t next = slot >= count ? 0 : slot + 1;
  uint32_t nextUs;
  if (next < count) {
    nextUs = pinServoUs[next];
  } else {
    uint32_t used = 0;                     // the gap: the rest of the 20 ms frame
    for (uint8_t i = 0; i < count; i++) used += pinServoUs[i];
    nextUs = used + 100 < SERVO_FRAME_US ? SERVO_FRAME_US - used : 100;
  }
  servoTimer.update(nextUs);
  slot = next;
}

void pinServosStart() {
  if (pinServoCount == 0) return;
  for (uint8_t i = 0; i < pinServoCount; i++) {
    pinMode(pinServoPin[i], OUTPUT);
    digitalWrite(pinServoPin[i], LOW);
  }
  pinServoRunning = pinServoCount;
  servoTimer.begin(servoPulseIsr, 100);
}

void pinServosStop() {
  servoTimer.end();
  pinServoRunning = 0;
  for (uint8_t i = 0; i < pinServoCount; i++) digitalWrite(pinServoPin[i], LOW);
}

// ---------------- PCA9685 driver ----------------

void servosBeginWire() {
  if (wireStarted) return;
  Wire.begin();   // pins 18 (SDA) and 19 (SCL)
  Wire.setClock(PCA_I2C_HZ);
  wireStarted = true;
}

bool pcaWriteReg(uint8_t addr, uint8_t reg, uint8_t value) {
  Wire.beginTransmission(addr);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

// Does anything answer at this address?
bool pcaProbe(uint8_t addr) {
  servosBeginWire();
  Wire.beginTransmission(addr);
  return Wire.endTransmission() == 0;
}

// 50 Hz servo pulses. The prescaler can only change while the chip sleeps.
bool pcaInit(uint8_t addr) {
  if (!pcaWriteReg(addr, PCA_MODE1, 0x10)) return false;           // sleep
  if (!pcaWriteReg(addr, PCA_PRESCALE, PCA_PRESCALE_50HZ)) return false;
  if (!pcaWriteReg(addr, PCA_MODE2, 0x04)) return false;           // totem-pole outputs
  if (!pcaWriteReg(addr, PCA_MODE1, 0x20)) return false;           // wake, register auto-increment
  delayMicroseconds(600);                                          // oscillator start-up (only at CFG DONE)
  return pcaWriteReg(addr, PCA_MODE1, 0xA0);                       // restart PWM, auto-increment
}

// One channel's pulse: high from tick 0 to tick `ticks` of each 20 ms frame (0 = no pulse).
bool pcaSetTicks(uint8_t addr, uint8_t ch, uint16_t ticks) {
  Wire.beginTransmission(addr);
  Wire.write(PCA_LED0 + 4 * ch);
  Wire.write(0);
  Wire.write(0);
  Wire.write(ticks & 0xFF);
  Wire.write(ticks >> 8);
  return Wire.endTransmission() == 0;
}

uint16_t usToTicks(float us) {
  uint32_t ticks = (uint32_t)(us * 4096.0f / 20000.0f + 0.5f);
  return ticks > 4095 ? 4095 : ticks;
}

// ---------------- Configuration ----------------

uint8_t servosCount() {
  uint8_t n = 0;
  for (uint8_t i = 0; i < MAX_SERVO_COUNT; i++) n += servos[i].defined;
  return n;
}

// CFG PCA: a PCA9685 at an I2C address. Returns an error message, or nullptr.
const char* pcaDefine(uint8_t id, uint8_t addr) {
  if (pcas[id].defined) return "duplicate PCA index";
  for (uint8_t i = 0; i < MAX_PCAS; i++) {
    if (pcas[i].defined && pcas[i].addr == addr) return "two PCAs at the same address";
  }
  if (!pcaProbe(addr)) return "PCA9685 doesn't answer at that address (check SDA 18, SCL 19, power, address jumpers)";
  pcas[id].defined = true;
  pcas[id].addr = addr;
  pcas[id].ok = true;
  return nullptr;
}

// CFG SERVO on a board pin (already checked and claimed by the caller).
const char* servosDefinePin(uint8_t id, uint8_t pin, uint16_t minUs, uint16_t maxUs, uint16_t homePm) {
  if (servos[id].defined) return "duplicate servo index";
  if (pinServoCount >= MAX_PIN_SERVOS) return "too many servos on board pins (max 12; use a PCA9685)";
  ServoOut& s = servos[id];
  s = ServoOut();
  s.defined = true;
  s.pin = pin;
  s.slot = pinServoCount;
  pinServoPin[pinServoCount] = pin;
  pinServoUs[pinServoCount] = 1500;
  pinServoCount++;
  s.minUs = minUs;
  s.maxUs = maxUs;
  s.homePm = homePm;
  return nullptr;
}

// CFG SERVO on a PCA9685 channel.
const char* servosDefinePca(uint8_t id, uint8_t pca, uint8_t ch, uint16_t minUs, uint16_t maxUs, uint16_t homePm) {
  if (servos[id].defined) return "duplicate servo index";
  if (pca >= MAX_PCAS || !pcas[pca].defined) return "that PCA isn't defined (CFG PCA first)";
  if (ch > 15) return "PCA channel must be 0..15";
  for (uint8_t i = 0; i < MAX_SERVO_COUNT; i++) {
    if (servos[i].defined && servos[i].pin == SERVO_NO_PIN && servos[i].pca == pca && servos[i].ch == ch) {
      return "PCA channel already used";
    }
  }
  ServoOut& s = servos[id];
  s = ServoOut();
  s.defined = true;
  s.pin = SERVO_NO_PIN;
  s.pca = pca;
  s.ch = ch;
  s.minUs = minUs;
  s.maxUs = maxUs;
  s.homePm = homePm;
  return nullptr;
}

float servoPmToUs(const ServoOut& s, uint16_t pm) {
  return s.minUs + (float)(s.maxUs - s.minUs) * pm / 1000.0f;
}

// Send a servo's current position out (pins now; PCA channels on a later loop pass).
void servoOutput(ServoOut& s) {
  if (s.pin != SERVO_NO_PIN) pinServoUs[s.slot] = (uint16_t)(s.curUs + 0.5f);
  else s.dirty = true;
}

// CFG DONE: start the outputs and send every servo home.
void servosStart() {
  for (uint8_t i = 0; i < MAX_PCAS; i++) {
    if (pcas[i].defined) pcas[i].ok = pcaInit(pcas[i].addr);
  }
  for (uint8_t i = 0; i < MAX_SERVO_COUNT; i++) {
    ServoOut& s = servos[i];
    if (!s.defined) continue;
    s.curUs = s.fromUs = s.toUs = servoPmToUs(s, s.homePm);   // jump: we can't know where it was
    s.rampMs = 0;
    servoOutput(s);
  }
  pinServosStart();   // after the home positions are set, so the first pulses are right
}

// Forget every servo and PCA (CFG CLEAR). Pin servos stop pulsing (the caller
// drives the pins low afterwards); PCA channels stop pulsing too, so servos go limp.
void servosClearConfig() {
  pinServosStop();
  for (uint8_t i = 0; i < MAX_SERVO_COUNT; i++) {
    ServoOut& s = servos[i];
    if (s.defined && s.pin == SERVO_NO_PIN && pcas[s.pca].ok) pcaSetTicks(pcas[s.pca].addr, s.ch, 0);
  }
  memset(servos, 0, sizeof(servos));
  memset(pcas, 0, sizeof(pcas));
  pinServoCount = 0;
  nextPcaServo = 0;
}

// ---------------- Running ----------------

// SERVO <servo> <pos> [ms] [ease]: move to pos (per mille) over ms (0 = jump).
void servosMove(uint8_t id, uint16_t pm, uint32_t ms, ServoEase ease, uint32_t now) {
  ServoOut& s = servos[id];
  s.fromUs  = s.curUs;
  s.toUs    = servoPmToUs(s, pm);
  s.startMs = now;
  s.ease    = ease;
  s.rampMs  = ms;
  if (ms == 0) {
    s.curUs = s.toUs;
    servoOutput(s);
  }
}

// Stop every ramp; each servo holds where it is (watchdog, HELLO, CFG SAVE).
void servosHold() {
  for (uint8_t i = 0; i < MAX_SERVO_COUNT; i++) {
    servos[i].toUs = servos[i].curUs;
    servos[i].rampMs = 0;
  }
}

// Every loop() pass: advance the ramps every SERVO_TICK_MS, then write at
// most one waiting PCA channel. Never waits.
void servosUpdate(uint32_t now) {
  if (now - lastServoTick >= SERVO_TICK_MS) {
    lastServoTick = now;
    for (uint8_t i = 0; i < MAX_SERVO_COUNT; i++) {
      ServoOut& s = servos[i];
      if (!s.defined || s.rampMs == 0) continue;
      float t = (float)(now - s.startMs) / s.rampMs;
      if (t >= 1.0f) {
        s.curUs = s.toUs;
        s.rampMs = 0;   // arrived
      } else {
        if (s.ease == EASE_SMOOTH) t = t * t * (3.0f - 2.0f * t);   // ease in and out
        s.curUs = s.fromUs + (s.toUs - s.fromUs) * t;
      }
      servoOutput(s);
    }
  }
  for (uint8_t n = 0; n < MAX_SERVO_COUNT; n++) {
    ServoOut& s = servos[nextPcaServo];
    nextPcaServo = (nextPcaServo + 1) % MAX_SERVO_COUNT;
    if (!s.defined || !s.dirty) continue;
    s.dirty = false;
    Pca& p = pcas[s.pca];
    if (!p.ok) continue;
    if (!pcaSetTicks(p.addr, s.ch, usToTicks(s.curUs))) {
      p.ok = false;   // stop talking to it, so a dead bus can't stall the board
      out->print("ERR PCA ");
      out->print(s.pca);
      out->println(" lost, its servos stop until the next CFG DONE");
    }
    break;   // one write per pass
  }
}

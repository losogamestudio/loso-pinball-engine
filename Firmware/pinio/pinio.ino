/*
  PINIO 0.3  —  generic pinball I/O firmware
  ------------------------------------------
  Needs the OctoWS2811 library, which comes with Teensyduino (for the LED chains).

  The board owns timing + safety, Godot owns rules + presentation.

  Unlike the 0.1 test sketch, nothing about the playfield is hard-coded here.
  The board only knows which of its pins CAN be inputs / outputs / PWM
  (see board_teensy41.h). Godot sends the actual layout as CFG lines:

      CFG CLEAR
      CFG PWM 20000
      CFG IN 0 33 NO 5                 input 0 = pin 33, normally open, 5 ms debounce
      CFG IN 1 34 NO 2                 input 1 = pin 34 (flipper EOS)
      CFG COIL 0 2 40 50 0 1 0         coil 0 = pin 2, 40 ms full power, 50% hold,
                                       trigger = input 0, EOS = input 1, no recycle
      CFG COIL 1 26 30 0 2 - 100       coil 1 = pin 26, 30 ms pulse, trigger = input 2,
                                       no EOS, 100 ms recycle  (a slingshot)
      CFG LAMP 0 27                    lamp 0 = pin 27
      CFG CHAIN 0 8 30 GRB             LED chain 0 = WS2812B strip on pin 8, 30 LEDs, GRB order
      CFG ZONE 0 0 0 30                zone 0 = chain 0, LEDs 0..29 (a named light in Godot)
      CFG ZONE 1 0 0 1                 zone 1 = chain 0, LED 0 only (an insert)
      CFG DONE                         -> ACK CFG <inputs> <coils> <lamps> <chains> <zones> <hash>, then SWS

  LED effects (all drawn on the board, see leds.h):
      FX 0 RAINBOW 000000 3000         zone 0: rainbow, one cycle every 3 s
      FX 1 BLINK FF0000 250 000000     zone 1: red / black, 250 ms each
      FX ALL OFF                       every zone off
    Effects: OFF SOLID BLINK PULSE CHASE WIPE FADE RAINBOW SPARKLE.
    Colors are RRGGBB hex; defaults FFFFFF, 500 ms, 000000.

  Storing the layout ("burning" it):
    CFG SAVE writes the current layout into EEPROM. At power-up the board
    replays it, so it's configured before Godot connects (rules stay disarmed
    until Godot arms them). HELLO reports a hash of the running layout and of
    the saved one, so Godot only re-sends the layout when it has changed.
    The hash is 32-bit FNV-1a over every accepted CFG line after CFG CLEAR,
    each followed by '\n' (Godot computes the same thing).

  Coil behavior (all local, Godot is never in this path):
    - A coil with a trigger input and RULE ON fires when the trigger closes.
    - FULL power for full_ms. If an EOS input is set, closing it ends full
      power early (full_ms is then just the failsafe if the EOS switch breaks).
    - After full power: hold_pct > 0 -> PWM HOLD while the trigger stays closed
                        hold_pct = 0 -> off, then report FIRED <coil>
    - Releasing the trigger turns a holding coil (a flipper) off at once.
    - After turning off, the coil ignores new fires for recycle_ms.

  Protocol: plain text, one message per line ending in '\n'.

  Board -> Godot
    HELLO PINIO 0.3 <board> <uid> <running_hash|-> <saved_hash|->   reply to HELLO
    SWS <bits>                      all input states (after CFG DONE, or when asked)
    SW <in> <0|1>                   debounced input change
    FIRED <coil>                    a pulse-type coil rule fired locally
    PONG <n>                        reply to PING
    ACK <cmd> ...                   command accepted
    ERR <message>                   something was wrong
    WD TRIP / WD OK                 watchdog killed outputs / link restored
    HB <millis>                     heartbeat, once per second

  Godot -> Board
    HELLO                           start/restart link: outputs off, rules disarmed,
                                    config KEPT, arms watchdog
    HB                              heartbeat (any line counts)
    CFG CLEAR | PWM | IN | COIL | LAMP | CHAIN | ZONE | DONE     configuration, see above
    CFG SAVE                        store the running layout in EEPROM (outputs go off)
    CFG ERASE                       forget the stored layout
    SWS                             ask for all input states
    PULSE <coil> [ms]               full power for ms (default full_ms), max 255
    HOLD <coil> <ON|OFF>            full power for full_ms, then hold until OFF
    RULE <coil|ALL> <ON|OFF>        arm/disarm trigger rules
    LED <lamp> <ON|OFF|BLINK>       lamp control
    FX <zone|ALL> <effect> [RRGGBB] [ms] [RRGGBB2]   LED zone effect
    BRIGHT <0..255>                 LED brightness for every chain (default 128)
    PING <n>                        round-trip latency test
    WD <ON|OFF>                     watchdog on/off (Serial Monitor testing only)

  Status LED (pin 13 on Teensy 4.1):
    slow blink = waiting for Godot     medium blink = linked, not configured
    solid      = running               fast blink   = watchdog tripped
*/

#include <Arduino.h>
#include <EEPROM.h>

#if defined(ARDUINO_TEENSY41)
  #include "board_teensy41.h"
#else
  #error "PINIO: unsupported board. Select Teensy 4.1 under Tools > Board (Uno support is planned)."
#endif

#if BOARD_HAS_LEDS
  #include "leds.h"
#endif

const char* FIRMWARE = "PINIO 0.3";

// ---------------- Limits and timing ----------------
const uint32_t WATCHDOG_MS      = 500;    // nothing from Godot this long -> outputs off
const uint32_t HEARTBEAT_OUT_MS = 1000;
const uint32_t BLINK_MS         = 250;    // lamp BLINK half-period
const uint8_t  MAX_PULSE_MS     = 255;    // hard cap on any full-power time
const uint16_t MAX_RECYCLE_MS   = 5000;
const uint8_t  MAX_DEBOUNCE_MS  = 100;
const uint32_t MIN_PWM_HZ       = 100;
const uint32_t MAX_PWM_HZ       = 100000;
const int8_t   NONE             = -1;     // "no input assigned"

// ---------------- Configured things ----------------
struct Input {
  bool     defined;
  uint8_t  pin;
  bool     nc;          // normally closed: active when the switch OPENS
  uint8_t  debounceMs;
  bool     state;       // debounced, true = active
  bool     raw;         // last raw reading (already NO/NC corrected)
  uint32_t changedAt;   // when raw last changed
};

enum CoilState : uint8_t { COIL_IDLE, COIL_FULL, COIL_HOLD, COIL_RECYCLE };

struct Coil {
  bool      defined;
  uint8_t   pin;
  uint8_t   fullMs;     // full power time (failsafe if EOS is set)
  uint8_t   holdPct;    // 0 = pulse only, 1..100 = PWM hold after full power
  int8_t    trig;       // trigger input, or NONE
  int8_t    eos;        // end-of-stroke input, or NONE
  uint16_t  recycleMs;  // dead time after turning off

  bool      ruleArmed;  // Godot said RULE <coil> ON
  bool      ruleActive; // current activation came from the trigger rule
  bool      godotHold;  // Godot said HOLD <coil> ON
  CoilState state;
  uint32_t  stateAt;    // when the current state started
  uint16_t  stateMs;    // how long FULL / RECYCLE lasts
};

enum LampMode : uint8_t { LAMP_OFF, LAMP_ON, LAMP_BLINK };

struct Lamp {
  bool     defined;
  uint8_t  pin;
  LampMode mode;
};

Input inputs[MAX_INPUTS];
Coil  coils[MAX_COILS];
Lamp  lamps[MAX_LAMPS];
bool  pinUsed[NUM_PINS];

bool     configured = false;   // CFG DONE accepted
bool     cfgError   = false;   // a CFG line was rejected since the last CFG CLEAR
uint32_t pwmHz      = DEFAULT_PWM_HZ;

// ---------------- Link state ----------------
bool     linked          = false;  // Godot has said HELLO
bool     watchdogEnabled = true;
bool     wdTripped       = false;
uint32_t lastRxMs        = 0;
uint32_t lastHbOutMs     = 0;

char    rxBuf[64];
uint8_t rxLen      = 0;
bool    rxOverflow = false;

// ---------------- Where replies go ----------------
// Normally the USB serial port. While the stored layout is replayed at boot,
// replies go to NullOut instead: nobody is listening yet.
class NullOut : public Print {
public:
  size_t write(uint8_t) override { return 1; }
};
NullOut nullOut;
Print*  out = &Serial;

// ---------------- Layout text, hash and storage ----------------
// Every accepted CFG line since CFG CLEAR, each followed by '\n'. This is
// exactly what CFG SAVE writes to EEPROM, and what the hash is taken over.
char     cfgText[CFG_TEXT_MAX];
uint16_t cfgTextLen = 0;

const uint32_t FNV_OFFSET = 2166136261UL;   // 32-bit FNV-1a hash constants
const uint32_t FNV_PRIME  = 16777619UL;
uint32_t cfgHash    = FNV_OFFSET;           // hash of cfgText
bool     savedValid = false;                // EEPROM holds a good layout
uint32_t savedHash  = 0;                    // ...and this is its hash

// EEPROM layout: 4-byte magic, 2-byte text length, 4-byte hash, then the text.
const char     EE_MAGIC[4] = {'P', 'I', 'O', '2'};
const uint16_t EE_LEN      = 4;
const uint16_t EE_HASH     = 6;
const uint16_t EE_TEXT     = 10;

// ---------------- Coil outputs ----------------
// pinMode() before digitalWrite() switches the pin back from PWM to plain
// GPIO, which a pin needs after it has been used with analogWrite().
void driveOff(const Coil& c)  { pinMode(c.pin, OUTPUT); digitalWrite(c.pin, LOW); }
void driveFull(const Coil& c) { pinMode(c.pin, OUTPUT); digitalWrite(c.pin, HIGH); }

void driveHold(const Coil& c) {
  if (c.holdPct >= 100) driveFull(c);
  else analogWrite(c.pin, (uint16_t)c.holdPct * 255 / 100);
}

void enterState(Coil& c, CoilState s, uint16_t ms, uint32_t now) {
  c.state   = s;
  c.stateAt = now;
  c.stateMs = ms;
  if (s == COIL_FULL)      driveFull(c);
  else if (s == COIL_HOLD) driveHold(c);
  else                     driveOff(c);
}

void turnOffAndRecycle(Coil& c, uint32_t now) {
  c.ruleActive = false;
  c.godotHold  = false;
  if (c.recycleMs > 0) enterState(c, COIL_RECYCLE, c.recycleMs, now);
  else                 enterState(c, COIL_IDLE, 0, now);
}

bool inputActive(int8_t id) {
  return id != NONE && inputs[id].state;
}

// Should this coil be holding right now?
bool wantsHold(const Coil& c) {
  if (c.holdPct == 0) return false;
  if (c.godotHold)    return true;
  return c.ruleActive && c.ruleArmed && inputActive(c.trig);
}

// Start full power. Returns false if the coil is busy or recycling.
bool startCoil(Coil& c, uint8_t ms, bool fromRule, uint32_t now) {
  if (c.state != COIL_IDLE) return false;
  c.ruleActive = fromRule;
  enterState(c, COIL_FULL, ms, now);
  return true;
}

void updateCoils(uint32_t now) {
  for (uint8_t i = 0; i < MAX_COILS; i++) {
    Coil& c = coils[i];
    if (!c.defined) continue;
    uint32_t elapsed = now - c.stateAt;   // unsigned subtraction survives millis() rollover

    switch (c.state) {
      case COIL_FULL: {
        // A flipper drops the moment its button is released (or its rule is disarmed).
        if (c.ruleActive && c.holdPct > 0 && (!c.ruleArmed || !inputActive(c.trig))) {
          turnOffAndRecycle(c, now);
          break;
        }
        bool eosHit = inputActive(c.eos);
        if (eosHit || elapsed >= c.stateMs) {
          if (wantsHold(c)) enterState(c, COIL_HOLD, 0, now);
          else              turnOffAndRecycle(c, now);
        }
        break;
      }
      case COIL_HOLD:
        if (!wantsHold(c)) turnOffAndRecycle(c, now);
        break;
      case COIL_RECYCLE:
        if (elapsed >= c.stateMs) enterState(c, COIL_IDLE, 0, now);
        break;
      case COIL_IDLE:
        break;
    }
  }
}

// ---------------- Lamps and status LED ----------------
void updateLamps(uint32_t now) {
  bool blinkPhase = (now / BLINK_MS) & 1;
  for (uint8_t i = 0; i < MAX_LAMPS; i++) {
    if (!lamps[i].defined) continue;
    bool on = (lamps[i].mode == LAMP_ON) || (lamps[i].mode == LAMP_BLINK && blinkPhase);
    digitalWrite(lamps[i].pin, on ? HIGH : LOW);
  }
}

void updateStatusLed(uint32_t now) {
  bool on;
  if (wdTripped)        on = (now / 100) & 1;   // fast: watchdog tripped
  else if (!linked)     on = (now / 800) & 1;   // slow: waiting for Godot
  else if (!configured) on = (now / 300) & 1;   // medium: linked, waiting for CFG
  else                  on = true;              // solid: running
  digitalWrite(STATUS_LED_PIN, on ? HIGH : LOW);
}

// ---------------- Safety ----------------
// Every coil off, every rule disarmed, every lamp off. Config is kept.
void allOutputsOff() {
  for (uint8_t i = 0; i < MAX_COILS; i++) {
    Coil& c = coils[i];
    if (!c.defined) continue;
    c.ruleArmed  = false;
    c.ruleActive = false;
    c.godotHold  = false;
    enterState(c, COIL_IDLE, 0, millis());
  }
  for (uint8_t i = 0; i < MAX_LAMPS; i++) {
    if (!lamps[i].defined) continue;
    lamps[i].mode = LAMP_OFF;
    digitalWrite(lamps[i].pin, LOW);
  }
#if BOARD_HAS_LEDS
  ledsAllOff();   // LED zones too; the next frame sends black
#endif
}

// Forget the whole configuration and drive every output pin low.
void clearConfig() {
  allOutputsOff();
#if BOARD_HAS_LEDS
  ledsClearConfig();   // before the pin loop below: gives the chain pins back to normal GPIO
#endif
  memset(inputs, 0, sizeof(inputs));
  memset(coils, 0, sizeof(coils));
  memset(lamps, 0, sizeof(lamps));
  memset(pinUsed, 0, sizeof(pinUsed));
  for (uint8_t pin = 0; pin < NUM_PINS; pin++) {
    if (PIN_CAPS[pin] & CAP_OUT) {
      pinMode(pin, OUTPUT);
      digitalWrite(pin, LOW);
    }
  }
  configured = false;
  cfgError   = false;
  pwmHz      = DEFAULT_PWM_HZ;
  boardSetPwmFrequency(pwmHz);
  cfgTextLen = 0;
  cfgHash    = FNV_OFFSET;   // the saved layout in EEPROM is untouched
}

// ---------------- Layout text, hash and EEPROM ----------------
uint32_t fnvAdd(uint32_t h, uint8_t byte) {
  h ^= byte;
  return h * FNV_PRIME;
}

// Remember an accepted CFG line. Returns false if there's no room to store it.
bool cfgRecord(const char* line) {
  uint16_t len = strlen(line);
  if (cfgTextLen + len + 1 > CFG_TEXT_MAX) return false;
  for (uint16_t i = 0; i < len; i++) {
    cfgText[cfgTextLen++] = line[i];
    cfgHash = fnvAdd(cfgHash, line[i]);
  }
  cfgText[cfgTextLen++] = '\n';
  cfgHash = fnvAdd(cfgHash, '\n');
  return true;
}

// Hash as 8 hex digits, or "-" if there isn't one.
void printHash(bool valid, uint32_t h) {
  if (!valid) { out->print('-'); return; }
  for (int8_t shift = 28; shift >= 0; shift -= 4) out->print("0123456789ABCDEF"[(h >> shift) & 0xF]);
}

void eeWrite32(uint16_t addr, uint32_t v) { for (uint8_t i = 0; i < 4; i++) EEPROM.update(addr + i, (v >> (8 * i)) & 0xFF); }
uint32_t eeRead32(uint16_t addr) {
  uint32_t v = 0;
  for (uint8_t i = 0; i < 4; i++) v |= (uint32_t)EEPROM.read(addr + i) << (8 * i);
  return v;
}

// Burn the running layout into EEPROM. Writing flash can stall loop() for a
// moment, so every output is turned off first: nothing may be mid-pulse.
void saveConfig() {
  allOutputsOff();
  for (uint8_t i = 0; i < 4; i++) EEPROM.update(i, EE_MAGIC[i]);
  EEPROM.update(EE_LEN, cfgTextLen & 0xFF);
  EEPROM.update(EE_LEN + 1, cfgTextLen >> 8);
  eeWrite32(EE_HASH, cfgHash);
  for (uint16_t i = 0; i < cfgTextLen; i++) EEPROM.update(EE_TEXT + i, cfgText[i]);
  savedValid = true;
  savedHash  = cfgHash;
  lastRxMs   = millis();   // don't let the time spent writing trip the watchdog
}

void eraseSavedConfig() {
  EEPROM.update(0, 0xFF);   // breaking the magic is enough
  savedValid = false;
}

// Feed one line through the normal command handler (used for the replay).
void runLine(const char* text, uint32_t now) {
  char line[sizeof(rxBuf)];
  strncpy(line, text, sizeof(line) - 1);
  line[sizeof(line) - 1] = '\0';
  handleLine(line, now);
}

// At power-up: if EEPROM holds a good layout, replay it so the board is
// configured before Godot connects. Rules stay disarmed until Godot arms them.
void loadSavedConfig() {
  for (uint8_t i = 0; i < 4; i++) if (EEPROM.read(i) != EE_MAGIC[i]) return;
  uint16_t len  = EEPROM.read(EE_LEN) | (EEPROM.read(EE_LEN + 1) << 8);
  uint32_t hash = eeRead32(EE_HASH);
  if (len > CFG_TEXT_MAX) return;
  uint32_t check = FNV_OFFSET;   // don't trust it until the hash matches
  for (uint16_t i = 0; i < len; i++) check = fnvAdd(check, EEPROM.read(EE_TEXT + i));
  if (check != hash) return;
  savedValid = true;
  savedHash  = hash;

  uint32_t now = millis();
  out = &nullOut;
  runLine("CFG CLEAR", now);
  char line[sizeof(rxBuf)];
  uint8_t n = 0;
  for (uint16_t i = 0; i < len; i++) {
    char c = EEPROM.read(EE_TEXT + i);
    if (c == '\n') {
      line[n] = '\0';
      runLine(line, now);
      n = 0;
    } else if (n < sizeof(line) - 1) {
      line[n++] = c;
    }
  }
  runLine("CFG DONE", now);   // if a line no longer fits this firmware, the board just stays unconfigured
  out = &Serial;
}

void checkWatchdog(uint32_t now) {
  if (!linked || !watchdogEnabled || wdTripped) return;
  if ((now - lastRxMs) > WATCHDOG_MS) {
    allOutputsOff();
    wdTripped = true;
    out->println("WD TRIP");
  }
}

void heartbeatOut(uint32_t now) {
  if ((now - lastHbOutMs) >= HEARTBEAT_OUT_MS) {
    lastHbOutMs = now;
    out->print("HB ");
    out->println(now);
  }
}

// ---------------- Inputs ----------------
bool readInputRaw(const Input& in) {
  bool closed = digitalRead(in.pin) == LOW;   // pull-up: switch to GND reads LOW
  return in.nc ? !closed : closed;
}

void sendAllSwitches() {
  // One character per input index, up to the highest one defined.
  int8_t last = NONE;
  for (uint8_t i = 0; i < MAX_INPUTS; i++) if (inputs[i].defined) last = i;
  out->print("SWS ");
  for (int8_t i = 0; i <= last; i++) out->print(inputs[i].state ? '1' : '0');
  out->println();
}

void onInputChanged(uint8_t id, bool active, uint32_t now) {
  // Hardware rules first: fire locally, THEN tell Godot. Godot never sits in this path.
  if (active && !wdTripped) {
    for (uint8_t i = 0; i < MAX_COILS; i++) {
      Coil& c = coils[i];
      if (!c.defined || !c.ruleArmed || c.trig != (int8_t)id) continue;
      if (startCoil(c, c.fullMs, true, now) && c.holdPct == 0) {
        out->print("FIRED ");
        out->println(i);
      }
    }
  }
  out->print("SW ");
  out->print(id);
  out->println(active ? " 1" : " 0");
}

void scanInputs(uint32_t now) {
  for (uint8_t i = 0; i < MAX_INPUTS; i++) {
    Input& in = inputs[i];
    if (!in.defined) continue;
    bool raw = readInputRaw(in);
    if (raw != in.raw) {
      in.raw = raw;
      in.changedAt = now;
    } else if (raw != in.state && (now - in.changedAt) >= in.debounceMs) {
      in.state = raw;
      onInputChanged(i, raw, now);
    }
  }
}

// ---------------- Parsing helpers ----------------
// Strict number parse: the whole token must be a number within [lo, hi].
bool parseNum(const char* s, long lo, long hi, long& out) {
  if (!s || !*s) return false;
  char* end;
  long v = strtol(s, &end, 10);
  if (*end != '\0' || v < lo || v > hi) return false;
  out = v;
  return true;
}

bool parseOnOff(const char* s, bool& out) {
  if (!s) return false;
  if (!strcmp(s, "ON"))  { out = true;  return true; }
  if (!strcmp(s, "OFF")) { out = false; return true; }
  return false;
}

// "-" means no input; otherwise it must be an input that's already defined.
bool parseInputRef(const char* s, int8_t& out) {
  if (s && !strcmp(s, "-")) { out = NONE; return true; }
  long v;
  if (!parseNum(s, 0, MAX_INPUTS - 1, v) || !inputs[v].defined) return false;
  out = (int8_t)v;
  return true;
}

// A color as 6 hex digits, RRGGBB (e.g. FF8000 = orange).
bool parseColor(const char* s, uint32_t& out) {
  if (!s || strlen(s) != 6) return false;
  char* end;
  unsigned long v = strtoul(s, &end, 16);
  if (*end != '\0') return false;
  out = v;
  return true;
}

bool pinHas(long pin, uint8_t cap) {
  return pin >= 0 && pin < NUM_PINS && (PIN_CAPS[pin] & cap) == cap;
}

// Look up a configured coil/lamp by index token. Replies ERR and returns -1 if bad.
int findCoil(const char* s) {
  long id;
  if (!parseNum(s, 0, MAX_COILS - 1, id) || !coils[id].defined) { out->println("ERR bad coil"); return -1; }
  return (int)id;
}

int findLamp(const char* s) {
  long id;
  if (!parseNum(s, 0, MAX_LAMPS - 1, id) || !lamps[id].defined) { out->println("ERR bad lamp"); return -1; }
  return (int)id;
}

// ---------------- CFG commands ----------------
// The CFG line being handled, exactly as received (strtok chops up the
// original), so an accepted line can be recorded for the hash and CFG SAVE.
char cfgRawLine[sizeof(rxBuf)];

void cfgFail(const char* why) {
  cfgError = true;
  out->print("ERR CFG ");
  out->println(why);
}

// Record the current CFG line as part of the layout. False (after replying) if it doesn't fit.
bool cfgAccept() {
  if (cfgRecord(cfgRawLine)) return true;
  cfgFail("layout too big to store on this board");
  return false;
}

// Shared pin checks for IN / COIL / LAMP. Returns false (after replying) if bad.
bool cfgCheckPin(const char* s, uint8_t cap, long& pin) {
  if (!parseNum(s, 0, NUM_PINS - 1, pin)) { cfgFail("bad pin number"); return false; }
  if (!pinHas(pin, cap)) {
    cfgFail(cap == CAP_IN ? "pin can't be an input on this board" : "pin can't be an output on this board");
    return false;
  }
  if (pinUsed[pin]) { cfgFail("pin already used"); return false; }
  return true;
}

void handleCfg(char** tok, uint8_t n, uint32_t now) {
  const char* sub = n > 1 ? tok[1] : "";

  if (!strcmp(sub, "CLEAR")) {
    clearConfig();
    out->println("ACK CFG CLEAR");
    return;
  }
  if (!strcmp(sub, "SAVE")) {
    if (!configured) { out->println("ERR CFG nothing to save, send CFG DONE first"); return; }
    saveConfig();
    out->print("ACK CFG SAVE ");
    printHash(true, savedHash);
    out->println();
    return;
  }
  if (!strcmp(sub, "ERASE")) {
    eraseSavedConfig();
    out->println("ACK CFG ERASE");
    return;
  }
  if (configured) { out->println("ERR CFG locked, send CFG CLEAR first"); return; }

  if (!strcmp(sub, "PWM")) {
    long hz;
    if (n != 3 || !parseNum(tok[2], MIN_PWM_HZ, MAX_PWM_HZ, hz)) { cfgFail("PWM needs <hz> 100..100000"); return; }
    pwmHz = hz;
    boardSetPwmFrequency(pwmHz);
    if (!cfgAccept()) return;
    out->print("ACK CFG PWM ");
    out->println(pwmHz);

  } else if (!strcmp(sub, "IN")) {
    // CFG IN <in> <pin> <NO|NC> <debounce_ms>
    long id, pin, deb;
    if (n != 6) { cfgFail("IN needs <in> <pin> <NO|NC> <debounce_ms>"); return; }
    if (!parseNum(tok[2], 0, MAX_INPUTS - 1, id) || inputs[id].defined) { cfgFail("bad or duplicate input index"); return; }
    if (!cfgCheckPin(tok[3], CAP_IN, pin)) return;
    bool nc;
    if (!strcmp(tok[4], "NO")) nc = false;
    else if (!strcmp(tok[4], "NC")) nc = true;
    else { cfgFail("contact must be NO or NC"); return; }
    if (!parseNum(tok[5], 0, MAX_DEBOUNCE_MS, deb)) { cfgFail("debounce must be 0..100 ms"); return; }

    Input& in = inputs[id];
    in.pin = pin;
    in.nc = nc;
    in.debounceMs = deb;
    pinMode(pin, INPUT_PULLUP);
    in.raw = in.state = readInputRaw(in);   // start from the real state, no event
    in.changedAt = now;
    in.defined = true;
    pinUsed[pin] = true;
    if (!cfgAccept()) return;
    out->print("ACK CFG IN ");
    out->println(id);

  } else if (!strcmp(sub, "COIL")) {
    // CFG COIL <coil> <pin> <full_ms> <hold_pct> <trig|-> <eos|-> <recycle_ms>
    long id, pin, full, hold, recycle;
    int8_t trig, eos;
    if (n != 9) { cfgFail("COIL needs <coil> <pin> <full_ms> <hold_pct> <trig|-> <eos|-> <recycle_ms>"); return; }
    if (!parseNum(tok[2], 0, MAX_COILS - 1, id) || coils[id].defined) { cfgFail("bad or duplicate coil index"); return; }
    if (!cfgCheckPin(tok[3], CAP_OUT, pin)) return;
    if (!parseNum(tok[4], 1, MAX_PULSE_MS, full)) { cfgFail("full_ms must be 1..255"); return; }
    if (!parseNum(tok[5], 0, 100, hold)) { cfgFail("hold_pct must be 0..100"); return; }
    if (hold > 0 && hold < 100 && !pinHas(pin, CAP_OUT | CAP_PWM)) { cfgFail("hold needs a PWM pin"); return; }
    if (!parseInputRef(tok[6], trig)) { cfgFail("trigger must be - or a defined input"); return; }
    if (!parseInputRef(tok[7], eos)) { cfgFail("eos must be - or a defined input"); return; }
    if (trig != NONE && trig == eos) { cfgFail("trigger and eos must be different inputs"); return; }
    if (!parseNum(tok[8], 0, MAX_RECYCLE_MS, recycle)) { cfgFail("recycle_ms must be 0..5000"); return; }

    Coil& c = coils[id];
    c.pin = pin;
    c.fullMs = full;
    c.holdPct = hold;
    c.trig = trig;
    c.eos = eos;
    c.recycleMs = recycle;
    c.defined = true;
    pinUsed[pin] = true;
    enterState(c, COIL_IDLE, 0, now);
    if (!cfgAccept()) return;
    out->print("ACK CFG COIL ");
    out->println(id);

  } else if (!strcmp(sub, "LAMP")) {
    // CFG LAMP <lamp> <pin>
    long id, pin;
    if (n != 4) { cfgFail("LAMP needs <lamp> <pin>"); return; }
    if (!parseNum(tok[2], 0, MAX_LAMPS - 1, id) || lamps[id].defined) { cfgFail("bad or duplicate lamp index"); return; }
    if (!cfgCheckPin(tok[3], CAP_OUT, pin)) return;

    Lamp& l = lamps[id];
    l.pin = pin;
    l.mode = LAMP_OFF;
    l.defined = true;
    pinUsed[pin] = true;
    pinMode(pin, OUTPUT);
    digitalWrite(pin, LOW);
    if (!cfgAccept()) return;
    out->print("ACK CFG LAMP ");
    out->println(id);

  } else if (!strcmp(sub, "CHAIN")) {
    // CFG CHAIN <chain> <pin> <count> <order>
#if BOARD_HAS_LEDS
    long id, pin, count;
    if (n != 6) { cfgFail("CHAIN needs <chain> <pin> <count> <order>"); return; }
    if (!parseNum(tok[2], 0, MAX_CHAINS - 1, id)) { cfgFail("bad chain index"); return; }
    if (!cfgCheckPin(tok[3], CAP_OUT, pin)) return;
    if (!parseNum(tok[4], 1, MAX_LEDS_PER_CHAIN, count)) { cfgFail("LED count must be 1..300"); return; }
    const char* why = ledsDefineChain(id, pin, count, tok[5]);
    if (why) { cfgFail(why); return; }
    pinUsed[pin] = true;
    if (!cfgAccept()) return;
    out->print("ACK CFG CHAIN ");
    out->println(id);
#else
    cfgFail("this board has no LED chain support");
#endif

  } else if (!strcmp(sub, "ZONE")) {
    // CFG ZONE <zone> <chain> <first> <count>
#if BOARD_HAS_LEDS
    long id, chain, first, count;
    if (n != 6 || !parseNum(tok[2], 0, MAX_ZONES - 1, id) || !parseNum(tok[3], 0, MAX_CHAINS - 1, chain)
        || !parseNum(tok[4], 0, MAX_LEDS_PER_CHAIN - 1, first) || !parseNum(tok[5], 1, MAX_LEDS_PER_CHAIN, count)) {
      cfgFail("ZONE needs <zone> <chain> <first> <count>");
      return;
    }
    const char* why = ledsDefineZone(id, chain, first, count);
    if (why) { cfgFail(why); return; }
    if (!cfgAccept()) return;
    out->print("ACK CFG ZONE ");
    out->println(id);
#else
    cfgFail("this board has no LED chain support");
#endif

  } else if (!strcmp(sub, "DONE")) {
    if (cfgError) { out->println("ERR CFG has errors, send CFG CLEAR and start over"); return; }
    uint8_t nIn = 0, nCoil = 0, nLamp = 0, nChain = 0, nZone = 0;
    for (uint8_t i = 0; i < MAX_INPUTS; i++) nIn += inputs[i].defined;
    for (uint8_t i = 0; i < MAX_COILS; i++)  nCoil += coils[i].defined;
    for (uint8_t i = 0; i < MAX_LAMPS; i++)  nLamp += lamps[i].defined;
#if BOARD_HAS_LEDS
    nChain = ledChainCount;
    nZone  = ledsZoneCount();
    ledsStart();
#endif
    configured = true;
    out->print("ACK CFG ");
    out->print(nIn);
    out->print(' ');
    out->print(nCoil);
    out->print(' ');
    out->print(nLamp);
    out->print(' ');
    out->print(nChain);
    out->print(' ');
    out->print(nZone);
    out->print(' ');
    printHash(true, cfgHash);
    out->println();
    sendAllSwitches();

  } else {
    out->println("ERR CFG needs CLEAR, PWM, IN, COIL, LAMP, CHAIN, ZONE, DONE, SAVE or ERASE");
  }
}

// ---------------- Commands from Godot ----------------
const uint8_t MAX_TOKENS = 9;   // "CFG COIL" is the longest command: 9 tokens

void handleLine(char* line, uint32_t now) {
  lastRxMs = now;  // any line from Godot counts as a heartbeat
  if (wdTripped) {
    wdTripped = false;
    out->println("WD OK");  // outputs stay off; Godot must re-arm rules/lamps
  }

  strncpy(cfgRawLine, line, sizeof(cfgRawLine) - 1);   // before strtok chops it up
  cfgRawLine[sizeof(cfgRawLine) - 1] = '\0';

  char*   tok[MAX_TOKENS];
  uint8_t n = 0;
  for (char* t = strtok(line, " "); t && n < MAX_TOKENS; t = strtok(nullptr, " ")) tok[n++] = t;
  if (n == 0) return;
  const char* cmd = tok[0];

  if (!strcmp(cmd, "HELLO")) {
    // Fresh link: everything off and disarmed, but the layout is kept. The
    // hashes tell Godot whether it needs to send a new one.
    linked = true;
    allOutputsOff();
    out->print("HELLO ");
    out->print(FIRMWARE);
    out->print(' ');
    out->print(BOARD_TYPE);
    out->print(' ');
    out->print(boardUid());
    out->print(' ');
    printHash(configured, cfgHash);
    out->print(' ');
    printHash(savedValid, savedHash);
    out->println();
    return;
  }
  if (!strcmp(cmd, "HB")) return;
  if (!strcmp(cmd, "PING")) {
    out->print("PONG ");
    out->println(n > 1 ? tok[1] : "0");
    return;
  }
  if (!strcmp(cmd, "WD")) {
    bool on;
    if (n < 2 || !parseOnOff(tok[1], on)) { out->println("ERR WD needs <ON|OFF>"); return; }
    watchdogEnabled = on;
    out->print("ACK WD ");
    out->println(tok[1]);
    return;
  }
  if (!strcmp(cmd, "CFG")) {
    handleCfg(tok, n, now);
    return;
  }

  // Everything below drives outputs, so it needs a finished config.
  if (!configured) { out->println("ERR not configured, send CFG first"); return; }

  if (!strcmp(cmd, "SWS")) {
    sendAllSwitches();   // Godot asks for this when it adopts a layout the board already has

  } else if (!strcmp(cmd, "PULSE")) {
    // PULSE <coil> [ms]
    if (n < 2) { out->println("ERR PULSE needs <coil> [ms]"); return; }
    int id = findCoil(tok[1]);
    if (id < 0) return;
    long ms = coils[id].fullMs;
    if (n > 2 && !parseNum(tok[2], 1, 100000, ms)) { out->println("ERR bad pulse ms"); return; }
    if (ms > MAX_PULSE_MS) ms = MAX_PULSE_MS;
    if (!startCoil(coils[id], (uint8_t)ms, false, now)) { out->println("ERR coil busy"); return; }
    out->print("ACK PULSE ");
    out->print(id);
    out->print(' ');
    out->println(ms);

  } else if (!strcmp(cmd, "HOLD")) {
    // HOLD <coil> <ON|OFF>
    bool on;
    if (n < 3 || !parseOnOff(tok[2], on)) { out->println("ERR HOLD needs <coil> <ON|OFF>"); return; }
    int id = findCoil(tok[1]);
    if (id < 0) return;
    Coil& c = coils[id];
    if (c.holdPct == 0) { out->println("ERR coil has no hold (hold_pct is 0)"); return; }
    if (on) {
      if (c.state == COIL_IDLE) startCoil(c, c.fullMs, false, now);
      else if (c.state == COIL_RECYCLE) { out->println("ERR coil busy"); return; }
      c.godotHold = true;   // FULL -> HOLD happens in updateCoils
    } else {
      c.godotHold = false;  // updateCoils turns it off unless the rule is holding it
    }
    out->print("ACK HOLD ");
    out->print(id);
    out->println(on ? " ON" : " OFF");

  } else if (!strcmp(cmd, "RULE")) {
    // RULE <coil|ALL> <ON|OFF>
    bool on;
    if (n < 3 || !parseOnOff(tok[2], on)) { out->println("ERR RULE needs <coil|ALL> <ON|OFF>"); return; }
    if (!strcmp(tok[1], "ALL")) {
      for (uint8_t i = 0; i < MAX_COILS; i++) {
        if (coils[i].defined && coils[i].trig != NONE) coils[i].ruleArmed = on;
      }
    } else {
      int id = findCoil(tok[1]);
      if (id < 0) return;
      if (coils[id].trig == NONE) { out->println("ERR coil has no trigger input"); return; }
      coils[id].ruleArmed = on;
    }
    out->print("ACK RULE ");
    out->print(tok[1]);
    out->println(on ? " ON" : " OFF");

  } else if (!strcmp(cmd, "LED")) {
    // LED <lamp> <ON|OFF|BLINK>
    if (n < 3) { out->println("ERR LED needs <lamp> <ON|OFF|BLINK>"); return; }
    int id = findLamp(tok[1]);
    if (id < 0) return;
    if      (!strcmp(tok[2], "ON"))    lamps[id].mode = LAMP_ON;
    else if (!strcmp(tok[2], "OFF"))   lamps[id].mode = LAMP_OFF;
    else if (!strcmp(tok[2], "BLINK")) lamps[id].mode = LAMP_BLINK;
    else { out->println("ERR bad lamp mode"); return; }
    out->print("ACK LED ");
    out->print(id);
    out->print(' ');
    out->println(tok[2]);

#if BOARD_HAS_LEDS
  } else if (!strcmp(cmd, "FX")) {
    // FX <zone|ALL> <effect> [RRGGBB] [ms] [RRGGBB2]
    if (n < 3) { out->println("ERR FX needs <zone|ALL> <effect> [RRGGBB] [ms] [RRGGBB2]"); return; }
    int effect = ledsEffectFromName(tok[2]);
    if (effect < 0) { out->println("ERR bad effect"); return; }
    uint32_t c1 = 0xFFFFFF, c2 = 0;
    long ms = 500;
    if (n > 3 && !parseColor(tok[3], c1)) { out->println("ERR bad color, use RRGGBB"); return; }
    if (n > 4 && !parseNum(tok[4], 1, 600000, ms)) { out->println("ERR bad ms"); return; }
    if (n > 5 && !parseColor(tok[5], c2)) { out->println("ERR bad color2, use RRGGBB"); return; }
    if (!strcmp(tok[1], "ALL")) {
      for (uint8_t i = 0; i < MAX_ZONES; i++) {
        if (zones[i].defined) ledsSetZone(zones[i], (LedEffect)effect, c1, ms, c2, now);
      }
    } else {
      long id;
      if (!parseNum(tok[1], 0, MAX_ZONES - 1, id) || !zones[id].defined) { out->println("ERR bad zone"); return; }
      ledsSetZone(zones[id], (LedEffect)effect, c1, ms, c2, now);
    }
    out->print("ACK FX ");
    out->print(tok[1]);
    out->print(' ');
    out->println(tok[2]);

  } else if (!strcmp(cmd, "BRIGHT")) {
    // BRIGHT <0..255>
    long level;
    if (n < 2 || !parseNum(tok[1], 0, 255, level)) { out->println("ERR BRIGHT needs <0..255>"); return; }
    ledBrightness = level;
    out->print("ACK BRIGHT ");
    out->println(level);
#endif

  } else {
    out->print("ERR unknown command ");
    out->println(cmd);
  }
}

void readSerial(uint32_t now) {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\r') continue;
    if (c == '\n') {
      if (!rxOverflow && rxLen > 0) {
        rxBuf[rxLen] = '\0';
        handleLine(rxBuf, now);
      }
      rxLen = 0;
      rxOverflow = false;
    } else if (rxLen < sizeof(rxBuf) - 1) {
      rxBuf[rxLen++] = c;
    } else if (!rxOverflow) {
      rxOverflow = true;  // skip the rest of this line
      out->println("ERR line too long");
    }
  }
}

// ---------------- Arduino ----------------
void setup() {
  // Outputs low before anything else, so coils stay off from the first instant
  // our code runs. (Before this, only the gate pulldown resistors protect them.)
  pinMode(STATUS_LED_PIN, OUTPUT);
  clearConfig();

  Serial.begin(115200);  // ignored on Teensy USB: always full USB speed

  loadSavedConfig();     // a burned layout makes the board ready before Godot connects
}

void loop() {
  uint32_t now = millis();
  readSerial(now);
  if (configured) scanInputs(now);
  updateCoils(now);
  updateLamps(now);
#if BOARD_HAS_LEDS
  ledsUpdate(now);   // draws + starts sending a frame about every 16 ms; never waits
#endif
  updateStatusLed(now);
  checkWatchdog(now);
  heartbeatOut(now);
}

/*
  PinIO test sketch  —  Teensy <-> Godot practice link
  ---------------------------------------------------
  Teensy owns timing + safety, Godot owns rules + presentation.

  Practice wiring (Teensy 4.x, all 3.3V!):
    Pins 2,3,4,5  -> pushbuttons to GND        = switches 0..3
    Pin 13        -> onboard LED               = "coil" 0 (sling stand-in)
    Pin 6         -> LED + 330R to GND         = "coil" 1
    Pins 7,8      -> LED + 330R to GND         = lamps 0..1
    A0 (optional) -> pot wiper, ends to 3.3V/GND (NOT 5V). Set USE_ANALOG true.

  Protocol: plain text, one message per line ending in '\n'.

  Teensy -> Godot
    HELLO <firmware>        reply to HELLO
    SWS <bits>              full switch state, e.g. SWS 0100 (switch 1 closed)
    SW <id> <0|1>           debounced switch change
    FIRED <rule>            a hardware rule fired locally (e.g. FIRED SLING_L)
    ANA <id> <value>        analog value changed (0..1023)
    PONG <n>                reply to PING
    ACK <cmd> ...           command accepted
    ERR <message>           something was wrong
    WD TRIP / WD OK         watchdog killed outputs / link restored
    HB <millis>             Teensy heartbeat, once per second

  Godot -> Teensy
    HELLO                   start/restart the link (arms the watchdog)
    HB                      heartbeat (any line counts, send ~10x per second)
    PULSE <coil> <ms>       fire a coil, clamped to MAX_PULSE_MS
    LED <id> <ON|OFF|BLINK>
    RULE <name> <ON|OFF>    enable/disable a hardware rule (only SLING_L here)
    PING <n>                round-trip latency test
    WD <ON|OFF>             enable/disable watchdog (handy in Serial Monitor)
*/

#include <Arduino.h>

// ---------------- Hardware map ----------------
const uint8_t SW_PINS[]   = {2, 3, 4, 5};
const uint8_t COIL_PINS[] = {13, 6};
const uint8_t LED_PINS[]  = {7, 8};
const uint8_t ANALOG_PIN  = A0;
const bool    USE_ANALOG  = false;   // leave false until a pot is wired, or the floating pin spams

const uint8_t NUM_SW    = sizeof(SW_PINS);
const uint8_t NUM_COILS = sizeof(COIL_PINS);
const uint8_t NUM_LEDS  = sizeof(LED_PINS);

// Switch 0 + coil 0 act as the left slingshot hardware rule
const uint8_t  SLING_L_SWITCH   = 0;
const uint8_t  SLING_L_COIL     = 0;
const uint16_t SLING_L_PULSE_MS = 40;

// ---------------- Timing ----------------
const uint32_t DEBOUNCE_MS      = 5;
const uint32_t WATCHDOG_MS      = 500;   // nothing from Godot this long -> outputs off
const uint32_t HEARTBEAT_OUT_MS = 1000;
const uint32_t BLINK_MS         = 250;
const uint32_t ANALOG_EVERY_MS  = 20;
const int      ANALOG_DEADBAND  = 8;
const int      MAX_PULSE_MS     = 255;   // hard safety cap for any coil pulse

const char* FIRMWARE = "PINIO 0.1";

// ---------------- State ----------------
struct Switch {
  bool state;          // debounced, true = closed/active
  bool raw;            // last raw reading
  uint32_t changedAt;  // when raw last changed
};
Switch sw[NUM_SW];

bool     coilActive[NUM_COILS];
uint32_t coilOffAt[NUM_COILS];

enum LedMode : uint8_t { LED_OFF, LED_ON, LED_BLINK };
LedMode ledMode[NUM_LEDS];

bool ruleSlingL = false;

bool     linked          = false;  // Godot has said HELLO
bool     watchdogEnabled = true;
bool     wdTripped       = false;
uint32_t lastRxMs        = 0;
uint32_t lastHbOutMs     = 0;

uint32_t lastAnalogMs  = 0;
int      lastAnalogVal = -1000;

char    rxBuf[64];
uint8_t rxLen      = 0;
bool    rxOverflow = false;

// ---------------- Outputs ----------------
void fireCoil(uint8_t id, int ms, uint32_t now) {
  if (id >= NUM_COILS || ms <= 0) return;
  if (ms > MAX_PULSE_MS) ms = MAX_PULSE_MS;
  digitalWrite(COIL_PINS[id], HIGH);
  coilActive[id] = true;
  coilOffAt[id]  = now + (uint32_t)ms;
}

void allOutputsOff() {
  for (uint8_t i = 0; i < NUM_COILS; i++) {
    digitalWrite(COIL_PINS[i], LOW);
    coilActive[i] = false;
  }
  for (uint8_t i = 0; i < NUM_LEDS; i++) {
    ledMode[i] = LED_OFF;
    digitalWrite(LED_PINS[i], LOW);
  }
}

void updateCoils(uint32_t now) {
  for (uint8_t i = 0; i < NUM_COILS; i++) {
    // signed compare survives the millis() rollover
    if (coilActive[i] && (int32_t)(now - coilOffAt[i]) >= 0) {
      digitalWrite(COIL_PINS[i], LOW);
      coilActive[i] = false;
    }
  }
  // A real flipper would be its own state machine here:
  // button -> 24V full power -> EOS closes -> PWM hold -> button released -> off.
}

void updateLeds(uint32_t now) {
  bool blinkPhase = (now / BLINK_MS) & 1;
  for (uint8_t i = 0; i < NUM_LEDS; i++) {
    bool on = (ledMode[i] == LED_ON) || (ledMode[i] == LED_BLINK && blinkPhase);
    digitalWrite(LED_PINS[i], on ? HIGH : LOW);
  }
}

// ---------------- Inputs ----------------
void sendAllSwitches() {
  Serial.print("SWS ");
  for (uint8_t i = 0; i < NUM_SW; i++) Serial.print(sw[i].state ? '1' : '0');
  Serial.println();
}

void onSwitchChanged(uint8_t id, bool active, uint32_t now) {
  // Hardware rule first: fire locally, THEN tell Godot. Godot never sits in this path.
  if (id == SLING_L_SWITCH && active && ruleSlingL && !wdTripped) {
    fireCoil(SLING_L_COIL, SLING_L_PULSE_MS, now);
    Serial.println("FIRED SLING_L");
  }
  Serial.printf("SW %u %u\n", id, active ? 1 : 0);
}

void scanSwitches(uint32_t now) {
  for (uint8_t i = 0; i < NUM_SW; i++) {
    bool raw = digitalRead(SW_PINS[i]) == LOW;  // pullup: pressed = LOW
    if (raw != sw[i].raw) {
      sw[i].raw = raw;
      sw[i].changedAt = now;
    } else if (raw != sw[i].state && (now - sw[i].changedAt) >= DEBOUNCE_MS) {
      sw[i].state = raw;
      onSwitchChanged(i, raw, now);
    }
  }
}

void scanAnalog(uint32_t now) {
  if (!USE_ANALOG || (now - lastAnalogMs) < ANALOG_EVERY_MS) return;
  lastAnalogMs = now;
  int v = analogRead(ANALOG_PIN);
  if (abs(v - lastAnalogVal) >= ANALOG_DEADBAND) {
    lastAnalogVal = v;
    Serial.printf("ANA 0 %d\n", v);
  }
}

// ---------------- Commands from Godot ----------------
bool parseOnOff(const char* s, bool& out) {
  if (!s) return false;
  if (!strcmp(s, "ON"))  { out = true;  return true; }
  if (!strcmp(s, "OFF")) { out = false; return true; }
  return false;
}

void handleLine(char* line, uint32_t now) {
  lastRxMs = now;  // any line from Godot counts as a heartbeat
  if (wdTripped) {
    wdTripped = false;
    Serial.println("WD OK");  // outputs stay off; Godot must re-send rules/lamps
  }

  char* cmd = strtok(line, " ");
  char* a1  = strtok(nullptr, " ");
  char* a2  = strtok(nullptr, " ");
  if (!cmd) return;

  if (!strcmp(cmd, "HELLO")) {
    linked = true;
    Serial.print("HELLO ");
    Serial.println(FIRMWARE);
    sendAllSwitches();

  } else if (!strcmp(cmd, "HB")) {
    // nothing else to do

  } else if (!strcmp(cmd, "PULSE")) {
    if (!a1 || !a2) { Serial.println("ERR PULSE needs <coil> <ms>"); return; }
    int id = atoi(a1), ms = atoi(a2);
    if (id < 0 || id >= NUM_COILS) { Serial.println("ERR bad coil"); return; }
    fireCoil(id, ms, now);
    Serial.printf("ACK PULSE %d %d\n", id, min(ms, MAX_PULSE_MS));

  } else if (!strcmp(cmd, "LED")) {
    if (!a1 || !a2) { Serial.println("ERR LED needs <id> <ON|OFF|BLINK>"); return; }
    int id = atoi(a1);
    if (id < 0 || id >= NUM_LEDS) { Serial.println("ERR bad led"); return; }
    if      (!strcmp(a2, "ON"))    ledMode[id] = LED_ON;
    else if (!strcmp(a2, "OFF"))   ledMode[id] = LED_OFF;
    else if (!strcmp(a2, "BLINK")) ledMode[id] = LED_BLINK;
    else { Serial.println("ERR bad led mode"); return; }
    Serial.printf("ACK LED %d %s\n", id, a2);

  } else if (!strcmp(cmd, "RULE")) {
    bool on;
    if (!a1 || !parseOnOff(a2, on)) { Serial.println("ERR RULE needs <name> <ON|OFF>"); return; }
    if (!strcmp(a1, "SLING_L")) ruleSlingL = on;
    else { Serial.println("ERR unknown rule"); return; }
    Serial.printf("ACK RULE %s %s\n", a1, a2);

  } else if (!strcmp(cmd, "PING")) {
    Serial.printf("PONG %s\n", a1 ? a1 : "0");

  } else if (!strcmp(cmd, "WD")) {
    bool on;
    if (!parseOnOff(a1, on)) { Serial.println("ERR WD needs <ON|OFF>"); return; }
    watchdogEnabled = on;
    Serial.printf("ACK WD %s\n", a1);

  } else {
    Serial.printf("ERR unknown command %s\n", cmd);
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
      Serial.println("ERR line too long");
    }
  }
}

// ---------------- Safety ----------------
void checkWatchdog(uint32_t now) {
  if (!linked || !watchdogEnabled || wdTripped) return;
  if ((now - lastRxMs) > WATCHDOG_MS) {
    allOutputsOff();
    ruleSlingL = false;
    wdTripped = true;
    Serial.println("WD TRIP");
  }
}

void heartbeatOut(uint32_t now) {
  if ((now - lastHbOutMs) >= HEARTBEAT_OUT_MS) {
    lastHbOutMs = now;
    Serial.printf("HB %lu\n", (unsigned long)now);
  }
}

// ---------------- Arduino ----------------
void setup() {
  Serial.begin(115200);  // ignored on Teensy USB: always full USB speed

  for (uint8_t i = 0; i < NUM_SW; i++) {
    pinMode(SW_PINS[i], INPUT_PULLUP);
    bool raw = digitalRead(SW_PINS[i]) == LOW;
    sw[i] = { raw, raw, 0 };
  }
  for (uint8_t i = 0; i < NUM_COILS; i++) pinMode(COIL_PINS[i], OUTPUT);
  for (uint8_t i = 0; i < NUM_LEDS; i++)  pinMode(LED_PINS[i], OUTPUT);
  allOutputsOff();
}

void loop() {
  uint32_t now = millis();
  readSerial(now);
  scanSwitches(now);
  scanAnalog(now);
  updateCoils(now);
  updateLeds(now);
  checkWatchdog(now);
  heartbeatOut(now);
}

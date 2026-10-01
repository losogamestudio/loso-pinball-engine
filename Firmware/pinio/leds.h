// LED engine: WS2812B chains, zones and effects
// ------------------------------------------------------------
// Godot names the playfield lights; the board only knows numbers:
//
//   chain  = one WS2812B strip on one output pin   (CFG CHAIN <chain> <pin> <count> <order>)
//   zone   = a range of LEDs on a chain             (CFG ZONE <zone> <chain> <first> <count>)
//            a strip section, or a single insert (count 1). Zones may overlap.
//   effect = what a zone shows right now             (FX <zone|ALL> <effect> [color] [ms] [color2])
//
// The board draws every zone itself about 60 times a second, so effects run
// smoothly no matter how busy Godot or the USB link is. Godot only sends a
// short line when a zone should change (a light show is a list of those).
//
// Zones are drawn in index order, so a later zone draws over an earlier one
// where they overlap (Godot numbers single inserts after strips). A zone with
// effect OFF draws nothing, so whatever is under it shows; SOLID 000000 forces black.
//
// Output uses PJRC's OctoWS2811 library: it sends all chains in parallel by
// DMA, without blocking the CPU or turning interrupts off, so switch scanning
// and coil timing are never delayed. Two library quirks shape this file:
//   - every chain is sent with the same length (the longest chain's); the
//     shorter ones just get black LEDs past their end, which nobody sees
//   - one color order for all chains, so we keep the library on RGB and put
//     each chain's bytes in its own order (GRB for most WS2812B) ourselves

#pragma once

#include <OctoWS2811.h>

enum LedEffect : uint8_t {
  FX_OFF, FX_SOLID, FX_BLINK, FX_PULSE, FX_CHASE, FX_WIPE, FX_FADE, FX_RAINBOW, FX_SPARKLE,
  FX_COUNT
};
const char* const FX_NAMES[FX_COUNT] = {
  "OFF", "SOLID", "BLINK", "PULSE", "CHASE", "WIPE", "FADE", "RAINBOW", "SPARKLE"
};

const uint32_t LED_FRAME_MS      = 16;    // about 60 frames a second
const uint8_t  DEFAULT_BRIGHTNESS = 128;  // 50%: a full-white strip draws a lot of current

struct Chain {
  bool     defined;
  uint8_t  pin;
  uint16_t count;
  uint8_t  rPos, gPos, bPos;   // where each color byte goes on the wire (0, 1 or 2)
};

struct Zone {
  bool      defined;
  uint8_t   chain;
  uint16_t  first;
  uint16_t  count;
  LedEffect effect;
  uint32_t  color1;     // 0xRRGGBB
  uint32_t  color2;
  uint32_t  fromColor;  // FADE starts from here (the zone's previous color)
  uint32_t  ms;         // period, or duration for FADE / WIPE
  uint32_t  startedAt;
};

Chain   chains[MAX_CHAINS];
Zone    zones[MAX_ZONES];
uint8_t ledBrightness = DEFAULT_BRIGHTNESS;

// Frame buffers: the library sends displayMemory while we draw into
// drawMemory. DMAMEM puts them in the RAM the DMA engine reads fastest.
DMAMEM int ledDisplayMemory[MAX_CHAINS * MAX_LEDS_PER_CHAIN * 3 / 4];
DMAMEM int ledDrawMemory[MAX_CHAINS * MAX_LEDS_PER_CHAIN * 3 / 4];
uint8_t    ledPins[MAX_CHAINS];
OctoWS2811 octo(MAX_LEDS_PER_CHAIN, ledDisplayMemory, ledDrawMemory, WS2811_RGB | WS2811_800kHz, 0, ledPins);

bool     ledsRunning   = false;   // octo.begin() done for the current chains
uint8_t  ledChainCount = 0;
uint16_t ledStripLen   = 0;       // the longest chain: every chain is sent this long
uint32_t lastLedFrame  = 0;

// ---------------- Configuration ----------------

uint8_t ledsZoneCount() {
  uint8_t n = 0;
  for (uint8_t i = 0; i < MAX_ZONES; i++) n += zones[i].defined;
  return n;
}

// Give the chain pins back to normal GPIO. OctoWS2811's begin() moves its pins
// from the fast GPIO6-9 ports (what digitalWrite uses on Teensy 4) to GPIO1-4
// (what its DMA writes). Undo that, so a former LED pin works as a coil again.
void ledsReleasePins() {
  for (uint8_t i = 0; i < MAX_CHAINS; i++) {
    if (!chains[i].defined) continue;
    uint8_t pin = chains[i].pin;
    uint8_t offset = ((uint32_t)portOutputRegister(pin) - (uint32_t)&GPIO6_DR) >> 14;
    if (offset <= 3) *(&IOMUXC_GPR_GPR26 + offset) |= (1 << digitalPinToBit(pin));
  }
}

// Forget all chains and zones (CFG CLEAR). The caller drives the pins low afterwards.
void ledsClearConfig() {
  if (ledsRunning) {
    uint32_t waitStart = micros();
    while (octo.busy() && micros() - waitStart < 20000) {}   // let the last frame finish (a few ms)
    ledsReleasePins();
  }
  memset(chains, 0, sizeof(chains));
  memset(zones, 0, sizeof(zones));
  ledsRunning   = false;
  ledChainCount = 0;
  ledStripLen   = 0;
}

// CFG CHAIN. Chains must be numbered 0, 1, 2... in order: chain N is the
// library's strip N. Returns nullptr if accepted, otherwise why not.
// (The pin itself is checked by the caller, like coil and lamp pins.)
const char* ledsDefineChain(long id, long pin, long count, const char* order) {
  if (id != ledChainCount || id >= MAX_CHAINS) return "chains must be numbered 0, 1, 2... in order";
  if (count < 1 || count > MAX_LEDS_PER_CHAIN) return "LED count must be 1..300";
  const char* orders[] = {"RGB", "RBG", "GRB", "GBR", "BRG", "BGR"};
  int8_t which = -1;
  for (uint8_t i = 0; i < 6; i++) if (!strcmp(order, orders[i])) which = i;
  if (which < 0) return "color order must be RGB, RBG, GRB, GBR, BRG or BGR";
  Chain& c = chains[id];
  c.pin   = pin;
  c.count = count;
  // Position of each color in the 3 bytes sent to every LED, e.g. GRB: G=0, R=1, B=2.
  c.rPos = strchr(orders[which], 'R') - orders[which];
  c.gPos = strchr(orders[which], 'G') - orders[which];
  c.bPos = strchr(orders[which], 'B') - orders[which];
  c.defined = true;
  ledChainCount++;
  if (count > ledStripLen) ledStripLen = count;
  return nullptr;
}

// CFG ZONE. Returns nullptr if accepted, otherwise why not.
const char* ledsDefineZone(long id, long chain, long first, long count) {
  if (id < 0 || id >= MAX_ZONES || zones[id].defined) return "bad or duplicate zone index";
  if (chain < 0 || chain >= MAX_CHAINS || !chains[chain].defined) return "zone needs a defined chain";
  if (first < 0 || count < 1 || first + count > chains[chain].count) return "zone doesn't fit on its chain";
  Zone& z = zones[id];
  z.chain   = chain;
  z.first   = first;
  z.count   = count;
  z.effect  = FX_OFF;
  z.defined = true;
  return nullptr;
}

// CFG DONE: start sending. Does nothing on a board without chains.
void ledsStart() {
  if (ledChainCount == 0) return;
  for (uint8_t i = 0; i < ledChainCount; i++) ledPins[i] = chains[i].pin;
  octo.begin(ledStripLen, ledDisplayMemory, ledDrawMemory, WS2811_RGB | WS2811_800kHz, ledChainCount, ledPins);
  ledsRunning = true;
}

// ---------------- Runtime control ----------------

// Every zone OFF (watchdog, HELLO, CFG SAVE). The next frame sends black.
void ledsAllOff() {
  for (uint8_t i = 0; i < MAX_ZONES; i++) {
    if (zones[i].defined) zones[i].effect = FX_OFF;
  }
}

// Parse an effect name; -1 if unknown.
int ledsEffectFromName(const char* s) {
  for (uint8_t i = 0; i < FX_COUNT; i++) if (!strcmp(s, FX_NAMES[i])) return i;
  return -1;
}

void ledsSetZone(Zone& z, LedEffect effect, uint32_t c1, uint32_t ms, uint32_t c2, uint32_t now) {
  z.fromColor = (z.effect == FX_OFF) ? 0 : z.color1;   // FADE starts from what was showing
  z.effect    = effect;
  z.color1    = c1;
  z.color2    = c2;
  z.ms        = ms < 1 ? 1 : ms;
  z.startedAt = now;
}

// ---------------- Drawing ----------------

uint8_t scale8(uint8_t v, uint8_t amount) { return ((uint16_t)v * amount) >> 8; }

uint32_t blend(uint32_t a, uint32_t b, uint8_t amount) {   // amount 0 = a, 255 = b
  uint8_t r = ((a >> 16) & 0xFF) + (((int)((b >> 16) & 0xFF) - (int)((a >> 16) & 0xFF)) * amount) / 255;
  uint8_t g = ((a >> 8) & 0xFF)  + (((int)((b >> 8) & 0xFF)  - (int)((a >> 8) & 0xFF))  * amount) / 255;
  uint8_t bl = (a & 0xFF)        + (((int)(b & 0xFF)         - (int)(a & 0xFF))         * amount) / 255;
  return ((uint32_t)r << 16) | ((uint32_t)g << 8) | bl;
}

uint32_t dim(uint32_t c, uint8_t amount) { return blend(0, c, amount); }

// Hue 0..255 around the color wheel, full brightness.
uint32_t wheel(uint8_t hue) {
  uint8_t region = hue / 43, rem = (hue - region * 43) * 6;
  uint8_t up = rem, down = 255 - rem;
  switch (region) {
    case 0:  return (255UL << 16) | ((uint32_t)up << 8);
    case 1:  return ((uint32_t)down << 16) | (255UL << 8);
    case 2:  return (255UL << 8) | up;
    case 3:  return ((uint32_t)down << 8) | 255;
    case 4:  return ((uint32_t)up << 16) | 255;
    default: return (255UL << 16) | down;
  }
}

// Write one LED into the draw buffer, in its chain's color order, at the global brightness.
void setLed(const Chain& c, uint8_t chainIndex, uint16_t led, uint32_t color) {
  uint8_t* px = (uint8_t*)ledDrawMemory + ((uint32_t)chainIndex * ledStripLen + led) * 3;
  px[c.rPos] = scale8((color >> 16) & 0xFF, ledBrightness);
  px[c.gPos] = scale8((color >> 8) & 0xFF, ledBrightness);
  px[c.bPos] = scale8(color & 0xFF, ledBrightness);
}

// The color of LED i (0 = the zone's first LED) of a zone at this moment.
uint32_t zoneColor(const Zone& z, uint16_t i, uint32_t elapsed) {
  switch (z.effect) {
    case FX_SOLID:
      return z.color1;
    case FX_BLINK:                                     // color1 / color2, ms each
      return ((elapsed / z.ms) & 1) ? z.color2 : z.color1;
    case FX_PULSE: {                                   // breathe color1 over ms
      uint32_t phase = (elapsed % z.ms) * 510 / z.ms;  // 0..509
      uint8_t level = phase < 255 ? phase : 509 - phase;
      return dim(z.color1, scale8(level, level) + 8);  // squared: looks smoother to the eye
    }
    case FX_CHASE:                                     // every 3rd LED lit, one step each ms
      return ((i + 3 - (elapsed / z.ms) % 3) % 3 == 0) ? z.color1 : z.color2;
    case FX_WIPE: {                                    // fill with color1 across ms, then hold
      uint32_t lit = elapsed >= z.ms ? z.count : (uint32_t)z.count * elapsed / z.ms;
      return i < lit ? z.color1 : z.color2;
    }
    case FX_FADE:                                      // previous color -> color1 across ms
      return elapsed >= z.ms ? z.color1 : blend(z.fromColor, z.color1, elapsed * 255 / z.ms);
    case FX_RAINBOW:                                   // one full color cycle each ms, spread along the zone
      return wheel((uint8_t)(i * 256 / z.count + (elapsed % z.ms) * 256 / z.ms));
    case FX_SPARKLE: {                                 // random LEDs flash color1 over color2
      uint32_t h = (i + 1) * 2654435761UL ^ ((elapsed / z.ms) * 40503UL);   // a cheap hash: new pattern every ms
      h ^= h >> 15;
      return (h % 8 == 0) ? z.color1 : z.color2;
    }
    default:
      return 0;
  }
}

// Draw and send a frame, about every 16 ms, when the previous frame has gone out.
void ledsUpdate(uint32_t now) {
  if (!ledsRunning || now - lastLedFrame < LED_FRAME_MS || octo.busy()) return;
  lastLedFrame = now;
  memset(ledDrawMemory, 0, (uint32_t)ledChainCount * ledStripLen * 3);
  for (uint8_t zi = 0; zi < MAX_ZONES; zi++) {
    const Zone& z = zones[zi];
    if (!z.defined || z.effect == FX_OFF) continue;
    const Chain& c = chains[z.chain];
    uint32_t elapsed = now - z.startedAt;   // unsigned: survives millis() rollover
    for (uint16_t i = 0; i < z.count; i++) setLed(c, z.chain, z.first + i, zoneColor(z, i, elapsed));
  }
  octo.show();   // copies the draw buffer and starts the DMA; returns right away
}

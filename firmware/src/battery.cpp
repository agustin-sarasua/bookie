#include "battery.h"

#include "config.h"
#include "log.h"

namespace battery {
namespace {

float g_volts = 0.0f;

float sample() {
  uint32_t mv = 0;
  for (int i = 0; i < 8; i++) {
    mv += analogReadMilliVolts(PIN_BATT_SENSE);
  }
  return (mv / 8.0f) * BATT_DIVIDER / 1000.0f;
}

}  // namespace

bool wired() { return PIN_BATT_SENSE >= 0; }

void begin() {
  if (!wired()) {
    // An unconnected ADC pin reads whatever it picks up, anywhere from 0 to
    // 2 V here — enough to fake a critical battery and put the toy to sleep.
    LOGI("battery   : not wired (PIN_BATT_SENSE = -1), no low-battery warning");
    return;
  }
  analogSetPinAttenuation(PIN_BATT_SENSE, ADC_11db);  // full 0-3.3 V span
  g_volts = sample();
  LOGI("battery %.2f V (%u%%)", g_volts, percent());
}

float volts() {
  if (!wired()) {
    return 0.0f;
  }
  const float now = sample();
  // Audio draws current in bursts; smooth so a bass note is not a low battery.
  g_volts = (g_volts <= 0.0f) ? now : (g_volts * 0.8f + now * 0.2f);
  return g_volts;
}

uint8_t percent() {
  static const struct { float v; uint8_t pct; } kCurve[] = {
      {4.15f, 100}, {4.05f, 90}, {3.95f, 75}, {3.87f, 60}, {3.80f, 50},
      {3.73f, 35},  {3.68f, 25}, {3.60f, 15}, {3.50f, 8},  {3.30f, 0},
  };
  const float v = g_volts;
  if (v >= kCurve[0].v) {
    return 100;
  }
  for (size_t i = 1; i < sizeof(kCurve) / sizeof(kCurve[0]); i++) {
    if (v >= kCurve[i].v) {
      const float span = kCurve[i - 1].v - kCurve[i].v;
      const float frac = (v - kCurve[i].v) / span;
      return kCurve[i].pct + (uint8_t)(frac * (kCurve[i - 1].pct - kCurve[i].pct));
    }
  }
  return 0;
}

}  // namespace battery

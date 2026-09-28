#include "settings.h"

#include <Preferences.h>

#include "config.h"
#include "log.h"

namespace settings {
namespace {

Preferences g_prefs;
String g_language;
uint8_t g_volume = VOLUME_DEFAULT_STEP;

}  // namespace

void begin() {
  g_prefs.begin("bookie", false);
  g_language = g_prefs.isKey("lang") ? g_prefs.getString("lang") : String(LANG_FALLBACK);
  g_volume = g_prefs.isKey("vol") ? g_prefs.getUChar("vol") : VOLUME_DEFAULT_STEP;
  if (g_volume > VOLUME_MAX_STEP) {
    g_volume = VOLUME_DEFAULT_STEP;
  }
  LOGI("settings: language=%s volume=%u", g_language.c_str(), g_volume);
}

String language() { return g_language; }

void setLanguage(const String &code) {
  if (code == g_language) {
    return;
  }
  g_language = code;
  g_prefs.putString("lang", code);
}

uint8_t volumeStep() { return g_volume; }

void setVolumeStep(uint8_t step) {
  if (step > VOLUME_MAX_STEP || step == g_volume) {
    return;
  }
  g_volume = step;
  g_prefs.putUChar("vol", step);
}

}  // namespace settings

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

void lamp(uint8_t &scene, float &level) {
  // isKey first: a missing float is logged as an error by Preferences.
  // "lampScene" counted from "warm"; "lampScn2" counts from the "bright" scene
  // added in front of it. An old value is read once and moved along by one.
  if (g_prefs.isKey("lampScn2")) {
    scene = g_prefs.getUChar("lampScn2", 0);
  } else {
    scene = g_prefs.isKey("lampScene") ? g_prefs.getUChar("lampScene", 0) + 1 : 0;
  }
  level = g_prefs.isKey("lampLevel") ? g_prefs.getFloat("lampLevel", LAMP_DEFAULT_LEVEL)
                                     : LAMP_DEFAULT_LEVEL;
}

void setLamp(uint8_t scene, float level) {
  uint8_t was;
  float wasLevel;
  lamp(was, wasLevel);
  if (!g_prefs.isKey("lampScn2") || was != scene) {
    g_prefs.putUChar("lampScn2", scene);
  }
  if (!g_prefs.isKey("lampLevel") || fabsf(wasLevel - level) > 0.005f) {
    g_prefs.putFloat("lampLevel", level);
  }
}

}  // namespace settings

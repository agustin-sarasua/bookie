// Bookie — tap an NFC tag on a page, hear that page read aloud.
//
//   language button : tap cycles through the folders in /audio, announced out loud;
//                     long press pauses / resumes, or replays the last tag when idle;
//                     wakes the toy from deep sleep
//   volume buttons  : eight steps, remembered across power cycles
//   language + vol+ : link mode (hold language, then press volume up)
//
// The decoder runs in its own task (see audio.cpp), so everything in loop() is
// free to block for a few milliseconds without the speaker noticing.

#include <Arduino.h>
#include <driver/gpio.h>
#include <driver/rtc_io.h>
#include <esp_sleep.h>

#include "app.h"
#include "audio.h"
#include "battery.h"
#include "buttons.h"
#include "config.h"
#include "console.h"
#include "library.h"
#include "log.h"
#include "nfc.h"
#include "sdfs.h"
#include "settings.h"
#include "toylink.h"

namespace {

String g_language;
String g_currentTag;    // last tag we found a clip for
String g_pendingTrack;  // queued behind the clip that is playing, e.g. after a language change
uint32_t g_completions = 0;
uint32_t g_lastActivityAt = 0;
uint32_t g_nextBatteryAt = 0;
bool g_batteryWarned = false;

bool playClip(const char *clip) {
  const String path = library::systemClip(g_language, clip);
  if (path.isEmpty()) {
    LOGD("no '%s' clip for %s", clip, g_language.c_str());
    return false;
  }
  audio::play(path.c_str());
  return true;
}

void onTagArrived(const String &uid) {
  app::markActivity();
  const String path = library::trackFor(uid, g_language);
  if (path.isEmpty()) {
    LOGE("tag %s has no clip in %s", uid.c_str(), g_language.c_str());
    g_pendingTrack = "";
    playClip(CLIP_UNKNOWN);
    return;
  }
  g_currentTag = uid;
  g_pendingTrack = "";
  audio::play(path.c_str());
}

void onTrackFinished() {
  if (g_pendingTrack.isEmpty()) {
    return;
  }
  const String next = g_pendingTrack;
  g_pendingTrack = "";
  audio::play(next.c_str());
}

void onButton(const buttons::Event &ev) {
  app::markActivity();
  static const char *const kKinds[] = {"press", "long press", "repeat"};
  LOGI("button %s: %s", buttons::name(ev.id), kKinds[(int)ev.kind]);

  // While the phone is connected the toy is a card reader, and every button is
  // the way out of that. Anything else would need a second gesture to undo.
  if (toylink::active()) {
    if (ev.kind == buttons::Kind::Press) {
      LOGI("link: %s button pressed", buttons::name(ev.id));
      toylink::stop();
    }
    return;
  }

  // Hold language, press volume up: the one combination a child will not find,
  // and the only way into link mode without a computer. While language is held
  // the volume keys belong to the combo, so a slow second press, or its
  // auto-repeat, does not also move the volume.
  const bool volKey = ev.id == buttons::Id::VolUp || ev.id == buttons::Id::VolDown;
  if (volKey && buttons::held(buttons::Id::Lang)) {
    if (ev.id == buttons::Id::VolUp && ev.kind == buttons::Kind::Press) {
      // Said out loud: holding language for more than BTN_LONG_MS before the
      // combo trips its long press first, so the last thing on the console may
      // be "paused" and it is not obvious whether the combo was seen at all.
      LOGI("link: language + vol+");
      buttons::consume(buttons::Id::Lang);
      app::toggleLink();
    }
    return;
  }

  switch (ev.id) {
    // With no play button, language carries its jobs on a long press. Its tap
    // fires on release, so a long press is never also a language change.
    case buttons::Id::Lang:
      if (ev.kind == buttons::Kind::Press) {
        app::cycleLanguage();
      } else if (ev.kind == buttons::Kind::LongPress) {
        if (audio::busy()) {
          audio::togglePause();
          LOGI("%s", audio::state() == audio::State::Paused ? "paused" : "resumed");
        } else if (!g_currentTag.isEmpty()) {
          onTagArrived(g_currentTag);  // replay the last page without re-tapping
        }
      }
      break;

    case buttons::Id::VolUp:
      if (ev.kind != buttons::Kind::LongPress) {
        app::setVolume(audio::volumeStep() + 1);
      }
      break;

    case buttons::Id::VolDown:
      if (ev.kind != buttons::Kind::LongPress) {
        const uint8_t step = audio::volumeStep();
        app::setVolume(step ? step - 1 : 0);
      }
      break;

    default:
      break;
  }
}

void checkBattery() {
  if (!battery::wired()) {
    return;
  }
  const uint32_t now = millis();
  if ((int32_t)(now - g_nextBatteryAt) < 0) {
    return;
  }
  g_nextBatteryAt = now + BATT_SAMPLE_MS;

  const float v = battery::volts();
  LOGD("battery %.2f V (%u%%)", v, battery::percent());

  if (v < 2.5f) {
    return;  // no cell connected, running off USB only
  }
  if (v < BATT_CRITICAL_V) {
    app::sleepNow("battery critical");
    return;
  }
  if (v < BATT_WARN_V && !g_batteryWarned) {
    g_batteryWarned = true;
    LOGI("battery low: %.2f V", v);
    if (!audio::busy()) {
      playClip(CLIP_LOWBATT);
    }
  } else if (v > BATT_WARN_V + 0.1f) {
    g_batteryWarned = false;
  }
}

void checkIdleSleep() {
  // A paused clip counts as idle; otherwise a toy left mid-story never sleeps.
  // Link mode does not: it has its own, shorter, timeout.
  if (IDLE_SLEEP_MS == 0 || audio::state() == audio::State::Playing || toylink::active()) {
    return;
  }
  if (millis() - g_lastActivityAt > IDLE_SLEEP_MS) {
    app::sleepNow("idle");
  }
}

}  // namespace

namespace app {

const String &language() { return g_language; }

void markActivity() { g_lastActivityAt = millis(); }

void setLanguage(const String &code) {
  if (!library::hasLanguage(code)) {
    LOGE("no /audio/%s folder on the card", code.c_str());
    return;
  }
  if (code == g_language) {
    // Not nothing happening for no reason: with one folder under /audio the
    // cycle comes straight back to where it started. Silence here reads as a
    // dead button, which is the one thing it is not.
    LOGD("language already %s — only %u on the card", code.c_str(),
         (unsigned)library::languages().size());
    return;
  }

  const bool wasPlaying = audio::busy();
  g_language = code;
  settings::setLanguage(code);
  LOGI("language: %s", code.c_str());

  // If a page was being read, pick it up again in the new language once the
  // announcement is done. Resuming mid-file would land in the wrong sentence.
  g_pendingTrack = "";
  if (wasPlaying && !g_currentTag.isEmpty()) {
    g_pendingTrack = library::trackFor(g_currentTag, code);
  }

  if (playClip(CLIP_LANGUAGE)) {
    return;
  }
  if (!g_pendingTrack.isEmpty()) {
    const String next = g_pendingTrack;
    g_pendingTrack = "";
    audio::play(next.c_str());
  } else {
    audio::stop();
  }
}

void cycleLanguage() { setLanguage(library::nextLanguage(g_language)); }

void setVolume(uint8_t step) {
  if (step > VOLUME_MAX_STEP) {
    step = VOLUME_MAX_STEP;
  }
  if (step == audio::volumeStep()) {
    LOGD("volume already %u/%u", step, VOLUME_MAX_STEP);  // at an end stop
    return;
  }
  audio::setVolumeStep(step);
  settings::setVolumeStep(step);
  LOGI("volume %u/%u", step, VOLUME_MAX_STEP);
}

void playTag(const String &uid) { onTagArrived(uid); }

void toggleLink() {
  if (toylink::active()) {
    toylink::stop();
    return;
  }
  // Said out loud where there is a clip for it — the toy has no screen, and
  // "did it work?" is otherwise a question only the serial monitor can answer.
  playClip(CLIP_LINK);
  if (!toylink::start()) {
    LOGE("link: not started");
  }
}

void printStatus() {
  LOGI("language  : %s", g_language.c_str());
  LOGI("volume    : %u/%u", audio::volumeStep(), VOLUME_MAX_STEP);
  LOGI("audio     : %s %s",
       audio::state() == audio::State::Playing ? "playing"
       : audio::state() == audio::State::Paused ? "paused"
                                                : "idle",
       audio::currentPath());
  LOGI("last tag  : %s", g_currentTag.isEmpty() ? "-" : g_currentTag.c_str());
  LOGI("card      : %s, %u named tags", sdfs::mounted() ? "mounted" : "MISSING",
       (unsigned)library::tagCount());
  LOGI("reader    : %s (%s)", nfc::ready() ? "ready" : "MISSING", nfc::busName());
  LOGI("link      : %s", toylink::active() ? toylink::ssid() : "off");
  if (battery::wired()) {
    LOGI("battery   : %.2f V (%u%%)", battery::volts(), battery::percent());
  } else {
    LOGI("battery   : not wired");
  }
  LOGI("free heap : %u B", (unsigned)ESP.getFreeHeap());
}

void sleepNow(const char *reason) {
  LOGI("sleeping (%s) — press the language button to wake", reason);
  toylink::stop();
  audio::stop();
  delay(80);
  audio::shutdownAmp();
  nfc::powerDown();
  Serial.flush();

  // Hold the amplifier in shutdown while the pins are unpowered, or it wakes up
  // hissing halfway through the sleep.
  gpio_hold_en((gpio_num_t)PIN_AMP_SD);
  gpio_deep_sleep_hold_en();

  rtc_gpio_pullup_en((gpio_num_t)PIN_BTN_LANG);
  rtc_gpio_pulldown_dis((gpio_num_t)PIN_BTN_LANG);
  esp_sleep_enable_ext0_wakeup((gpio_num_t)PIN_BTN_LANG, 0);
  esp_deep_sleep_start();
}

}  // namespace app

void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println();
  LOGI("Bookie starting (reset reason %d)", (int)esp_reset_reason());

  // Release whatever the deep sleep was holding before touching the pins.
  gpio_deep_sleep_hold_dis();
  gpio_hold_dis((gpio_num_t)PIN_AMP_SD);
  // The ext0 wake leaves the button pad routed to the RTC domain; hand it back
  // to the digital GPIO matrix or digitalRead() never sees it change.
  if (esp_sleep_get_wakeup_cause() == ESP_SLEEP_WAKEUP_EXT0) {
    rtc_gpio_deinit((gpio_num_t)PIN_BTN_LANG);
  }

  settings::begin();
  buttons::begin();
  battery::begin();

  audio::begin();
  audio::setVolumeStep(settings::volumeStep());

  if (!sdfs::begin()) {
    LOGE("continuing without a card — nothing will play");
  }
  library::begin();

  g_language = settings::language();
  if (!library::hasLanguage(g_language)) {
    const String fallback = library::languages().empty() ? String(LANG_FALLBACK)
                                                         : library::languages().front();
    LOGI("stored language '%s' is not on the card, using '%s'", g_language.c_str(),
         fallback.c_str());
    g_language = fallback;
    settings::setLanguage(g_language);
  }

  nfc::begin();
  console::begin();

  app::markActivity();
  g_completions = audio::completions();
  g_nextBatteryAt = millis() + BATT_SAMPLE_MS;

  playClip(CLIP_READY);
  LOGI("ready — tap a tag, or type 'help' for the serial console");
}

void loop() {
  buttons::Event ev;
  while (buttons::poll(ev)) {
    onButton(ev);
  }

  // Reading tags while the phone is writing the card would only race the very
  // files it is replacing, and the I2C poll costs the transfer time.
  if (toylink::active()) {
    toylink::poll();
  } else {
    switch (nfc::poll(audio::busy())) {
      case nfc::Event::Arrived:
        onTagArrived(String(nfc::lastUid()));
        break;
      case nfc::Event::Departed:
        LOGD("tag lifted, letting the clip finish");
        break;
      default:
        break;
    }
  }

  const uint32_t completions = audio::completions();
  if (completions != g_completions) {
    g_completions = completions;
    onTrackFinished();
  }

  console::poll();
  checkBattery();
  checkIdleSleep();

  delay(2);  // nothing here is urgent; let the idle task feed the watchdog
}

// Bookie — tap an NFC tag on a page, hear that page read aloud. And a lamp,
// with a face.
//
//   lamp pad        : tap switches the lamp on and off, a double tap changes its
//                     colour, holding it dims (the next hold goes the other way);
//                     wakes the toy from deep sleep with the lamp on
//   face pad        : tickles the face (optional, TOUCH1)
//   play button     : pause / resume, or replay the last tag; long press stops
//
//   language button : tap cycles through the folders in /audio, announced out loud;
//                     long press pauses / resumes, or replays the last tag when idle;
//                     wakes the toy from deep sleep
//   volume buttons  : eight steps, remembered across power cycles
//   language + vol+ : link mode (hold language, then press volume up)
//
// Every button answers on the face (face.h) and the ring (light.h) as well as
// out loud with a chime (chimes.h): a
// flutter for a new language, a rising or falling blip for volume — higher
// the louder — and a low bonk when there is nowhere further to go. Link mode
// plays a rising arpeggio when it comes up, blips softly every few seconds
// until a phone joins, and plays the arpeggio backwards when it goes down.
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
#include "chimes.h"
#include "config.h"
#include "console.h"
#include "face.h"
#include "library.h"
#include "light.h"
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
bool g_linkWasActive = false;
bool g_phoneWasHere = false;
uint32_t g_nextLinkCheckAt = 0;
uint32_t g_nextPulseAt = 0;
uint32_t g_lastLampTapAt = 0;

using chimes::Chime;

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
    light::tagUnknown();
    face::react(face::Mood::Confused, 1600);
    playClip(CLIP_UNKNOWN);
    return;
  }
  // Each tag has a colour of its own, which the ring keeps for as long as its
  // story plays.
  light::tag(light::hueFor(uid.c_str()));
  face::react(face::Mood::Surprised, 650);
  g_currentTag = uid;
  g_pendingTrack = "";
  audio::play(path.c_str());
}

void onTrackFinished() {
  if (g_pendingTrack.isEmpty()) {
    face::react(face::Mood::Happy, 1300);  // the end
    return;
  }
  const String next = g_pendingTrack;
  g_pendingTrack = "";
  audio::play(next.c_str());
}

void onButton(const buttons::Event &ev) {
  app::markActivity();
  static const char *const kKinds[] = {"press", "long press", "repeat", "release"};
  LOGI("button %s: %s", buttons::name(ev.id), kKinds[(int)ev.kind]);

  // The lamp is a lamp whatever else is going on, link mode included.
  if (ev.id == buttons::Id::LampTouch) {
    if (ev.kind == buttons::Kind::Press) {
      const uint32_t now = millis();
      if (g_lastLampTapAt && now - g_lastLampTapAt < TOUCH_DOUBLE_MS) {
        // The first tap of the pair already toggled; this one undoes that
        // and moves on a colour, so the light dips and comes back changed.
        g_lastLampTapAt = 0;
        light::lampNextScene();
      } else {
        g_lastLampTapAt = now;
        light::lampToggle();
      }
    } else if (ev.kind == buttons::Kind::LongPress) {
      light::dimStart();
    } else if (ev.kind == buttons::Kind::Release) {
      light::dimStop();
    }
    return;
  }
  if (ev.id == buttons::Id::FaceTouch) {
    if (ev.kind == buttons::Kind::Press || ev.kind == buttons::Kind::LongPress) {
      face::react(face::Mood::Giggle, 1400);
      light::tickle();
    }
    return;
  }
  if (ev.kind == buttons::Kind::Release) {
    return;  // only the lamp's dimmer cares when a hold ends
  }

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

    case buttons::Id::Play:
      if (ev.kind == buttons::Kind::Press) {
        if (audio::busy()) {
          audio::togglePause();
          LOGI("%s", audio::state() == audio::State::Paused ? "paused" : "resumed");
        } else if (!g_currentTag.isEmpty()) {
          onTagArrived(g_currentTag);
        } else {
          audio::chime(Chime::Limit);
          light::limit();
        }
      } else if (ev.kind == buttons::Kind::LongPress) {
        g_pendingTrack = "";
        audio::stop();
        LOGI("stopped");
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
    light::lowBattery();
    face::react(face::Mood::Sleepy, 3000);
    if (!audio::busy()) {
      playClip(CLIP_LOWBATT);
    }
  } else if (v > BATT_WARN_V + 0.1f) {
    g_batteryWarned = false;
  }
}

// Link mode's sounds, all driven from here so they follow the mode however it
// was entered or left — the button combo, the console, the app saying it is
// done, or the idle timeout.
void checkLink() {
  const uint32_t now = millis();
  const bool active = toylink::active();
  if (active != g_linkWasActive) {
    g_linkWasActive = active;
    g_phoneWasHere = false;
    g_nextPulseAt = now + LINK_PULSE_MS;
    light::link(active ? light::Link::Waiting : light::Link::Off);
    face::link(active, false, toylink::ssid());
    if (active) {
      audio::chime(Chime::Pairing);
      // Said out loud where there is a clip for it — "did it work?" is
      // otherwise a question only the serial monitor can answer.
      playClip(CLIP_LINK);
    } else {
      audio::chime(Chime::Unpaired);
    }
    return;
  }
  if (!active || (int32_t)(now - g_nextLinkCheckAt) < 0) {
    return;
  }
  g_nextLinkCheckAt = now + LINK_CHECK_MS;

  const bool phone = toylink::phoneConnected();
  if (phone != g_phoneWasHere) {
    g_phoneWasHere = phone;
    LOGI("link: phone %s", phone ? "joined" : "left");
    light::link(phone ? light::Link::Phone : light::Link::Waiting);
    face::link(true, phone, toylink::ssid());
    if (phone) {
      audio::chime(Chime::Paired);
    }
    g_nextPulseAt = now + LINK_PULSE_MS;  // a phone that leaves gets a moment before the blip
  }
  if (!phone && !audio::busy() && (int32_t)(now - g_nextPulseAt) >= 0) {
    g_nextPulseAt = now + LINK_PULSE_MS;
    audio::chime(Chime::PairingPulse);
  }
}

void checkIdleSleep() {
  // A paused clip counts as idle; otherwise a toy left mid-story never sleeps.
  // Link mode does not: it has its own, shorter, timeout. Nor does a lamp
  // that is on: it is a lamp, and it has a timeout of its own as well.
  if (IDLE_SLEEP_MS == 0 || audio::state() == audio::State::Playing || toylink::active() ||
      light::lampIsOn()) {
    return;
  }
  if (millis() - g_lastActivityAt > IDLE_SLEEP_MS) {
    app::sleepNow("idle");
  }
}

}  // namespace

namespace app {

const String &language() { return g_language; }

void markActivity() {
  g_lastActivityAt = millis();
  face::poke();
}

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
    audio::chime(Chime::Limit);
    light::limit();
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

  String shown = code;
  shown.toUpperCase();
  face::say(shown.c_str());
  light::language(code);
  audio::chime(Chime::Language);
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
  const uint8_t was = audio::volumeStep();
  if (step == was) {
    LOGD("volume already %u/%u", step, VOLUME_MAX_STEP);  // at an end stop
    // Heard at the top; at the bottom the volume is zero and so is the bonk,
    // which is its own answer. Seen at both.
    audio::chime(Chime::Limit);
    light::volume(step, VOLUME_MAX_STEP);
    face::volume(step, VOLUME_MAX_STEP);
    return;
  }
  audio::setVolumeStep(step);
  settings::setVolumeStep(step);
  LOGI("volume %u/%u", step, VOLUME_MAX_STEP);
  light::volume(step, VOLUME_MAX_STEP);
  face::volume(step, VOLUME_MAX_STEP);
  // After the gain, so the chime is at the new volume; two semitones a step,
  // so the pitch says roughly where in the range it is as well.
  audio::chime(step > was ? Chime::VolumeUp : Chime::VolumeDown, (int8_t)(2 * (step - 1)));
}

void playTag(const String &uid) { onTagArrived(uid); }

void toggleLink() {
  if (toylink::active()) {
    toylink::stop();
    return;
  }
  // What it sounds like when it does come up is checkLink()'s job. Playing the
  // clip here, before start(), would only have it cut off by the audio::stop()
  // that start() does to make room for the radio.
  if (!toylink::start()) {
    LOGE("link: not started");
    audio::chime(Chime::Limit);
    light::limit();
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
  LOGI("lamp      : %s", light::lampIsOn() ? "on" : "off");
  if (battery::wired()) {
    LOGI("battery   : %.2f V (%u%%)", battery::volts(), battery::percent());
  } else {
    LOGI("battery   : not wired");
  }
  LOGI("free heap : %u B", (unsigned)ESP.getFreeHeap());
}

void sleepNow(const char *reason) {
  LOGI("sleeping (%s) — press the language button or touch the lamp to wake", reason);
  toylink::stop();
  audio::stop();
  face::sleep();  // eyes shut, panel off
  light::sleep();  // ring faded out, data line held low
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
  // The lamp pad too: a TTP223 drives its line high while touched, and stays
  // powered from the 3.3 V rail through the sleep.
  esp_sleep_enable_ext1_wakeup(1ULL << PIN_TOUCH_LAMP, ESP_EXT1_WAKEUP_ANY_HIGH);
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
  const esp_sleep_wakeup_cause_t woke = esp_sleep_get_wakeup_cause();
  if (woke == ESP_SLEEP_WAKEUP_EXT0) {
    rtc_gpio_deinit((gpio_num_t)PIN_BTN_LANG);
  }
  const bool wokeByLamp = woke == ESP_SLEEP_WAKEUP_EXT1;
  if (wokeByLamp) {
    rtc_gpio_deinit((gpio_num_t)PIN_TOUCH_LAMP);
  }

  settings::begin();
  // The face and the ring first: they are the toy waking up, and everything
  // after this is the toy finding its feet behind them. Woken by the lamp pad,
  // the lamp is what it was asked for.
  face::begin();
  light::begin(wokeByLamp);
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

  checkLink();  // after toylink::poll() and the buttons, either may have taken it down
  console::poll();
  checkBattery();
  checkIdleSleep();

  delay(2);  // nothing here is urgent; let the idle task feed the watchdog
}

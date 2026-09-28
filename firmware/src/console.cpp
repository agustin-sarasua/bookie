#include "console.h"

#include <Arduino.h>

#include "app.h"
#include "audio.h"
#include "battery.h"
#include "config.h"
#include "library.h"
#include "log.h"
#include "nfc.h"
#include "sdfs.h"
#include "toylink.h"

namespace console {
namespace {

char g_line[128];
size_t g_len = 0;

void help() {
  LOGI("commands:");
  LOGI("  info              status of every subsystem");
  LOGI("  ls [path]         list the card (default /)");
  LOGI("  play <path>       play one file, e.g. play /audio/en/bear.mp3");
  LOGI("  stop | pause      transport control");
  LOGI("  vol [0-%u]         read or set the volume", VOLUME_MAX_STEP);
  LOGI("  lang [code]       read or set the language");
  LOGI("  uid               wait 5 s for a tag and report what it maps to");
  LOGI("  i2c               scan the I2C bus, then probe HSU both ways round");
  LOGI("  pins              loopback test on the reader's two pins (jumper them first)");
  LOGI("  tags              reload %s", FILE_TAGS);
  LOGI("  rescan            mount the card if needed, re-read %s and the folders under %s", FILE_TAGS,
       DIR_AUDIO);
  LOGI("  btn               watch the three button pins for 8 s");
  LOGI("  bat               battery voltage");
  LOGI("  link [off]        WiFi for the phone to write the card, or hold language + vol+");
  LOGI("  sleep             deep sleep now");
}

// The three button pins, read directly. A button that is not wired, one whose
// ground has come loose, and one nobody pressed all look identical from up in
// buttons::poll() — they are all just a pin that stayed high.
void watchButtons() {
  struct Pin {
    uint8_t pin;
    const char *name;
  };
  const Pin kPins[] = {
      {PIN_BTN_LANG, "language"},
      {PIN_BTN_VOL_UP, "vol+"},
      {PIN_BTN_VOL_DN, "vol-"},
  };
  constexpr size_t kCount = sizeof(kPins) / sizeof(kPins[0]);

  bool last[kCount];
  uint16_t edges[kCount] = {0};
  LOGI("resting levels (pulled up, so HIGH until pressed):");
  for (size_t i = 0; i < kCount; i++) {
    last[i] = digitalRead(kPins[i].pin);
    LOGI("  %-8s GPIO%-2u %s", kPins[i].name, kPins[i].pin,
         last[i] ? "HIGH" : "LOW  <- held down, or shorted to GND");
  }

  LOGI("press and hold each button in turn — watching for 8 s");
  const uint32_t deadline = millis() + 8000;
  while ((int32_t)(millis() - deadline) < 0) {
    for (size_t i = 0; i < kCount; i++) {
      const bool level = digitalRead(kPins[i].pin);
      if (level == last[i]) {
        continue;
      }
      last[i] = level;
      edges[i]++;
      LOGI("  %-8s GPIO%-2u -> %s", kPins[i].name, kPins[i].pin, level ? "HIGH" : "LOW");
    }
    delay(1);
  }

  // Read below the debounce filter, so chatter shows up here as a burst of
  // edges where buttons::poll() would only ever have reported one press, or
  // none at all. That is what a loose wire looks like.
  for (size_t i = 0; i < kCount; i++) {
    if (edges[i] == 0) {
      LOGE("  %-8s GPIO%-2u never moved", kPins[i].name, kPins[i].pin);
    } else if (edges[i] > 6) {
      LOGE("  %-8s GPIO%-2u %u edges — chattering, suspect the wiring", kPins[i].name,
           kPins[i].pin, (unsigned)edges[i]);
    }
  }
}

void reportTag(const String &uid) {
  const String name = library::tagName(uid);
  LOGI("uid %s%s%s%s", uid.c_str(), name.isEmpty() ? "" : " (", name.c_str(),
       name.isEmpty() ? "" : ")");
  for (const String &lang : library::languages()) {
    const String path = library::trackFor(uid, lang);
    LOGI("  %-6s %s", lang.c_str(), path.isEmpty() ? "— no clip" : path.c_str());
  }
}

void execute(char *line) {
  char *cmd = strtok(line, " ");
  if (!cmd) {
    return;
  }
  char *arg = strtok(nullptr, "");  // rest of the line, paths may contain spaces
  if (arg) {
    while (*arg == ' ') {
      arg++;
    }
  }
  app::markActivity();

  if (!strcmp(cmd, "help") || !strcmp(cmd, "?")) {
    help();
  } else if (!strcmp(cmd, "info")) {
    app::printStatus();
  } else if (!strcmp(cmd, "ls")) {
    const char *path = (arg && *arg) ? arg : "/";
    LOGI("%s:", path);
    sdfs::listDir(path, 2);
  } else if (!strcmp(cmd, "play")) {
    if (arg && *arg) {
      audio::play(arg);
    } else {
      LOGE("usage: play /audio/en/bear.mp3");
    }
  } else if (!strcmp(cmd, "stop")) {
    audio::stop();
  } else if (!strcmp(cmd, "pause")) {
    audio::togglePause();
  } else if (!strcmp(cmd, "vol")) {
    if (arg && *arg) {
      app::setVolume((uint8_t)atoi(arg));
    }
    LOGI("volume %u/%u", audio::volumeStep(), VOLUME_MAX_STEP);
  } else if (!strcmp(cmd, "lang")) {
    if (arg && *arg) {
      app::setLanguage(String(arg));
    }
    LOGI("language %s", app::language().c_str());
  } else if (!strcmp(cmd, "uid")) {
    char uid[16] = {0};
    if (nfc::readOnce(uid, sizeof(uid), 5000)) {
      reportTag(String(uid));
    } else {
      LOGE("no tag seen");
    }
  } else if (!strcmp(cmd, "i2c")) {
    nfc::scanBus();
  } else if (!strcmp(cmd, "pins")) {
    nfc::testPins();
  } else if (!strcmp(cmd, "tags")) {
    library::reloadTags();
    LOGI("%u tags named in %s", (unsigned)library::tagCount(), FILE_TAGS);
  } else if (!strcmp(cmd, "rescan")) {
    // Language folders are read once, in library::begin(). Copying a folder
    // onto the card while the toy is running is otherwise invisible until the
    // next boot, which is a confusing way to find out nothing is wrong. The
    // same goes for a card that was not there, or did not answer, at boot.
    sdfs::begin();
    library::begin();
  } else if (!strcmp(cmd, "btn")) {
    watchButtons();
  } else if (!strcmp(cmd, "bat")) {
    if (battery::wired()) {
      LOGI("battery %.2f V (%u%%)", battery::volts(), battery::percent());
    } else {
      LOGI("battery sense not wired (PIN_BATT_SENSE in config.h)");
    }
  } else if (!strcmp(cmd, "link")) {
    if (arg && !strcmp(arg, "off")) {
      toylink::stop();
      LOGI("link off");
    } else if (toylink::active()) {
      LOGI("link already up on '%s'", toylink::ssid());
    } else {
      app::toggleLink();
    }
  } else if (!strcmp(cmd, "sleep")) {
    app::sleepNow("console");
  } else {
    LOGE("unknown command '%s', try 'help'", cmd);
  }
}

}  // namespace

void begin() { g_len = 0; }

void poll() {
  while (Serial.available()) {
    const char c = (char)Serial.read();
    if (c == '\r') {
      continue;
    }
    if (c == '\n') {
      g_line[g_len] = '\0';
      if (g_len) {
        execute(g_line);
      }
      g_len = 0;
      continue;
    }
    if (g_len + 1 < sizeof(g_line)) {
      g_line[g_len++] = c;
    }
  }
}

}  // namespace console

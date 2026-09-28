#include "buttons.h"

#include "config.h"
#include "log.h"

namespace buttons {
namespace {

constexpr size_t kCount = static_cast<size_t>(Id::Count);

struct Button {
  uint8_t pin;
  bool repeats;   // volume keys fire on the way down and again while held;
                  // the rest fire on the way up, so a long press is not also a tap
  bool stable;    // debounced level, true = pressed
  bool raw;
  uint32_t changedAt;
  uint32_t pressedAt;
  uint32_t nextRepeatAt;
  bool longFired;
};

Button g_buttons[kCount] = {
    {PIN_BTN_LANG, false, false, false, 0, 0, 0, false},
    {PIN_BTN_VOL_UP, true, false, false, 0, 0, 0, false},
    {PIN_BTN_VOL_DN, true, false, false, 0, 0, 0, false},
};

}  // namespace

void begin() {
  for (auto &b : g_buttons) {
    pinMode(b.pin, INPUT_PULLUP);
    // Start from the level the pin is at, not from "released": the press that
    // woke the toy is usually still down here, and it should not also change
    // the language (or, held, trip a long press) on the way up.
    delayMicroseconds(50);  // let the pull-up charge the line
    b.raw = b.stable = digitalRead(b.pin) == LOW;
    b.longFired = b.stable;
    b.nextRepeatAt = millis() + BTN_LONG_MS;
    b.changedAt = millis();
  }
}

bool poll(Event &out) {
  const uint32_t now = millis();

  for (size_t i = 0; i < kCount; i++) {
    Button &b = g_buttons[i];
    const bool raw = digitalRead(b.pin) == LOW;  // pulled up, button shorts to GND

    if (raw != b.raw) {
      b.raw = raw;
      b.changedAt = now;
      continue;
    }
    if (raw != b.stable && (now - b.changedAt) >= BTN_DEBOUNCE_MS) {
      b.stable = raw;
      if (raw) {
        b.pressedAt = now;
        b.longFired = false;
        b.nextRepeatAt = now + BTN_LONG_MS;
        if (b.repeats) {
          // Fire on the edge: a child gets a response the moment they press.
          out = {static_cast<Id>(i), Kind::Press};
          return true;
        }
      } else if (!b.repeats && !b.longFired) {
        // A key with a long press can only know it was a tap once it is let go.
        out = {static_cast<Id>(i), Kind::Press};
        return true;
      }
      continue;
    }

    if (!b.stable) {
      continue;
    }
    if (b.repeats && (int32_t)(now - b.nextRepeatAt) >= 0) {
      b.nextRepeatAt = now + BTN_REPEAT_MS;
      out = {static_cast<Id>(i), Kind::Repeat};
      return true;
    }
    if (!b.repeats && !b.longFired && (now - b.pressedAt) >= BTN_LONG_MS) {
      b.longFired = true;
      out = {static_cast<Id>(i), Kind::LongPress};
      return true;
    }
  }
  return false;
}

bool held(Id id) {
  const size_t i = (size_t)id;
  return i < kCount && g_buttons[i].stable;
}

void consume(Id id) {
  const size_t i = (size_t)id;
  if (i < kCount && g_buttons[i].stable) {
    g_buttons[i].longFired = true;  // no long press, and no tap on release
  }
}

const char *name(Id id) {
  switch (id) {
    case Id::Lang: return "language";
    case Id::VolUp: return "vol+";
    case Id::VolDown: return "vol-";
    default: return "?";
  }
}

}  // namespace buttons

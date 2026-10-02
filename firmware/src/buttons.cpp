#include "buttons.h"

#include "config.h"
#include "log.h"

namespace buttons {
namespace {

constexpr size_t kCount = static_cast<size_t>(Id::Count);

struct Button {
  int8_t pin;  // -1: not fitted, never pressed
  uint8_t mode;     // pinMode: the keys pull up, the touch pads drive their own line
  bool activeHigh;  // a TTP223 output is high while touched; a key shorts to GND
  uint16_t longMs;
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
    {PIN_BTN_LANG, INPUT_PULLUP, false, BTN_LONG_MS, false, false, false, 0, 0, 0, false},
    {PIN_BTN_VOL_UP, INPUT_PULLUP, false, BTN_LONG_MS, true, false, false, 0, 0, 0, false},
    {PIN_BTN_VOL_DN, INPUT_PULLUP, false, BTN_LONG_MS, true, false, false, 0, 0, 0, false},
    {PIN_BTN_PLAY, INPUT_PULLUP, false, BTN_LONG_MS, false, false, false, 0, 0, 0, false},
    // GPIO39 has no pulls to offer; the pad drives it both ways anyway.
    {PIN_TOUCH_LAMP, INPUT, true, TOUCH_HOLD_MS, false, false, false, 0, 0, 0, false},
    // Not always fitted (PIN_TOUCH_FACE is -1 then).
    {PIN_TOUCH_FACE, INPUT_PULLDOWN, true, TOUCH_HOLD_MS, false, false, false, 0, 0, 0, false},
};

bool pressedNow(const Button &b) {
  return b.pin >= 0 && (digitalRead(b.pin) == HIGH) == b.activeHigh;
}

// The pins are sampled by a task of their own, not from loop(). loop() can be
// held up for a good part of a second at a time — a tag read over HSU waits
// on the reader — and a quick tap that starts and ends inside one of those
// waits was simply never seen, which felt like buttons that only work when
// held. Here nothing blocks, and whatever is found waits in the queue until
// loop() gets to it.
QueueHandle_t g_events = nullptr;
portMUX_TYPE g_lock = portMUX_INITIALIZER_UNLOCKED;  // consume() reaches in from loop()

// Advances one button by one sample; true when that produced an event.
bool step(size_t i, uint32_t now, Event &out) {
  Button &b = g_buttons[i];
  if (b.pin < 0) {
    return false;  // not fitted
  }
  const bool raw = pressedNow(b);

  if (raw != b.raw) {
    b.raw = raw;
    b.changedAt = now;
    return false;
  }
  if (raw != b.stable && (now - b.changedAt) >= BTN_DEBOUNCE_MS) {
    b.stable = raw;
    if (raw) {
      b.pressedAt = now;
      b.longFired = false;
      b.nextRepeatAt = now + b.longMs;
      if (b.repeats) {
        // Fire on the edge: a child gets a response the moment they press.
        out = {static_cast<Id>(i), Kind::Press};
        return true;
      }
    } else if (!b.repeats && !b.longFired) {
      // A key with a long press can only know it was a tap once it is let go.
      out = {static_cast<Id>(i), Kind::Press};
      return true;
    } else if (!b.repeats && b.longFired && b.pressedAt) {
      out = {static_cast<Id>(i), Kind::Release};
      return true;
    }
    return false;
  }

  if (!b.stable) {
    return false;
  }
  if (b.repeats && (int32_t)(now - b.nextRepeatAt) >= 0) {
    b.nextRepeatAt = now + BTN_REPEAT_MS;
    out = {static_cast<Id>(i), Kind::Repeat};
    return true;
  }
  if (!b.repeats && !b.longFired && (now - b.pressedAt) >= b.longMs) {
    b.longFired = true;
    out = {static_cast<Id>(i), Kind::LongPress};
    return true;
  }
  return false;
}

void scanTask(void *) {
  TickType_t wake = xTaskGetTickCount();
  for (;;) {
    Event found[kCount];
    size_t n = 0;
    const uint32_t now = millis();
    portENTER_CRITICAL(&g_lock);
    for (size_t i = 0; i < kCount; i++) {
      if (step(i, now, found[n])) {
        n++;
      }
    }
    portEXIT_CRITICAL(&g_lock);
    for (size_t i = 0; i < n; i++) {
      if (xQueueSend(g_events, &found[i], 0) != pdTRUE) {
        LOGE("button queue full, %s dropped", name(found[i].id));
      }
    }
    vTaskDelayUntil(&wake, pdMS_TO_TICKS(BTN_SCAN_MS));
  }
}

}  // namespace

void begin() {
  for (auto &b : g_buttons) {
    if (b.pin >= 0) {
      pinMode(b.pin, b.mode);
    }
    // Start from the level the pin is at, not from "released": the press that
    // woke the toy is usually still down here, and it should not also change
    // the language (or, held, trip a long press) on the way up.
    delayMicroseconds(50);  // let the pull-up charge the line
    b.raw = b.stable = pressedNow(b);
    b.longFired = b.stable;
    b.pressedAt = 0;  // a hold left over from the wake has no Release to send
    b.nextRepeatAt = millis() + b.longMs;
    b.changedAt = millis();
  }

  g_events = xQueueCreate(16, sizeof(Event));
  // Core 1 with loop(), one priority above it, so it preempts a loop() that is
  // busy-waiting on the reader. It runs for microseconds every few ms.
  if (!g_events || xTaskCreatePinnedToCore(scanTask, "buttons", 3072, nullptr, 2, nullptr, 1) != pdPASS) {
    LOGE("cannot start the button task");
  }
}

bool poll(Event &out) { return g_events && xQueueReceive(g_events, &out, 0) == pdTRUE; }

bool held(Id id) {
  const size_t i = (size_t)id;
  return i < kCount && g_buttons[i].stable;
}

void consume(Id id) {
  const size_t i = (size_t)id;
  portENTER_CRITICAL(&g_lock);
  if (i < kCount && g_buttons[i].stable) {
    g_buttons[i].longFired = true;  // no long press, and no tap on release
  }
  portEXIT_CRITICAL(&g_lock);
}

const char *name(Id id) {
  switch (id) {
    case Id::Lang: return "language";
    case Id::VolUp: return "vol+";
    case Id::VolDown: return "vol-";
    case Id::Play: return "play";
    case Id::LampTouch: return "lamp pad";
    case Id::FaceTouch: return "face pad";
    default: return "?";
  }
}

}  // namespace buttons

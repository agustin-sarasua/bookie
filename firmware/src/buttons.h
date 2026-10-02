// Four INPUT_PULLUP buttons and two TTP223 touch pads, debounced, with long
// press and volume auto-repeat. Sampled by their own task every BTN_SCAN_MS;
// poll() drains what it found.
#pragma once

#include <Arduino.h>

namespace buttons {

enum class Id : uint8_t { Lang, VolUp, VolDown, Play, LampTouch, FaceTouch, Count };

// Press is a tap, reported on release for everything but the volume keys.
// Release follows a LongPress when the finger lifts, so a hold can steer
// something for as long as it lasts (the lamp's dimmer).
enum class Kind : uint8_t { Press, LongPress, Repeat, Release };

struct Event {
  Id id;
  Kind kind;
};

void begin();
bool poll(Event &out);
const char *name(Id id);

// Debounced state, for the one place a combination matters: holding language
// while volume up is pressed. Events alone cannot say what is still down.
bool held(Id id);

// The held button was part of a combination: swallow the rest of its press, so
// letting go of it is not also a tap and holding on is not also a long press.
void consume(Id id);

}  // namespace buttons

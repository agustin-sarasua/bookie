// The OLED face: two big eyes and a mouth, animated by a task of their own.
//
// It is alive on its own — it blinks, glances about, gets drowsy when nobody
// has played with it for a while and eventually shuts its eyes and turns the
// panel off (an OLED showing the same face all night burns it in). Any button,
// touch or tag wakes it.
//
// While a story plays the mouth follows the voice, using the same level the
// ring dances to, delayed to match the speaker, so the two are in step.
//
// Like light.h, every call only queues a request and returns at once, except
// sleep(), which waits for the eyes to close.
#pragma once

#include <Arduino.h>

namespace face {

bool begin();  // false if no panel answered; everything else is then a no-op

enum class Mood : uint8_t {
  Happy,      // ^ ^ and a grin
  Surprised,  // a tag just landed
  Confused,   // ...and nobody knows it
  Giggle,     // tickled
  Sleepy,     // low battery
};
void react(Mood mood, uint32_t ms = 900);

// Shown where the mouth is, for a moment: a language code, say.
void say(const char *text, uint32_t ms = 1400);
void volume(uint8_t step, uint8_t max);

// Link mode: the network name under the eyes until it is over.
void link(bool on, bool phone, const char *ssid);

// Something happened: wake up if dozing, and start the doze clock again.
void poke();

// Eyes closed, panel off. Waits for the animation.
void sleep();

}  // namespace face

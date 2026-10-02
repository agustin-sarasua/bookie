// The WS2812B ring: a bedside lamp first, and the toy's mood light second.
//
// Three layers, mixed every frame by a task of their own (~60 fps):
//
//   lamp     whatever the touch pad asked for — one of a few scenes, at a
//            brightness the pad's hold dims, faded in and out
//   story    while a story plays, the ring breathes with the voice in the
//            colour of the tag that started it; with the lamp off it glows
//            softly on its own, with the lamp on it rides on top of it
//   effects  short one-offs layered over both: waking up, a tag arriving,
//            a tag nobody knows, volume, language, link mode, sleep
//
// Every call here only queues a request, so all of them are safe from loop()
// and return at once — except sleep(), which waits for the fade to finish.
#pragma once

#include <Arduino.h>

namespace light {

void begin(bool lampOn);  // also plays the wake-up sweep

// ---- lamp, driven by the touch pad
void lampToggle();
void lampOn();
void lampNextScene();  // also switches the lamp on
void dimStart();       // finger down and held: sweep the brightness...
void dimStop();        // ...until it lifts, then remember it
bool lampIsOn();

// ---- effects
void tag(uint16_t hue);  // a known tag: a burst in its colour, which the story keeps
void tagUnknown();
void volume(uint8_t step, uint8_t max);
void language(const String &code);
void limit();            // nothing to do: an end stop, a failure
void tickle();
void lowBattery();
enum class Link : uint8_t { Off, Waiting, Phone };
void link(Link state);

// Fades everything out and leaves the data line held low, so the ring stays
// dark through deep sleep (it is powered straight from the cell).
void sleep();

// A stable, pleasant colour for a string, e.g. a tag UID or a language code.
uint16_t hueFor(const char *text);

}  // namespace light

// The toy's wordless vocabulary: short tones synthesised on the spot.
//
// The toy has no screen, so the speaker is the only way it can say "I heard
// you". Spoken /system clips do that job where the card has them; these do it
// always — with a blank card, in any language, and in link mode, when the card
// belongs to the phone. Each one has its own shape, so they can be told apart
// without looking:
//
//   Pairing       rising arpeggio   link mode is up, waiting for the phone
//   PairingPulse  soft double blip  ...still waiting (repeats, see LINK_PULSE_MS)
//   Paired        short "ta-da"     the phone joined the toy's network
//   Unpaired      falling arpeggio  link mode is down again
//   Language      up-down flutter   language changed
//   VolumeUp      rising two notes  pitched higher the louder it gets
//   VolumeDown    falling two notes ...and lower the quieter
//   Limit         low double bonk   nothing to do: end stop, one language, failure
#pragma once

#include <Arduino.h>

namespace chimes {

enum class Chime : uint8_t {
  Pairing,
  PairingPulse,
  Paired,
  Unpaired,
  Language,
  VolumeUp,
  VolumeDown,
  Limit,
};

struct Note {
  uint16_t hz;  // 0 is a rest
  uint16_t ms;
};

struct Tune {
  const Note *notes;
  uint8_t count;
  int16_t level;  // peak amplitude before the volume gain, out of 32767
};

Tune tune(Chime which);

}  // namespace chimes

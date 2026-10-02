#include "chimes.h"

namespace chimes {
namespace {

// Pitches from the C major scale, kept above ~500 Hz: a toy speaker gives
// back very little below that.
constexpr uint16_t C5 = 523, E5 = 659, G5 = 784, A5 = 880;
constexpr uint16_t C6 = 1047, D6 = 1175, E6 = 1319;
constexpr uint16_t G4 = 392;  // the bonk: low for this speaker, still audible

constexpr Note kPairing[] = {{C5, 110}, {E5, 110}, {G5, 110}, {C6, 320}};
constexpr Note kPulse[] = {{E6, 60}, {0, 70}, {E6, 60}};
constexpr Note kPaired[] = {{G5, 90}, {C6, 260}};
constexpr Note kUnpaired[] = {{C6, 110}, {G5, 110}, {E5, 110}, {C5, 320}};
constexpr Note kLanguage[] = {{A5, 90}, {D6, 90}, {A5, 180}};
// Volume is transposed by the caller with the step, so these are the pitch at
// the bottom of the range.
constexpr Note kVolumeUp[] = {{C5, 60}, {G5, 110}};
constexpr Note kVolumeDown[] = {{G5, 60}, {C5, 110}};
constexpr Note kLimit[] = {{G4, 90}, {0, 50}, {G4, 90}};

template <size_t N>
constexpr Tune make(const Note (&notes)[N], int16_t level) {
  return {notes, (uint8_t)N, level};
}

}  // namespace

Tune tune(Chime which) {
  switch (which) {
    case Chime::Pairing: return make(kPairing, 14000);
    case Chime::PairingPulse: return make(kPulse, 7000);  // repeats, so it whispers
    case Chime::Paired: return make(kPaired, 14000);
    case Chime::Unpaired: return make(kUnpaired, 14000);
    case Chime::Language: return make(kLanguage, 14000);
    case Chime::VolumeUp: return make(kVolumeUp, 12000);
    case Chime::VolumeDown: return make(kVolumeDown, 12000);
    case Chime::Limit: return make(kLimit, 14000);
  }
  return {nullptr, 0, 0};
}

}  // namespace chimes

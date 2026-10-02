// Turns audio::level() into something worth animating: normalised against the
// recent peak, so a quiet recording moves the face as much as a loud one, and
// shaped with a quick attack and a slower release, so it moves like a voice
// rather than flickering like a meter.
#pragma once

#include <Arduino.h>

class Envelope {
 public:
  // Call once a frame with the raw level and the frame length.
  void update(float raw, float dtMs) {
    // The peak creeps down over a few seconds, and never below a floor, or
    // silence with a little hiss would be stretched to look like shouting.
    peak_ = fmaxf(raw, peak_ * powf(0.5f, dtMs / 2500.0f));
    peak_ = fmaxf(peak_, 0.06f);
    float norm = fminf(raw / peak_, 1.0f);
    norm = norm < 0.08f ? 0.0f : norm;  // breaths and hiss between words read as shut

    const float attack = 1.0f - powf(0.5f, dtMs / 18.0f);
    const float release = 1.0f - powf(0.5f, dtMs / 90.0f);
    value_ += (norm - value_) * (norm > value_ ? attack : release);

    // A syllable: a jump well above the recent average, and not straight
    // after the last one.
    slow_ += (value_ - slow_) * (1.0f - powf(0.5f, dtMs / 250.0f));
    sinceOnset_ += dtMs;
    onset_ = false;
    if (value_ - slow_ > 0.22f && sinceOnset_ > 140.0f) {
      onset_ = true;
      sinceOnset_ = 0.0f;
    }
  }

  float value() const { return value_; }  // 0..1
  bool onset() const { return onset_; }   // true for one frame per syllable
  void reset() { value_ = slow_ = 0.0f; }

 private:
  float peak_ = 0.2f;
  float value_ = 0.0f;
  float slow_ = 0.0f;
  float sinceOnset_ = 0.0f;
  bool onset_ = false;
};

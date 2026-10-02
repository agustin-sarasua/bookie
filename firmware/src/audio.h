// Playback engine: owns the I2S output, the decoder and the amplifier enable pin.
//
// Everything here is safe to call from the main loop. The decoding itself runs in
// its own FreeRTOS task, so a slow NFC read can never starve the I2S DMA.
#pragma once

#include <Arduino.h>

#include "chimes.h"

namespace audio {

enum class State : uint8_t { Idle, Playing, Paused };

bool begin();

// Starts `path` (.wav or .mp3), replacing whatever was playing.
void play(const char *path);
void stop();
void pause();
void resume();
void togglePause();

State state();
bool busy();  // playing or paused

// Bumped once every time a track ends by itself (or fails to start), so the
// caller can chain clips without polling for a specific file name.
uint32_t completions();

// Plays one of the synthesised tones in chimes.h, at the current volume. It
// slots in between whatever else is queued: a story that is playing stops for
// the length of the chime and carries on, and a paused one stays paused.
// `transpose` shifts it by that many semitones. Chimes do not count as
// completions, and do not make busy() true.
void chime(chimes::Chime which, int8_t transpose = 0);

void setVolumeStep(uint8_t step);
uint8_t volumeStep();

const char *currentPath();

// How loud the speaker is right now, 0..1, before the volume gain — so the
// face talks at any volume. Delayed to match what is actually being heard.
// Chimes count: the face sings along.
float level();

// Silences the amplifier immediately; used before deep sleep.
void shutdownAmp();

}  // namespace audio

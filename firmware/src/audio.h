// Playback engine: owns the I2S output, the decoder and the amplifier enable pin.
//
// Everything here is safe to call from the main loop. The decoding itself runs in
// its own FreeRTOS task, so a slow NFC read can never starve the I2S DMA.
#pragma once

#include <Arduino.h>

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

void setVolumeStep(uint8_t step);
uint8_t volumeStep();

const char *currentPath();

// Silences the amplifier immediately; used before deep sleep.
void shutdownAmp();

}  // namespace audio

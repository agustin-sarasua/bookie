// Language, volume and the lamp survive a power cycle.
#pragma once

#include <Arduino.h>

namespace settings {

void begin();

String language();
void setLanguage(const String &code);

uint8_t volumeStep();
void setVolumeStep(uint8_t step);

// The lamp's colour scene and brightness (0..1), as the touch pad left them.
void lamp(uint8_t &scene, float &level);
void setLamp(uint8_t scene, float level);

}  // namespace settings

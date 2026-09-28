// Language and volume survive a power cycle.
#pragma once

#include <Arduino.h>

namespace settings {

void begin();

String language();
void setLanguage(const String &code);

uint8_t volumeStep();
void setVolumeStep(uint8_t step);

}  // namespace settings

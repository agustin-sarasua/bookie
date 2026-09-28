// Actions the state machine in main.cpp exposes to the serial console.
#pragma once

#include <Arduino.h>

namespace app {

const String &language();
void setLanguage(const String &code);
void cycleLanguage();
void setVolume(uint8_t step);
void playTag(const String &uid);
void printStatus();
void toggleLink();
void sleepNow(const char *reason);
void markActivity();

}  // namespace app

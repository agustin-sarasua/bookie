// Battery voltage from a 100k/100k divider on PIN_BATT_SENSE, when there is one.
#pragma once

#include <Arduino.h>

namespace battery {

void begin();
bool wired();      // false when PIN_BATT_SENSE is -1: every reading below is 0
float volts();     // smoothed
uint8_t percent(); // rough LiPo discharge curve

}  // namespace battery

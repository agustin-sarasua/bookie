// The one I2C bus, shared by the reader and the face.
//
// Wire serialises single transactions on its own, which is all the reader's
// steady-state polling needs. What it does not cover is the reader taking the
// bus apart: its probe and recovery paths end Wire, drive the pins by hand and
// start it again, and a display frame caught halfway through that writes into
// a freed buffer. Anything that does either holds a Guard for the duration.
#pragma once

#include <Arduino.h>

namespace i2cbus {

// Starts Wire on the shared pins at I2C_BUS_HZ. Safe to call again.
void begin();

// Wire back up if someone ended it. Call while holding a Guard.
void ensureStarted();

class Guard {
 public:
  Guard();
  ~Guard();
  Guard(const Guard &) = delete;
  Guard &operator=(const Guard &) = delete;
};

}  // namespace i2cbus

// SD card mount plus the lock that serialises it between the app and the audio task.
#pragma once

#include <Arduino.h>

namespace sdfs {

bool begin();
bool mounted();

// Both the audio task and the main loop touch the card, and they share one SPI bus.
void lock();
void unlock();

struct Guard {
  Guard() { lock(); }
  ~Guard() { unlock(); }
  Guard(const Guard &) = delete;
  Guard &operator=(const Guard &) = delete;
};

bool exists(const char *path);
void listDir(const char *path, uint8_t levels = 1);

}  // namespace sdfs

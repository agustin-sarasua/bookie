#include "i2cbus.h"

#include <Wire.h>
#include <esp32-hal-i2c.h>

#include "config.h"

namespace i2cbus {
namespace {

SemaphoreHandle_t g_mutex = nullptr;

SemaphoreHandle_t mutex() {
  if (!g_mutex) {
    g_mutex = xSemaphoreCreateRecursiveMutex();
  }
  return g_mutex;
}

}  // namespace

void begin() {
  mutex();
  Guard guard;
  ensureStarted();
}

void ensureStarted() {
  if (!i2cIsInit(0)) {
    Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL, I2C_BUS_HZ);
    Wire.setTimeOut(50);
  }
}

Guard::Guard() { xSemaphoreTakeRecursive(mutex(), portMAX_DELAY); }

Guard::~Guard() { xSemaphoreGiveRecursive(g_mutex); }

}  // namespace i2cbus

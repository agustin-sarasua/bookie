#include "sdfs.h"

#include <SD.h>
#include <SPI.h>

#include "config.h"
#include "log.h"

namespace sdfs {
namespace {

SemaphoreHandle_t g_lock = nullptr;
bool g_mounted = false;

}  // namespace

bool begin() {
  if (!g_lock) {
    g_lock = xSemaphoreCreateRecursiveMutex();
  }
  Guard guard;

  if (g_mounted) {
    return true;
  }

  SPI.begin(PIN_SD_SCK, PIN_SD_MISO, PIN_SD_MOSI, PIN_SD_CS);

  g_mounted = SD.begin(PIN_SD_CS, SPI, SD_SPI_HZ);
  if (!g_mounted) {
    LOGE("SD mount failed at %u MHz, retrying slower", SD_SPI_HZ / 1000000);
    g_mounted = SD.begin(PIN_SD_CS, SPI, SD_SPI_HZ_SLOW);
  }
  if (!g_mounted) {
    LOGE("SD card not found (check CS on GPIO%d and the 3V3 mod on the breakout)", PIN_SD_CS);
    return false;
  }

  LOGI("SD mounted, %llu MB, type %d", SD.cardSize() / (1024ULL * 1024ULL), (int)SD.cardType());
  return true;
}

bool mounted() { return g_mounted; }

void lock() {
  if (g_lock) {
    xSemaphoreTakeRecursive(g_lock, portMAX_DELAY);
  }
}

void unlock() {
  if (g_lock) {
    xSemaphoreGiveRecursive(g_lock);
  }
}

bool exists(const char *path) {
  if (!g_mounted) {
    return false;
  }
  Guard guard;
  return SD.exists(path);
}

void listDir(const char *path, uint8_t levels) {
  if (!g_mounted) {
    LOGE("no card mounted");
    return;
  }
  Guard guard;
  File dir = SD.open(path);
  if (!dir || !dir.isDirectory()) {
    LOGE("%s is not a directory", path);
    return;
  }
  for (File entry = dir.openNextFile(); entry; entry = dir.openNextFile()) {
    if (entry.isDirectory()) {
      LOGI("  %-40s <dir>", entry.path());
      if (levels > 1) {
        listDir(entry.path(), levels - 1);
      }
    } else {
      LOGI("  %-40s %8u B", entry.path(), (unsigned)entry.size());
    }
    entry.close();
  }
  dir.close();
}

}  // namespace sdfs

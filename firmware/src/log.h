// Tiny printf-style logging over the USB serial port.
#pragma once

#include <Arduino.h>

#ifndef BOOKIE_LOG_DEBUG
#define BOOKIE_LOG_DEBUG 0
#endif

#define LOGI(fmt, ...) Serial.printf("[%7lu] " fmt "\r\n", millis(), ##__VA_ARGS__)
#define LOGE(fmt, ...) Serial.printf("[%7lu] ERR  " fmt "\r\n", millis(), ##__VA_ARGS__)

#if BOOKIE_LOG_DEBUG
#define LOGD(fmt, ...) Serial.printf("[%7lu] dbg  " fmt "\r\n", millis(), ##__VA_ARGS__)
#else
#define LOGD(fmt, ...) do {} while (0)
#endif

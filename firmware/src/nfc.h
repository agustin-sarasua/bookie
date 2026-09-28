// PN532 over I2C: reports tags arriving and leaving, and survives a wedged reader.
#pragma once

#include <Arduino.h>

namespace nfc {

enum class Event : uint8_t { None, Arrived, Departed };

bool begin();
bool ready();

// "I2C", "HSU", or "none" — which interface the reader actually answered on.
const char *busName();

// Call often. `busy` slows the polling down while a story is playing.
Event poll(bool busy);

// UID of the tag the last Arrived event referred to, e.g. "04A224AA5C6180".
const char *lastUid();

// Blocking helper for the serial console.
bool readOnce(char *uidOut, size_t len, uint32_t timeoutMs);

void powerDown();

// Every address that answers on the I2C bus, printed. The one diagnostic that
// separates "the reader is in the wrong mode" from "the reader is not wired".
void scanBus();

// Drive each of the reader's two pins and read it back on the other, with a
// jumper between them: the one test that tells the board apart from the module.
void testPins();

}  // namespace nfc

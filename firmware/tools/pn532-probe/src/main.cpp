// PN532 on a bare ESP32, in isolation. One bus, chosen at build time, and
// nothing else running that could be blamed for the result.
//
// Build one of:  pio run -e spi    (recommended)
//                pio run -e hsu
//                pio run -e i2c    (expected to fail — see below)
//
// The module's DIP switches have to agree with the build:
//
//   SPI   switch 1 OFF, switch 2 ON
//   HSU   both OFF        (the factory default)
//   I2C   switch 1 ON,  switch 2 OFF
//
// Power-cycle the module after changing them. A PN532 only reads its mode
// switches at power-on, and it wedges easily enough without being asked to
// change bus underneath itself.

#include <Adafruit_PN532.h>
#include <Arduino.h>
#include <SPI.h>
#include <Wire.h>

#define BUS_SPI 0
#define BUS_HSU 1
#define BUS_I2C 2
#ifndef PN532_PROBE_BUS
#define PN532_PROBE_BUS BUS_SPI
#endif

namespace {

// ---- SPI (VSPI, the ESP32 defaults) ----
constexpr uint8_t PIN_SPI_SCK  = 18;
constexpr uint8_t PIN_SPI_MISO = 19;
constexpr uint8_t PIN_SPI_MOSI = 23;
constexpr uint8_t PIN_SPI_SS   = 5;

// ---- HSU (UART2's own pins, which is what the library reopens) ----
constexpr uint8_t PIN_HSU_RX = 16;  // <- the module's TX
constexpr uint8_t PIN_HSU_TX = 17;  // -> the module's RX

// ---- I2C (the ESP32 defaults; nothing else is on this bus) ----
constexpr uint8_t PIN_I2C_SDA = 21;
constexpr uint8_t PIN_I2C_SCL = 22;

// The module's RSTO pin, wired to a spare GPIO. Optional, but the one thing
// that turns "unplug it and try again" into something the firmware can do by
// itself — and this module has already proved it can wedge hard enough to need
// it. Set to 255 if you leave RSTO unconnected.
constexpr uint8_t PIN_RSTO = 27;

#if PN532_PROBE_BUS == BUS_SPI
Adafruit_PN532 g_nfc(PIN_SPI_SS, &SPI);
const char *kBusName = "SPI";
#elif PN532_PROBE_BUS == BUS_HSU
Adafruit_PN532 g_nfc(255, &Serial2);
const char *kBusName = "HSU";
// Which of the module's two pins transmits is a property of the board, and the
// labels are not to be trusted. Both are tried, in this order.
struct Wiring {
  uint8_t rx;
  uint8_t tx;
  const char *name;
};
const Wiring kWirings[] = {
    {PIN_HSU_RX, PIN_HSU_TX, "module TXD on GPIO16"},
    {PIN_HSU_TX, PIN_HSU_RX, "module TXD on GPIO17"},
};
#else
Adafruit_PN532 g_nfc(255, 255, &Wire);
const char *kBusName = "I2C";
#endif

#if PN532_PROBE_BUS == BUS_HSU
// A readPassiveTargetID() that times out has not cancelled anything: its answer
// is still on its way, and it lands in the UART buffer a few milliseconds after
// we stopped listening. One leftover byte puts every reply after it out of step
// — the next command reads the previous command's response — which is why
// getFirmwareVersion() fails five seconds later on a reader that is perfectly
// healthy. Discard whatever the line is still holding before asking anything.
void drainHsu() {
  const uint32_t deadline = millis() + 40;
  uint32_t lastByteAt = millis();
  while ((int32_t)(millis() - deadline) < 0) {
    if (Serial2.available()) {
      Serial2.read();
      lastByteAt = millis();
    } else if (millis() - lastByteAt > 5) {
      return;  // quiet long enough to call it finished
    } else {
      delay(1);
    }
  }
}
#else
void drainHsu() {}
#endif

uint32_t g_reads = 0;
uint32_t g_nextHealthAt = 0;
bool g_up = false;

void printWiring() {
  Serial.println();
#if PN532_PROBE_BUS == BUS_SPI
  Serial.println("  DIP switches: 1 OFF, 2 ON");
  Serial.println();
  Serial.println("  PN532      ESP32");
  Serial.println("  VCC    ->  3V3        (5V only if your board has a regulator)");
  Serial.println("  GND    ->  GND");
  Serial.printf("  SCK    ->  GPIO %u\n", PIN_SPI_SCK);
  Serial.printf("  MISO   ->  GPIO %u\n", PIN_SPI_MISO);
  Serial.printf("  MOSI   ->  GPIO %u\n", PIN_SPI_MOSI);
  Serial.printf("  SS/NSS ->  GPIO %u\n", PIN_SPI_SS);
#elif PN532_PROBE_BUS == BUS_HSU
  Serial.println("  DIP switches: both OFF");
  Serial.println();
  Serial.println("  PN532      ESP32");
  Serial.println("  VCC    ->  3V3");
  Serial.println("  GND    ->  GND");
  Serial.printf("  TXD    ->  GPIO %u   (our RX — the wires cross)\n", PIN_HSU_RX);
  Serial.printf("  RXD    ->  GPIO %u   (our TX)\n", PIN_HSU_TX);
  Serial.println();
  Serial.println("  ... or the other way round. Both are tried, so either wiring");
  Serial.println("  works and the probe reports which one answered.");
  if (PIN_RSTO == 255) {
    Serial.println();
    Serial.println("  WARNING: RSTO is not wired. Trying the wrong orientation leaves");
    Serial.println("  the module wedged, and without RSTO only a power cycle clears it.");
  }
#else
  Serial.println("  DIP switches: 1 ON, 2 OFF");
  Serial.println();
  Serial.println("  PN532      ESP32");
  Serial.println("  VCC    ->  3V3");
  Serial.println("  GND    ->  GND");
  Serial.printf("  SDA    ->  GPIO %u\n", PIN_I2C_SDA);
  Serial.printf("  SCL    ->  GPIO %u\n", PIN_I2C_SCL);
#endif
  if (PIN_RSTO != 255) {
    Serial.printf("  RSTO   ->  GPIO %u   (optional, lets us reset a wedged module)\n",
                  PIN_RSTO);
  }
  Serial.println("  IRQ        unconnected");
  Serial.println();
}

// RSTO is active low. The datasheet wants the line held for a moment and then
// a settling period before the chip will talk — it is coming out of reset into
// LowVbat, which is slower than a bus is usually willing to wait.
void hardReset() {
  if (PIN_RSTO == 255) {
    return;
  }
  pinMode(PIN_RSTO, OUTPUT);
  digitalWrite(PIN_RSTO, LOW);
  delay(20);
  digitalWrite(PIN_RSTO, HIGH);
  delay(100);
}

// Open whatever bus is already configured and see who is on it.
bool identify(const char *how) {
  g_nfc.begin();

  const uint32_t version = g_nfc.getFirmwareVersion();
  if (!version) {
    Serial.printf("  no answer (%s)\n", how);
    return false;
  }
  Serial.printf("PN532 firmware %d.%d over %s, %s  (chip 0x%02X)\n",
                (int)((version >> 16) & 0xFF), (int)((version >> 8) & 0xFF), kBusName, how,
                (int)((version >> 24) & 0xFF));

  // The step that fails over I2C on this chip. Over SPI the master owns the
  // clock outright, so there is nothing for the module to stretch and nothing
  // for the ESP32 to time out on.
  Serial.print("SAMConfig ... ");
  if (!g_nfc.SAMConfig()) {
    Serial.println("REFUSED");
#if PN532_PROBE_BUS == BUS_I2C
    Serial.println();
    Serial.println("Expected. The PN532 clock-stretches through SAMConfig for longer");
    Serial.println("than the ESP32's I2C peripheral can be asked to wait (~13 ms is the");
    Serial.println("hardware maximum), so every readiness poll times out. Build -e spi.");
#endif
    return false;
  }
  Serial.println("accepted");

  // One retry per read. A miss has to come back quickly or polling stalls.
  g_nfc.setPassiveActivationRetries(0x01);
  return true;
}

bool bringUp() {
#if PN532_PROBE_BUS == BUS_SPI
  hardReset();
  SPI.begin(PIN_SPI_SCK, PIN_SPI_MISO, PIN_SPI_MOSI, PIN_SPI_SS);
  return identify("VSPI");

#elif PN532_PROBE_BUS == BUS_HSU
  // Try it both ways round rather than making anyone read a silkscreen that
  // may be wrong. This is only safe because RSTO lets us reset the module
  // between attempts: probing the wrong orientation drives our TX into the
  // module's TX, and two push-pull outputs arguing leaves it unwilling to talk
  // to anyone until it has been reset.
  for (const Wiring &wiring : kWirings) {
    hardReset();
    Serial2.end();
    Serial2.begin(115200, SERIAL_8N1, wiring.rx, wiring.tx);
    Serial.printf("trying %s ...\n", wiring.name);
    if (identify(wiring.name)) {
      return true;
    }
  }
  return false;

#else
  hardReset();
  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL, 100000);
  return identify("I2C");
#endif
}

}  // namespace

void setup() {
  Serial.begin(115200);
  delay(300);  // the USB-serial chip needs a moment or the first lines are lost

  Serial.println();
  Serial.printf("=== PN532 probe (%s) ===\n", kBusName);
  printWiring();

  g_up = bringUp();
  if (!g_up) {
    Serial.println();
    Serial.println("In order of likelihood:");
    Serial.println("  - DIP switches do not match this build (see the header above)");
    Serial.println("  - not power-cycled since the switches were last moved");
    Serial.println("  - VCC or GND not actually landing on the module");
    Serial.println("  - a wire on the wrong pin");
    Serial.println();
    Serial.println("Retrying every 3 s — fix the wiring and it will find it.");
    return;
  }

  Serial.println();
  Serial.println("ready — hold a tag against the antenna");
  g_nextHealthAt = millis() + 5000;
}

void loop() {
  if (!g_up) {
    delay(3000);
    g_up = bringUp();
    if (g_up) {
      Serial.println("ready — hold a tag against the antenna");
      g_nextHealthAt = millis() + 5000;
    }
    return;
  }

  // An empty read and a dead reader look identical from up here, so ask the
  // module who it is now and then. This is the check that would have told us
  // the last module had wedged rather than simply seen no tag.
  if ((int32_t)(millis() - g_nextHealthAt) >= 0) {
    g_nextHealthAt = millis() + 5000;
    drainHsu();
    if (!g_nfc.getFirmwareVersion()) {
      Serial.println("reader stopped answering — resetting");
      g_up = bringUp();
      return;
    }
  }

  uint8_t uid[7] = {0};
  uint8_t uidLen = 0;
  drainHsu();
  // 150 ms rather than 60: long enough that the module's answer usually lands
  // inside the call that asked for it, which is cheaper than resynchronising.
  if (g_nfc.readPassiveTargetID(PN532_MIFARE_ISO14443A, uid, &uidLen, 150) && uidLen) {
    char hex[15];
    size_t n = 0;
    for (uint8_t i = 0; i < uidLen && n + 3 <= sizeof(hex); i++) {
      n += snprintf(hex + n, sizeof(hex) - n, "%02X", uid[i]);
    }
    hex[n] = '\0';
    g_reads++;
    Serial.printf("[%5u] tag %s  (%u bytes)\n", g_reads, hex, (unsigned)uidLen);
  }
  delay(80);
}

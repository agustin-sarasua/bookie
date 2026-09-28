// RC522 on a bare ESP32, in isolation.
//
// Wiring (VSPI, the default pins every RC522 example assumes):
//
//   RC522        ESP32 WROOM-32D
//   ---------    ---------------
//   3.3V     ->  3V3      <- NOT 5V. The MFRC522 is a 3.3 V part.
//   GND      ->  GND
//   SDA/SS   ->  GPIO 5
//   SCK      ->  GPIO 18
//   MOSI     ->  GPIO 23
//   MISO     ->  GPIO 19
//   RST      ->  GPIO 22
//   IRQ          leave unconnected
//
// The only pin whose name lies is SDA: on an RC522 it is the SPI chip select,
// nothing to do with I2C.

#include <Arduino.h>
#include <MFRC522.h>
#include <SPI.h>

namespace {

constexpr uint8_t PIN_SS   = 5;
constexpr uint8_t PIN_RST  = 22;
constexpr uint8_t PIN_SCK  = 18;
constexpr uint8_t PIN_MISO = 19;
constexpr uint8_t PIN_MOSI = 23;

MFRC522 g_rfid(PIN_SS, PIN_RST);  // SPI clock is set by MFRC522_SPICLOCK

uint32_t g_nextHealthAt = 0;
uint32_t g_reads = 0;
char g_lastUid[21] = {0};

// What the version register means. A genuine NXP part answers 0x91 or 0x92;
// the Fudan FM17522 that a lot of "RC522" boards actually carry answers 0x88
// and works fine. 0x00 and 0xFF are not chips at all — they are what MISO
// reads when it is stuck low or stuck high, i.e. a wiring fault.
const char *versionName(uint8_t version) {
  switch (version) {
    case 0x88: return "FM17522 clone (fine, very common)";
    case 0x90: return "MFRC522 v0.0";
    case 0x91: return "MFRC522 v1.0";
    case 0x92: return "MFRC522 v2.0";
    case 0x12: return "counterfeit";
    case 0x00: return "NOTHING — MISO stuck low";
    case 0xFF: return "NOTHING — MISO stuck high / floating";
    default:   return "unknown silicon";
  }
}

bool versionIsReal(uint8_t version) {
  return version != 0x00 && version != 0xFF;
}

void printWiring() {
  Serial.println();
  Serial.println("  RC522      ESP32");
  Serial.println("  3.3V   ->  3V3   (NOT 5V)");
  Serial.println("  GND    ->  GND");
  Serial.printf("  SDA/SS ->  GPIO %u\n", PIN_SS);
  Serial.printf("  SCK    ->  GPIO %u\n", PIN_SCK);
  Serial.printf("  MOSI   ->  GPIO %u\n", PIN_MOSI);
  Serial.printf("  MISO   ->  GPIO %u\n", PIN_MISO);
  Serial.printf("  RST    ->  GPIO %u\n", PIN_RST);
  Serial.println("  IRQ        unconnected");
  Serial.println();
}

// The self test wipes the configuration, so the chip has to be brought back up
// afterwards. Worth it: it is the one check that exercises the chip's internal
// datapath rather than just the four wires to it.
void selfTest() {
  Serial.print("self test ... ");
  const bool ok = g_rfid.PCD_PerformSelfTest();
  Serial.println(ok ? "passed" : "FAILED (clones often fail this and still work)");
  g_rfid.PCD_Init();
  g_rfid.PCD_SetAntennaGain(MFRC522::RxGain_max);
  g_rfid.PCD_AntennaOn();
}

void reportTag() {
  char hex[sizeof(g_lastUid)];
  size_t n = 0;
  for (uint8_t i = 0; i < g_rfid.uid.size && n + 3 <= sizeof(hex); i++) {
    n += snprintf(hex + n, sizeof(hex) - n, "%02X", g_rfid.uid.uidByte[i]);
  }
  hex[n] = '\0';

  const MFRC522::PICC_Type type = g_rfid.PICC_GetType(g_rfid.uid.sak);
  g_reads++;
  Serial.printf("[%5u] tag %s  (%u bytes, SAK 0x%02X, %s)\n", g_reads, hex,
                (unsigned)g_rfid.uid.size, g_rfid.uid.sak,
                g_rfid.PICC_GetTypeName(type));
  strncpy(g_lastUid, hex, sizeof(g_lastUid) - 1);
}

}  // namespace

void setup() {
  Serial.begin(115200);
  delay(300);  // the USB-serial chip needs a moment or the first lines are lost

  Serial.println();
  Serial.println("=== RC522 probe ===");
  printWiring();

  SPI.begin(PIN_SCK, PIN_MISO, PIN_MOSI, PIN_SS);
  g_rfid.PCD_Init();
  delay(50);  // the datasheet's oscillator start-up, and then some

  const uint8_t version = g_rfid.PCD_ReadRegister(MFRC522::VersionReg);
  Serial.printf("VersionReg = 0x%02X  (%s)\n", version, versionName(version));

  if (!versionIsReal(version)) {
    Serial.println();
    Serial.println("The chip is not answering at all. In order of likelihood:");
    Serial.println("  - 3.3V or GND not actually landing on the module");
    Serial.println("  - MISO and MOSI swapped, or SDA/SS on the wrong pin");
    Serial.println("  - powered from 5V, which damages the part");
    Serial.println("  - a dead board (they do arrive dead)");
    Serial.println();
    Serial.println("Nothing below this line will work until that reads 0x88/0x91/0x92.");
    return;
  }

  selfTest();
  Serial.println();
  Serial.println("ready — hold a tag against the antenna");
  g_nextHealthAt = millis() + 5000;
}

void loop() {
  // A reader that has browned out or lost its power rail still returns happily
  // from PICC_IsNewCardPresent(), it just never sees anything. Re-reading the
  // version register now and then is what tells "no tag" apart from "no chip".
  if ((int32_t)(millis() - g_nextHealthAt) >= 0) {
    g_nextHealthAt = millis() + 5000;
    const uint8_t version = g_rfid.PCD_ReadRegister(MFRC522::VersionReg);
    if (!versionIsReal(version)) {
      Serial.printf("reader stopped answering (VersionReg = 0x%02X) — re-initialising\n",
                    version);
      g_rfid.PCD_Init();
      g_rfid.PCD_SetAntennaGain(MFRC522::RxGain_max);
      g_rfid.PCD_AntennaOn();
    }
  }

  // WakeupA rather than RequestA: a card that has been halted ignores REQA and
  // would look like it had been taken away while it was still sitting there.
  byte atqa[2];
  byte atqaLen = sizeof(atqa);
  const MFRC522::StatusCode status = g_rfid.PICC_WakeupA(atqa, &atqaLen);
  if (status != MFRC522::STATUS_OK && status != MFRC522::STATUS_COLLISION) {
    delay(80);
    return;
  }

  if (g_rfid.PICC_ReadCardSerial()) {
    reportTag();
  }
  g_rfid.PICC_HaltA();
  delay(80);
}

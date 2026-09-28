// microSD probe: is anything on the other end of the SPI wires?
//
// Wiring (the firmware's pins):
//   CS   -> GPIO 5      CLK  -> GPIO 18
//   CMD  -> GPIO 23     DAT0 -> GPIO 19
//   VDD  -> 3V3         VSS  -> GND
//
// CMD0 is the first thing a card is ever sent, and its one-byte answer is the
// whole diagnosis:
//   0x01  the card is alive and in SPI mode — the wiring is fine
//   0xFF  nobody answered: no power at the card, CS or CLK not arriving, or
//         DAT0 not connected
//   0x00  DAT0 held low: shorted to GND, or CMD/DAT0 swapped
//   other a card that answers but garbled: CLK too fast for the wires, or noise

#include <Arduino.h>
#include <SD.h>
#include <SPI.h>

constexpr uint8_t PIN_SCK  = 18;
constexpr uint8_t PIN_MISO = 19;
constexpr uint8_t PIN_MOSI = 23;
constexpr uint8_t PIN_CS   = 5;

// DAT0 read with each pull in turn. A pin that follows both pulls is driven by
// nothing; one that ignores them is driven by something.
void floatTest(const char *when) {
  pinMode(PIN_MISO, INPUT_PULLUP);
  delay(2);
  const int up = digitalRead(PIN_MISO);
  pinMode(PIN_MISO, INPUT_PULLDOWN);
  delay(2);
  const int down = digitalRead(PIN_MISO);
  pinMode(PIN_MISO, INPUT);
  const char *verdict = (up && !down) ? "floating (nothing drives it)"
                        : (up && down) ? "driven HIGH"
                                       : (!up && !down) ? "driven LOW  <- shorted or held by the card/module"
                                                        : "odd (low with pull-up, high with pull-down)";
  Serial.printf("  DAT0 with CS %s: %s\n", when, verdict);
}

uint8_t cmd0(uint32_t hz) {
  SPI.begin(PIN_SCK, PIN_MISO, PIN_MOSI, -1);
  pinMode(PIN_CS, OUTPUT);
  digitalWrite(PIN_CS, HIGH);
  SPI.beginTransaction(SPISettings(hz, MSBFIRST, SPI_MODE0));
  for (int i = 0; i < 10; i++) {
    SPI.transfer(0xFF);  // 80 clocks with CS high: how a card is woken into SPI mode
  }
  digitalWrite(PIN_CS, LOW);
  const uint8_t frame[] = {0x40, 0, 0, 0, 0, 0x95};  // CMD0, CRC is checked for this one
  for (uint8_t b : frame) {
    SPI.transfer(b);
  }
  uint8_t r = 0xFF;
  for (int i = 0; i < 10 && r == 0xFF; i++) {
    r = SPI.transfer(0xFF);
  }
  digitalWrite(PIN_CS, HIGH);
  SPI.transfer(0xFF);
  SPI.endTransaction();
  SPI.end();
  return r;
}

void run() {
  Serial.println("\n==== microSD probe ====");
  Serial.printf("  CS GPIO%u  CLK GPIO%u  CMD GPIO%u  DAT0 GPIO%u\n", PIN_CS, PIN_SCK, PIN_MOSI,
                PIN_MISO);

  pinMode(PIN_CS, OUTPUT);
  digitalWrite(PIN_CS, HIGH);
  floatTest("high");
  digitalWrite(PIN_CS, LOW);
  floatTest("low ");
  digitalWrite(PIN_CS, HIGH);

  for (uint32_t hz : {100000u, 400000u}) {
    const uint8_t r = cmd0(hz);
    const char *meaning = r == 0x01   ? "card alive, wiring OK"
                          : r == 0xFF ? "no answer: power at the card, CS, CLK or DAT0"
                          : r == 0x00 ? "DAT0 stuck low: short, or CMD/DAT0 swapped"
                                      : "garbled: slow down, shorten the wires";
    Serial.printf("  CMD0 at %3u kHz -> 0x%02X  %s\n", (unsigned)(hz / 1000), r, meaning);
  }

  SPI.begin(PIN_SCK, PIN_MISO, PIN_MOSI, PIN_CS);
  for (uint32_t hz : {400000u, 4000000u, 16000000u}) {
    const bool ok = SD.begin(PIN_CS, SPI, hz);
    if (ok) {
      Serial.printf("  SD.begin at %5u kHz: mounted, %llu MB, type %d\n", (unsigned)(hz / 1000),
                    SD.cardSize() / (1024ULL * 1024ULL), (int)SD.cardType());
      File root = SD.open("/");
      for (File f = root.openNextFile(); f; f = root.openNextFile()) {
        Serial.printf("    %s%s\n", f.name(), f.isDirectory() ? "/" : "");
      }
      SD.end();
    } else {
      Serial.printf("  SD.begin at %5u kHz: failed\n", (unsigned)(hz / 1000));
    }
  }
  Serial.println("==== press EN / RST to run again ====");
}

void setup() {
  Serial.begin(115200);
  delay(500);
  run();
}

void loop() { delay(1000); }

#include "nfc.h"

#include <Adafruit_PN532.h>
#include <Wire.h>

#include "config.h"
#include "i2cbus.h"
#include "log.h"

namespace nfc {
namespace {

// No IRQ or reset line is wired, so the library falls back to polling the
// status byte. Passing 255 leaves those pins unconfigured — which is where the
// two `__pinMode(): Invalid pin selected` lines at boot come from.
//
// Both interfaces are built, because which one a given module speaks is a
// property of the board you happened to buy: the DIP switches select it, and
// some of the clones only ever do HSU. Only one is ever opened.
Adafruit_PN532 g_overI2c(255, 255, &Wire);
Adafruit_PN532 g_overHsu(255, &Serial2);
Adafruit_PN532 *g_dev = nullptr;
const char *g_busName = "none";

bool g_ready = false;
bool g_present = false;
uint8_t g_misses = 0;
uint32_t g_nextPollAt = 0;
uint32_t g_lastContactAt = 0;
uint32_t g_nextRetryAt = 0;
uint32_t g_retryDelay = NFC_RETRY_FIRST_MS;
char g_uid[15] = {0};      // 7 bytes of UID as hex, plus terminator
char g_lastUid[15] = {0};

void toHex(const uint8_t *uid, uint8_t len, char *out, size_t outLen) {
  size_t n = 0;
  for (uint8_t i = 0; i < len && n + 3 <= outLen; i++) {
    n += snprintf(out + n, outLen - n, "%02X", uid[i]);
  }
  out[n] = '\0';
}

// An idle I2C bus rests high on both wires, held there by pull-ups. If it does
// not, there is no point asking the peripheral anything: it cannot get a START
// out, and the IDF driver meets a stuck bus with its own recovery path — nine
// clock pulses and an FSM reset — which is not bounded by Wire::setTimeOut()
// and costs a flat second. Measured: a full 126-address sweep took 126,015 ms,
// which is 1000 ms per address with the timeout asked to be 50.
//
// So check the wires directly first. It costs two milliseconds and turns a
// two-second probe against a dead bus into an instant no.
bool busIdle(bool *sdaOut, bool *sclOut) {
  Wire.end();  // let go of the pins so we can read them as plain inputs
  pinMode(PIN_I2C_SDA, INPUT_PULLUP);
  pinMode(PIN_I2C_SCL, INPUT_PULLUP);
  delay(2);
  const bool sda = digitalRead(PIN_I2C_SDA);
  const bool scl = digitalRead(PIN_I2C_SCL);
  if (sdaOut) {
    *sdaOut = sda;
  }
  if (sclOut) {
    *sclOut = scl;
  }
  return sda && scl;
}

// The I2C wake-up condition from the PN532 manual: SDA held low for tWAKEUP
// while the clock idles. A module fresh out of power-on is in LowVbat and
// acknowledges nothing at all until it has seen this, and the START pulse of
// an address probe is orders of magnitude too short to count.
void wakeI2c() {
  Wire.end();  // let go of the pins so we can drive them by hand
  pinMode(PIN_I2C_SCL, INPUT_PULLUP);
  pinMode(PIN_I2C_SDA, OUTPUT);
  digitalWrite(PIN_I2C_SDA, LOW);
  delay(PN532_I2C_WAKE_MS);
  pinMode(PIN_I2C_SDA, INPUT_PULLUP);
  delay(1);  // let the line settle before the peripheral takes the pins back
}

// A plain address probe. The library's begin() walks into a readiness loop that
// takes seconds to give up when nothing answers, and "nothing answers" is
// exactly what an unplugged reader looks like.
bool presentOnI2c() {
  Serial2.end();  // in case an HSU attempt is holding the pins

  // Said once per change of state, not once per retry: this runs every few
  // seconds and a wire that is still down is not news the second time.
  static int8_t lastIdle = -1;
  bool sdaHigh = false;
  bool sclHigh = false;
  if (!busIdle(&sdaHigh, &sclHigh)) {
    if (lastIdle != 0) {
      lastIdle = 0;
      LOGE("I2C bus is not idle (SDA=%d SCL=%d, both should be 1) — not probing",
           (int)sdaHigh, (int)sclHigh);
    }
    return false;
  }
  if (lastIdle != 1) {
    lastIdle = 1;
    LOGD("I2C bus idle, both lines high");
  }

  wakeI2c();
  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL, I2C_BUS_HZ);
  // Default is one second per transaction, and the library polls readiness in a
  // loop — a missing reader would hold up setup() for ten seconds.
  Wire.setTimeOut(50);

  // Ask more than once. The wake-up leaves the module a moment behind us, and
  // one unanswered probe is not the same as an absent reader.
  for (int attempt = 0; attempt < PN532_I2C_ATTEMPTS; attempt++) {
    Wire.beginTransmission(PN532_I2C_ADDRESS);
    if (Wire.endTransmission() == 0) {
      return true;
    }
    delay(2);
  }
  return false;
}

// The HSU wake-up condition from the PN532 manual: 0x55 0x55, then a run of
// zeros holding the line while its oscillator starts. Adafruit_PN532 sends
// three bytes, which is inside spec but which some modules sleep straight
// through, and a module that never wakes is indistinguishable from one that is
// not plugged in.
const uint8_t kWakeup[] = {0x55, 0x55, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                           0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
const uint8_t kGetFirmwareVersion[] = {0x00, 0x00, 0xFF, 0x02, 0xFE, 0xD4, 0x02, 0x2A, 0x00};

// Which way round the two data wires are. TX and RX have to cross, and the
// silkscreen on these boards is not always to be believed, so rather than make
// anyone guess we try it one way and then the other. The first is UART2's own
// pin assignment, which is the one the library will reopen the port with.
struct Wiring {
  int rx;
  int tx;
  const char *name;
};
// Only one way round now the reader has pins of its own: GPIO34 cannot
// transmit, so there is no second orientation to try.
const Wiring kWirings[] = {
    {PIN_NFC_RX, PIN_NFC_TX, "HSU, module TX on GPIO34"},
};

// The wiring that last answered, tried first from then on. Probing the wrong
// one is not free: our TX is driving into the module's TX for as long as it
// takes to give up, two push-pull outputs arguing, and the module is in no
// state to be reasoned with afterwards.
const Wiring *g_lastGood = nullptr;

// The six bytes the PN532 acknowledges every command with, before it answers.
const uint8_t kAck[] = {0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00};

// Read until the line has been quiet for a moment. The probe stops at the ACK,
// so the answer to its own command is usually still on its way, and a single
// leftover byte puts every reply after it out of step.
void drainHsu() {
  const uint32_t deadline = millis() + PN532_HSU_DRAIN_MS;
  uint32_t lastByteAt = millis();
  while ((int32_t)(millis() - deadline) < 0) {
    if (Serial2.available()) {
      Serial2.read();
      lastByteAt = millis();
    } else if (millis() - lastByteAt > 10) {
      return;  // quiet long enough to call it finished
    } else {
      delay(1);
    }
  }
}

bool awaitAck() {
  // Bytes arriving is not enough. A jumper across the two pins loops our own
  // frame straight back and looks exactly like an answer.
  size_t matched = 0;
  const uint32_t deadline = millis() + PN532_HSU_PROBE_MS;  // per attempt
  while ((int32_t)(millis() - deadline) < 0) {
    while (Serial2.available()) {
      const uint8_t byte = (uint8_t)Serial2.read();
      if (byte == kAck[matched]) {
        matched++;
      } else {
        matched = (byte == kAck[0]) ? 1 : 0;
      }
      if (matched == sizeof(kAck)) {
        return true;
      }
    }
    delay(2);
  }
  return false;
}

// The same idea as the address probe, over UART, where there is no address:
// ask for the firmware version by hand and give the module a moment to say
// anything at all. Going through the library would mean two one-second waits
// per attempt, every thirty seconds, on a toy that may have no reader at all.
bool presentOnHsu(const Wiring &wiring) {
  Serial2.begin(PN532_HSU_BAUD, SERIAL_8N1, wiring.rx, wiring.tx);
  while (Serial2.available()) {
    Serial2.read();
  }
  Serial2.write(kWakeup, sizeof(kWakeup));
  Serial2.flush();
  delay(PN532_HSU_WAKE_MS);
  drainHsu();  // the wake-up is sometimes echoed back before the real answer

  // Ask twice. A module still coming out of LowVbat swallows the first command
  // and answers the second, and at boot it is doing exactly that — powered up
  // the same instant the ESP32 was. One attempt found this reader only on the
  // thirty-second health retry, which reads as a wiring fault and is not one.
  for (int attempt = 0; attempt < PN532_HSU_ATTEMPTS; attempt++) {
    Serial2.write(kGetFirmwareVersion, sizeof(kGetFirmwareVersion));
    if (awaitAck()) {
      g_lastGood = &wiring;
      return true;
    }
  }
  Serial2.end();
  return false;
}

// The same idea as drainHsu(), but for the steady state rather than the probe,
// and a no-op unless HSU is the bus we ended up on. See NFC_HSU_STALE_MS.
void drainStaleHsu() {
  if (g_dev != &g_overHsu) {
    return;
  }
  const uint32_t deadline = millis() + NFC_HSU_STALE_MS;
  uint32_t lastByteAt = millis();
  while ((int32_t)(millis() - deadline) < 0) {
    if (Serial2.available()) {
      Serial2.read();
      lastByteAt = millis();
    } else if (millis() - lastByteAt > 5) {
      return;
    } else {
      delay(1);
    }
  }
}

bool identify(Adafruit_PN532 &device, const char *bus) {
  const uint32_t version = device.getFirmwareVersion();
  if (!version) {
    // The probe got an ACK out of it a moment ago, so this is the library and
    // the module disagreeing, not an absent reader. Worth saying out loud.
    LOGE("%s: no answer to getFirmwareVersion()", bus);
    return false;
  }

  // SAMConfig before RFConfiguration: that is the order Adafruit's own examples
  // use, and setPassiveActivationRetries() on a SAM that has not been brought
  // up yet is one more command for a module that may already be struggling.
  //
  // Twice, for the same reason the probe asks twice: a module a few hundred
  // milliseconds out of power-on answers the first SAMConfig late, and a late
  // answer is read as no answer. Not twice if it is holding the clock low,
  // though — that is a wedged module rather than a slow one, and the second
  // attempt costs eleven seconds to learn nothing. digitalRead() still reports
  // the true line level while the I2C peripheral owns the pin.
  bool configured = device.SAMConfig();
  if (!configured) {
    if (&device == &g_overI2c && digitalRead(PIN_I2C_SCL) == LOW) {
      LOGE("%s: module is holding SCL low. It clock-stretches past the %d ms the", bus,
           (int)ESP32_I2C_STRETCH_CEILING_MS);
      LOGE("ESP32's I2C peripheral can tolerate, then wedges mid-transaction. Only a");
      LOGE("power cycle clears it — see the HSU note in config.h for the way out.");
      return false;
    }
    configured = device.SAMConfig();
  }
  if (!configured) {
    LOGE("%s reports firmware %d.%d but will not take SAMConfig", bus,
         (int)((version >> 16) & 0xFF), (int)((version >> 8) & 0xFF));
    return false;
  }

  // One retry per read: a miss has to come back quickly or the main loop stalls.
  device.setPassiveActivationRetries(0x01);

  // Only now — announcing the firmware before the reader is actually usable
  // means a boot that reports finding it and then reports that it is missing.
  LOGI("PN532 firmware %d.%d over %s", (int)((version >> 16) & 0xFF),
       (int)((version >> 8) & 0xFF), bus);
  g_dev = &device;
  g_busName = bus;
  return true;
}

bool configureHsu(const Wiring &wiring) {
  // No longer gated on presentOnHsu(). That hand-rolled ACK probe is the one
  // part of this path never observed to succeed: tools/pn532-probe brings the
  // same module up on the same two pins, first try, every try, and it does not
  // use it. The probe costs a second when no reader is fitted, which the retry
  // backoff already exists to absorb, and it was buying a false negative.
  Serial2.end();
  Serial2.begin(PN532_HSU_BAUD, SERIAL_8N1, wiring.rx, wiring.tx);
  while (Serial2.available()) {
    Serial2.read();
  }

  // The long wake-up rather than the three bytes Adafruit sends: see kWakeup.
  Serial2.write(kWakeup, sizeof(kWakeup));
  Serial2.flush();
  delay(PN532_HSU_WAKE_MS);
  drainHsu();  // the wake-up is sometimes echoed back

  // Adafruit_PN532::begin() does the library's own wake-up and state reset.
  // It calls Serial2.begin(115200) with no pins, which in this core only falls
  // back to UART2's default pins (16/17, the OLED's bus) when the port is not
  // already open — and it is, on ours, just above. Skipping it for that fear
  // left the module never woken the way the library expects; tools/pn532-probe
  // always calls it, and that is the one that worked.
  g_overHsu.begin();
  drainHsu();

  return identify(g_overHsu, wiring.name);
}

bool configureOnce();

// The probes take the bus apart (see i2cbus.h), so the face waits them out,
// and whatever they leave behind, the face gets its bus back.
bool configure() {
  i2cbus::Guard guard;
  const bool ok = configureOnce();
  i2cbus::ensureStarted();
  return ok;
}

bool configureOnce() {
  g_dev = nullptr;
  g_busName = "none";

#if PN532_BUS == PN532_BUS_AUTO || PN532_BUS == PN532_BUS_I2C
  if (presentOnI2c() && g_overI2c.begin() && identify(g_overI2c, "I2C")) {
    return true;
  }
#endif
#if PN532_BUS == PN532_BUS_AUTO || PN532_BUS == PN532_BUS_HSU
#if PN532_HSU_WIRING == PN532_HSU_WIRING_AUTO
  // Whichever answered last goes first: see the warning in config.h about what
  // probing the other one costs.
  if (g_lastGood && configureHsu(*g_lastGood)) {
    return true;
  }
  for (const Wiring &wiring : kWirings) {
    if (&wiring != g_lastGood && configureHsu(wiring)) {
      return true;
    }
  }
#else
  if (configureHsu(kWirings[PN532_HSU_WIRING])) {
    return true;
  }
#endif
#endif
  return false;
}

}  // namespace

bool begin() {
  g_retryDelay = NFC_RETRY_FIRST_MS;
  g_present = false;
  g_misses = 0;
  g_lastContactAt = millis();

  // Too early to ask without wedging it (see NFC_BOOT_SETTLE_MS): leave the
  // first attempt to poll(), which says "PN532 ready" when it comes up.
  if (millis() < NFC_BOOT_SETTLE_MS) {
    g_ready = false;
    g_nextRetryAt = NFC_BOOT_SETTLE_MS;
    LOGI("reader: first look at %u ms, once it has had time to power up",
         (unsigned)NFC_BOOT_SETTLE_MS);
    return false;
  }

  g_nextRetryAt = millis() + NFC_RETRY_FIRST_MS;
  g_ready = configure();
  if (!g_ready) {
    // Not an error yet: the reader is usually just slower off the mark than the
    // ESP32. poll() keeps asking, and says so when one turns up.
    LOGI("no reader yet, still looking (type 'i2c' if it never appears)");
  }
  g_present = false;
  g_misses = 0;
  g_lastContactAt = millis();
  return g_ready;
}

bool ready() { return g_ready; }

const char *busName() { return g_busName; }

void scanBus() {
  i2cbus::Guard guard;
  LOGI("scanning I2C on SDA=GPIO%d SCL=GPIO%d", PIN_I2C_SDA, PIN_I2C_SCL);
  Serial2.end();

  bool sdaIdleHigh = false;
  bool sclIdleHigh = false;
  const bool idle = busIdle(&sdaIdleHigh, &sclIdleHigh);
  LOGI("idle levels: SDA=%d SCL=%d (both must read 1)", (int)sdaIdleHigh, (int)sclIdleHigh);
  if (!idle) {
    LOGE("a line is held low — the bus is stuck, not empty, and every probe would");
    LOGE("cost a second. Unplug the reader's VCC and run 'i2c' again: if the line");
    LOGE("comes up, the module is clamping it (unpowered chips do this through their");
    LOGE("protection diodes); if it stays low, the fault is on our side of the wires.");
    return;
  }

  wakeI2c();  // otherwise a module still in LowVbat is scanned as an empty bus
  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL, I2C_BUS_HZ);
  Wire.setTimeOut(50);
  uint8_t found = 0;
  const uint32_t sweepStartedAt = millis();
  uint32_t slowest = 0;
  // 0x00-0x07 and 0x78-0x7F are reserved, and probing them buys nothing but
  // time we have already established is expensive here.
  for (uint8_t address = 0x08; address < 0x78; address++) {
    const uint32_t at = millis();
    Wire.beginTransmission(address);
    const bool answered = Wire.endTransmission() == 0;
    const uint32_t took = millis() - at;
    if (took > slowest) {
      slowest = took;
    }
    if (!answered) {
      continue;
    }
    found++;
    LOGI("  0x%02X answers%s", address,
         address == PN532_I2C_ADDRESS ? "  <- the PN532" : "");
  }
  LOGI("swept 112 addresses in %lu ms, slowest %lu ms (50 ms is the timeout asked for)",
       (unsigned long)(millis() - sweepStartedAt), (unsigned long)slowest);
  if (found == 0) {
    LOGE("nothing on the bus — no power, no ground, or the module does not do I2C");
    LOGE("(it answers at 0x%02X, and only with its DIP switches at 1 on, 2 off)",
         PN532_I2C_ADDRESS);
  }
#if PN532_BUS != PN532_BUS_HSU
  else if (!g_ready) {
    LOGE("something is on the bus, but not at 0x%02X — check the DIP switches",
         PN532_I2C_ADDRESS);
  }
#endif

  // Say what HSU makes of the same two wires, both ways round, because a module
  // that only speaks UART is silent above however it is wired. This is the one
  // place that deliberately probes the wrong orientation too, so expect to
  // power-cycle the reader afterwards — see PN532_HSU_WIRING in config.h.
#if PN532_BUS == PN532_BUS_I2C
  // The bus is pinned to I2C, so the module's switches say I2C. Driving UART
  // frames down SDA would only wedge a reader we already know how to talk to.
  LOGI("(HSU probe skipped: PN532_BUS is pinned to I2C in config.h)");
#else
#if PN532_HSU_WIRING == PN532_HSU_WIRING_AUTO
  LOGI("(this probes both ways round; the wrong one may need a power cycle after)");
#endif
  for (const Wiring &wiring : kWirings) {
#if PN532_HSU_WIRING != PN532_HSU_WIRING_AUTO
    // The wiring is pinned, so the other orientation is known to be the one
    // that fights the module's transmit pin. Diagnosing is not worth breaking it.
    if (&wiring != &kWirings[PN532_HSU_WIRING]) {
      continue;
    }
#endif
    LOGI("probing HSU with RX on GPIO%d, TX on GPIO%d (both switches off)", wiring.rx,
         wiring.tx);
    if (presentOnHsu(wiring)) {
      LOGI("  answered — this is the wiring to keep");
    } else {
      LOGE("  nothing");
    }
  }
#endif

  // Leave the reader as we found it rather than on whichever bus was tried last.
  configure();
}

Event poll(bool busy) {
  const uint32_t now = millis();
  if ((int32_t)(now - g_nextPollAt) < 0) {
    return Event::None;
  }
  g_nextPollAt = now + (busy ? NFC_POLL_BUSY_MS : NFC_POLL_IDLE_MS);

  if (!g_ready) {
    // Not ready yet at boot, or unplugged since. Keep looking, quietly, and
    // less and less often — see NFC_RETRY_FIRST_MS.
    if ((int32_t)(now - g_nextRetryAt) >= 0) {
      g_lastContactAt = now;
      g_ready = configure();
      if (g_ready) {
        LOGI("PN532 ready (%s)", g_busName);
        g_retryDelay = NFC_RETRY_FIRST_MS;
      } else {
        g_retryDelay *= NFC_RETRY_GROWTH;
        if (g_retryDelay > NFC_HEALTH_MS) {
          g_retryDelay = NFC_HEALTH_MS;
        }
        g_nextRetryAt = now + g_retryDelay;
      }
    }
    return Event::None;
  }

  uint8_t uid[7] = {0};
  uint8_t uidLen = 0;
  drainStaleHsu();
  const bool found =
      g_dev->readPassiveTargetID(PN532_MIFARE_ISO14443A, uid, &uidLen, NFC_READ_TIMEOUT_MS);

  if (found && uidLen > 0) {
    g_lastContactAt = now;
    g_misses = 0;

    char hex[sizeof(g_uid)];
    toHex(uid, uidLen, hex, sizeof(hex));
    if (g_present && strcmp(hex, g_uid) == 0) {
      return Event::None;  // same tag still sitting there
    }
    strlcpy(g_uid, hex, sizeof(g_uid));
    strlcpy(g_lastUid, hex, sizeof(g_lastUid));
    g_present = true;
    LOGI("tag %s", g_uid);
    return Event::Arrived;
  }

  // An empty read is also what "no tag on the reader" looks like, so silence is
  // not an error. Instead, ask the reader who it is now and then; a module that
  // has locked up (brownout, ESD from a curious child) fails that and gets reset.
  if ((int32_t)(now - g_lastContactAt) > (int32_t)NFC_HEALTH_MS) {
    g_lastContactAt = now;
    drainStaleHsu();
    if (!g_dev->getFirmwareVersion()) {
      LOGE("PN532 unresponsive, re-initialising");
      g_ready = configure();
    }
  }

  if (g_present && ++g_misses >= NFC_MISS_LIMIT) {
    g_present = false;
    g_misses = 0;
    LOGD("tag %s removed", g_uid);
    g_uid[0] = '\0';
    return Event::Departed;
  }
  return Event::None;
}

void rawHsu() {
  Serial2.end();
  // A UART line idles high. Low here means the module's TX is not on this pin
  // (or not powered); flickering means something else is.
  pinMode(PIN_NFC_RX, INPUT);
  int highs = 0;
  for (int i = 0; i < 200; i++) {
    highs += digitalRead(PIN_NFC_RX);
    delayMicroseconds(250);
  }
  LOGI("GPIO%d (module TX) idle: high %d of 200 samples", PIN_NFC_RX, highs);

  Serial2.begin(PN532_HSU_BAUD, SERIAL_8N1, PIN_NFC_RX, PIN_NFC_TX);
  while (Serial2.available()) {
    Serial2.read();
  }
  Serial2.write(kWakeup, sizeof(kWakeup));
  Serial2.flush();
  delay(PN532_HSU_WAKE_MS);
  Serial2.write(kGetFirmwareVersion, sizeof(kGetFirmwareVersion));
  Serial2.flush();
  char line[3 * 32 + 1];
  size_t n = 0, total = 0;
  const uint32_t until = millis() + 300;
  while ((int32_t)(millis() - until) < 0) {
    while (Serial2.available()) {
      const int b = Serial2.read();
      total++;
      if (n + 4 < sizeof(line)) {
        n += snprintf(line + n, sizeof(line) - n, "%02X ", b);
      }
    }
    delay(2);
  }
  line[n] = '\0';
  LOGI("sent wake-up + GetFirmwareVersion on GPIO%d, got %u bytes back: %s", PIN_NFC_TX,
       (unsigned)total, total ? line : "(nothing)");
  configure();
}

const char *lastUid() { return g_lastUid; }

bool readOnce(char *uidOut, size_t len, uint32_t timeoutMs) {
  if (!g_ready) {
    return false;
  }
  const uint32_t deadline = millis() + timeoutMs;
  while ((int32_t)(millis() - deadline) < 0) {
    uint8_t uid[7] = {0};
    uint8_t uidLen = 0;
    if (g_dev->readPassiveTargetID(PN532_MIFARE_ISO14443A, uid, &uidLen, 100) && uidLen) {
      toHex(uid, uidLen, uidOut, len);
      return true;
    }
    delay(10);
  }
  return false;
}

void powerDown() {
  if (!g_ready) {
    return;
  }
  // PowerDown, waking on whichever interface we are actually using: bit 5 is
  // I2C, bit 3 is HSU. Saves ~60 mA while the ESP32 sleeps.
  const uint8_t wakeOn = (g_dev == &g_overHsu) ? 0x08 : 0x20;
  uint8_t cmd[] = {0x16, wakeOn, 0x00};
  g_dev->sendCommandCheckAck(cmd, sizeof(cmd), 100);
  g_ready = false;
}

void testPins() {
  i2cbus::Guard guard;
  Serial2.end();
  Wire.end();
  LOGI("loopback on GPIO%d and GPIO%d — join them with one jumper and nothing else",
       PIN_I2C_SDA, PIN_I2C_SCL);

  bool ok = true;
  for (int pass = 0; pass < 2; pass++) {
    const int out = pass ? PIN_I2C_SCL : PIN_I2C_SDA;
    const int in = pass ? PIN_I2C_SDA : PIN_I2C_SCL;

    pinMode(out, OUTPUT);
    pinMode(in, INPUT_PULLDOWN);
    digitalWrite(out, HIGH);
    delay(5);
    const bool sawHigh = digitalRead(in);
    digitalWrite(out, LOW);
    delay(5);
    const bool sawLow = !digitalRead(in);
    pinMode(out, INPUT);

    if (sawHigh && sawLow) {
      LOGI("  GPIO%d -> GPIO%d ok", out, in);
    } else {
      ok = false;
      LOGE("  GPIO%d -> GPIO%d failed (high read %d, low read %d)", out, in, (int)sawHigh,
           (int)!sawLow);
    }
  }

  if (ok) {
    LOGI("both pins do as they are told — the ESP32 side is fine, so the reader is not");
  } else {
    LOGE("a pin is not following its own output: no jumper fitted, or these two pins are");
    LOGE("not free on this board — a D32 Pro (WROVER) wires GPIO16/17 to its PSRAM");
  }

  configure();  // leave the reader as we found it
}

}  // namespace nfc

// Board wiring and tunables for Bookie.
#pragma once

#include <Arduino.h>

// ---------------------------------------------------------------- pin map
// LOLIN D32 (plain, no PSRAM). Strapping pins 0, 2, 12 and 15 are left alone.
// GPIO 16 and 17 carry the reader either way, but not the same way round.
// Over I2C they are what they say: SDA to the module's SDA, SCL to its SCL.
// Over HSU they are UART2, whose pins the ESP32 core fixes at RX=16, TX=17 and
// which Adafruit_PN532 reopens for itself — so the wires cross: the module's TX
// (the pin marked SCL/TX) goes to GPIO 16, its RX (SDA/RX) to GPIO 17.
constexpr int PIN_I2C_SDA   = 16;  // PN532 SDA over I2C, and its TX over HSU
constexpr int PIN_I2C_SCL   = 17;  // PN532 SCL over I2C, and its RX over HSU

constexpr int PIN_SD_SCK    = 18;
constexpr int PIN_SD_MISO   = 19;
constexpr int PIN_SD_MOSI   = 23;
constexpr int PIN_SD_CS     = 5;   // also drives the onboard LED, harmless

constexpr int PIN_I2S_BCLK  = 26;  // MAX98357A BCLK
constexpr int PIN_I2S_LRC   = 25;  // MAX98357A LRC
constexpr int PIN_I2S_DIN   = 27;  // MAX98357A DIN
constexpr int PIN_AMP_SD    = 33;  // MAX98357A SD: high = on (left channel), low = shutdown

constexpr int PIN_BTN_LANG   = 4;   // also the wake-from-sleep button (RTC-capable)
constexpr int PIN_BTN_VOL_UP = 14;
constexpr int PIN_BTN_VOL_DN = 22;  // not RTC-capable, so it cannot be the wake button

// Battery sense: a 100k/100k divider from the cell (after the switch) to an ADC
// pin. Not fitted on this board, so -1: nothing reads a pin, and no warning or
// shutdown ever hangs off a reading. Set it to 35 once the divider is there.
constexpr int PIN_BATT_SENSE = -1;

// ---------------------------------------------------------------- storage
constexpr uint32_t SD_SPI_HZ      = 16000000;  // dropped to 4 MHz automatically if the mount fails
constexpr uint32_t SD_SPI_HZ_SLOW = 4000000;

constexpr char DIR_AUDIO[]  = "/audio";   // /audio/<lang>/<track>.mp3|wav
constexpr char DIR_SYSTEM[] = "/system";  // /system/<lang>/<clip>.mp3|wav
constexpr char FILE_TAGS[]  = "/tags.csv";
constexpr char LANG_FALLBACK[] = "en";

// System clips, all optional — a missing one is simply skipped.
constexpr char CLIP_READY[]   = "ready";
constexpr char CLIP_LANGUAGE[] = "language";
constexpr char CLIP_UNKNOWN[]  = "unknown";
constexpr char CLIP_LOWBATT[]  = "low-battery";

// ---------------------------------------------------------------- audio
constexpr size_t   AUDIO_PATH_MAX     = 96;
constexpr uint32_t AUDIO_BUFFER_BYTES = 8192;  // read-ahead buffer in front of the decoder
constexpr int      I2S_DMA_BUFFERS    = 24;    // 24 x 128 frames (~70 ms) of slack, 12 kB of RAM
constexpr uint32_t AMP_LINGER_MS      = 1500;  // keep the amp awake after a track, avoids pop-per-track
constexpr uint32_t AMP_SETTLE_MS      = 20;    // let the amp bias up before the first sample

// Volume curve, roughly perceptual. Step 0 is silence.
constexpr float VOLUME_STEPS[] = {0.00f, 0.06f, 0.10f, 0.16f, 0.25f, 0.38f, 0.55f, 0.75f, 1.00f};
constexpr uint8_t VOLUME_MAX_STEP = (sizeof(VOLUME_STEPS) / sizeof(VOLUME_STEPS[0])) - 1;
constexpr uint8_t VOLUME_DEFAULT_STEP = 5;

// ---------------------------------------------------------------- NFC
// How the reader is wired, which its DIP switches have to agree with:
//
//   I2C   switch 1 on, switch 2 off
//   HSU   both off — the factory default, and the only mode some of the clone
//         boards have at all, whatever the listing claims
//
// Auto tries I2C first, because that probe is a single address check, and falls
// back to HSU, which costs 150 ms when nothing answers. Pin it to one of the
// two once you know which board you have.
//
// Pinned to HSU, and not by preference: over I2C this module answers
// getFirmwareVersion (1.6) and then clock-stretches through SAMConfig for
// longer than ESP32_I2C_STRETCH_CEILING_MS below, which is the most the ESP32's
// I2C peripheral can be asked to wait. Every readiness poll then times out
// (ESP_ERR_TIMEOUT, 263) and the module is left holding SCL down, which nothing
// but a power cycle clears — a slave gripping the clock cannot be clocked off
// the bus the way a stuck SDA can. HSU has no clock to stretch.
//
// Leaving this on auto is worse than slow, it is destructive: a module strapped
// for I2C that misses the address probe then gets a UART frame blasted down the
// same two wires at 115200, which its I2C state machine reads as a storm of
// START conditions.
#define PN532_BUS_AUTO 0
#define PN532_BUS_I2C  1
#define PN532_BUS_HSU  2
#ifndef PN532_BUS
#define PN532_BUS PN532_BUS_HSU
#endif

// Which of the module's two pins transmits. The labels are the I2C ones and say
// nothing useful here. Measured on this module with tools/pn532-probe: it
// transmits on the pin marked SCL, so the module's TX lands on GPIO16 and
// PN532_HSU_WIRING_TX16 is the one that answers. (An earlier note here claimed
// GPIO17 from the other board; the probe disagreed, twice, cleanly.)
//
// Auto tries both, and that is not free — probing the wrong way round means
// driving our TX straight into the module's TX, two outputs arguing for a fifth
// of a second, and this module stops answering anything at all afterwards until
// it is power-cycled. Use auto once to find out which you have, read it off the
// `PN532 firmware … over …` line, then pin it here and leave it pinned.
#define PN532_HSU_WIRING_AUTO (-1)
#define PN532_HSU_WIRING_TX16 0
#define PN532_HSU_WIRING_TX17 1
#ifndef PN532_HSU_WIRING
#define PN532_HSU_WIRING PN532_HSU_WIRING_TX16
#endif

// The PN532 powers up in LowVbat and does not acknowledge its own address
// until it has been woken, which over I2C means holding SDA low for at least
// 1 ms (datasheet tWAKEUP) — a bare address probe's START pulse is far too
// short. Adafruit_PN532::begin() sidesteps the same problem by passing false
// to the bus library's address detection.
// The hard ceiling on how long a slave may hold SCL down before the ESP32's I2C
// peripheral gives up: the stretch timeout is a 20-bit count of 80 MHz APB
// cycles, so 2^20/80e6 is all there is, and i2cInit() already asks for the
// maximum. Lowering the bus frequency does not buy more. A PN532 that stretches
// longer than this cannot be talked to over I2C on this chip at all.
constexpr uint32_t ESP32_I2C_STRETCH_CEILING_MS = 13;

constexpr uint32_t PN532_I2C_WAKE_MS   = 2;  // SDA held low; datasheet minimum is 1
constexpr int      PN532_I2C_ATTEMPTS  = 2;  // the first probe after a wake is often swallowed
                                             // (kept low: a probe against a stuck bus does not
                                             //  honour the 50 ms timeout, it costs ~900 ms, and
                                             //  configure() blocks the main loop while it runs)

constexpr uint32_t PN532_HSU_BAUD     = 115200;  // what Adafruit_PN532 opens the port at
constexpr uint32_t PN532_HSU_PROBE_MS = 100;     // long enough for the module, short enough to retry
constexpr uint32_t PN532_HSU_WAKE_MS  = 20;      // let the oscillator start before asking anything
constexpr int      PN532_HSU_ATTEMPTS = 2;       // the first command after power-on is often swallowed
constexpr uint32_t PN532_HSU_DRAIN_MS = 60;      // wait for the tail of the probe's own answer

constexpr uint32_t NFC_POLL_IDLE_MS    = 120;  // how often to look for a tag when quiet
constexpr uint32_t NFC_POLL_BUSY_MS    = 350;  // ... and while a story is playing
constexpr uint16_t NFC_READ_TIMEOUT_MS = 60;   // per read, keeps the main loop responsive
// A read that times out has not cancelled anything: over HSU the module's
// answer lands in the UART buffer a few milliseconds later, and one leftover
// byte puts every reply after it out of step — the next command reads the
// previous command's response. The symptom is a healthy reader failing its
// heartbeat and being re-initialised on a loop. Cheaper to discard the tail
// than to resynchronise, so every command drains first.
constexpr uint32_t NFC_HSU_STALE_MS    = 40;   // ceiling on that drain
constexpr uint8_t  NFC_MISS_LIMIT      = 3;    // consecutive misses before we call the tag gone
constexpr uint32_t NFC_HEALTH_MS       = 30000;  // quiet period after which the reader is pinged for a heartbeat

// The reader comes up on the same rail as the ESP32 and is not ready when
// setup() first asks — a PN532 out of power-on wants a few hundred milliseconds
// more than the ESP32 does. Rather than hold up the boot for a reader that may
// not be fitted at all, a failed probe is retried soon and then progressively
// less often, up to the heartbeat interval. The toy finds a reader that is
// there within a second, and one plugged in later whenever it appears.
constexpr uint32_t NFC_RETRY_FIRST_MS = 250;
constexpr uint32_t NFC_RETRY_GROWTH   = 4;
// ...but not too soon. Asked at ~250 ms after power-on, this module takes the
// wake-up half-awake and then answers nothing, retries included, until it is
// power-cycled. It used to be asked at ~1.5 s only because a failing SD mount
// happened to cost that long first; with a working card the reader was reached
// at 260 ms and never came up. So the first attempt waits for this, counted
// from boot, and the rest of setup() carries on meanwhile.
constexpr uint32_t NFC_BOOT_SETTLE_MS = 1500;

// ---------------------------------------------------------------- link mode
// The toy's own WiFi network, brought up on demand so the phone can write the
// card without anyone taking it out. Off unless you ask for it: the radio costs
// ~80 mA, and an access point a child can wander into is not a toy's resting
// state.
//
// The password is shared with Bookie Studio, which is how the app can offer to
// join without anyone typing anything. Change it here and in
// `app/lib/card/toy_card.dart` together, or they will not find each other.
constexpr char     LINK_AP_PREFIX[]   = "Bookie-";  // + the last two bytes of the MAC
constexpr char     LINK_AP_PASSWORD[] = "bookie-card";  // WPA2 wants eight characters or more
constexpr uint8_t  LINK_AP_CHANNEL    = 6;
constexpr uint32_t LINK_IDLE_MS       = 5UL * 60UL * 1000UL;  // no request for this long: drop the AP
constexpr size_t   LINK_PATH_MAX      = 128;   // longer than AUDIO_PATH_MAX, the app writes /system too
constexpr size_t   LINK_CHUNK_BYTES   = 4096;  // one SD read/write per HTTP chunk
constexpr char     CLIP_LINK[]        = "link";  // optional "ready to connect" prompt

// ---------------------------------------------------------------- buttons
constexpr uint32_t BTN_DEBOUNCE_MS   = 25;
constexpr uint32_t BTN_LONG_MS       = 800;
constexpr uint32_t BTN_REPEAT_MS     = 300;   // volume auto-repeat while held

// ---------------------------------------------------------------- power
constexpr float    BATT_DIVIDER      = 2.0f;   // 100k/100k on the D32
constexpr float    BATT_WARN_V       = 3.55f;
constexpr float    BATT_CRITICAL_V   = 3.30f;
constexpr uint32_t BATT_SAMPLE_MS    = 30000;
constexpr uint32_t IDLE_SLEEP_MS     = 10UL * 60UL * 1000UL;  // 0 disables deep sleep

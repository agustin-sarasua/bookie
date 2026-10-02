#include "face.h"

#include <Adafruit_GFX.h>
#include <Wire.h>

#include "audio.h"
#include "config.h"
#include "envelope.h"
#include "i2cbus.h"
#include "log.h"

namespace face {
namespace {

// ---------------------------------------------------------------- panel

constexpr uint16_t SSD_BLACK = 0;
constexpr uint16_t SSD_WHITE = 1;
constexpr int W = 128;
constexpr int H = 64;
constexpr int kPages = H / 8;

// Adafruit_GFX does the drawing; this does the wire. It keeps a copy of what
// the panel is showing and, each frame, sends only the span of each page that
// changed — while a story plays that is the mouth, a few dozen bytes, not a
// kilobyte, and the reader on the same bus barely notices.
class Panel : public Adafruit_GFX {
 public:
  Panel() : Adafruit_GFX(W, H) {}

  void drawPixel(int16_t x, int16_t y, uint16_t color) override {
    if ((uint16_t)x >= W || (uint16_t)y >= H) {
      return;
    }
    uint8_t &b = buf_[x + (y >> 3) * W];
    const uint8_t bit = 1 << (y & 7);
    b = color ? (b | bit) : (b & ~bit);
  }

  void fillScreen(uint16_t color) override { memset(buf_, color ? 0xFF : 0x00, sizeof(buf_)); }

  bool begin() {
    i2cbus::Guard guard;
    i2cbus::ensureStarted();
    Wire.beginTransmission(OLED_ADDRESS);
    if (Wire.endTransmission() != 0) {
      return false;
    }
#if OLED_CONTROLLER == OLED_SH1106
    static const uint8_t kInit[] = {
        0xAE, 0xD5, 0x80, 0xA8, 0x3F, 0xD3, 0x00, 0x40, 0xAD, 0x8B,
        (uint8_t)(OLED_FLIP ? 0xA0 : 0xA1), (uint8_t)(OLED_FLIP ? 0xC0 : 0xC8),
        0xDA, 0x12, 0x81, 0x80, 0xD9, 0x22, 0xDB, 0x35, 0xA4, 0xA6};
#else
    static const uint8_t kInit[] = {
        0xAE, 0xD5, 0x80, 0xA8, 0x3F, 0xD3, 0x00, 0x40, 0x8D, 0x14,
        0x20, 0x02,  // page addressing, the one mode both controllers share
        (uint8_t)(OLED_FLIP ? 0xA0 : 0xA1), (uint8_t)(OLED_FLIP ? 0xC0 : 0xC8),
        0xDA, 0x12, 0x81, 0xCF, 0xD9, 0xF1, 0xDB, 0x40, 0xA4, 0xA6};
#endif
    if (!command(kInit, sizeof(kInit))) {
      return false;
    }
    memset(buf_, 0, sizeof(buf_));
    memset(shown_, 0xFF, sizeof(shown_));  // anything: the first flush sends it all
    flush();
    power(true);
    return true;
  }

  void power(bool on) {
    const uint8_t cmd = on ? 0xAF : 0xAE;
    i2cbus::Guard guard;
    command(&cmd, 1);
    on_ = on;
  }
  bool isOn() const { return on_; }

  void contrast(uint8_t level) {
    const uint8_t cmd[] = {0x81, level};
    i2cbus::Guard guard;
    command(cmd, sizeof(cmd));
  }

  void flush() {
    i2cbus::Guard guard;
    for (int page = 0; page < kPages; page++) {
      const uint8_t *now = buf_ + page * W;
      uint8_t *was = shown_ + page * W;
      int first = 0, last = W - 1;
      while (first < W && now[first] == was[first]) {
        first++;
      }
      if (first == W) {
        continue;
      }
      while (now[last] == was[last]) {
        last--;
      }
      const int col = first + kColumnOffset;
      const uint8_t addr[] = {(uint8_t)(0xB0 | page), (uint8_t)(col & 0x0F),
                              (uint8_t)(0x10 | (col >> 4))};
      if (!command(addr, sizeof(addr))) {
        return;  // try the whole thing again next frame
      }
      for (int x = first; x <= last; x += kChunk) {
        const int n = min(kChunk, last - x + 1);
        Wire.beginTransmission(OLED_ADDRESS);
        Wire.write(0x40);
        Wire.write(now + x, n);
        if (Wire.endTransmission() != 0) {
          return;
        }
        memcpy(was + x, now + x, n);
      }
    }
  }

 private:
#if OLED_CONTROLLER == OLED_SH1106
  static constexpr int kColumnOffset = 2;  // 132 columns of RAM, 128 of glass
#else
  static constexpr int kColumnOffset = 0;
#endif
  static constexpr int kChunk = 32;  // Wire's buffer is 128; small keeps the bus shared fairly

  bool command(const uint8_t *cmds, size_t n) {
    Wire.beginTransmission(OLED_ADDRESS);
    Wire.write(0x00);
    Wire.write(cmds, n);
    return Wire.endTransmission() == 0;
  }

  uint8_t buf_[W * kPages];
  uint8_t shown_[W * kPages];
  bool on_ = false;
};

Panel g_panel;

void fillEllipse(int cx, int cy, int rx, int ry, uint16_t color) {
  if (rx <= 0 || ry <= 0) {
    return;
  }
  for (int dy = -ry; dy <= ry; dy++) {
    const float k = 1.0f - (float)(dy * dy) / (ry * ry);
    const int dx = (int)(rx * sqrtf(k > 0 ? k : 0) + 0.5f);
    g_panel.drawFastHLine(cx - dx, cy + dy, 2 * dx + 1, color);
  }
}

// ---------------------------------------------------------------- commands

enum class Op : uint8_t { React, Say, Volume, Link, Poke, Sleep };

struct Msg {
  Op op;
  uint8_t a;
  uint8_t b;
  uint32_t ms;
  char text[20];
};

QueueHandle_t g_queue = nullptr;
SemaphoreHandle_t g_asleep = nullptr;
bool g_present = false;

// ---------------------------------------------------------------- animation

// Everything the drawing depends on, eased toward a target every frame.
struct Pose {
  float open = 0.0f;   // eyelids, 0 shut .. 1 open
  float happy = 0.0f;  // eyes curving into ^ ^
  float scaleL = 1.0f, scaleR = 1.0f;
  float lookX = 0.0f, lookY = 0.0f;  // -1..1
  float mouthOpen = 0.0f;            // 0..1
  float mouthW = 18.0f;              // px
  float smile = 0.6f;                // -1 frown .. 1 grin, for a closed mouth
  float squiggle = 0.0f;             // a wobbly "huh?" mouth
  float bob = 0.0f;                  // px, the whole face
};

struct State {
  Pose pose;
  Envelope env;

  Mood mood = Mood::Happy;
  uint32_t moodUntil = 0;
  char text[20] = {0};
  uint32_t textUntil = 0;
  uint8_t volStep = 0, volMax = 1;
  uint32_t volUntil = 0;
  bool link = false, phone = false;
  char ssid[20] = {0};

  uint32_t bornAt = 0;
  uint32_t pokedAt = 0;
  uint32_t nextBlinkAt = 0;
  uint32_t blinkAt = 0;
  bool doubleBlink = false;
  uint32_t nextGlanceAt = 0;
  float glanceX = 0.0f, glanceY = 0.0f;

  bool sleeping = false;
  uint32_t sleepAt = 0;
} s;

float ease(float current, float target, float dt, float tauMs) {
  return current + (target - current) * (1.0f - expf(-dt / tauMs));
}

float frand(float lo, float hi) { return lo + (hi - lo) * (random(10001) / 10000.0f); }

void handle(const Msg &m, uint32_t now) {
  switch (m.op) {
    case Op::React:
      s.mood = (Mood)m.a;
      s.moodUntil = now + m.ms;
      s.pokedAt = now;
      break;
    case Op::Say:
      strlcpy(s.text, m.text, sizeof(s.text));
      s.textUntil = now + m.ms;
      s.volUntil = 0;
      break;
    case Op::Volume:
      s.volStep = m.a;
      s.volMax = m.b ? m.b : 1;
      s.volUntil = now + 1300;
      s.textUntil = 0;
      break;
    case Op::Link:
      s.link = m.a;
      s.phone = m.b;
      strlcpy(s.ssid, m.text, sizeof(s.ssid));
      break;
    case Op::Poke:
      s.pokedAt = now;
      break;
    case Op::Sleep:
      s.sleeping = true;
      s.sleepAt = now;
      break;
  }
}

// What the face would like to look like right now, before easing.
Pose target(uint32_t now, float dt) {
  Pose t;
  const audio::State st = audio::state();
  const bool talking = st == audio::State::Playing;
  const uint32_t age = now - s.bornAt;
  const uint32_t idle = now - s.pokedAt;

  // Glances: somewhere new every couple of seconds, smaller while listening.
  if ((int32_t)(now - s.nextGlanceAt) >= 0) {
    const bool centre = random(100) < 35;
    const float range = talking ? 0.35f : 0.85f;
    s.glanceX = centre ? 0.0f : frand(-range, range);
    s.glanceY = centre ? 0.0f : frand(-0.6f * range, 0.5f * range);
    s.nextGlanceAt = now + (talking ? random(1500, 4000) : random(900, 3800));
  }
  t.lookX = s.glanceX;
  t.lookY = s.glanceY;

  if (talking) {
    // The mouth is the voice: no easing beyond the envelope's own, or it lags.
    const float e = s.env.value();
    t.mouthOpen = e;
    t.mouthW = 13.0f + 11.0f * e;
    t.smile = 0.35f;
    t.open = 1.0f - 0.12f * e;  // a little squint on the loud bits
    t.bob = 1.6f * e;
  } else if (st == audio::State::Paused) {
    t.open = 0.62f;
    t.smile = 0.1f;
    t.mouthW = 12.0f;
    t.lookY = 0.25f;
  }

  // Drowsiness, when nothing is going on.
  if (!talking && idle > FACE_DOZE_MS) {
    const float breathe = 0.5f - 0.5f * cosf(2.0f * PI * (now % 4000) / 4000.0f);
    t.open = 0.12f + 0.12f * breathe;
    t.lookX = 0.0f;
    t.lookY = 0.45f;
    t.smile = 0.0f;
    t.mouthOpen = 0.12f + 0.12f * breathe;  // a small snore
    t.mouthW = 9.0f;
  }

  // A reaction overrides all of the above for its moment.
  if ((int32_t)(s.moodUntil - now) > 0) {
    switch (s.mood) {
      case Mood::Happy:
        t.happy = 1.0f;
        t.smile = 1.0f;
        t.mouthOpen = 0.35f;
        t.mouthW = 26.0f;
        t.open = 1.0f;
        break;
      case Mood::Surprised:
        t.scaleL = t.scaleR = 1.18f;
        t.open = 1.0f;
        t.mouthOpen = 0.75f;
        t.mouthW = 11.0f;
        t.lookX = 0.0f;
        t.lookY = -0.2f;
        break;
      case Mood::Confused:
        t.scaleL = 0.72f;
        t.scaleR = 1.08f;
        t.open = 1.0f;
        t.squiggle = 1.0f;
        t.mouthOpen = 0.0f;
        t.lookX = 0.45f;
        t.lookY = -0.5f;
        break;
      case Mood::Giggle:
        t.happy = 1.0f;
        t.mouthOpen = 0.45f + 0.35f * sinf(2.0f * PI * (now % 260) / 260.0f);
        t.mouthW = 22.0f;
        t.bob = 2.0f * fabsf(sinf(2.0f * PI * (now % 520) / 520.0f));
        t.open = 1.0f;
        break;
      case Mood::Sleepy:
        t.open = 0.3f;
        t.smile = -0.3f;
        t.lookY = 0.4f;
        break;
    }
  }

  // Waking up: eyes shut, then they open slowly, blink, look left, look
  // right, and smile at you.
  if (age < 3600) {
    t.lookX = age < 1900 ? 0.0f : age < 2350 ? -0.8f : age < 2800 ? 0.8f : 0.0f;
    t.lookY = age < 1900 ? 0.0f : -0.15f;
    t.open = age < 450 ? 0.0f : 1.0f;
    t.happy = age > 2900 ? 1.0f : 0.0f;
    t.smile = age > 2900 ? 1.0f : 0.2f;
    t.mouthOpen = age > 2900 ? 0.3f : 0.0f;
    t.mouthW = age > 2900 ? 24.0f : 12.0f;
  }

  if (s.link) {
    t.lookY = s.phone ? 0.0f : -0.7f;
    t.happy = s.phone ? 1.0f : 0.0f;
  }

  // Going to sleep: shut, and stay shut.
  if (s.sleeping) {
    t = Pose{};
    t.open = 0.0f;
    t.smile = 0.15f;
    t.mouthW = 10.0f;
    t.lookY = 0.3f;
  }

  (void)dt;
  return t;
}

// The blink, on top of whatever the lids are doing.
float blink(uint32_t now) {
  if ((int32_t)(now - s.nextBlinkAt) >= 0) {
    s.blinkAt = now;
    s.doubleBlink = random(100) < 18;
    s.nextBlinkAt = now + random(2200, 6000);
  }
  const uint32_t t = now - s.blinkAt;
  const uint32_t len = 150;
  float k = 1.0f;
  if (t < len) {
    k = fabsf((float)t / len * 2.0f - 1.0f);
  } else if (s.doubleBlink && t >= len + 90 && t < 2 * len + 90) {
    k = fabsf((float)(t - len - 90) / len * 2.0f - 1.0f);
  }
  return k;
}

void drawEye(int cx, int cy, float scale, float open, float happy) {
  const int w = (int)(25 * scale);
  const int fullH = (int)(30 * scale);
  int h = (int)(fullH * open + 0.5f);
  if (h < 3) {
    // Shut: a gentle downward curve, like a sleeping eye.
    for (int dx = -w / 2; dx <= w / 2; dx++) {
      const float u = (float)dx / (w / 2);
      const int y = cy + (int)(3.0f * (1.0f - u * u));
      g_panel.drawFastVLine(cx + dx, y, 2, SSD_WHITE);
    }
    return;
  }
  const int x = cx - w / 2;
  const int y = cy - h / 2;
  const int r = min(min(w, h) / 2, (int)(9 * scale));
  g_panel.fillRoundRect(x, y, w, h, r, SSD_WHITE);
  if (happy > 0.02f) {
    // A dark ellipse rising from below cuts the eye into a ^ — the further
    // it rises, the happier.
    const int cutY = cy + h / 2 + (int)((1.0f - happy) * h * 0.9f) + 2;
    fillEllipse(cx, cutY, (int)(w * 0.75f), (int)(h * 0.62f), SSD_BLACK);
  }
}

void drawMouth(int cx, int cy, const Pose &p) {
  const int w = (int)p.mouthW;
  if (p.squiggle > 0.5f) {
    for (int dx = -w / 2; dx <= w / 2; dx++) {
      const int y = cy + (int)roundf(2.0f * sinf(dx * 0.6f));
      g_panel.drawFastVLine(cx + dx, y, 2, SSD_WHITE);
    }
    return;
  }
  const int h = (int)(p.mouthOpen * 15.0f + 0.5f);
  if (h < 3) {
    // Closed: a curve, smiling or not.
    for (int dx = -w / 2; dx <= w / 2; dx++) {
      const float u = (float)dx / (w / 2 ? w / 2 : 1);
      const int y = cy - (int)roundf(p.smile * 4.0f * (u * u - 0.5f));
      g_panel.drawFastVLine(cx + dx, y, 2, SSD_WHITE);
    }
    return;
  }
  // Open: rounder the more it opens, and flatter on top when smiling, so a
  // laugh looks like a laugh and a story looks like talking.
  fillEllipse(cx, cy, w / 2, h / 2 + 1, SSD_WHITE);
  if (p.smile > 0.5f && h > 6) {
    g_panel.fillRect(cx - w / 2 - 1, cy - h / 2 - 2, w + 2, (int)(h * 0.22f) + 1, SSD_BLACK);
  }
  if (h > 9) {
    // A tongue, or at least the dark of a mouth.
    fillEllipse(cx, cy + h / 4, max(2, w / 4), max(1, h / 6), SSD_BLACK);
  }
}

void drawOverlay(uint32_t now, int mouthY) {
  // Text or the volume bars stand in for the mouth while they are up.
  if (s.link) {
    g_panel.setTextSize(1);
    g_panel.setTextColor(SSD_WHITE);
    const char *line = s.phone ? "connected" : s.ssid;
    int16_t x1, y1;
    uint16_t tw, th;
    g_panel.getTextBounds(line, 0, 0, &x1, &y1, &tw, &th);
    g_panel.setCursor((W - tw) / 2, H - 9);
    g_panel.print(line);
    return;
  }
  if ((int32_t)(s.volUntil - now) > 0) {
    const int bars = s.volMax;
    const int bw = 6, gap = 3;
    const int total = bars * bw + (bars - 1) * gap;
    const int x0 = (W - total) / 2;
    for (int i = 0; i < bars; i++) {
      const int bh = 3 + i;  // a ramp, louder to the right
      const int x = x0 + i * (bw + gap);
      const int y = H - 3 - bh;
      if (i < s.volStep) {
        g_panel.fillRect(x, y, bw, bh, SSD_WHITE);
      } else {
        g_panel.drawRect(x, y, bw, bh, SSD_WHITE);
      }
    }
    return;
  }
  if ((int32_t)(s.textUntil - now) > 0) {
    g_panel.setTextSize(2);
    g_panel.setTextColor(SSD_WHITE);
    int16_t x1, y1;
    uint16_t tw, th;
    g_panel.getTextBounds(s.text, 0, 0, &x1, &y1, &tw, &th);
    g_panel.setCursor((W - tw) / 2, mouthY - th / 2);
    g_panel.print(s.text);
  }
}

bool mouthReplaced(uint32_t now) {
  return s.link || (int32_t)(s.volUntil - now) > 0 || (int32_t)(s.textUntil - now) > 0;
}

void drawZs(uint32_t now) {
  // Two little z's floating up and away from the corner.
  g_panel.setTextSize(1);
  g_panel.setTextColor(SSD_WHITE);
  for (int k = 0; k < 2; k++) {
    const float t = ((now + k * 1300) % 2600) / 2600.0f;
    g_panel.setCursor(104 + (int)(t * 10), 22 - (int)(t * 20));
    g_panel.print('z');
  }
}

void render(uint32_t now, float dt) {
  s.env.update(audio::level(), dt);
  const Pose t = target(now, dt);
  Pose &p = s.pose;

  const bool waking = now - s.bornAt < 3600;
  const float lidTau = s.sleeping ? 160.0f : waking ? 260.0f : 55.0f;
  p.open = ease(p.open, t.open, dt, lidTau);
  p.happy = ease(p.happy, t.happy, dt, 70.0f);
  p.scaleL = ease(p.scaleL, t.scaleL, dt, 60.0f);
  p.scaleR = ease(p.scaleR, t.scaleR, dt, 60.0f);
  p.lookX = ease(p.lookX, t.lookX, dt, 45.0f);  // eyes dart, they do not drift
  p.lookY = ease(p.lookY, t.lookY, dt, 45.0f);
  p.mouthW = ease(p.mouthW, t.mouthW, dt, 50.0f);
  p.smile = ease(p.smile, t.smile, dt, 80.0f);
  p.squiggle = t.squiggle;
  // Talking: the envelope already moves like a mouth; easing again would lag
  // the voice. Everything else gets a short ease.
  p.mouthOpen = audio::state() == audio::State::Playing && t.squiggle == 0.0f
                    ? t.mouthOpen
                    : ease(p.mouthOpen, t.mouthOpen, dt, 50.0f);
  p.bob = ease(p.bob, t.bob, dt, 40.0f);

  const bool dozing = !s.sleeping && audio::state() != audio::State::Playing &&
                      now - s.pokedAt > FACE_DOZE_MS;
  const float lids = (s.sleeping || waking) ? p.open : p.open * blink(now);

  g_panel.fillScreen(SSD_BLACK);
  const int ex = (int)(p.lookX * 10.0f);
  const int ey = (int)(p.lookY * 6.0f + p.bob);
  // Turning to one side, the far eye is a touch smaller: cheap depth.
  drawEye(40 + ex, 24 + ey, p.scaleL * (1.0f + 0.07f * p.lookX), lids, p.happy);
  drawEye(88 + ex, 24 + ey, p.scaleR * (1.0f - 0.07f * p.lookX), lids, p.happy);

  const int mouthY = 52 + (int)(p.bob * 0.6f) + (int)(p.lookY * 2.0f);
  if (mouthReplaced(now)) {
    drawOverlay(now, mouthY);
  } else {
    drawMouth(64 + (int)(p.lookX * 4.0f), mouthY, p);
  }
  if (dozing) {
    drawZs(now);
  }
  g_panel.flush();
}

void faceTask(void *) {
  uint32_t last = millis();
  TickType_t wake = xTaskGetTickCount();
  for (;;) {
    const uint32_t now = millis();
    Msg m;
    while (xQueueReceive(g_queue, &m, 0) == pdTRUE) {
      handle(m, now);
    }

    // The panel rests once nobody has touched anything for long enough; a poke
    // brings it back with a little start.
    const bool playing = audio::state() == audio::State::Playing;
    const bool rest = !s.sleeping && !playing && !s.link && now - s.pokedAt > FACE_OFF_MS;
    if (rest && g_panel.isOn()) {
      LOGD("face: resting the panel");
      g_panel.power(false);
    } else if (!rest && !g_panel.isOn() && !s.sleeping) {
      g_panel.power(true);
      s.mood = Mood::Surprised;
      s.moodUntil = now + 500;
    }

    const float dt = fmaxf(1.0f, (float)(now - last));
    last = now;
    if (g_panel.isOn()) {
      render(now, dt);
    }

    if (s.sleeping && now - s.sleepAt > 750) {
      g_panel.power(false);
      xSemaphoreGive(g_asleep);
      vTaskDelete(nullptr);
    }
    vTaskDelayUntil(&wake, pdMS_TO_TICKS(FACE_FRAME_MS));
  }
}

void send(const Msg &m) {
  if (g_queue) {
    xQueueSend(g_queue, &m, 0);
  }
}

}  // namespace

bool begin() {
  i2cbus::begin();
  g_present = g_panel.begin();
  if (!g_present) {
    LOGE("face: no display at 0x%02X", OLED_ADDRESS);
    return false;
  }
  LOGI("face: display at 0x%02X", OLED_ADDRESS);

  const uint32_t now = millis();
  s.bornAt = now;
  s.pokedAt = now;
  s.nextBlinkAt = now + 3800;   // the wake-up has its own blink
  s.nextGlanceAt = now + 3800;
  s.blinkAt = now - 10000;

  g_queue = xQueueCreate(12, sizeof(Msg));
  g_asleep = xSemaphoreCreateBinary();
  // Core 1 alongside loop(), at the same priority: the frame is mostly waiting
  // on the bus, and loop() spends most of its time waiting on the reader.
  if (!g_queue || !g_asleep ||
      xTaskCreatePinnedToCore(faceTask, "face", 4096, nullptr, 1, nullptr, 1) != pdPASS) {
    LOGE("cannot start the face task");
    return false;
  }
  return true;
}

void react(Mood mood, uint32_t ms) {
  Msg m{};
  m.op = Op::React;
  m.a = (uint8_t)mood;
  m.ms = ms;
  send(m);
}

void say(const char *text, uint32_t ms) {
  Msg m{};
  m.op = Op::Say;
  m.ms = ms;
  strlcpy(m.text, text, sizeof(m.text));
  send(m);
}

void volume(uint8_t step, uint8_t max) {
  Msg m{};
  m.op = Op::Volume;
  m.a = step;
  m.b = max;
  send(m);
}

void link(bool on, bool phone, const char *ssid) {
  Msg m{};
  m.op = Op::Link;
  m.a = on;
  m.b = phone;
  strlcpy(m.text, ssid ? ssid : "", sizeof(m.text));
  send(m);
}

void poke() {
  Msg m{};
  m.op = Op::Poke;
  send(m);
}

void sleep() {
  if (!g_queue) {
    return;
  }
  Msg m{};
  m.op = Op::Sleep;
  send(m);
  xSemaphoreTake(g_asleep, pdMS_TO_TICKS(1500));
}

}  // namespace face

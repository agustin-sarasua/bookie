#include "light.h"

#include <Adafruit_NeoPixel.h>
#include <driver/gpio.h>

#include "audio.h"
#include "config.h"
#include "envelope.h"
#include "log.h"
#include "settings.h"

namespace light {
namespace {

// ---------------------------------------------------------------- colour

struct Rgb {
  float r, g, b;
};

Rgb operator*(const Rgb &c, float k) { return {c.r * k, c.g * k, c.b * k}; }
Rgb operator+(const Rgb &a, const Rgb &b) { return {a.r + b.r, a.g + b.g, a.b + b.b}; }
Rgb mix(const Rgb &a, const Rgb &b, float t) { return a * (1.0f - t) + b * t; }

// Hue on the 16-bit wheel NeoPixel uses: 0 red, ~21845 green, ~43690 blue.
Rgb hsv(uint16_t hue, float sat, float val) {
  const float h = hue / 65536.0f * 6.0f;
  const int sector = (int)h;
  const float f = h - sector;
  const float p = val * (1.0f - sat);
  const float q = val * (1.0f - sat * f);
  const float t = val * (1.0f - sat * (1.0f - f));
  switch (sector) {
    case 0: return {val, t, p};
    case 1: return {q, val, p};
    case 2: return {p, val, t};
    case 3: return {p, q, val};
    case 4: return {t, p, val};
    default: return {val, p, q};
  }
}

float clamp01(float v) { return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v); }
float smooth(float t) {
  t = clamp01(t);
  return t * t * (3.0f - 2.0f * t);
}
float wave01(float phase) { return 0.5f + 0.5f * sinf(2.0f * PI * phase); }

// Round the ring: 0 is the top LED, increasing the way the arcs grow.
float angleOf(int i) { return (float)i / LED_RING_COUNT; }
int physical(int i) {
  const int n = LED_RING_COUNT;
  const int step = LED_RING_CLOCKWISE ? i : -i;
  return ((LED_RING_OFFSET + step) % n + n) % n;
}

// How far `a` sits behind `head` going round, 0..1.
float behind(float head, float a) {
  float d = head - a;
  d -= floorf(d);
  return d;
}

// ---------------------------------------------------------------- lamp scenes

constexpr uint8_t kScenes = 6;
const char *const kSceneNames[kScenes] = {"warm", "candle", "sunset", "ocean", "rainbow", "night"};

// Cheap smooth noise, for the candle: a few incommensurate sines per LED.
float flicker(int i, float t) {
  const float k = i * 1.7f;
  return 0.5f + 0.22f * sinf(t * 0.0071f + k) + 0.16f * sinf(t * 0.0173f + k * 2.3f) +
         0.12f * sinf(t * 0.041f + k * 0.7f);
}

Rgb scene(uint8_t which, int i, float t) {
  const float a = angleOf(i);
  switch (which) {
    case 0:  // warm white, ~2700 K on a WS2812
      return {1.0f, 0.62f, 0.28f};
    case 1: {  // candle: amber that breathes and flickers, never quite still
      const float f = flicker(i, t);
      return Rgb{1.0f, 0.45f + 0.12f * f, 0.08f} * (0.55f + 0.45f * f);
    }
    case 2: {  // sunset: orange to rose to violet, drifting round
      const float p = wave01(a + t / 24000.0f);
      return mix(Rgb{1.0f, 0.38f, 0.05f}, Rgb{0.75f, 0.12f, 0.55f}, p);
    }
    case 3: {  // ocean: teal and deep blue, a slow swell
      const float p = wave01(a * 2.0f - t / 9000.0f) * wave01(a - t / 17000.0f);
      return mix(Rgb{0.0f, 0.18f, 0.85f}, Rgb{0.0f, 0.75f, 0.65f}, p);
    }
    case 4:  // rainbow, pastel, turning slowly
      return hsv((uint16_t)((a + t / 30000.0f) * 65536.0f), 0.6f, 1.0f);
    default:  // night light: a low ember red-amber
      return Rgb{1.0f, 0.22f, 0.02f} * 0.45f;
  }
}

// ---------------------------------------------------------------- commands

enum class Op : uint8_t {
  Toggle, On, NextScene, DimStart, DimStop,
  Tag, Unknown, Volume, Language, Limit, Tickle, LowBattery, Link, Sleep,
};

struct Msg {
  Op op;
  uint16_t a;
  uint16_t b;
};

enum class Fx : uint8_t { None, Boot, Tag, Unknown, Volume, Language, Limit, LowBattery };

QueueHandle_t g_queue = nullptr;
SemaphoreHandle_t g_asleep = nullptr;
volatile bool g_lampTarget = false;

Adafruit_NeoPixel g_strip(LED_RING_COUNT, PIN_LED_DATA, NEO_GRB + NEO_KHZ800);

// Everything below belongs to the light task alone.
struct State {
  // lamp
  bool lampOn = false;
  float lampFade = 0.0f;  // 0 off .. 1 on, linear; eased when drawn
  float lampLevel = LAMP_DEFAULT_LEVEL;
  float fadeMs = LAMP_FADE_MS;
  uint8_t scene = 0;
  uint8_t prevScene = 0;
  float sceneBlend = 1.0f;
  bool dimming = false;
  int8_t dimDir = 1;
  uint32_t lampTouchedAt = 0;

  // story
  uint16_t storyHue = 8000;
  float storyMix = 0.0f;
  float wavePhase = 0.0f;
  Envelope env;

  // sparkles, additive, decaying
  float spark[LED_RING_COUNT] = {0};
  uint16_t sparkHue[LED_RING_COUNT] = {0};
  uint32_t tickleUntil = 0;

  // one-shot effect
  Fx fx = Fx::None;
  uint32_t fxAt = 0;
  uint16_t fxA = 0, fxB = 0;

  Link link = Link::Off;
  float linkMix = 0.0f;

  bool sleeping = false;
  float master = 1.0f;

  float residual[LED_RING_COUNT][3] = {{0}};
} s;

void startFx(Fx fx, uint16_t a = 0, uint16_t b = 0) {
  s.fx = fx;
  s.fxAt = millis();
  s.fxA = a;
  s.fxB = b;
}

void setLamp(bool on) {
  s.lampOn = on;
  g_lampTarget = on;
  s.fadeMs = LAMP_FADE_MS;
  s.lampTouchedAt = millis();
  LOGI("lamp %s (%s, %u%%)", on ? "on" : "off", kSceneNames[s.scene], (unsigned)(s.lampLevel * 100));
}

void handle(const Msg &m) {
  switch (m.op) {
    case Op::Toggle:
      setLamp(!s.lampOn);
      break;
    case Op::On:
      setLamp(true);
      break;
    case Op::NextScene:
      s.prevScene = s.scene;
      s.scene = (s.scene + 1) % kScenes;
      s.sceneBlend = 0.0f;
      settings::setLamp(s.scene, s.lampLevel);
      setLamp(true);
      break;
    case Op::DimStart:
      if (!s.lampOn) {
        // Held from dark: come up from the bottom, not jump to the last level.
        s.lampLevel = LAMP_MIN_LEVEL;
        s.lampFade = 1.0f;
        s.dimDir = 1;
        setLamp(true);
      } else if (s.lampLevel >= 0.98f) {
        s.dimDir = -1;
      } else if (s.lampLevel <= LAMP_MIN_LEVEL + 0.02f) {
        s.dimDir = 1;
      }
      s.dimming = true;
      break;
    case Op::DimStop:
      if (s.dimming) {
        s.dimming = false;
        s.dimDir = -s.dimDir;  // the next hold goes the other way
        s.lampTouchedAt = millis();
        settings::setLamp(s.scene, s.lampLevel);
        LOGI("lamp level %u%%", (unsigned)(s.lampLevel * 100));
      }
      break;
    case Op::Tag:
      s.storyHue = m.a;
      startFx(Fx::Tag, m.a);
      break;
    case Op::Unknown:
      startFx(Fx::Unknown);
      break;
    case Op::Volume:
      startFx(Fx::Volume, m.a, m.b);
      break;
    case Op::Language:
      startFx(Fx::Language, m.a);
      break;
    case Op::Limit:
      startFx(Fx::Limit);
      break;
    case Op::Tickle:
      s.tickleUntil = millis() + 1400;
      break;
    case Op::LowBattery:
      startFx(Fx::LowBattery);
      break;
    case Op::Link:
      s.link = (Link)m.a;
      break;
    case Op::Sleep:
      s.sleeping = true;
      break;
  }
}

void sparkle(int i, uint16_t hue, float level) {
  if (level > s.spark[i]) {
    s.spark[i] = level;
    s.sparkHue[i] = hue;
  }
}

// ---------------------------------------------------------------- effects
// Each one draws over `px` and says whether it is still running.

bool drawFx(Rgb *px, uint32_t now) {
  const float t = (float)(now - s.fxAt);
  const int n = LED_RING_COUNT;
  switch (s.fx) {
    case Fx::None:
      return false;

    case Fx::Boot: {
      // A comet that gathers speed round the ring, gold turning rose, then the
      // whole ring blooms and settles into whatever the lamp is doing.
      constexpr float kRun = 1500.0f, kBloom = 450.0f, kSettle = 700.0f;
      if (t > kRun + kBloom + kSettle) {
        return false;
      }
      const float run = clamp01(t / kRun);
      const float head = 2.0f * powf(run, 1.7f);
      for (int i = 0; i < n; i++) {
        const float a = angleOf(i);
        Rgb c{0, 0, 0};
        if (t < kRun + kBloom) {
          const float d = behind(head, a);
          const float tail = expf(-d * 7.0f) * smooth(run * 6.0f);
          c = hsv((uint16_t)(5500 + 56000 * run + 4000 * d), 0.75f, 1.0f) * tail;
          const float bloom = smooth((t - kRun) / kBloom);
          c = mix(c, Rgb{1.0f, 0.7f, 0.4f} * 0.8f, bloom);
          px[i] = c;
        } else {
          const float k = 1.0f - smooth((t - kRun - kBloom) / kSettle);
          px[i] = mix(px[i], Rgb{1.0f, 0.7f, 0.4f} * 0.8f, k);
        }
      }
      return true;
    }

    case Fx::Tag: {
      // A spark at the top, two comets racing down both sides in the tag's
      // colour, a full-ring bloom where they meet, then the story takes over.
      constexpr float kFlash = 140.0f, kRace = 560.0f, kBloom = 900.0f;
      if (t > kFlash + kRace + kBloom) {
        return false;
      }
      const uint16_t hue = s.fxA;
      for (int i = 0; i < n; i++) {
        const float a = angleOf(i);
        const float fromTop = fminf(a, 1.0f - a) * 2.0f;  // 0 at top, 1 at bottom
        Rgb c;
        float alpha;
        if (t < kFlash) {
          const float k = t / kFlash;
          c = Rgb{1, 1, 1} * (k * expf(-fromTop * 5.0f));
          alpha = k * expf(-fromTop * 3.0f);
        } else if (t < kFlash + kRace) {
          const float head = smooth((t - kFlash) / kRace);
          const float d = head - fromTop;  // > 0: already swept
          const float lit = d < 0.0f ? 0.0f : 0.35f + 0.65f * expf(-d * 6.0f);
          c = mix(hsv(hue, 0.9f, 1.0f), Rgb{1, 1, 1}, d >= 0 && d < 0.12f ? 0.6f : 0.0f) * lit;
          alpha = 1.0f;
        } else {
          const float k = (t - kFlash - kRace) / kBloom;
          const float pulse = 0.55f + 0.45f * sinf(PI * clamp01(k * 2.0f));
          c = hsv(hue, 0.85f, 1.0f) * pulse;
          alpha = 1.0f - smooth(k);
        }
        px[i] = mix(px[i], c, alpha);
      }
      return true;
    }

    case Fx::Unknown: {
      // A little arc at the top shaking its head: no.
      constexpr float kLen = 1100.0f;
      if (t > kLen) {
        return false;
      }
      const float centre = 0.11f * sinf(2.0f * PI * t / 340.0f) * (1.0f - t / kLen);
      const float alpha = 1.0f - smooth((t - 700.0f) / 400.0f);
      for (int i = 0; i < n; i++) {
        float d = angleOf(i) - centre;
        d -= roundf(d);
        const float lit = expf(-(d * d) * 260.0f);
        px[i] = mix(px[i], Rgb{1.0f, 0.2f, 0.02f} * lit, alpha);
      }
      return true;
    }

    case Fx::Volume: {
      // An arc from the top, as long as the volume is loud, over a dimmed ring.
      constexpr float kHold = 1200.0f, kFade = 450.0f;
      if (t > kHold + kFade) {
        return false;
      }
      const float frac = s.fxB ? (float)s.fxA / s.fxB : 0.0f;
      const float alpha = 1.0f - smooth((t - kHold) / kFade);
      const float grow = smooth(t / 180.0f);
      for (int i = 0; i < n; i++) {
        const float a = angleOf(i);
        const float fill = clamp01((frac * grow - a) * n);  // the edge LED partly lit
        const Rgb on = hsv((uint16_t)(30000 - 26000 * a), 0.45f, 0.85f);  // cool to warm
        px[i] = mix(px[i], mix(Rgb{0.02f, 0.02f, 0.03f}, on, fill), alpha);
      }
      return true;
    }

    case Fx::Language: {
      // A wipe round the ring in the new language's colour.
      constexpr float kWipe = 550.0f, kHold = 250.0f, kFade = 450.0f;
      if (t > kWipe + kHold + kFade) {
        return false;
      }
      const float pos = smooth(t / kWipe);
      const float alpha = 1.0f - smooth((t - kWipe - kHold) / kFade);
      for (int i = 0; i < n; i++) {
        const float lit = clamp01((pos - angleOf(i)) * n);
        px[i] = mix(px[i], hsv(s.fxA, 0.8f, 0.9f) * lit, alpha * (0.3f + 0.7f * lit));
      }
      return true;
    }

    case Fx::Limit: {
      constexpr float kLen = 380.0f;
      if (t > kLen) {
        return false;
      }
      const float alpha = 0.55f * sinf(PI * t / kLen);
      for (int i = 0; i < n; i++) {
        px[i] = mix(px[i], Rgb{0.6f, 0.08f, 0.02f}, alpha);
      }
      return true;
    }

    case Fx::LowBattery: {
      constexpr float kLen = 2700.0f;
      if (t > kLen) {
        return false;
      }
      const float alpha = 0.8f * powf(sinf(PI * t / 900.0f), 2.0f);
      for (int i = 0; i < n; i++) {
        px[i] = mix(px[i], Rgb{1.0f, 0.03f, 0.0f} * 0.7f, alpha);
      }
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------- frame

void render(uint32_t now, float dt) {
  const int n = LED_RING_COUNT;

  // Lamp: fade, dimmer, scene cross-fade, and the night-light timeout.
  const float fadeStep = dt / s.fadeMs;
  s.lampFade = s.lampOn ? fminf(1.0f, s.lampFade + fadeStep) : fmaxf(0.0f, s.lampFade - fadeStep);
  if (s.dimming) {
    s.lampLevel += s.dimDir * dt / LAMP_DIM_SWEEP_MS * (1.0f - LAMP_MIN_LEVEL);
    s.lampLevel = fminf(1.0f, fmaxf(LAMP_MIN_LEVEL, s.lampLevel));
  }
  s.sceneBlend = fminf(1.0f, s.sceneBlend + dt / 700.0f);
  if (LAMP_AUTO_OFF_MS && s.lampOn && now - s.lampTouchedAt > LAMP_AUTO_OFF_MS) {
    LOGI("lamp: %lu min without a touch, fading out", (unsigned long)(LAMP_AUTO_OFF_MS / 60000));
    setLamp(false);
    s.fadeMs = 8000.0f;  // a slow goodnight rather than a switch
  }

  // Story: follows the voice while playing, breathes while paused.
  const audio::State st = audio::state();
  s.env.update(audio::level(), dt);
  const float storyTarget = st == audio::State::Playing ? 1.0f : st == audio::State::Paused ? 0.7f : 0.0f;
  s.storyMix += (storyTarget - s.storyMix) * (1.0f - powf(0.5f, dt / 220.0f));
  const float e = s.env.value();
  s.wavePhase += dt * (0.00008f + 0.0009f * e);
  if (st == audio::State::Playing && s.env.onset()) {
    sparkle(random(n), s.storyHue + 9000 + random(8000), 0.5f + 0.5f * e);
  }
  // Animation time, wrapped hourly: a float of milliseconds since boot runs
  // out of precision overnight, and a lamp is on overnight.
  const float tf = (float)(now % 3600000UL);
  const float breathe = 0.5f - 0.5f * cosf(2.0f * PI * tf / 3600.0f);

  if ((int32_t)(s.tickleUntil - now) > 0 && random(100) < 35) {
    sparkle(random(n), random(65536), 0.9f);
  }

  s.linkMix += ((s.link != Link::Off ? 1.0f : 0.0f) - s.linkMix) * (1.0f - powf(0.5f, dt / 150.0f));

  const float lampVis = smooth(s.lampFade) * s.lampLevel;
  Rgb px[LED_RING_COUNT];
  for (int i = 0; i < n; i++) {
    const float a = angleOf(i);
    Rgb lamp = scene(s.scene, i, tf);
    if (s.sceneBlend < 1.0f) {
      lamp = mix(scene(s.prevScene, i, tf), lamp, smooth(s.sceneBlend));
    }
    lamp = lamp * lampVis;

    Rgb story{0, 0, 0};
    if (s.storyMix > 0.001f) {
      if (st == audio::State::Paused) {
        story = hsv(s.storyHue, 0.8f, 1.0f) * (0.08f + 0.22f * breathe);
      } else {
        // A wave of the story's colour turning round the ring, faster and
        // brighter as the voice gets louder; a floor so it never goes out
        // mid-sentence.
        const float w = wave01(a - s.wavePhase);
        const uint16_t hue = s.storyHue + (int16_t)((w - 0.5f) * 5000.0f);
        story = hsv(hue, 0.82f, 1.0f) * (0.16f + 0.62f * e * (0.45f + 0.55f * w));
      }
    }
    // With the lamp on the story rides on top of it, and the lamp steps back
    // a little to make room; with it off, the story is the only light.
    Rgb c = lamp * (1.0f - 0.4f * s.storyMix) + story * s.storyMix;

    if (s.spark[i] > 0.01f) {
      c = c + hsv(s.sparkHue[i], 0.5f, 1.0f) * s.spark[i];
    }
    px[i] = c;
  }
  for (int i = 0; i < n; i++) {
    s.spark[i] *= powf(0.5f, dt / 110.0f);
  }

  if (!drawFx(px, now)) {
    s.fx = Fx::None;
  }

  // Link mode: the toy is a card reader for now, and the ring says so — a
  // blue spinner while it waits for the phone, a calm blue breath once it is
  // here.
  if (s.linkMix > 0.01f) {
    for (int i = 0; i < n; i++) {
      Rgb c;
      if (s.link == Link::Phone) {
        c = Rgb{0.05f, 0.25f, 1.0f} * (0.15f + 0.35f * breathe);
      } else {
        const float head = tf / 1100.0f;
        const float d = fminf(behind(head, angleOf(i)), behind(head + 0.5f, angleOf(i)));
        c = Rgb{0.05f, 0.3f, 1.0f} * (0.04f + 0.8f * expf(-d * 9.0f));
      }
      px[i] = mix(px[i], c, s.linkMix);
    }
  }

  if (s.sleeping) {
    s.master = fmaxf(0.0f, s.master - dt / 900.0f);
  }

  // Out: perceptual to linear (gamma 2.2), the current cap, and the rounding
  // error carried into the next frame so a slow fade near black glides
  // instead of stepping.
  const float m = smooth(s.master);
  for (int i = 0; i < n; i++) {
    const float ch[3] = {px[i].r, px[i].g, px[i].b};
    uint8_t out[3];
    for (int k = 0; k < 3; k++) {
      const float lin = powf(clamp01(ch[k] * m), 2.2f) * LED_MAX_BRIGHTNESS + s.residual[i][k];
      const float q = floorf(lin + 0.5f);
      out[k] = (uint8_t)fminf(255.0f, q);
      s.residual[i][k] = fmaxf(-0.5f, fminf(0.5f, lin - q));
    }
    g_strip.setPixelColor(physical(i), out[0], out[1], out[2]);
  }
  g_strip.show();
}

void lightTask(void *) {
  uint32_t last = millis();
  TickType_t wake = xTaskGetTickCount();
  for (;;) {
    Msg m;
    while (xQueueReceive(g_queue, &m, 0) == pdTRUE) {
      handle(m);
    }
    const uint32_t now = millis();
    const float dt = fmaxf(1.0f, (float)(now - last));
    last = now;
    render(now, dt);

    if (s.sleeping && s.master <= 0.0f) {
      g_strip.clear();
      g_strip.show();
      delay(2);
      // Held low through the sleep: a floating data line is noise, and noise
      // is random colours on a ring that is still powered from the cell.
      pinMode(PIN_LED_DATA, OUTPUT);
      digitalWrite(PIN_LED_DATA, LOW);
      gpio_hold_en((gpio_num_t)PIN_LED_DATA);
      xSemaphoreGive(g_asleep);
      vTaskDelete(nullptr);
    }
    vTaskDelayUntil(&wake, pdMS_TO_TICKS(LIGHT_FRAME_MS));
  }
}

void send(Op op, uint16_t a = 0, uint16_t b = 0) {
  if (!g_queue) {
    return;
  }
  const Msg m{op, a, b};
  xQueueSend(g_queue, &m, 0);
}

}  // namespace

void begin(bool lampOn) {
  gpio_hold_dis((gpio_num_t)PIN_LED_DATA);
  g_strip.begin();
  g_strip.clear();
  g_strip.show();

  uint8_t scene = 0;
  float level = LAMP_DEFAULT_LEVEL;
  settings::lamp(scene, level);
  s.scene = s.prevScene = scene < kScenes ? scene : 0;
  s.lampLevel = fminf(1.0f, fmaxf(LAMP_MIN_LEVEL, level));
  s.lampOn = lampOn;
  g_lampTarget = lampOn;
  s.lampTouchedAt = millis();
  startFx(Fx::Boot);

  g_queue = xQueueCreate(16, sizeof(Msg));
  g_asleep = xSemaphoreCreateBinary();
  // Core 0, under the audio decoder: a late frame is invisible, a late sample
  // is a click.
  if (!g_queue || !g_asleep ||
      xTaskCreatePinnedToCore(lightTask, "light", 4096, nullptr, 2, nullptr, 0) != pdPASS) {
    LOGE("cannot start the light task");
  }
}

void lampToggle() { send(Op::Toggle); }
void lampOn() { send(Op::On); }
void lampNextScene() { send(Op::NextScene); }
void dimStart() { send(Op::DimStart); }
void dimStop() { send(Op::DimStop); }
bool lampIsOn() { return g_lampTarget; }

void tag(uint16_t hue) { send(Op::Tag, hue); }
void tagUnknown() { send(Op::Unknown); }
void volume(uint8_t step, uint8_t max) { send(Op::Volume, step, max); }
void language(const String &code) { send(Op::Language, hueFor(code.c_str())); }
void limit() { send(Op::Limit); }
void tickle() { send(Op::Tickle); }
void lowBattery() { send(Op::LowBattery); }
void link(Link state) { send(Op::Link, (uint16_t)state); }

void sleep() {
  if (!g_queue) {
    return;
  }
  send(Op::Sleep);
  xSemaphoreTake(g_asleep, pdMS_TO_TICKS(1500));
}

uint16_t hueFor(const char *text) {
  uint32_t h = 2166136261u;  // FNV-1a
  for (; *text; text++) {
    h = (h ^ (uint8_t)*text) * 16777619u;
  }
  return (uint16_t)(h ^ (h >> 16));
}

}  // namespace light

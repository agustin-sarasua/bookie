#include "audio.h"

#include <AudioFileSourceBuffer.h>
#include <AudioFileSourceID3.h>
#include <AudioFileSourceSD.h>
#include <AudioGeneratorMP3.h>
#include <AudioGeneratorWAV.h>
#include <AudioOutputI2S.h>

#include "config.h"
#include "log.h"
#include "sdfs.h"

namespace audio {
namespace {

enum class CmdType : uint8_t { Play, Stop, Pause, Resume, TogglePause, Gain, Chime };

struct Cmd {
  CmdType type;
  char path[AUDIO_PATH_MAX];
  float gain;
  chimes::Chime chime;
  int8_t transpose;
};

// The loudness meter the face and the ring dance to. Every sample that makes it
// into the DMA ring is metered in blocks; a block's RMS is reported only once
// the speaker is actually playing it, which is the depth of the DMA ring later.
// Measured on the way in, the mouth would open ~70 ms before the voice does.
constexpr uint16_t kMeterBlock = 256;  // frames per reading, ~6 ms at 44.1 kHz
constexpr uint8_t kMeterRing = 32;     // power of two, deeper than the DMA ring
constexpr uint8_t kMeterLag = (I2S_DMA_BUFFERS * 128) / kMeterBlock;
static_assert(kMeterLag < kMeterRing, "meter ring shallower than the DMA ring");

volatile uint16_t g_meter[kMeterRing] = {0};
volatile uint8_t g_meterHead = 0;
volatile uint32_t g_meterAt = 0;
float g_meterSum = 0.0f;
uint16_t g_meterCount = 0;

void meter(const int16_t sample[2]) {
  const float v = sample[0] / 32768.0f;  // before the gain: the face moves at any volume
  g_meterSum += v * v;
  if (++g_meterCount < kMeterBlock) {
    return;
  }
  const float rms = sqrtf(g_meterSum / kMeterBlock);
  g_meterSum = 0.0f;
  g_meterCount = 0;
  const uint8_t head = (g_meterHead + 1) & (kMeterRing - 1);
  g_meter[head] = (uint16_t)(fminf(rms * 2.0f, 1.0f) * 65535.0f);
  g_meterHead = head;
  g_meterAt = millis();
}

// AudioOutputI2S, with what a chime has to borrow from the decoder and give
// back: the format it left the output in, and whether the driver is up at all.
class Output : public AudioOutputI2S {
 public:
  using AudioOutputI2S::AudioOutputI2S;
  bool on() const { return i2sOn; }
  uint32_t rate() const { return hertz; }
  uint8_t bits() const { return bps; }
  uint8_t chans() const { return channels; }

  bool ConsumeSample(int16_t sample[2]) override {
    if (!AudioOutputI2S::ConsumeSample(sample)) {
      return false;  // DMA full: the decoder offers the same sample again later
    }
    meter(sample);
    return true;
  }
};

QueueHandle_t g_queue = nullptr;
TaskHandle_t g_task = nullptr;

Output *g_out = nullptr;
AudioFileSourceSD *g_file = nullptr;
AudioFileSourceBuffer *g_buffer = nullptr;
AudioFileSourceID3 *g_id3 = nullptr;
AudioGenerator *g_gen = nullptr;

volatile State g_state = State::Idle;
volatile uint32_t g_completions = 0;
volatile uint8_t g_volumeStep = VOLUME_DEFAULT_STEP;

char g_currentPath[AUDIO_PATH_MAX] = {0};
bool g_ampOn = false;
uint32_t g_ampOffAt = 0;

void ampOn() {
  if (g_ampOn) {
    return;
  }
  digitalWrite(PIN_AMP_SD, HIGH);  // high also selects the left channel
  g_ampOn = true;
  delay(AMP_SETTLE_MS);
}

void ampOff() {
  if (!g_ampOn) {
    return;
  }
  digitalWrite(PIN_AMP_SD, LOW);
  g_ampOn = false;
}

bool endsWithIgnoreCase(const char *s, const char *suffix) {
  const size_t sl = strlen(s), fl = strlen(suffix);
  return sl >= fl && strcasecmp(s + sl - fl, suffix) == 0;
}

void teardown(bool drain) {
  if (g_gen) {
    if (drain && g_gen->isRunning()) {
      g_out->flush();  // let the tail of the track leave the DMA buffers
    }
    if (g_gen->isRunning()) {
      g_gen->stop();
    }
    delete g_gen;
    g_gen = nullptr;
  }
  // The wrappers never own their inner source, so unwind them outside-in.
  delete g_id3;
  g_id3 = nullptr;
  delete g_buffer;
  g_buffer = nullptr;
  if (g_file) {
    g_file->close();
    delete g_file;
    g_file = nullptr;
  }
  g_currentPath[0] = '\0';
}

void finish(bool drain) {
  teardown(drain);
  g_state = State::Idle;
  g_ampOffAt = millis() + AMP_LINGER_MS;
  g_completions++;
}

void startTrack(const char *path) {
  teardown(false);

  sdfs::Guard guard;

  g_file = new AudioFileSourceSD();
  if (!g_file->open(path)) {
    LOGE("cannot open %s", path);
    finish(false);
    return;
  }

  g_buffer = new AudioFileSourceBuffer(g_file, AUDIO_BUFFER_BYTES);
  AudioFileSource *source = g_buffer;

  if (endsWithIgnoreCase(path, ".mp3")) {
    g_id3 = new AudioFileSourceID3(g_buffer);  // skips the tag so libhelix sees clean frames
    source = g_id3;
    g_gen = new AudioGeneratorMP3();
  } else {
    g_gen = new AudioGeneratorWAV();
  }

  g_out->SetGain(VOLUME_STEPS[g_volumeStep]);
  ampOn();

  if (!g_gen->begin(source, g_out)) {
    LOGE("decoder refused %s (unsupported format?)", path);
    finish(false);
    return;
  }

  strlcpy(g_currentPath, path, sizeof(g_currentPath));
  g_state = State::Playing;
  LOGI("playing %s", path);
}

// One cycle of a sine, filled in by begin(). A table rather than sinf() per
// sample, and indexed by the top byte of a 32-bit phase so it wraps for free.
int16_t g_sine[256];

void writeFrame(int16_t value) {
  int16_t frame[2] = {value, value};
  while (!g_out->ConsumeSample(frame)) {
    vTaskDelay(1);  // DMA full: the chime is ahead of the speaker, which is fine
  }
}

// Rendered straight into the I2S output from this task. Nothing else is
// serviced while it plays, which is why the chimes are all well under a second.
void playChime(chimes::Chime which, int8_t transpose) {
  const chimes::Tune tune = chimes::tune(which);
  if (!tune.count) {
    return;
  }
  // A decoder that finished has stopped the driver behind it.
  if (!g_out->on() && !g_out->begin()) {
    LOGE("chime: no I2S output");
    return;
  }

  // Borrow the output at whatever rate it is running — changing the clock
  // under a story would be audible — but in the format the chime is written
  // in, since an 8-bit or mono WAV leaves the output expecting that.
  const State before = g_state;
  const uint8_t bits = g_out->bits();
  const uint8_t chans = g_out->chans();
  g_out->SetBitsPerSample(16);
  g_out->SetChannels(2);
  ampOn();  // no-op mid-story; paused or idle, it is off

  const uint32_t rate = g_out->rate();
  const uint32_t startedAt = millis();
  const uint32_t attack = rate * CHIME_ATTACK_MS / 1000;
  const float shift = powf(2.0f, transpose / 12.0f);

  for (uint8_t n = 0; n < tune.count; n++) {
    const chimes::Note &note = tune.notes[n];
    const uint32_t len = rate * note.ms / 1000;
    if (!note.hz) {
      for (uint32_t i = 0; i < len; i++) {
        writeFrame(0);
      }
      continue;
    }
    const uint32_t step = (uint32_t)(note.hz * shift * 4294967296.0 / rate);
    uint32_t phase = 0;
    for (uint32_t i = 0; i < len; i++, phase += step) {
      // A quick fade in, then a squared fade out: struck, like a bell, and
      // ending at zero so neither edge clicks.
      float env;
      if (i < attack) {
        env = (float)i / attack;
      } else {
        env = 1.0f - (float)(i - attack) / (len - attack);
        env *= env;
      }
      // A little of the octave above for body; a pure sine sounds thin on a
      // small speaker.
      const int32_t wave = (3 * g_sine[phase >> 24] + g_sine[(phase << 1) >> 24]) / 4;
      writeFrame((int16_t)(wave * env * tune.level / 32767));
    }
  }

  g_out->SetBitsPerSample(bits);
  g_out->SetChannels(chans);
  // Rendering runs ahead of the speaker by one DMA ring, so this is a little
  // short of the chime's length, not near zero. Near zero means the samples
  // went nowhere.
  LOGD("chime %u at %u Hz, gain step %u: %u ms", (unsigned)which, (unsigned)rate,
       (unsigned)g_volumeStep, (unsigned)(millis() - startedAt));

  if (before == State::Paused) {
    g_out->flush();  // let the chime out before the amp goes quiet again
    ampOff();
  } else if (before == State::Idle) {
    g_ampOffAt = millis() + AMP_LINGER_MS;
  }
}

void handle(const Cmd &cmd) {
  switch (cmd.type) {
    case CmdType::Play:
      startTrack(cmd.path);
      break;

    case CmdType::Stop:
      if (g_gen) {
        LOGD("stop");
        teardown(false);
      }
      g_state = State::Idle;
      g_ampOffAt = millis() + AMP_LINGER_MS;
      break;

    case CmdType::Pause:
      if (g_state == State::Playing) {
        g_state = State::Paused;
        ampOff();  // muting beats letting the DMA loop its last buffer
      }
      break;

    case CmdType::Resume:
      if (g_state == State::Paused) {
        ampOn();
        g_state = State::Playing;
      }
      break;

    case CmdType::TogglePause:
      if (g_state == State::Playing) {
        g_state = State::Paused;
        ampOff();
      } else if (g_state == State::Paused) {
        ampOn();
        g_state = State::Playing;
      }
      break;

    case CmdType::Gain:
      g_out->SetGain(cmd.gain);
      break;

    case CmdType::Chime:
      playChime(cmd.chime, cmd.transpose);
      break;
  }
}

void audioTask(void *) {
  for (;;) {
    const bool running = (g_gen != nullptr) && (g_state == State::Playing);
    const TickType_t wait = running ? 1 : pdMS_TO_TICKS(10);

    Cmd cmd;
    if (xQueueReceive(g_queue, &cmd, wait) == pdTRUE) {
      handle(cmd);
      continue;
    }

    if (running) {
      bool alive;
      {
        sdfs::Guard guard;
        alive = g_gen->isRunning() && g_gen->loop();
      }
      if (!alive) {
        LOGI("finished %s", g_currentPath);
        finish(true);
      }
    } else if (g_ampOn && g_state == State::Idle && (int32_t)(millis() - g_ampOffAt) >= 0) {
      ampOff();
    }
  }
}

void send(const Cmd &cmd) {
  if (!g_queue) {
    return;
  }
  if (xQueueSend(g_queue, &cmd, pdMS_TO_TICKS(50)) != pdTRUE) {
    LOGE("audio queue full, command dropped");
  }
}

}  // namespace

bool begin() {
  pinMode(PIN_AMP_SD, OUTPUT);
  digitalWrite(PIN_AMP_SD, LOW);  // stay silent until we have something to say
  g_ampOn = false;

  g_out = new Output(0, AudioOutputI2S::EXTERNAL_I2S, I2S_DMA_BUFFERS);
  g_out->SetPinout(PIN_I2S_BCLK, PIN_I2S_LRC, PIN_I2S_DIN);
  g_out->SetOutputModeMono(true);  // one speaker, and the amp only plays the left channel
  g_out->SetGain(VOLUME_STEPS[g_volumeStep]);

  for (int i = 0; i < 256; i++) {
    g_sine[i] = (int16_t)(32767.0f * sinf(2.0f * PI * i / 256.0f));
  }

  // Room for a volume key held down: each step queues a gain and a chime.
  g_queue = xQueueCreate(10, sizeof(Cmd));
  if (!g_queue) {
    LOGE("cannot create audio queue");
    return false;
  }

  // Core 0 is idle in this build (no WiFi/BT), so decoding never competes with
  // the I2C and SPI work happening in loop() on core 1.
  const BaseType_t ok = xTaskCreatePinnedToCore(audioTask, "audio", 10240, nullptr, 3, &g_task, 0);
  if (ok != pdPASS) {
    LOGE("cannot start audio task");
    return false;
  }
  return true;
}

void play(const char *path) {
  Cmd cmd = {};
  cmd.type = CmdType::Play;
  strlcpy(cmd.path, path, sizeof(cmd.path));
  g_state = State::Playing;  // claim the state now so callers don't see a gap
  send(cmd);
}

void stop() {
  Cmd cmd = {};
  cmd.type = CmdType::Stop;
  g_state = State::Idle;
  send(cmd);
}

void pause() {
  Cmd cmd = {};
  cmd.type = CmdType::Pause;
  send(cmd);
}

void resume() {
  Cmd cmd = {};
  cmd.type = CmdType::Resume;
  send(cmd);
}

void togglePause() {
  Cmd cmd = {};
  cmd.type = CmdType::TogglePause;
  send(cmd);
}

State state() { return g_state; }

bool busy() { return g_state != State::Idle; }

uint32_t completions() { return g_completions; }

void chime(chimes::Chime which, int8_t transpose) {
  Cmd cmd = {};
  cmd.type = CmdType::Chime;
  cmd.chime = which;
  cmd.transpose = transpose;
  send(cmd);
}

void setVolumeStep(uint8_t step) {
  if (step > VOLUME_MAX_STEP) {
    step = VOLUME_MAX_STEP;
  }
  g_volumeStep = step;
  Cmd cmd = {};
  cmd.type = CmdType::Gain;
  cmd.gain = VOLUME_STEPS[step];
  send(cmd);
}

uint8_t volumeStep() { return g_volumeStep; }

const char *currentPath() { return g_currentPath; }

float level() {
  // Nothing written for a while: paused, stopped, or between tracks.
  if (millis() - g_meterAt > 150 || g_state == State::Paused) {
    return 0.0f;
  }
  return g_meter[(g_meterHead - kMeterLag) & (kMeterRing - 1)] / 65535.0f;
}

void shutdownAmp() {
  digitalWrite(PIN_AMP_SD, LOW);
  g_ampOn = false;
}

}  // namespace audio

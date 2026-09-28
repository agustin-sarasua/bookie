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

enum class CmdType : uint8_t { Play, Stop, Pause, Resume, TogglePause, Gain };

struct Cmd {
  CmdType type;
  char path[AUDIO_PATH_MAX];
  float gain;
};

QueueHandle_t g_queue = nullptr;
TaskHandle_t g_task = nullptr;

AudioOutputI2S *g_out = nullptr;
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

  g_out = new AudioOutputI2S(0, AudioOutputI2S::EXTERNAL_I2S, I2S_DMA_BUFFERS);
  g_out->SetPinout(PIN_I2S_BCLK, PIN_I2S_LRC, PIN_I2S_DIN);
  g_out->SetOutputModeMono(true);  // one speaker, and the amp only plays the left channel
  g_out->SetGain(VOLUME_STEPS[g_volumeStep]);

  g_queue = xQueueCreate(6, sizeof(Cmd));
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

void shutdownAmp() {
  digitalWrite(PIN_AMP_SD, LOW);
  g_ampOn = false;
}

}  // namespace audio

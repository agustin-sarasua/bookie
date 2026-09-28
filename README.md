# Bookie

Tap an NFC tag on a page of a children's book, hear that page read aloud, in
whichever language the toy is set to. LOLIN D32 (ESP32), PN532 reader, microSD
card, MAX98357A amplifier.

```
firmware/src/        the firmware
firmware/sdcard/     copy this to the microSD card
firmware/tools/      ffmpeg helper for preparing clips
app/                 Bookie Studio: configure the tags and write the card
```

## Build and flash

```sh
make          # list every target
make go       # build, flash, open the serial monitor
make monitor  # just the monitor, 115200 baud
make debug    # same firmware, chattier logging
make card CARD=/Volumes/BOOKIE   # copy firmware/sdcard/ onto the card
make erase    # wipe flash, including the stored language and volume
```

Add `PORT=/dev/cu.usbserial-0001` to any of them if the board is not found
automatically; `make ports` lists the candidates. The Makefile just wraps
PlatformIO (`pio run -d firmware -e lolin_d32 …`), so use that directly if you
prefer.

## Wiring

| D32 pin | Goes to |
|---|---|
| GPIO 16 | PN532 SDA over I²C — over HSU, whichever of its two pins receives |
| GPIO 17 | PN532 SCL over I²C — over HSU, whichever of its two pins transmits |
| GPIO 18 / 19 / 23 | SD SCK / MISO / MOSI |
| GPIO 5 | SD CS |
| GPIO 26 / 25 / 27 | MAX98357A BCLK / LRC / DIN |
| GPIO 33 | MAX98357A SD (shutdown, driven high to play) |
| GPIO 4 | Language button → GND (also wakes the toy) |
| GPIO 14 | Volume up → GND |
| GPIO 22 | Volume down → GND |
| GPIO 35 | Battery sense — not wired yet; `PIN_BATT_SENSE = -1` turns it off |

All three buttons are `INPUT_PULLUP` and just short their pin to ground. Pin
assignments live in one place, `firmware/src/config.h`.

Three notes on this board specifically:

* **GPIO 5 is also the onboard LED, and a strapping pin.** Using it as SD CS is
  fine either way: CS idles high, which is what the bootloader wants, and the
  LED (active low) flickers on card activity — a free activity indicator.
* **GPIO 4 wakes the toy from deep sleep.** It is the one button wired as an
  `ext0` wake source, so "press language to wake up" is the rule. Volume down
  is on GPIO 22, which is not an RTC pin and could not wake it anyway.
* **GPIO 33 is held low through deep sleep** (`gpio_hold_en`) so the amplifier
  cannot wake up hissing while the ESP32 is asleep.

## How it behaves

* **Tag arrives** → its clip starts in the current language. Tapping a different
  tag interrupts. Lifting the tag does *not* stop playback, so a child can close
  the book mid-sentence; the clip plays to the end.
* **Same tag again** → restarts that clip (the reader has to see it leave first,
  which takes about a third of a second).
* **Unknown tag** → plays `/system/<lang>/unknown.*` if that clip exists.
* **Language button, tap** → next folder under `/audio`, alphabetically,
  wrapping around. It announces itself with `/system/<lang>/language.*`, then,
  if a page was being read, starts that same page again in the new language.
  The tap registers on release, so a long press is never also a tap.
* **Language button, long press (0.8 s)** → pause/resume. While idle, it
  replays the last tag, so the book works without re-tapping.
* **Volume buttons** → eight steps, repeating while held. Volume and language
  are stored in NVS and survive a power cycle.
* **Battery** → sampled every 30 s. Below 3.55 V it plays `low-battery` once;
  below 3.30 V it announces nothing and goes to sleep to protect the cell.
  Only with a divider on `PIN_BATT_SENSE`; at -1 (the default for now) the
  battery is never read and nothing above happens.
* **Hold language, press volume up** → link mode: the toy raises its own WiFi network
  and serves the card over HTTP so Bookie Studio can write it without anyone
  taking the card out. Any button drops it again, and so does five quiet
  minutes. NFC and idle sleep are suspended while it is up.
* **Idle** → after 10 minutes with no button, no tag and nothing playing, it
  deep sleeps (PN532 powered down too, ~50 µA). Press language to wake.
  Set `IDLE_SLEEP_MS` to 0 in `config.h` to disable.

## Card layout

See `firmware/sdcard/README.md`. Short version:

```
/audio/en/bear.mp3     one clip per tag per language, .mp3 or .wav
/audio/es/bear.mp3
/system/en/ready.mp3   optional prompts: ready, language, unknown, low-battery, link
/tags.csv              optional "UID,name" lines
```

Every directory under `/audio` is a language. Tags not listed in `tags.csv` are
looked up by UID, e.g. `/audio/en/04A224AA5C6180.mp3`.

```sh
firmware/tools/prepare_audio.sh firmware/sdcard/audio/en ~/recordings/bear.m4a
```

## The app

`app/` is **Bookie Studio**, a Flutter app for Android and iOS that does the
same job without a computer: hold the phone against a tag, record the page in
your own voice, and write the card — either through a USB card reader, or over
the toy's own WiFi with the card still inside it.

```sh
dart pub global activate melos   # once
melos bootstrap
melos run app                    # a real device — no NFC or card reader on a simulator
```

`melos run` on its own lists the rest: `devices`, `test`, `analyze`, `format`,
`build`, `clean`. They live in the `melos:` section of the root `pubspec.yaml`,
which is also what makes `app/` a Dart pub workspace — one lockfile, at the
root. `make app`, `make app-test` and `make app-build` are doors into the same
scripts.

### Writing the card without taking it out

Hold the language button and press volume up. The toy comes up as
`Bookie-XXXX`, WPA2, password `bookie-card` — both set in `config.h`, and
`app/test/firmware_contract_test.dart` fails if the app and the firmware ever
disagree about them. In the app, **Connect to the toy instead**; on Android that
is one system dialog and no typing, because `WifiNetworkSpecifier` can be handed
a network name to look for. Everything after that is the same screen as a
reader: the same diff, the same progress bar, the same files.

`firmware/src/toylink.cpp` is the whole of the toy's side — a SoftAP and six
HTTP routes over the card (`/info`, `/list`, `/read`, `/write`, `/delete`,
`/done`), all of them refusing any path that is not absolute or that contains
`..`. It costs 300 kB of flash and nothing at all when it is off, which is its
resting state: the radio draws ~80 mA, and an access point a child can wander
into is not something to leave running. `link` in the serial console is the
other door into it, and `link off` the way back.

It writes exactly the layout above, plus a `/bookie.json` the firmware ignores
and the app uses to keep your labels. It can also read a card back, and, with no
reader to hand, export the whole card as a zip. The rules it shares with
`library.cpp` — UID normalisation, how `tags.csv` parses, what fits in
`AUDIO_PATH_MAX` — are pinned by `app/test/firmware_contract_test.dart`.

See `app/README.md`.

## First boot, with nothing wired yet

This is what a bare D32 prints — every line is the firmware correctly reporting
something that is not connected, and it reaches the prompt in 2.4 s — the extra
150 ms over the I²C-only probe is the HSU fallback giving a reader that is not
there its turn to answer:

```
[   216] Bookie starting (reset reason 1)
[   217] settings: language=en volume=5
[   220] battery 1.98 V (0%)
[  1225] ERR  SD mount failed at 16 MHz, retrying slower
[  2237] ERR  SD card not found (check CS on GPIO5 and the 3V3 mod on the breakout)
[  2436] no reader yet, still looking (type 'i2c' if it never appears)
[  2437] ready — tap a tag, or type 'help' for the serial console
```

Two harmless lines you will also see, both from libraries rather than this code:

* `__pinMode(): Invalid pin selected`, twice, before anything else. The PN532
  library always configures an IRQ and a reset pin; we wire neither, so it gets
  handed pin 255. The first one is garbled because the bootloader is still
  changing the baud rate underneath it.
* `f_mount failed: (3)` from the SD driver, immediately before our own, friendlier
  version of the same news.
* `Please build project in debug configuration…` every time the monitor opens.
  That is the exception decoder saying it could give richer crash dumps in a
  debug build; it decodes backtraces either way.

With no battery on the JST connector the divider reads around 2 V. Anything
under 2.5 V is treated as "running off USB, no cell" and skips the low-battery
logic entirely.

## Bring-up, in the order the hardware wants it

The serial console does the staged bring-up you planned — one subsystem at a
time, without reflashing. Type `help` in the monitor.

1. **Boot.** `Bookie starting` plus a battery reading means the ESP32 and the
   divider are alive.
2. **SD.** `ls` lists the card root, `ls /audio/en` a language folder. If the
   mount fails, the log says so at both 16 MHz and 4 MHz.
3. **I²S.** `play /audio/en/bear.mp3`, then `vol 8`. Sound here means clock,
   data, amplifier enable and speaker are all correct.
4. **PN532.** `pins` first if it never answers at all: jumper GPIO 16 to GPIO 17,
   nothing else attached, and it drives each one and reads it back on the other.
   That separates the board from the module in a minute — if the loopback fails,
   the reader was never the problem. `i2c` then scans the bus and probes HSU
   both ways round: 0x24 means the reader is wired and in I2C
   mode, an empty bus means power, ground or the two data lines are not making
   it across, and an address that is not 0x24 means the DIP switches are wrong.
   Once it answers, `uid` waits five seconds for a tag and prints its UID *and*
   which file it resolves to in each language — that is also how you fill in
   `tags.csv`.
5. **Together.** `info` dumps the state of every subsystem at once.

## How it is put together

`loop()` only does slow, interruptible things: polling the reader over I²C,
debouncing buttons, reading the battery. Decoding runs in its own FreeRTOS task
pinned to core 0 at a higher priority (`firmware/src/audio.cpp`), fed by an
8 KB read-ahead buffer, so a 60 ms NFC read cannot starve the I²S DMA and make
the speaker stutter. The two tasks share the SD card through one lock
(`sdfs.h`), because the card and nothing else sits on that SPI bus.

| File | Does |
|---|---|
| `main.cpp` | state machine: tags, buttons, battery, sleep |
| `audio.cpp` | I²S output, WAV/MP3 decode task, amplifier enable |
| `nfc.cpp` | PN532 polling, arrival/removal debounce, reader heartbeat |
| `library.cpp` | what is on the card: languages, `tags.csv`, path lookup |
| `toylink.cpp` | link mode: the SoftAP and the HTTP API over the card |
| `buttons.cpp` `battery.cpp` `settings.cpp` `sdfs.cpp` `console.cpp` | the rest |

## Hardware gotchas worth remembering

* The amplifier is fed from the battery through the Y-splitter, not from 3V3 —
  the regulator has nothing left after the ESP32, reader and card. Keep the
  470 µF capacitor right at the amplifier's Vin.
* The SD breakout needs its AMS1117 bridged (input to output) to run natively at
  3.3 V, otherwise the card browns out.
* PN532 DIP switches: 1 on, 2 off for I²C; both off for HSU. Plenty of the
  clone boards sold as "V3" only do SPI and HSU whatever the listing says, and
  a module in the wrong mode is indistinguishable from one that is not plugged
  in. The firmware tries I²C and then HSU at boot and says which one answered,
  so `i2c` in the console is the fastest way to find out what you have.
* **Do not trust SDA and SCL over HSU.** The labels are the I²C ones; which of
  the two actually transmits varies by board, and on the one this was developed
  against it is SDA, so the module's TX lands on GPIO 17. `PN532_HSU_WIRING` in
  `config.h` is set to match; `PN532_HSU_WIRING_AUTO` tries both and prints
  which it found — `PN532 firmware 1.6 over HSU, module TX on GPIO17` — and
  that is what auto is for: run it once, read the line, pin it, leave it pinned.
* **Probing the wrong way round is not free.** It means driving the ESP32's
  transmit pin into the module's, two push-pull outputs arguing for a fifth of
  a second, and this module answers nothing afterwards until it is
  power-cycled — which looks exactly like a reader that has died. `i2c` still
  probes both, because that is its job, and warns that you may need to pull the
  power after it.
* **The PN532 does not answer the first thing you say to it.** Out of power-on
  it is in LowVbat, and the wake-up sequence has to be the long one — `55 55`
  and a run of zeros, not the three bytes `Adafruit_PN532` sends — with the
  first command after it usually swallowed. The probe sends the long wake-up,
  waits 20 ms, and asks twice.
* **And it is not ready when `setup()` first asks.** It comes up on the same
  rail as the ESP32, which is booting faster than it is, so the first probe at
  ~260 ms can find nothing at all on a reader that is wired perfectly. A failed
  probe is not reported as an error: it is retried after 250 ms and then
  progressively less often up to the heartbeat interval, and the boot line says
  `no reader yet, still looking`. A reader that is there turns up within a
  second or so, `PN532 ready (…)`; one plugged in later turns up when it does.
* Your speaker is 8 Ω, and the diagram says 4 Ω — the firmware does not care,
  but 8 Ω is about 3 dB quieter. If step 8 is still too quiet for a noisy room,
  tie the amplifier's GAIN pin to GND for 12 dB instead of the 9 dB you get by
  leaving it floating.
* Speaker wires go to the amplifier's + and − only. Neither leg touches ground.

## Troubleshooting

| Symptom | Look at |
|---|---|
| `SD card not found` | the 3.3 V mod, CS on GPIO 5, wire length |
| `no reader yet` and it never appears | `i2c` in the console: it scans the bus and probes HSU both ways round. An empty result is wiring, power, or a module that only speaks HSU — in which case both switches off |
| Audio stutters | shorten SD wires, or raise `AUDIO_BUFFER_BYTES` / `I2S_DMA_BUFFERS` |
| Quiet, distorted, or the board resets on loud passages | the amplifier is on 3V3 instead of battery, or the 470 µF cap is missing |
| `tag … has no clip in en` | file name vs `tags.csv`, or a `.m4a` that was never converted |
| Toy seems dead | it deep sleeps after 10 minutes — press language |
| The app writes but the toy sees an empty card | the folder you picked is not the card. The Card tab prints where it really points: `primary:/…` is the phone's own storage |
| The phone will not find `Bookie-XXXX` | link mode is off (hold language, press volume up), or it timed out after five quiet minutes |
| `Unable to verify flash chip connection` while flashing | upload baud; `upload_speed` is 460800, drop further with `make flash SPEED=115200` |
| `__pinMode(): Invalid pin selected` at boot | harmless, see above |

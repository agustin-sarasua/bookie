# Card layout

Copy the contents of this folder to the root of a FAT32 microSD card.

```
/audio/en/bear.mp3        one clip per tag, per language
/audio/es/bear.mp3
/system/en/ready.mp3      optional spoken prompts
/system/en/language.mp3
/system/en/unknown.mp3
/system/en/low-battery.mp3
/system/en/link.mp3
/tags.csv                 optional UID -> name map
```

* Every folder under `/audio` is a language. Their names are what the language
  button cycles through, in alphabetical order — `en`, `es`, `fr`, whatever you
  call them.
* A clip may be `.mp3` or `.wav`; if both exist the `.mp3` wins.
* **MP3** is the better default: at 64 kbps the 8 kB read-ahead buffer holds a
  full second of audio, against 0.19 s for a 22 kHz WAV. Bigger cushion against
  SD hiccups, and a fifth of the file size.
* **WAV** must be plain PCM (`audioFormat` 1, so no WAVE_FORMAT_EXTENSIBLE),
  8 or 16 bit, 1 or 2 channels. A 24-bit or 32-bit float export from a DAW is
  rejected with `only 8 or 16 bits is supported`. Check any file with
  `afinfo foo.wav` — you want it to say `Int16`.
* Either way, mono at 22050 Hz is the sweet spot for speech.
* The five `/system` clips are all optional. A missing one is skipped, and a
  language with no `/system` folder of its own falls back to `/system/en`.
  `link` is the one played when the toy raises its WiFi for the phone — "ready
  to connect", or whatever you want it to say.
* Tags do not need to appear in `tags.csv` — without it, name each file after
  the tag's UID. `tags.csv` just lets you write `bear.mp3` instead.

Use `tools/prepare_audio.sh` to convert recordings into the right format.

# Bookie Studio

Give each NFC tag a story, then write the card. Flutter, Android and iOS.

```
lib/model/     the card's contract: UIDs, tags.csv, file names
lib/store/     the project as it lives on the phone
lib/card/      the microSD card, through the toy: diff, write, import
lib/audio/     recording, playback, WAV
lib/nfc/       reading a tag's UID
lib/ai/        the story assistant: Gemini client, story model, engine
lib/ui/        the screens
```

## Run it

The repo is a Melos workspace, so these work from anywhere in the tree:

```sh
dart pub global activate melos   # once
melos bootstrap                  # resolve the workspace

melos run app          # a real device: the simulator has no NFC and cannot join the toy
melos run devices      # which phones Flutter can see
melos run test         # the contract tests, which are the ones that matter
melos run              # pick from the list
```

`melos run app` sets `stdio: inherit` so `flutter run` keeps its terminal —
without it `r`, `R` and `q` do nothing. Plain `cd app && flutter run` still
works if you would rather not install Melos.

The iOS build needs the **Near Field Communication Tag Reading** capability on
your signing team — `ios/Runner/Runner.entitlements` asks for it, but Apple only
issues the provisioning profile if the capability is enabled for the App ID.
Everything else works on a free personal team.

## What it does

**Tags.** Hold the phone against a tag and it appears in the list, named after
its UID until you name it. The sheet stays open, so a whole book can be tagged
in one pass. No NFC, or an iPhone that will not read your tag? *Type a UID* —
which is what `make monitor` then `uid` prints.

**Clips.** Every tag gets one clip per language. Record in your own voice, or
import an mp3/wav you already have. Recording goes straight to mono 22.05 kHz
16-bit WAV, which is what `sdcard/README.md` asks for, so nothing is transcoded
afterwards; a quarter-second of silence is appended the way
`tools/prepare_audio.sh` does with `apad`, so the I²S buffers cannot clip the
last syllable. An imported file is checked before it is accepted — a float WAV
or a 24-bit one would reach the toy as noise, and it says so rather than letting
you find out from the speaker.

**AI stories.** *Create a story with AI* (Tags tab, or any tag's page) turns
photos of a book into a narrated clip. Photograph the pages, optionally say how
it should sound — follow the printed words, retell them, or invent a new
adventure; a length; free-form instructions — and pick the languages. Then:

1. **Gemini 3.8 Flash** (`generateContent`, JSON response schema) looks at the
   pages, finds the characters, casts a prebuilt voice for the narrator and
   for each character (all different), writes a one-line voice direction for
   each ("a slow, rumbling, sleepy old bear"), and writes the script as
   speaker-tagged lines in the first language.
2. Every further language is a retelling of that script by the same cast, so
   the bear keeps his voice in Spanish.
3. **Gemini 3.8 Flash TTS** (`interactions`) reads it. The model speaks at most
   two voices per request, so the script is cut into runs of consecutive lines
   with one or two speakers, three requests at a time, and the WAV pieces are
   stitched in order, resampled 24 → 22.05 kHz and saved as a 16-bit mono PCM
   WAV on the tag — an ordinary clip, synced like any other.

Voices can be auditioned and recast, and script lines edited; the app marks the
audio out of date and re-records on request. Adding a language on the
Languages tab offers to retell every AI story in it.

There is no backend: the phone calls the Gemini API directly with a key the
user pastes into *AI settings* (✨ on the Tags tab), kept in the app's support
directory — never in the workspace, so it cannot reach the card. For
development, `flutter run --dart-define=GEMINI_API_KEY=…` bakes one in. Model
names are editable under *Advanced*. Stories live at
`workspace/stories/<uid>/` (pages, `story.json`, voice samples) and never go
onto the card. Generation needs the internet, so do it before joining the
toy's WiFi.

**Languages.** Add or remove folders under `/audio`. The list is what the
language button cycles through, alphabetically, so the name you pick is the
name the toy walks past. Each language also holds the four optional `/system`
prompts (`ready`, `language`, `unknown`, `low-battery`), with `en` marked
because every other language falls back to it.

**The card.** The card stays in the toy. Hold the language button and press
volume up: the toy raises `Bookie-XXXX` and serves the card over HTTP, and
**Connect** on the Card tab joins it. On Android the join is one system dialog;
the binding afterwards is the part that matters, since the toy's network has no
internet and every request would otherwise leave over cellular and never arrive.

Once connected, the tab shows every tag and, per language, whether the toy
already has that clip or will get it with the next update, and lists what will
be removed. **Update the toy** makes the card match the app exactly:

* clips that are new or changed are written — compared by size, the same
  shortcut `make card` takes; FAT32 timestamps are too coarse to trust;
* `tags.csv` and `bookie.json` are written only when they differ from what the
  card already holds, so a card that is up to date says so;
* every clip under `/audio` that no tag uses is deleted — deleted or renamed
  tags, the other container of a stem, removed languages — and an emptied
  `/audio/<lang>` folder goes too, since every folder there is a language the
  button cycles. `/system` prompts the app did not put there are left alone.

After an update the card is read again; anything still pending is reported
rather than assumed written.

## What lands on the card

Exactly what `firmware/sdcard/README.md` describes, plus one file of our own:

```
/audio/en/bear.mp3      one clip per tag, per language
/system/en/ready.mp3    the four optional prompts
/tags.csv               UID,name — what the firmware reads
/bookie.json            labels and provenance — what this app reads
```

`bookie.json` exists so a card carries its own labels to the next phone.
`library.cpp` never opens the card root except for `tags.csv`, so it rides
along harmlessly; deleting it costs you nothing but the labels.

**Load what is already on the card** reads it back, in order of how much the
card knows about itself: `bookie.json`, then `tags.csv`, then — failing both —
the audio folders themselves, because the firmware's own fallback is to name a
clip after the UID, so `/audio/en/04A224AA5C6180.mp3` is a tag and is recovered
as one.

## The parts worth knowing about

**`lib/model/`** is where the firmware's rules are written down, and
`test/firmware_contract_test.dart` is where they are held to. `normaliseUid`
mirrors `library.cpp::normaliseUid`; the CSV parser mirrors `reloadTags()`,
including the part where everything after the first comma is the name — which
is why data lines carry no trailing comments; `maxStemLength` keeps
`/audio/<lang>/<stem>.mp3` inside `AUDIO_PATH_MAX`. If one of those tests goes
red, the app is writing a card the toy will misread.

**Card access is a hand-written platform channel**, `com.bookie.studio/card`,
because the two platforms share nothing here:

* `android/…/CardPlugin.kt` — Android will not hand out a path for removable
  storage, so it is the Storage Access Framework: a persisted tree URI, and
  every path walked through `DocumentsContract`. That walk is one cursor query
  per directory, so each directory's listing is cached for the life of the
  plugin; without it, writing sixty clips would be a few hundred queries.
* `ios/Runner/CardPlugin.swift` — a security-scoped folder URL from the Files
  app, stored as a bookmark so it survives a relaunch, and re-resolved (and
  refreshed when iOS calls it stale) on the way back. Inside the scope it is an
  ordinary directory and `FileManager` does the rest.

**The workspace mirrors the card.** `audio/<lang>/<stem>.<ext>` on the phone is
`/audio/<lang>/<stem>.<ext>` on the card, which is what makes syncing a plain
directory diff rather than a translation step.

**One container per stem.** `library.cpp::resolveStem()` prefers `.mp3` over
`.wav`, so a leftover `bear.wav` beside a new `bear.mp3` is dead weight at best
and the wrong clip at worst. Replacing a clip removes the other container
locally, and the update clears the twin on the card.

## Known edges

* Writes are file-by-file and not transactional. If the toy drops its WiFi
  mid-update the card is left part-new; connect again and update once more,
  which is why deletes happen after writes rather than before.
* Removing an emptied language folder needs the firmware from this change
  (`/delete` now takes an empty directory); older firmware leaves the folder.
* Importing a card replaces the workspace outright. It asks first, and
  refuses outright when the folder has no `tags.csv`, no `bookie.json` and
  no `/audio` — pointing at the wrong volume should not empty the app.

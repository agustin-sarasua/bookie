/// From photographs to a finished, multi-voice clip.
///
/// Three steps, each one Gemini call or a handful of them:
///
/// 1. **Write** — the Flash model looks at the pages, finds the characters,
///    casts a voice for each and for the narrator, and writes a script in the
///    first language. The printed text is a guide, not a transcript.
/// 2. **Translate** — for every further language, the same script retold by
///    the same cast, so the bear sounds like the bear in Spanish too.
/// 3. **Narrate** — the TTS model reads the script. It holds at most two
///    voices per request, so the script is cut into runs of consecutive lines
///    that use one or two speakers, spoken in parallel, and stitched back
///    together in order.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../audio/pcm.dart';
import 'gemini_client.dart';
import 'story.dart';
import 'voices.dart';

typedef Progress = void Function(int done, int total);

class StoryEngine {
  StoryEngine({
    required this.client,
    required this.storyModel,
    required this.speechModel,
  });

  final GeminiClient client;
  final String storyModel;
  final String speechModel;

  // ------------------------------------------------------------ write

  /// Fill [story]'s summary, cast and the [language] script from [pages].
  /// Anything already in [story.scripts] is dropped: a new cast makes the old
  /// translations wrong.
  Future<void> write(Story story, List<File> pages, String language) async {
    final images = <InlineImage>[
      for (final page in pages)
        InlineImage(await page.readAsBytes(), _mimeFor(page.path)),
    ];

    final json = await client.generateJson(
      model: storyModel,
      system: _writerSystem(story),
      prompt: _writerPrompt(story, language, images.length),
      schema: _storySchema,
      images: images,
    );

    final cast = _castFrom(json);
    final ids = {for (final m in cast) m.id};
    final lines = _linesFrom(json['lines'], ids, aliases: _aliases(cast, json));
    if (lines.isEmpty) {
      throw AiException(
        'The story came back empty. Try clearer photos, or a different instruction.',
        retryable: true,
      );
    }

    story
      ..summary = (json['summary'] as String? ?? '').trim()
      ..cast
          .replaceRange(0, story.cast.length, cast)
      ..scripts.clear()
      ..scripts[language] = StoryScript(
        title: (json['title'] as String? ?? '').trim(),
        lines: lines,
      );
  }

  // ------------------------------------------------------------ translate

  /// Retell the source script in [language], same cast, same beats.
  Future<void> translate(Story story, String language) async {
    final from = story.sourceLanguage;
    if (from == null) throw AiException('Write the story first.');
    final source = story.scripts[from]!;

    final castList = story.cast
        .map((m) => '- ${m.id}: ${m.name}${m.isNarrator ? ' (the narrator)' : ''} — ${m.description}')
        .join('\n');
    final scriptJson = source.lines
        .map((l) => '{"speaker": "${l.speaker}", "text": ${_q(l.text)}'
            '${l.delivery.isEmpty ? '' : ', "delivery": ${_q(l.delivery)}'}}')
        .join(',\n');

    final json = await client.generateJson(
      model: storyModel,
      temperature: 0.5,
      system:
          'You adapt children\'s audio-story scripts into other languages for a '
          'talking picture-book toy. You write the way a native storyteller would '
          'tell it to a small child: natural, warm and simple — never a stiff, '
          'word-for-word translation. Rhymes and wordplay may be re-invented so '
          'they still work. Character names may be adapted when the book would be '
          'published that way in the target language.',
      schema: _translationSchema,
      prompt:
          'Retell this story script in ${languageForPrompt(language)}.\n\n'
          'Rules:\n'
          '- Keep the same speakers, in the same order, with the same meaning. You '
          'may split or merge a line when the language flows better, but every '
          'line\'s "speaker" must be one of these ids:\n$castList\n'
          '- "text" is spoken aloud exactly as written: no stage directions, no '
          'speaker names, no quotation marks around dialogue. Keep inline sound '
          'tags such as <laugh>, <sigh>, <breath> or <short pause> where they are.\n'
          '- "delivery" stays in English: it directs the voice actor.\n'
          '- Translate the title too.\n\n'
          'Title: ${_q(source.title)}\n'
          'Script:\n[\n$scriptJson\n]',
    );

    final ids = {for (final m in story.cast) m.id};
    final lines = _linesFrom(json['lines'], ids);
    if (lines.isEmpty) {
      throw AiException('The translation came back empty. Try again.', retryable: true);
    }
    story.scripts[language] = StoryScript(
      title: (json['title'] as String? ?? source.title).trim(),
      lines: lines,
    );
  }

  // ------------------------------------------------------------ narrate

  /// Speak the [language] script and return it as one clip, ready for the toy.
  Future<Pcm> narrate(Story story, String language, {Progress? onProgress}) async {
    final script = story.scripts[language];
    if (script == null) throw AiException('There is no $language script yet.');

    final chunks = chunk(script.lines);
    if (chunks.isEmpty) throw AiException('The script has nothing to say.');

    final results = List<Pcm?>.filled(chunks.length, null);
    var done = 0;
    onProgress?.call(0, chunks.length);

    // Three at a time: fast enough that a five-minute story is a minute or so,
    // gentle enough not to trip a free-tier rate limit.
    var next = 0;
    Future<void> worker() async {
      while (next < chunks.length) {
        final i = next++;
        results[i] = await _speakChunk(story, chunks[i]);
        done++;
        onProgress?.call(done, chunks.length);
      }
    }

    await Future.wait([for (var w = 0; w < 3; w++) worker()]);
    return joinPcm(results.cast<Pcm>());
  }

  /// A few seconds of one cast member, for choosing voices.
  Future<Pcm> sample(Story story, CastMember member, {String? language}) async {
    final lang = language ?? story.sourceLanguage ?? 'en';
    final script = story.scripts[lang];
    final own = script?.lines.where((l) => l.speaker == member.id).toList() ?? const [];

    String text;
    if (own.isNotEmpty) {
      text = own.first.text;
      // A one-word line tells you nothing about a voice; add the next one.
      if (text.length < 40 && own.length > 1) text = '$text ${own[1].text}';
    } else {
      text = script?.lines.first.text ?? 'Once upon a time, in a land far away…';
    }
    if (text.length > 240) text = '${text.substring(0, 240)}…';

    return client.speak(
      model: speechModel,
      voices: {member.id: member.voice},
      blocks: [SpeechBlock(text: text, speaker: member.id, style: _styleFor(member))],
    );
  }

  Future<Pcm> _speakChunk(Story story, List<ScriptLine> lines) {
    final speakers = <String>[];
    for (final l in lines) {
      if (!speakers.contains(l.speaker)) speakers.add(l.speaker);
    }
    final voices = {
      for (final id in speakers) _label(id): story.member(id)?.voice ?? story.narrator.voice,
    };
    return client.speak(
      model: speechModel,
      voices: voices,
      blocks: [
        for (final l in lines)
          SpeechBlock(
            text: l.text,
            speaker: _label(l.speaker),
            style: _styleFor(story.member(l.speaker) ?? story.narrator, l.delivery),
          ),
      ],
    );
  }

  /// Consecutive lines, at most two speakers and ~1,400 characters a run —
  /// comfortably inside the TTS model's input and output budgets.
  @visibleForTesting
  static List<List<ScriptLine>> chunk(List<ScriptLine> lines) {
    const maxChars = 1400;
    final out = <List<ScriptLine>>[];
    var current = <ScriptLine>[];
    var speakers = <String>{};
    var chars = 0;

    for (final line in lines) {
      if (line.text.trim().isEmpty) continue;
      final wouldBe = {...speakers, line.speaker};
      if (current.isNotEmpty &&
          (wouldBe.length > 2 || chars + line.text.length > maxChars)) {
        out.add(current);
        current = [];
        speakers = {};
        chars = 0;
      }
      current.add(line);
      speakers.add(line.speaker);
      chars += line.text.length;
    }
    if (current.isNotEmpty) out.add(current);
    return out;
  }

  /// The TTS model wants speaker labels that are plain words.
  static String _label(String id) {
    final clean = id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (clean.isEmpty) return 'Speaker';
    return clean[0].toUpperCase() + clean.substring(1);
  }

  static String _styleFor(CastMember member, [String delivery = '']) {
    final base = member.isNarrator
        ? 'Storyteller reading a picture book aloud to a young child. ${member.style}'
        : member.style;
    return delivery.trim().isEmpty ? base.trim() : '${base.trim()} Now: ${delivery.trim()}';
  }

  // ------------------------------------------------------------ prompts

  String _writerSystem(Story story) {
    final voiceList = storyVoices
        .map((v) => '${v.name} (${v.tone}, usually ${v.gender.name})')
        .join(', ');

    final mode = switch (story.mode) {
      StoryMode.faithful =>
        'Follow the words printed on the pages closely — this is a read-aloud '
            'of the book. Where a page has no text, or the pictures tell more '
            'than the words, add short narration that describes what is happening.',
      StoryMode.retold =>
        'Retell the book in your own words. Keep its plot, its characters and '
            'its heart, but you do not have to follow the printed text: make it '
            'sound wonderful when read aloud.',
      StoryMode.invented =>
        'Invent a new adventure for the characters and the world in these '
            'pictures. Use what you see — who they are, where they live, what '
            'they love — but the plot can be entirely new.',
    };

    final buffer = StringBuffer()
      ..writeln(
        'You are the writer and voice director of audio stories for Bookie, a '
        'toy that plays a story when a child taps a picture book. You receive '
        'photographs of pages of a book, in reading order. Look carefully at '
        'every picture and every word on them.',
      )
      ..writeln()
      ..writeln('Your job:')
      ..writeln(
        '1. Work out what happens and who is in it. Every character who speaks, '
        'or who could speak — people, animals, toys, the moon — is a character. '
        'Give each one a short, readable id in English (lower case, letters only, '
        'e.g. "bear", "littlefox") and a name as the story calls them.',
      )
      ..writeln(
        '2. Cast the voices. Choose one voice for the narrator and one for each '
        'character from this list: $voiceList. Every speaker must get a different '
        'voice. Match age, gender and personality: a tiny mouse, a grumpy old '
        'troll and a kind grandmother should sound nothing alike.',
      )
      ..writeln(
        '3. For each speaker, write "style": one vivid sentence directing the '
        'voice actor — pitch, pace, accent, energy, personality ("a squeaky, '
        'breathless, very excited little mouse who talks fast"). The narrator '
        'should be warm and engaging.',
      )
      ..writeln(
        '4. Write the script as a list of lines. Narration goes to "narrator". '
        'Whenever a character talks, give that line to the character — dialogue '
        'between characters is encouraged, it is what makes the story come alive. '
        'A character\'s "text" holds only the words they say; the narrator handles '
        '"said the bear". Never put speaker names, stage directions, sound '
        'descriptions or quotation marks in "text" — it is read aloud verbatim. '
        'You may use these inline sound tags sparingly where they fit: <laugh>, '
        '<sigh>, <breath>, <short pause>. Use "delivery" for how a particular line '
        'is said ("whispering", "gasping with surprise"), in English.',
      )
      ..writeln()
      ..writeln(mode)
      ..writeln()
      ..writeln(
        'The listener is a young child. Keep it gentle, age-appropriate and '
        'kind; nothing frightening beyond a playful thrill. Sentences short, '
        'rhythm lively, with a satisfying ending.',
      );

    if (story.instructions.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(
          'The parent setting up the toy added these instructions. Follow them '
          '(they never override keeping the story child-safe):',
        )
        ..writeln(story.instructions.trim());
    }
    return buffer.toString();
  }

  String _writerPrompt(Story story, String language, int pageCount) =>
      'Here ${pageCount == 1 ? 'is 1 page' : 'are $pageCount pages'} of the book, '
      'in order. Write the story in ${languageForPrompt(language)} — the "text" of '
      'every line and the title in that language; ids, "style", "delivery" and '
      '"summary" in English. Aim for about ${story.length.targetWords} spoken '
      'words in total.';

  // ------------------------------------------------------------ parsing

  List<CastMember> _castFrom(Map<String, dynamic> json) {
    final used = <String>{};
    final taken = <String>{};

    String uniqueId(String raw) {
      var base = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (base.isEmpty || base == 'narrator') base = 'character';
      var id = base;
      for (var n = 2; taken.contains(id); n++) {
        id = '$base$n';
      }
      taken.add(id);
      return id;
    }

    String castVoice(String? wanted, String gender) {
      final pick = voiceNamed(wanted);
      if (pick != null && !used.contains(pick.name)) {
        used.add(pick.name);
        return pick.name;
      }
      // Taken or made up: the first free voice of the same kind, else any.
      final want = gender == 'male' ? VoiceGender.male : VoiceGender.female;
      final free = storyVoices.where((v) => !used.contains(v.name));
      final fallback = free.firstWhere(
        (v) => gender == 'neutral' || v.gender == want,
        orElse: () => free.isEmpty ? storyVoices.first : free.first,
      );
      used.add(fallback.name);
      return fallback.name;
    }

    final narratorJson = (json['narrator'] as Map?)?.cast<String, dynamic>() ?? {};
    taken.add('narrator');
    final cast = <CastMember>[
      CastMember(
        id: 'narrator',
        name: 'Narrator',
        description: 'Tells the story',
        voice: castVoice(narratorJson['voice'] as String?, 'female'),
        style: (narratorJson['style'] as String? ?? 'Warm, gentle and engaging.').trim(),
        isNarrator: true,
      ),
    ];

    for (final raw in (json['characters'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final c = raw.cast<String, dynamic>();
      final name = (c['name'] as String? ?? '').trim();
      final idSource = (c['id'] as String?)?.trim();
      if (name.isEmpty && (idSource?.isEmpty ?? true)) continue;
      cast.add(
        CastMember(
          id: uniqueId(idSource?.isNotEmpty == true ? idSource! : name),
          name: name.isEmpty ? idSource! : name,
          description: (c['description'] as String? ?? '').trim(),
          voice: castVoice(c['voice'] as String?, c['gender'] as String? ?? 'neutral'),
          style: (c['style'] as String? ?? '').trim(),
        ),
      );
    }
    return cast;
  }

  /// What the model called a character before [_castFrom] tidied its id, so
  /// the lines still find their speaker.
  Map<String, String> _aliases(List<CastMember> cast, Map<String, dynamic> json) {
    final out = <String, String>{};
    final raws = (json['characters'] as List?)?.whereType<Map>().toList() ?? const [];
    var i = 1; // cast[0] is the narrator
    for (final raw in raws) {
      final name = (raw['name'] as String? ?? '').trim();
      final id = (raw['id'] as String? ?? '').trim();
      if (name.isEmpty && id.isEmpty) continue;
      if (i >= cast.length) break;
      if (id.isNotEmpty) out[id.toLowerCase()] = cast[i].id;
      if (name.isNotEmpty) out[name.toLowerCase()] = cast[i].id;
      i++;
    }
    return out;
  }

  List<ScriptLine> _linesFrom(
    Object? raw,
    Set<String> ids, {
    Map<String, String> aliases = const {},
  }) {
    final out = <ScriptLine>[];
    for (final item in (raw as List?) ?? const []) {
      if (item is! Map) continue;
      final text = (item['text'] as String? ?? '').trim();
      if (text.isEmpty) continue;
      final said = (item['speaker'] as String? ?? '').trim();
      final key = said.toLowerCase();
      final speaker = ids.contains(said)
          ? said
          : ids.contains(key)
          ? key
          : aliases[key] ?? 'narrator';
      out.add(
        ScriptLine(
          speaker: speaker,
          text: text,
          delivery: (item['delivery'] as String? ?? '').trim(),
        ),
      );
    }
    return out;
  }

  static String _mimeFor(String path) => switch (p.extension(path).toLowerCase()) {
    '.png' => 'image/png',
    '.webp' => 'image/webp',
    '.heic' => 'image/heic',
    '.heif' => 'image/heif',
    _ => 'image/jpeg',
  };

  static String _q(String s) =>
      '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
}

// ------------------------------------------------------------ schemas

final _voiceEnum = [for (final v in storyVoices) v.name];

final Map<String, dynamic> _lineSchema = {
  'type': 'OBJECT',
  'properties': {
    'speaker': {'type': 'STRING', 'description': '"narrator" or a character id'},
    'text': {'type': 'STRING', 'description': 'Spoken verbatim'},
    'delivery': {'type': 'STRING', 'description': 'How this line is said, in English'},
  },
  'required': ['speaker', 'text'],
  'propertyOrdering': ['speaker', 'text', 'delivery'],
};

final Map<String, dynamic> _storySchema = {
  'type': 'OBJECT',
  'properties': {
    'title': {'type': 'STRING'},
    'summary': {
      'type': 'STRING',
      'description': 'One or two sentences in English: what the book is about',
    },
    'narrator': {
      'type': 'OBJECT',
      'properties': {
        'voice': {'type': 'STRING', 'enum': _voiceEnum},
        'style': {'type': 'STRING'},
      },
      'required': ['voice', 'style'],
    },
    'characters': {
      'type': 'ARRAY',
      'items': {
        'type': 'OBJECT',
        'properties': {
          'id': {'type': 'STRING'},
          'name': {'type': 'STRING'},
          'description': {
            'type': 'STRING',
            'description': 'Who they are and what they look like, in English',
          },
          'gender': {
            'type': 'STRING',
            'enum': ['female', 'male', 'neutral'],
          },
          'voice': {'type': 'STRING', 'enum': _voiceEnum},
          'style': {'type': 'STRING'},
        },
        'required': ['id', 'name', 'description', 'gender', 'voice', 'style'],
        'propertyOrdering': ['id', 'name', 'description', 'gender', 'voice', 'style'],
      },
    },
    'lines': {'type': 'ARRAY', 'items': _lineSchema},
  },
  'required': ['title', 'summary', 'narrator', 'characters', 'lines'],
  'propertyOrdering': ['title', 'summary', 'narrator', 'characters', 'lines'],
};

final Map<String, dynamic> _translationSchema = {
  'type': 'OBJECT',
  'properties': {
    'title': {'type': 'STRING'},
    'lines': {'type': 'ARRAY', 'items': _lineSchema},
  },
  'required': ['title', 'lines'],
  'propertyOrdering': ['title', 'lines'],
};

/// Written to a temp file so [Workspace.setClip] can copy it in like any other.
Future<File> writeTempWav(Pcm pcm, String name) async {
  final dir = await Directory.systemTemp.createTemp('bookie-story-');
  final file = File(p.join(dir.path, '$name.wav'));
  await file.writeAsBytes(Uint8List.fromList(pcm.toWav()), flush: true);
  return file;
}

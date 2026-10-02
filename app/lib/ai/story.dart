/// An AI story for one tag: the photographed pages, what the user asked for,
/// the cast the model found, and a script per language.
///
/// Lives beside the workspace at `stories/<uid>/story.json`, never on the card.
/// The clip it produces is an ordinary clip in `audio/<lang>/`, so the toy and
/// the sync know nothing about any of this.
library;

import 'voices.dart';

/// How closely to follow any words printed on the pages.
enum StoryMode {
  /// Read the printed words, adding narration only where the pictures carry
  /// the story.
  faithful,

  /// Retell the book in its own words — the default.
  retold,

  /// A new adventure with the same characters and world.
  invented,
}

enum StoryLength { short, medium, long }

extension StoryLengthWords on StoryLength {
  String get label => switch (this) {
    StoryLength.short => 'Short',
    StoryLength.medium => 'Medium',
    StoryLength.long => 'Long',
  };

  String get hint => switch (this) {
    StoryLength.short => '~1 min',
    StoryLength.medium => '~3 min',
    StoryLength.long => '~5 min',
  };

  /// What the writer is asked for, in spoken words (≈150 a minute for a
  /// storyteller reading to a child).
  int get targetWords => switch (this) {
    StoryLength.short => 160,
    StoryLength.medium => 450,
    StoryLength.long => 750,
  };
}

extension StoryModeWords on StoryMode {
  String get label => switch (this) {
    StoryMode.faithful => "Book's words",
    StoryMode.retold => 'Retold',
    StoryMode.invented => 'New story',
  };
}

/// Someone who speaks: the narrator, or a character in the book.
class CastMember {
  CastMember({
    required this.id,
    required this.name,
    required this.description,
    required this.voice,
    required this.style,
    this.isNarrator = false,
  });

  /// ASCII, unique within the story — also the speaker label the TTS model
  /// sees in a dialogue, so it has to be stable across languages.
  final String id;
  String name;
  String description;

  /// A prebuilt voice name from [storyVoices].
  String voice;

  /// Delivery direction: "a slow, rumbling, sleepy old bear".
  String style;

  final bool isNarrator;

  StoryVoice? get voiceInfo => voiceNamed(voice);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'voice': voice,
    'style': style,
    if (isNarrator) 'narrator': true,
  };

  static CastMember fromJson(Map<String, dynamic> json) => CastMember(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
    voice: json['voice'] as String? ?? 'Sulafat',
    style: json['style'] as String? ?? '',
    isNarrator: json['narrator'] == true,
  );
}

/// One spoken turn.
class ScriptLine {
  ScriptLine({required this.speaker, required this.text, this.delivery = ''});

  /// A [CastMember.id].
  String speaker;
  String text;

  /// How this particular line is said, on top of the speaker's own style:
  /// "whispering", "suddenly excited".
  String delivery;

  Map<String, dynamic> toJson() => {
    'speaker': speaker,
    'text': text,
    if (delivery.isNotEmpty) 'delivery': delivery,
  };

  static ScriptLine fromJson(Map<String, dynamic> json) => ScriptLine(
    speaker: json['speaker'] as String? ?? 'narrator',
    text: json['text'] as String? ?? '',
    delivery: json['delivery'] as String? ?? '',
  );
}

/// The story in one language, and what became of it.
class StoryScript {
  StoryScript({required this.title, required this.lines, this.narration});

  String title;
  final List<ScriptLine> lines;

  /// Set once the audio exists; says which voices it was made with, so the
  /// app can tell when the cast has changed since.
  Narration? narration;

  int get wordCount => lines.fold(
    0,
    (n, l) => n + l.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length,
  );

  Map<String, dynamic> toJson() => {
    'title': title,
    'lines': lines.map((l) => l.toJson()).toList(),
    if (narration != null) 'narration': narration!.toJson(),
  };

  static StoryScript fromJson(Map<String, dynamic> json) => StoryScript(
    title: json['title'] as String? ?? '',
    lines: ((json['lines'] as List?) ?? const [])
        .map((l) => ScriptLine.fromJson((l as Map).cast<String, dynamic>()))
        .toList(),
    narration: json['narration'] == null
        ? null
        : Narration.fromJson(
            (json['narration'] as Map).cast<String, dynamic>(),
          ),
  );
}

class Narration {
  Narration({
    required this.castSignature,
    required this.scriptSignature,
    required this.durationMs,
    required this.createdAt,
  });

  final String castSignature;
  final String scriptSignature;
  final int durationMs;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'cast': castSignature,
    'script': scriptSignature,
    'durationMs': durationMs,
    'createdAt': createdAt.toIso8601String(),
  };

  static Narration fromJson(Map<String, dynamic> json) => Narration(
    castSignature: json['cast'] as String? ?? '',
    scriptSignature: json['script'] as String? ?? '',
    durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime(2000),
  );
}

class Story {
  Story({
    List<String>? pages,
    this.instructions = '',
    this.mode = StoryMode.retold,
    this.length = StoryLength.medium,
    this.summary = '',
    List<CastMember>? cast,
    Map<String, StoryScript>? scripts,
  }) : pages = pages ?? [],
       cast = cast ?? [],
       scripts = scripts ?? {};

  /// File names under `stories/<uid>/pages/`, in reading order.
  final List<String> pages;

  /// The user's own direction, passed to the model as extra system
  /// instructions. Optional.
  String instructions;
  StoryMode mode;
  StoryLength length;

  /// What the model made of the book, in a sentence or two (English).
  String summary;

  /// Narrator first, then the characters.
  final List<CastMember> cast;

  /// Language code -> script.
  final Map<String, StoryScript> scripts;

  bool get isWritten => cast.isNotEmpty && scripts.isNotEmpty;

  CastMember? member(String id) {
    for (final m in cast) {
      if (m.id == id) return m;
    }
    return null;
  }

  CastMember get narrator =>
      cast.firstWhere((m) => m.isNarrator, orElse: () => cast.first);

  /// The language the story was first written in — the one others are
  /// translated from.
  String? get sourceLanguage => scripts.keys.isEmpty ? null : scripts.keys.first;

  /// Changes whenever a voice or a style does; compared against
  /// [Narration.castSignature] to spot audio that is out of date.
  String get castSignature =>
      cast.map((m) => '${m.id}:${m.voice}:${m.style}').join('|');

  Map<String, dynamic> toJson() => {
    'schema': 1,
    'pages': pages,
    'instructions': instructions,
    'mode': mode.name,
    'length': length.name,
    'summary': summary,
    'cast': cast.map((m) => m.toJson()).toList(),
    'scripts': scripts.map((lang, s) => MapEntry(lang, s.toJson())),
  };

  static Story fromJson(Map<String, dynamic> json) => Story(
    pages: ((json['pages'] as List?) ?? const []).cast<String>().toList(),
    instructions: json['instructions'] as String? ?? '',
    mode: StoryMode.values.firstWhere(
      (m) => m.name == json['mode'],
      orElse: () => StoryMode.retold,
    ),
    length: StoryLength.values.firstWhere(
      (l) => l.name == json['length'],
      orElse: () => StoryLength.medium,
    ),
    summary: json['summary'] as String? ?? '',
    cast: ((json['cast'] as List?) ?? const [])
        .map((m) => CastMember.fromJson((m as Map).cast<String, dynamic>()))
        .toList(),
    scripts: ((json['scripts'] as Map?) ?? {}).map(
      (lang, s) => MapEntry(
        lang as String,
        StoryScript.fromJson((s as Map).cast<String, dynamic>()),
      ),
    ),
  );
}

/// A cheap fingerprint of a script's words, so an edited line marks the audio
/// as out of date. Not cryptographic; it only has to change when the text does.
String scriptSignature(StoryScript script) {
  var h = 0x811c9dc5;
  for (final line in script.lines) {
    for (final unit in '${line.speaker}\u0001${line.text}\u0001${line.delivery}\u0002'
        .codeUnits) {
      h = ((h ^ unit) * 0x01000193) & 0xffffffff;
    }
  }
  return h.toRadixString(16);
}

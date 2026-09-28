/// The configuration, in memory.
///
/// This is a one-to-one picture of what ends up on the card:
///
///     /audio/<lang>/<tag.name>.mp3|wav    one clip per tag, per language
///     /system/<lang>/<clip>.mp3|wav       the four optional prompts
///     /tags.csv                           "UID,name" lines the firmware reads
///     /bookie.json                        this file, so the card can be re-opened
///
/// Only `tags.csv` and the audio matter to the toy. `bookie.json` is ours: the
/// firmware never opens the card root except for `tags.csv`, so it rides along
/// harmlessly and means a card carries its own labels to the next phone.
library;

import 'uid.dart';

/// `config.h`: the four optional prompts under `/system/<lang>/`.
const systemClipIds = <String>['ready', 'language', 'unknown', 'low-battery'];

const systemClipBlurbs = <String, String>{
  'ready': 'Played once at boot, when the card and reader are both up.',
  'language': 'Played when the language button switches to this language.',
  'unknown': 'Played when a tag has no clip in this language.',
  'low-battery': 'Played once when the cell drops below 3.55 V.',
};

/// `config.h::LANG_FALLBACK` — the language `/system` clips fall back to.
const fallbackLanguage = 'en';

/// `config.h::AUDIO_PATH_MAX`, minus the NUL the firmware leaves room for.
const _audioPathMax = 96;

enum ClipSource { recorded, imported }

/// One audio file. [fileName] carries the extension because the firmware
/// prefers `.mp3` over `.wav` when both exist, so the extension is part of
/// the identity of the file on the card, not a detail.
class Clip {
  const Clip({
    required this.fileName,
    required this.bytes,
    required this.source,
    this.durationMs,
    this.originalName,
  });

  final String fileName;
  final int bytes;
  final ClipSource source;
  final int? durationMs;

  /// For imported clips: what the file was called before we renamed it.
  final String? originalName;

  String get extension {
    final dot = fileName.lastIndexOf('.');
    return dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  }

  Clip copyWith({String? fileName}) => Clip(
    fileName: fileName ?? this.fileName,
    bytes: bytes,
    source: source,
    durationMs: durationMs,
    originalName: originalName,
  );

  Map<String, dynamic> toJson() => {
    'file': fileName,
    'bytes': bytes,
    'source': source.name,
    if (durationMs != null) 'durationMs': durationMs,
    if (originalName != null) 'originalName': originalName,
  };

  static Clip fromJson(Map<String, dynamic> json) => Clip(
    fileName: json['file'] as String,
    bytes: (json['bytes'] as num?)?.toInt() ?? 0,
    source: ClipSource.values.firstWhere(
      (s) => s.name == json['source'],
      orElse: () => ClipSource.imported,
    ),
    durationMs: (json['durationMs'] as num?)?.toInt(),
    originalName: json['originalName'] as String?,
  );
}

/// One NFC tag: a UID, the file stem every language looks up, and the clips.
class BookieTag {
  BookieTag({
    required this.uid,
    required this.name,
    this.label,
    Map<String, Clip>? clips,
  }) : clips = clips ?? {};

  /// Normalised, as `tags.csv` stores it.
  final String uid;

  /// The file stem: `/audio/<lang>/<name>.mp3`. This is the `name` column.
  String name;

  /// Ours only — "Page 4, the bear wakes up". Never reaches the firmware.
  String? label;

  /// Language code -> clip. A language with no entry has nothing to play, and
  /// the toy falls back to `/system/<lang>/unknown`.
  final Map<String, Clip> clips;

  String get displayName =>
      (label?.trim().isNotEmpty ?? false) ? label!.trim() : name;

  Map<String, dynamic> toJson() => {
    'uid': uid,
    'name': name,
    if (label != null && label!.isNotEmpty) 'label': label,
    'clips': clips.map((lang, clip) => MapEntry(lang, clip.toJson())),
  };

  static BookieTag fromJson(Map<String, dynamic> json) => BookieTag(
    uid: normaliseUid(json['uid'] as String? ?? ''),
    name: json['name'] as String? ?? '',
    label: json['label'] as String?,
    clips: ((json['clips'] as Map?) ?? {}).map(
      (lang, clip) => MapEntry(
        lang as String,
        Clip.fromJson((clip as Map).cast<String, dynamic>()),
      ),
    ),
  );
}

/// Everything the card holds.
class Project {
  Project({
    List<String>? languages,
    List<BookieTag>? tags,
    Map<String, Map<String, Clip>>? system,
  }) : languages = languages ?? [fallbackLanguage],
       tags = tags ?? [],
       system = system ?? {};

  /// Folder names under `/audio`. The language button cycles these in
  /// alphabetical order, so we keep the list sorted the same way.
  final List<String> languages;

  final List<BookieTag> tags;

  /// language -> clip id (`ready`, `language`, …) -> clip.
  final Map<String, Map<String, Clip>> system;

  BookieTag? tagByUid(String uid) {
    final key = normaliseUid(uid);
    for (final tag in tags) {
      if (tag.uid == key) return tag;
    }
    return null;
  }

  /// How many tags have nothing to play in [lang].
  int missingIn(String lang) =>
      tags.where((t) => !t.clips.containsKey(lang)).length;

  void sortLanguages() => languages.sort();

  Map<String, dynamic> toJson() => {
    'schema': 1,
    'languages': languages,
    'tags': tags.map((t) => t.toJson()).toList(),
    'system': system.map(
      (lang, clips) =>
          MapEntry(lang, clips.map((id, clip) => MapEntry(id, clip.toJson()))),
    ),
  };

  static Project fromJson(Map<String, dynamic> json) => Project(
    languages: ((json['languages'] as List?) ?? const [])
        .cast<String>()
        .toList(),
    tags: ((json['tags'] as List?) ?? const [])
        .map((t) => BookieTag.fromJson((t as Map).cast<String, dynamic>()))
        .toList(),
    system: ((json['system'] as Map?) ?? {}).map(
      (lang, clips) => MapEntry(
        lang as String,
        (clips as Map).map(
          (id, clip) => MapEntry(
            id as String,
            Clip.fromJson((clip as Map).cast<String, dynamic>()),
          ),
        ),
      ),
    ),
  );
}

// --------------------------------------------------------------- names

/// Accented Latin letters, folded to ASCII.
///
/// A toy that ships with `es` and `fr` folders will be handed names like
/// "Página" and "Forêt". Dropping the accented letter outright would make those
/// `pgina` and `fort`; folding gives `pagina` and `foret`, which is both
/// readable and safe on FAT.
const _fold = {
  'á': 'a',
  'à': 'a',
  'ä': 'a',
  'â': 'a',
  'ã': 'a',
  'å': 'a',
  'ā': 'a',
  'é': 'e',
  'è': 'e',
  'ë': 'e',
  'ê': 'e',
  'ē': 'e',
  'í': 'i',
  'ì': 'i',
  'ï': 'i',
  'î': 'i',
  'ī': 'i',
  'ó': 'o',
  'ò': 'o',
  'ö': 'o',
  'ô': 'o',
  'õ': 'o',
  'ø': 'o',
  'ō': 'o',
  'ú': 'u',
  'ù': 'u',
  'ü': 'u',
  'û': 'u',
  'ū': 'u',
  'ñ': 'n',
  'ç': 'c',
  'ý': 'y',
  'ÿ': 'y',
  'æ': 'ae',
  'œ': 'oe',
  'ß': 'ss',
  'đ': 'd',
  'ł': 'l',
  'þ': 'th',
};

/// FAT is happier with lower case and no spaces, and so is `prepare_audio.sh`,
/// which does `tr '[:upper:] ' '[:lower:]-'`. We go a little further: accents
/// are folded to ASCII, and anything still left that is not a letter, a digit,
/// a dash or an underscore is dropped.
String sanitiseStem(String raw) {
  final lowered = raw.trim().toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lowered.runes) {
    var c = String.fromCharCode(rune);
    c = _fold[c] ?? c;
    if (RegExp(r'^[a-z0-9_]+$').hasMatch(c)) {
      buffer.write(c);
    } else if (c == '-' || c == ' ' || c == '.') {
      buffer.write('-');
    }
  }
  var out = buffer.toString().replaceAll(RegExp(r'-+'), '-');
  out = out.replaceAll(RegExp(r'^-+|-+$'), '');
  return out;
}

/// The longest stem that still fits `AUDIO_PATH_MAX` for every language we
/// have, counting the longest language code and the longest extension.
int maxStemLength(Iterable<String> languages) {
  final longestLang = languages.fold<int>(
    2,
    (m, l) => l.length > m ? l.length : m,
  );
  // "/audio/" + lang + "/" + stem + ".mp3", and the firmware's buffer is
  // AUDIO_PATH_MAX bytes including the terminator.
  final room =
      _audioPathMax - 1 - '/audio/'.length - longestLang - 1 - '.mp3'.length;
  return room.clamp(1, 64);
}

/// A stem no other tag is using. Collisions matter: two tags with the same
/// name would silently share one clip on the card.
String uniqueStem(String wanted, Project project, {String? exceptUid}) {
  final limit = maxStemLength(project.languages);
  var base = sanitiseStem(wanted);
  if (base.isEmpty) base = 'tag';
  if (base.length > limit) base = base.substring(0, limit);

  bool taken(String candidate) => project.tags.any(
    (t) =>
        t.uid != exceptUid && t.name.toLowerCase() == candidate.toLowerCase(),
  );

  if (!taken(base)) return base;
  for (var n = 2; n < 1000; n++) {
    final suffix = '-$n';
    final head = base.length + suffix.length > limit
        ? base.substring(0, limit - suffix.length)
        : base;
    final candidate = '$head$suffix';
    if (!taken(candidate)) return candidate;
  }
  return base;
}

/// Language codes are folder names under `/audio`, so the same rules apply.
String sanitiseLanguage(String raw) {
  final out = sanitiseStem(raw);
  return out.length > 16 ? out.substring(0, 16) : out;
}

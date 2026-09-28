/// The configuration as it lives on the phone.
///
/// The workspace is laid out exactly like the card — `audio/<lang>/<stem>.<ext>`,
/// `system/<lang>/<clip>.<ext>`, `project.json` — so writing the card is a plain
/// directory diff rather than a translation step. Everything the app edits
/// happens here first; the card is only ever touched by an explicit sync.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../model/project.dart';
import '../model/uid.dart';

class Workspace extends ChangeNotifier {
  Workspace._(this.root, this._project);

  final Directory root;
  Project _project;

  Project get project => _project;

  /// Bumped on every save. The card page keys its plan on this, so editing a
  /// tag and switching to the Card tab recomputes rather than showing a plan
  /// from before the edit.
  int get revision => _revision;
  int _revision = 0;

  static const _stateFile = 'project.json';

  static Future<Workspace> open() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(docs.path, 'workspace'));
    await root.create(recursive: true);

    final state = File(p.join(root.path, _stateFile));
    var project = Project();
    if (await state.exists()) {
      try {
        project = Project.fromJson(
          (jsonDecode(await state.readAsString()) as Map)
              .cast<String, dynamic>(),
        );
      } on Object catch (e) {
        debugPrint('workspace: project.json unreadable ($e), starting empty');
      }
    }
    if (project.languages.isEmpty) project.languages.add(fallbackLanguage);
    project.sortLanguages();

    final workspace = Workspace._(root, project);
    await workspace._ensureLanguageDirs();
    return workspace;
  }

  // ------------------------------------------------------------ paths

  /// Where a clip lives inside the workspace, relative to [root]. The same
  /// string, with a leading slash, is where it goes on the card.
  String audioRel(String lang, String fileName) => 'audio/$lang/$fileName';
  String systemRel(String lang, String fileName) => 'system/$lang/$fileName';

  File fileAt(String relative) => File(p.join(root.path, relative));

  File? clipFile(BookieTag tag, String lang) {
    final clip = tag.clips[lang];
    return clip == null ? null : fileAt(audioRel(lang, clip.fileName));
  }

  File? systemFile(String lang, String clipId) {
    final clip = _project.system[lang]?[clipId];
    return clip == null ? null : fileAt(systemRel(lang, clip.fileName));
  }

  /// Every file that should end up on the card, card path -> local file.
  /// Audio only: `tags.csv` and `bookie.json` are generated at sync time.
  Map<String, File> desiredFiles() {
    final out = <String, File>{};
    for (final tag in _project.tags) {
      for (final entry in tag.clips.entries) {
        if (!_project.languages.contains(entry.key)) continue;
        final rel = audioRel(entry.key, entry.value.fileName);
        out['/$rel'] = fileAt(rel);
      }
    }
    for (final lang in _project.languages) {
      for (final entry
          in (_project.system[lang] ?? const <String, Clip>{}).entries) {
        final rel = systemRel(lang, entry.value.fileName);
        out['/$rel'] = fileAt(rel);
      }
    }
    return out;
  }

  // ------------------------------------------------------------ mutation

  Future<void> save() async {
    final state = File(p.join(root.path, _stateFile));
    await state.writeAsString(
      const JsonEncoder.withIndent('  ').convert(_project.toJson()),
    );
    _revision++;
    notifyListeners();
  }

  Future<void> _ensureLanguageDirs() async {
    for (final lang in _project.languages) {
      await Directory(p.join(root.path, 'audio', lang)).create(recursive: true);
      await Directory(
        p.join(root.path, 'system', lang),
      ).create(recursive: true);
    }
  }

  Future<BookieTag> addTag(String uid, {String? label}) async {
    final key = normaliseUid(uid);
    final existing = _project.tagByUid(key);
    if (existing != null) return existing;

    // An unnamed tag is named after its UID, spelled the way library.cpp's own
    // fallback spells it: upper case, no separators. `trackFor()` ends with
    // `resolveStem(base + key)`, so that spelling is what finds the clip on a
    // card whose tags.csv has been lost — which is the case the fallback is
    // there for. sanitiseStem would lower-case it and give that up.
    final named = label?.trim().isNotEmpty ?? false;
    final tag = BookieTag(
      uid: key,
      name: named ? uniqueStem(label!.trim(), _project) : key,
      label: label,
    );
    _project.tags.add(tag);
    await save();
    return tag;
  }

  Future<void> removeTag(BookieTag tag) async {
    for (final lang in tag.clips.keys.toList()) {
      await _deleteQuietly(clipFile(tag, lang));
    }
    _project.tags.removeWhere((t) => t.uid == tag.uid);
    await save();
  }

  /// Renaming a tag renames its clip in every language: the stem *is* the file
  /// name the firmware looks up.
  Future<void> renameTag(BookieTag tag, {String? label, String? stem}) async {
    if (label != null) tag.label = label;

    final wanted = stem ?? (label != null ? sanitiseStem(label) : null);
    if (wanted != null && wanted.isNotEmpty) {
      final next = uniqueStem(wanted, _project, exceptUid: tag.uid);
      if (next != tag.name) {
        for (final entry in tag.clips.entries.toList()) {
          final clip = entry.value;
          final ext = clip.extension;
          final from = fileAt(audioRel(entry.key, clip.fileName));
          final to = fileAt(audioRel(entry.key, '$next.$ext'));
          if (await from.exists()) {
            await to.parent.create(recursive: true);
            await from.rename(to.path);
          }
          tag.clips[entry.key] = clip.copyWith(fileName: '$next.$ext');
        }
        tag.name = next;
      }
    }
    await save();
  }

  /// Bring [source] into the workspace as this tag's clip for [lang]. The file
  /// is copied, never referenced: pickers hand out URIs that expire.
  Future<Clip> setClip(
    BookieTag tag,
    String lang,
    File source, {
    required ClipSource origin,
    int? durationMs,
    String? originalName,
  }) async {
    final ext = _normaliseExtension(p.extension(source.path));
    final fileName = '${tag.name}.$ext';
    final dest = fileAt(audioRel(lang, fileName));
    await dest.parent.create(recursive: true);

    // The firmware prefers .mp3 when both exist, so a wav replacing an mp3
    // would be silently ignored. Clear the other container first.
    await _deleteSiblings(dest.parent, tag.name, keep: ext);
    if (source.path != dest.path) await source.copy(dest.path);

    final clip = Clip(
      fileName: fileName,
      bytes: await dest.length(),
      source: origin,
      durationMs: durationMs,
      originalName: originalName,
    );
    tag.clips[lang] = clip;
    await save();
    return clip;
  }

  Future<void> removeClip(BookieTag tag, String lang) async {
    await _deleteQuietly(clipFile(tag, lang));
    tag.clips.remove(lang);
    await save();
  }

  Future<Clip> setSystemClip(
    String lang,
    String clipId,
    File source, {
    required ClipSource origin,
    int? durationMs,
  }) async {
    final ext = _normaliseExtension(p.extension(source.path));
    final fileName = '$clipId.$ext';
    final dest = fileAt(systemRel(lang, fileName));
    await dest.parent.create(recursive: true);
    await _deleteSiblings(dest.parent, clipId, keep: ext);
    if (source.path != dest.path) await source.copy(dest.path);

    final clip = Clip(
      fileName: fileName,
      bytes: await dest.length(),
      source: origin,
      durationMs: durationMs,
    );
    (_project.system[lang] ??= {})[clipId] = clip;
    await save();
    return clip;
  }

  Future<void> removeSystemClip(String lang, String clipId) async {
    await _deleteQuietly(systemFile(lang, clipId));
    _project.system[lang]?.remove(clipId);
    await save();
  }

  Future<void> addLanguage(String code) async {
    final clean = sanitiseLanguage(code);
    if (clean.isEmpty || _project.languages.contains(clean)) return;
    _project.languages.add(clean);
    _project.sortLanguages();
    await _ensureLanguageDirs();
    await save();
  }

  Future<void> removeLanguage(String code) async {
    _project.languages.remove(code);
    _project.system.remove(code);
    for (final tag in _project.tags) {
      tag.clips.remove(code);
    }
    for (final dir in ['audio', 'system']) {
      final target = Directory(p.join(root.path, dir, code));
      if (await target.exists()) await target.delete(recursive: true);
    }
    await save();
  }

  /// Replace the whole project — used when importing a card.
  Future<void> replace(Project next) async {
    _project = next;
    if (_project.languages.isEmpty) _project.languages.add(fallbackLanguage);
    _project.sortLanguages();
    await _ensureLanguageDirs();
    await save();
  }

  // ------------------------------------------------------------ helpers

  /// `.mp3` and `.wav` are what `library.cpp::resolveStem()` looks for; nothing
  /// else can reach here, the pickers filter for it.
  String _normaliseExtension(String raw) {
    final ext = raw.replaceFirst('.', '').toLowerCase();
    return (ext == 'mp3' || ext == 'wav') ? ext : 'wav';
  }

  Future<void> _deleteSiblings(
    Directory dir,
    String stem, {
    required String keep,
  }) async {
    for (final ext in const ['mp3', 'wav']) {
      if (ext == keep) continue;
      await _deleteQuietly(File(p.join(dir.path, '$stem.$ext')));
    }
  }

  Future<void> _deleteQuietly(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (e) {
      debugPrint('workspace: could not delete ${file.path} ($e)');
    }
  }
}

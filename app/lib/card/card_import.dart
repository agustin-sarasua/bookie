/// Reading a card back into the app.
///
/// Two sources, in order of how much they know:
///
///   `/bookie.json`  written by this app, so it still has the labels
///   `/tags.csv`     written by anyone, so names survive but labels do not
///
/// If neither is there we can still recover something, because the firmware's
/// own fallback is to name clips after the UID: a file called `04A224AA5C6180.mp3`
/// under `/audio/en` is a tag, and we say so.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../model/project.dart';
import '../model/tags_csv.dart';
import '../model/uid.dart';
import '../store/workspace.dart';
import 'card_target.dart';

class ImportSummary {
  const ImportSummary({
    required this.source,
    required this.languages,
    required this.tags,
    required this.clipsCopied,
    required this.bytesCopied,
  });

  /// How much the card told us about itself.
  final String source;
  final int languages;
  final int tags;
  final int clipsCopied;
  final int bytesCopied;
}

class CardImport {
  /// Does this folder hold anything a Bookie card would hold?
  ///
  /// Worth asking before [pullInto], which replaces the whole project: point at
  /// the wrong volume — an empty card, or the phone's own Documents folder —
  /// and importing would otherwise "succeed" by emptying everything, with the
  /// clips already deleted by the time you noticed.
  static Future<bool> looksLikeCard(CardTarget card) async {
    if (await card.readFile('/bookie.json') != null) return true;
    if (await card.readFile('/tags.csv') != null) return true;
    return (await card.list('/audio')).any((entry) => entry.isDirectory);
  }

  /// Replace the workspace with what is on the card. Destructive on purpose —
  /// the caller confirms first, and checks [looksLikeCard].
  static Future<ImportSummary> pullInto(
    Workspace workspace,
    CardTarget card, {
    void Function(String path, int done, int total)? onProgress,
  }) async {
    final languages = <String>[];
    for (final entry in await card.list('/audio')) {
      if (entry.isDirectory && !entry.name.startsWith('.')) {
        languages.add(entry.name);
      }
    }
    languages.sort();

    var source = 'nothing but the audio folders';
    Project project;

    final metaBytes = await card.readFile('/bookie.json');
    if (metaBytes != null) {
      project = Project.fromJson(
        (jsonDecode(utf8.decode(metaBytes)) as Map).cast<String, dynamic>(),
      );
      source = 'bookie.json';
      for (final lang in languages) {
        if (!project.languages.contains(lang)) project.languages.add(lang);
      }
    } else {
      project = Project(
        languages: languages.isEmpty ? [fallbackLanguage] : languages,
      );
      final csvBytes = await card.readFile('/tags.csv');
      if (csvBytes != null) {
        source = 'tags.csv';
        for (final row in parseTagsCsv(utf8.decode(csvBytes))) {
          project.tags.add(BookieTag(uid: row.uid, name: row.name));
        }
      }
    }
    project.sortLanguages();

    // Walk the audio folders and attach whatever is actually there. This also
    // rescues UID-named clips for tags that never made it into tags.csv.
    final byStem = {
      for (final tag in project.tags) tag.name.toLowerCase(): tag,
    };
    final toCopy = <_Pending>[];

    for (final lang in project.languages) {
      for (final file in await card.list('/audio/$lang')) {
        if (file.isDirectory) continue;
        final ext = p.extension(file.name).replaceFirst('.', '').toLowerCase();
        if (ext != 'mp3' && ext != 'wav') continue;
        final stem = p.basenameWithoutExtension(file.name);

        var tag = byStem[stem.toLowerCase()];
        if (tag == null) {
          final asUid = normaliseUid(stem);
          // The firmware's fallback: an unnamed tag's clip is its UID.
          if (asUid.length < 8 || asUid.length != stem.length) continue;
          tag = BookieTag(uid: asUid, name: stem);
          project.tags.add(tag);
          byStem[stem.toLowerCase()] = tag;
        }
        tag.clips[lang] = Clip(
          fileName: file.name,
          bytes: file.size,
          source: ClipSource.imported,
        );
        toCopy.add(
          _Pending(
            '/audio/$lang/${file.name}',
            workspace.audioRel(lang, file.name),
            file.size,
          ),
        );
      }

      for (final file in await card.list('/system/$lang')) {
        if (file.isDirectory) continue;
        final id = p.basenameWithoutExtension(file.name);
        if (!systemClipIds.contains(id)) continue;
        (project.system[lang] ??= {})[id] = Clip(
          fileName: file.name,
          bytes: file.size,
          source: ClipSource.imported,
        );
        toCopy.add(
          _Pending(
            '/system/$lang/${file.name}',
            workspace.systemRel(lang, file.name),
            file.size,
          ),
        );
      }
    }

    await workspace.replace(project);

    // Clear out the old audio before copying, so a stale clip cannot survive
    // an import as a file nothing references.
    for (final dir in const ['audio', 'system']) {
      final target = Directory(p.join(workspace.root.path, dir));
      if (await target.exists()) await target.delete(recursive: true);
    }

    var bytes = 0;
    for (var i = 0; i < toCopy.length; i++) {
      final pending = toCopy[i];
      onProgress?.call(pending.cardPath, i, toCopy.length);
      final dest = workspace.fileAt(pending.localRel);
      await dest.parent.create(recursive: true);
      await card.copyOut(pending.cardPath, dest.path);
      bytes += pending.bytes;
    }

    await workspace.save();
    return ImportSummary(
      source: source,
      languages: project.languages.length,
      tags: project.tags.length,
      clipsCopied: toCopy.length,
      bytesCopied: bytes,
    );
  }
}

class _Pending {
  const _Pending(this.cardPath, this.localRel, this.bytes);
  final String cardPath;
  final String localRel;
  final int bytes;
}

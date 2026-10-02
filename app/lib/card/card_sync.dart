/// Working out what the card is missing, and then putting it there.
///
/// Both directions are a directory diff, because the workspace is laid out
/// exactly like the card. Files are compared by size only — the card is FAT32
/// with two-second timestamp granularity and no checksums, and re-copying a
/// 3 MB clip to be sure is slower than it is worth. `make card` takes the same
/// shortcut (`rsync --modify-window=2`).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../model/tags_csv.dart';
import '../store/workspace.dart';
import 'card_target.dart';

class SyncWrite {
  const SyncWrite({
    required this.cardPath,
    required this.bytes,
    this.source,
    this.inline,
    this.replaces = false,
  });

  final String cardPath;
  final int bytes;

  /// A file to stream across, for clips.
  final File? source;

  /// Content generated on the spot, for `tags.csv` and `bookie.json`.
  final Uint8List? inline;

  /// True when the card already has a different file at [cardPath].
  final bool replaces;

  bool get isClip => source != null;
  String get name => cardPath.split('/').last;
}

class SyncPlan {
  const SyncPlan({
    required this.writes,
    required this.deletions,
    required this.folders,
    required this.onCard,
    required this.missingLocally,
  });

  /// Files to add or replace. `tags.csv` and `bookie.json` are only here when
  /// what is on the card differs from what the project would write.
  final List<SyncWrite> writes;

  /// Clips on the card that no tag plays: tags that were deleted or renamed,
  /// languages that were removed, and the other container of a stem we are
  /// writing (`bear.wav` beside a new `bear.mp3`). All of them go — the card
  /// holds exactly what the project says and nothing else.
  final List<String> deletions;

  /// `/audio/<lang>` folders for languages the project no longer has, removed
  /// once they are empty: every folder under `/audio` is a language the button
  /// cycles through, so an empty one would still be announced.
  final List<String> folders;

  /// What the card holds under `/audio` and `/system`, path -> size, as read
  /// when the plan was made.
  final Map<String, int> onCard;

  /// Clips the project lists but whose file has gone missing on the phone.
  final List<String> missingLocally;

  List<SyncWrite> get clipWrites => writes.where((w) => w.isClip).toList();
  bool get tagListChanged => writes.any((w) => !w.isClip);
  int get added => writes.where((w) => w.isClip && !w.replaces).length;
  int get updated => writes.where((w) => w.isClip && w.replaces).length;

  int get totalBytes => writes.fold(0, (sum, w) => sum + w.bytes);
  bool get isEmpty => writes.isEmpty && deletions.isEmpty && folders.isEmpty;

  /// Whether [cardPath] is on the card and needs nothing.
  bool isSynced(String cardPath) =>
      onCard.containsKey(cardPath) && !writes.any((w) => w.cardPath == cardPath);
}

class SyncProgress {
  const SyncProgress({
    required this.done,
    required this.total,
    required this.bytesDone,
    required this.bytesTotal,
    required this.current,
  });

  final int done;
  final int total;
  final int bytesDone;
  final int bytesTotal;
  final String current;

  double get fraction =>
      bytesTotal == 0 ? 1 : (bytesDone / bytesTotal).clamp(0, 1);
}

class CardSync {
  /// Compare the workspace with the card. Nothing is written.
  static Future<SyncPlan> plan(Workspace workspace, CardTarget card) async {
    final project = workspace.project;
    final desired = workspace.desiredFiles();

    final writes = <SyncWrite>[];
    final deletions = <String>[];
    final folders = <String>[];
    final missing = <String>[];

    // What the card holds right now, under the two folders we own.
    final onCard = <String, int>{};
    final audioLanguages = <String>[];
    for (final dir in const ['/audio', '/system']) {
      for (final langDir in await card.list(dir)) {
        if (!langDir.isDirectory) continue;
        if (dir == '/audio') audioLanguages.add(langDir.name);
        for (final file in await card.list('$dir/${langDir.name}')) {
          if (file.isDirectory) continue;
          onCard['$dir/${langDir.name}/${file.name}'] = file.size;
        }
      }
    }

    for (final entry in desired.entries) {
      final file = entry.value;
      if (!await file.exists()) {
        missing.add(entry.key);
        continue;
      }
      final length = await file.length();
      final existing = onCard[entry.key];
      if (existing != length) {
        writes.add(
          SyncWrite(
            cardPath: entry.key,
            bytes: length,
            source: file,
            replaces: existing != null,
          ),
        );
      }
    }

    // Anything on the card we did not ask for. Under /audio that is always
    // removed. Under /system only the twin of a prompt we are writing is: a
    // card set up with `make card` carries prompts the app never imported, and
    // they are the toy's voice, not a tag's clip.
    for (final path in onCard.keys) {
      if (desired.containsKey(path)) continue;
      if (path.startsWith('/audio/') || _shadows(path, desired.keys)) {
        deletions.add(path);
      }
    }
    for (final lang in audioLanguages) {
      if (!project.languages.contains(lang)) folders.add('/audio/$lang');
    }

    // The two generated files, only when they would change something.
    final csv = Uint8List.fromList(utf8.encode(renderTagsCsv(project)));
    final meta = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(project.toJson())),
    );
    for (final (path, bytes) in [('/tags.csv', csv), ('/bookie.json', meta)]) {
      final current = await card.readFile(path);
      if (current == null || !_sameBytes(current, bytes)) {
        writes.add(
          SyncWrite(
            cardPath: path,
            bytes: bytes.length,
            inline: bytes,
            replaces: current != null,
          ),
        );
      }
    }

    writes.sort((a, b) => a.cardPath.compareTo(b.cardPath));
    deletions.sort();
    folders.sort();
    return SyncPlan(
      writes: writes,
      deletions: deletions,
      folders: folders,
      onCard: onCard,
      missingLocally: missing,
    );
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Carry the plan out. Writes first, deletes last: if the card is pulled
  /// half way through, the toy is left with too many files rather than too few.
  static Stream<SyncProgress> apply(CardTarget card, SyncPlan plan) async* {
    // Folders last, once their files are gone. A toy on older firmware cannot
    // remove a folder and says so with `deleted: false`, which is not an error.
    final deletions = [...plan.deletions, ...plan.folders];
    final total = plan.writes.length + deletions.length;
    var done = 0;
    var bytesDone = 0;
    final bytesTotal = plan.totalBytes;

    for (final write in plan.writes) {
      yield SyncProgress(
        done: done,
        total: total,
        bytesDone: bytesDone,
        bytesTotal: bytesTotal,
        current: write.cardPath,
      );
      if (write.inline != null) {
        await card.writeBytes(write.cardPath, write.inline!);
      } else {
        await card.copyFile(write.cardPath, write.source!.path);
      }
      done++;
      bytesDone += write.bytes;
    }

    for (final path in deletions) {
      yield SyncProgress(
        done: done,
        total: total,
        bytesDone: bytesDone,
        bytesTotal: bytesTotal,
        current: path,
      );
      await card.delete(path);
      done++;
    }

    yield SyncProgress(
      done: total,
      total: total,
      bytesDone: bytesTotal,
      bytesTotal: bytesTotal,
      current: 'Done',
    );
  }

  /// True when [path] is the same stem as a file we are writing, in the other
  /// container — `/audio/en/bear.wav` against a desired `/audio/en/bear.mp3`.
  static bool _shadows(String path, Iterable<String> desired) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return false;
    final stem = path.substring(0, dot);
    return desired.any((d) => d != path && d.startsWith('$stem.'));
  }
}

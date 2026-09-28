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
  });

  final String cardPath;
  final int bytes;

  /// A file to stream across, for clips.
  final File? source;

  /// Content generated on the spot, for `tags.csv` and `bookie.json`.
  final Uint8List? inline;

  String get name => cardPath.split('/').last;
}

class SyncPlan {
  const SyncPlan({
    required this.writes,
    required this.shadowing,
    required this.orphans,
    required this.missingLocally,
  });

  /// Files to add or replace.
  final List<SyncWrite> writes;

  /// Files that *must* go: a `bear.wav` left behind next to a new `bear.mp3`
  /// would win the lookup in `library.cpp::resolveStem()` — no, worse: the mp3
  /// would win and the wav would just waste space. Either way the card should
  /// hold one container per stem, so these are always removed.
  final List<String> shadowing;

  /// Everything else on the card that the project does not know about —
  /// clips for deleted tags, folders for removed languages. Removing these is
  /// the user's call.
  final List<String> orphans;

  /// Clips the project lists but whose file has gone missing on the phone.
  final List<String> missingLocally;

  int get totalBytes => writes.fold(0, (sum, w) => sum + w.bytes);
  bool get isEmpty => writes.isEmpty && shadowing.isEmpty;
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
    final shadowing = <String>[];
    final orphans = <String>[];
    final missing = <String>[];

    // What the card holds right now, under the two folders we own.
    final onCard = <String, int>{};
    for (final dir in const ['/audio', '/system']) {
      for (final langDir in await card.list(dir)) {
        if (!langDir.isDirectory) continue;
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
        writes.add(SyncWrite(cardPath: entry.key, bytes: length, source: file));
      }
    }

    // Anything on the card we did not ask for.
    for (final path in onCard.keys) {
      if (desired.containsKey(path)) continue;
      if (_shadows(path, desired.keys)) {
        shadowing.add(path);
      } else {
        orphans.add(path);
      }
    }

    final csv = Uint8List.fromList(utf8.encode(renderTagsCsv(project)));
    writes.add(
      SyncWrite(cardPath: '/tags.csv', bytes: csv.length, inline: csv),
    );

    final meta = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(project.toJson())),
    );
    writes.add(
      SyncWrite(cardPath: '/bookie.json', bytes: meta.length, inline: meta),
    );

    writes.sort((a, b) => a.cardPath.compareTo(b.cardPath));
    shadowing.sort();
    orphans.sort();
    return SyncPlan(
      writes: writes,
      shadowing: shadowing,
      orphans: orphans,
      missingLocally: missing,
    );
  }

  /// Carry the plan out. Writes first, deletes last: if the card is pulled
  /// half way through, the toy is left with too many files rather than too few.
  static Stream<SyncProgress> apply(
    CardTarget card,
    SyncPlan plan, {
    bool removeOrphans = false,
  }) async* {
    final deletions = [...plan.shadowing, if (removeOrphans) ...plan.orphans];
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

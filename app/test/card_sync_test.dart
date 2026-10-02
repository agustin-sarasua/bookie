// The update the Card tab offers: exactly what changed, and nothing no tag
// uses left behind.

import 'dart:io';
import 'dart:typed_data';

import 'package:bookie_studio/card/card_sync.dart';
import 'package:bookie_studio/card/card_target.dart';
import 'package:bookie_studio/model/project.dart';
import 'package:bookie_studio/store/workspace.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// A card in memory, with the firmware's rules: a folder only goes when empty.
class _FakeCard implements CardTarget {
  final files = <String, Uint8List>{};
  final dirs = <String>{'/audio', '/system'};

  @override
  CardInfo get info => const CardInfo(handle: 'fake', name: 'Bookie');

  @override
  Future<CardTarget?> refresh() async => this;

  @override
  Future<List<CardEntry>> list(String path) async {
    final out = <CardEntry>[];
    for (final d in dirs) {
      if (d != path && d.startsWith('$path/') && !d.substring(path.length + 1).contains('/')) {
        out.add(CardEntry(name: d.split('/').last, isDirectory: true, size: 0));
      }
    }
    for (final f in files.entries) {
      if (f.key.startsWith('$path/') && !f.key.substring(path.length + 1).contains('/')) {
        out.add(CardEntry(name: f.key.split('/').last, isDirectory: false, size: f.value.length));
      }
    }
    return out;
  }

  @override
  Future<Uint8List?> readFile(String path) async => files[path];

  void _mkdirs(String path) {
    final parts = path.split('/')..removeLast();
    for (var i = 2; i <= parts.length; i++) {
      dirs.add(parts.sublist(0, i).join('/'));
    }
  }

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    _mkdirs(path);
    files[path] = bytes;
  }

  @override
  Future<void> copyFile(String path, String localPath) async =>
      writeBytes(path, await File(localPath).readAsBytes());

  @override
  Future<void> copyOut(String path, String localPath) async =>
      File(localPath).writeAsBytes(files[path]!);

  @override
  Future<bool> delete(String path) async {
    if (files.remove(path) != null) return true;
    if (dirs.contains(path) && !files.keys.any((f) => f.startsWith('$path/'))) {
      return dirs.remove(path);
    }
    return false;
  }

  @override
  Future<void> release() async {}
}

void main() {
  late Directory tmp;
  late Workspace workspace;
  late _FakeCard card;

  Future<File> clip(String name, int size) async =>
      File('${tmp.path}/$name')..writeAsBytesSync(Uint8List(size));

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sync-test');
    PathProviderPlatform.instance = _Paths(tmp.path);
    workspace = await Workspace.open();
    card = _FakeCard();
  });
  tearDown(() => tmp.delete(recursive: true));

  test('after an update there is nothing left to do — tags.csv included', () async {
    await workspace.addLanguage('es');
    final tag = await workspace.addTag('04A1', label: 'Bear');
    await workspace.setClip(tag, 'en', await clip('a.wav', 100), origin: ClipSource.recorded);
    await workspace.setClip(tag, 'es', await clip('b.wav', 120), origin: ClipSource.generated);

    final first = await CardSync.plan(workspace, card);
    expect(first.added, 2);
    expect(first.tagListChanged, isTrue);
    await CardSync.apply(card, first).drain<void>();

    final second = await CardSync.plan(workspace, card);
    expect(second.isEmpty, isTrue, reason: 'writes: ${second.writes.map((w) => w.cardPath)}');
    expect(second.isSynced('/audio/en/bear.wav'), isTrue);

    // Renaming a tag changes tags.csv but re-sends nothing that did not change
    // — except the renamed clips themselves, whose old names go.
    await workspace.renameTag(tag, label: 'Big bear', stem: 'big-bear');
    final third = await CardSync.plan(workspace, card);
    expect(third.tagListChanged, isTrue);
    expect(third.added, 2);
    expect(third.deletions, ['/audio/en/bear.wav', '/audio/es/bear.wav']);
  });

  test('clips no tag uses are removed, and so is a dropped language', () async {
    final tag = await workspace.addTag('04A1', label: 'Bear');
    await workspace.setClip(tag, 'en', await clip('a.mp3', 100), origin: ClipSource.imported);

    card.files['/audio/en/old-tag.mp3'] = Uint8List(10);
    card.files['/audio/en/bear.wav'] = Uint8List(10); // twin of the new mp3
    card.files['/audio/fr/bear.mp3'] = Uint8List(10); // language not in the app
    card.files['/system/en/ready.mp3'] = Uint8List(10); // prompt from `make card`
    card.dirs.addAll({'/audio/en', '/audio/fr', '/system/en'});

    final plan = await CardSync.plan(workspace, card);
    expect(plan.deletions, ['/audio/en/bear.wav', '/audio/en/old-tag.mp3', '/audio/fr/bear.mp3']);
    expect(plan.folders, ['/audio/fr']);

    await CardSync.apply(card, plan).drain<void>();
    expect(card.dirs, isNot(contains('/audio/fr')));
    expect(card.files.keys, contains('/system/en/ready.mp3'));
    expect((await CardSync.plan(workspace, card)).isEmpty, isTrue);
  });
}

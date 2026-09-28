/// The microSD card, however we can reach it.
///
/// There are two ways. A card reader plugged into the phone, where the two
/// platforms give us nothing alike — Android hands back a Storage Access
/// Framework tree URI and every path has to be walked through
/// `DocumentsContract`, iOS hands back a security-scoped folder URL that
/// behaves like an ordinary directory — both wrapped by one native channel as
/// [ReaderCard]. Or the card stays in the toy and we talk to it over the toy's
/// own WiFi, which is [ToyCard] in `toy_card.dart`.
///
/// [CardSync] and [CardImport] know about neither: they are written against
/// [CardTarget], which is the same handful of calls either way.
library;

import 'package:flutter/services.dart';

const _channel = MethodChannel('com.bookie.studio/card');

/// A card we are allowed to write to. [handle] is opaque and durable — a SAF
/// tree URI on Android, a security-scoped bookmark key on iOS — so it is what
/// we persist to reconnect to the same card next launch.
class CardInfo {
  const CardInfo({
    required this.handle,
    required this.name,
    this.freeBytes,
    this.totalBytes,
    this.location,
    this.removable,
    this.atRoot,
  });

  final String handle;
  final String name;
  final int? freeBytes;
  final int? totalBytes;

  /// Where the folder the user chose actually sits, in whatever terms the
  /// platform can give: `1A2B-3C4D:/` or `primary:/Download` on Android, a
  /// path on iOS. Null when the provider will not say.
  final String? location;

  /// Whether that volume is removable — false means the phone's own storage,
  /// which writes perfectly and leaves the toy with an empty card. Null when
  /// unknown, and then the app says nothing.
  final bool? removable;

  /// Whether it is the root of the volume rather than a folder inside it. The
  /// firmware looks for `/audio` and `/tags.csv` at the very top of the card,
  /// so a subfolder is just as silently wrong.
  final bool? atRoot;

  /// True only when we know the choice cannot work: the right answer is the
  /// root of a removable volume.
  bool get looksWrong => removable == false || atRoot == false;

  Map<String, dynamic> toJson() => {
    'handle': handle,
    'name': name,
    'freeBytes': freeBytes,
    'totalBytes': totalBytes,
    'location': location,
    'removable': removable,
    'atRoot': atRoot,
  };

  static CardInfo fromMap(Map<Object?, Object?> map) => CardInfo(
    handle: map['handle'] as String,
    name: (map['name'] as String?) ?? 'Card',
    freeBytes: (map['freeBytes'] as num?)?.toInt(),
    totalBytes: (map['totalBytes'] as num?)?.toInt(),
    location: map['location'] as String?,
    removable: map['removable'] as bool?,
    atRoot: map['atRoot'] as bool?,
  );
}

class CardEntry {
  const CardEntry({
    required this.name,
    required this.isDirectory,
    required this.size,
  });
  final String name;
  final bool isDirectory;
  final int size;
}

/// Raised when the card is gone: unplugged mid-write, or the OS dropped the
/// permission we persisted. Always recoverable by picking the card again.
class CardUnavailable implements Exception {
  const CardUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Everything the rest of the app is allowed to do to a card.
abstract class CardTarget {
  CardInfo get info;

  /// The same card with fresh free-space numbers, or null if it went away.
  /// May return a new instance; use the one that comes back.
  Future<CardTarget?> refresh();

  Future<List<CardEntry>> list(String path);

  /// Small files only — `tags.csv` and `bookie.json`. Returns null if absent.
  Future<Uint8List?> readFile(String path);

  Future<void> writeBytes(String path, Uint8List bytes);

  /// Streamed, so a 4 MB clip never lands in the Dart heap.
  Future<void> copyFile(String path, String localPath);

  /// The other direction, for importing a card someone else wrote.
  Future<void> copyOut(String path, String localPath);

  Future<bool> delete(String path);

  /// Let go: the security-scoped resource on iOS, the WiFi network on a toy.
  Future<void> release();
}

/// A card in a reader plugged into the phone.
class ReaderCard implements CardTarget {
  ReaderCard(this.info);

  @override
  final CardInfo info;

  /// Ask the user to point at the card's root folder. Returns null if they
  /// backed out. Both platforms persist the grant, so this is a one-time cost
  /// per card.
  static Future<CardInfo?> pick() async {
    final result = await _invoke<Map<Object?, Object?>>('pick', const {});
    return result == null ? null : CardInfo.fromMap(result);
  }

  /// Reconnect to a card we were granted access to in an earlier session.
  /// Returns null when the grant is gone or the card is simply not plugged in.
  static Future<CardInfo?> restore(String handle) async {
    final result = await _invoke<Map<Object?, Object?>>('resolve', {
      'handle': handle,
    });
    return result == null ? null : CardInfo.fromMap(result);
  }

  @override
  Future<CardTarget?> refresh() async {
    final fresh = await restore(info.handle);
    return fresh == null ? null : ReaderCard(fresh);
  }

  @override
  Future<List<CardEntry>> list(String path) async {
    final raw = await _invoke<List<Object?>>('list', {
      'handle': info.handle,
      'path': path,
    });
    if (raw == null) return const [];
    return raw.map((e) {
      final map = (e as Map).cast<Object?, Object?>();
      return CardEntry(
        name: map['name'] as String,
        isDirectory: map['isDirectory'] as bool? ?? false,
        size: (map['size'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }

  @override
  Future<Uint8List?> readFile(String path) =>
      _invoke<Uint8List>('read', {'handle': info.handle, 'path': path});

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    await _invoke<int>('writeBytes', {
      'handle': info.handle,
      'path': path,
      'bytes': bytes,
    });
  }

  @override
  Future<void> copyFile(String path, String localPath) async {
    await _invoke<int>('copy', {
      'handle': info.handle,
      'path': path,
      'src': localPath,
    });
  }

  @override
  Future<void> copyOut(String path, String localPath) async {
    await _invoke<int>('copyOut', {
      'handle': info.handle,
      'path': path,
      'dest': localPath,
    });
  }

  @override
  Future<bool> delete(String path) async =>
      await _invoke<bool>('delete', {'handle': info.handle, 'path': path}) ??
      false;

  @override
  Future<void> release() async {
    await _invoke<void>('release', {'handle': info.handle});
  }

  static Future<T?> _invoke<T>(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      if (e.code == 'unavailable') {
        throw CardUnavailable(e.message ?? 'The card is not reachable.');
      }
      throw CardUnavailable(
        '${e.code}: ${e.message ?? 'card operation failed'}',
      );
    } on MissingPluginException {
      throw const CardUnavailable(
        'Card access is not available on this platform.',
      );
    }
  }
}

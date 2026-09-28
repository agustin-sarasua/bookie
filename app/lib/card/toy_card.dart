/// The card while it is still in the toy, over the toy's own WiFi.
///
/// Hold language and press volume up and the ESP32 raises an access point
/// called `Bookie-XXXX`, serving the SD card over HTTP at 192.168.4.1. The
/// calls are the same six the reader offers, so [CardSync] cannot tell the
/// difference — see `firmware/src/toylink.cpp` for the other end.
///
/// Joining is the platform-specific part. Android can be asked to connect to a
/// network by name, which is one tap; anywhere else the user joins from system
/// settings and we simply look for the toy at the other end.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'card_target.dart';

const _channel = MethodChannel('com.bookie.studio/toy');

/// Must match `LINK_AP_PREFIX` and `LINK_AP_PASSWORD` in
/// `firmware/src/config.h`. Change one without the other and the phone will
/// keep asking for a password the toy has stopped accepting.
const toyApPrefix = 'Bookie-';
const toyApPassword = 'bookie-card';

final _toy = Uri.parse('http://192.168.4.1');

/// How joining went, so the UI can tell "say no" apart from "your phone cannot
/// do this for you".
enum ToyJoin { joined, refused, manual }

class ToyCard implements CardTarget {
  ToyCard._(this.info, this._client);

  @override
  final CardInfo info;

  final HttpClient _client;

  /// Ask the platform to join the toy's network. [ToyJoin.manual] means the
  /// phone will not do it for us and the user has to pick the network by hand —
  /// [connect] still works after that.
  static Future<ToyJoin> join() async {
    try {
      final bound = await _channel.invokeMethod<bool>('join', {
        'prefix': toyApPrefix,
        'passphrase': toyApPassword,
        'timeoutMs': 30000,
      });
      return bound == null ? ToyJoin.refused : ToyJoin.joined;
    } on PlatformException catch (e) {
      if (e.code == 'unsupported') return ToyJoin.manual;
      throw CardUnavailable(e.message ?? 'Could not join the toy.');
    } on MissingPluginException {
      return ToyJoin.manual;
    }
  }

  /// Talk to whatever is at 192.168.4.1. Throws [CardUnavailable] when that is
  /// nothing, which is what "you are still on your home WiFi" looks like.
  static Future<ToyCard> connect() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      // A wedged transfer should surface as an error, not a spinner that never
      // ends, but the toy is a 240 MHz chip writing to SPI: be patient with it.
      ..idleTimeout = const Duration(seconds: 30);

    try {
      // The first /info is the slow one: the firmware walks the whole FAT to
      // work out free space, which on a 32 GB card takes a few seconds.
      final body = await _json(client, 'GET', '/info', timeout: const Duration(seconds: 45));
      return ToyCard._(_infoFrom(body as Map<String, dynamic>), client);
    } on CardUnavailable {
      client.close(force: true);
      rethrow;
    } catch (e) {
      client.close(force: true);
      throw CardUnavailable('Nothing answered at ${_toy.host}: $e');
    }
  }

  @override
  Future<CardTarget?> refresh() async {
    try {
      final body = await _json(_client, 'GET', '/info', timeout: const Duration(seconds: 45));
      final map = body as Map<String, dynamic>;
      return ToyCard._(_infoFrom(map), _client);
    } on CardUnavailable {
      return null;
    }
  }

  @override
  Future<List<CardEntry>> list(String path) async {
    final body = await _json(_client, 'GET', '/list', query: path);
    return (body as List<Object?>).map((e) {
      final map = (e as Map).cast<String, Object?>();
      return CardEntry(
        name: map['name'] as String,
        isDirectory: map['isDirectory'] as bool? ?? false,
        size: (map['size'] as num?)?.toInt() ?? 0,
      );
    }).toList();
  }

  @override
  Future<Uint8List?> readFile(String path) async {
    final response = await _send(_client, 'GET', '/read', query: path);
    if (response.statusCode == 404) {
      await response.drain<void>();
      return null;
    }
    _check(response, '/read', path);
    final bytes = await _collect(response);
    return bytes;
  }

  @override
  Future<void> writeBytes(String path, Uint8List bytes) =>
      _put(path, Stream.value(bytes), bytes.length);

  @override
  Future<void> copyFile(String path, String localPath) async {
    final file = File(localPath);
    final length = await file.length();
    await _put(path, file.openRead(), length);
  }

  @override
  Future<void> copyOut(String path, String localPath) async {
    final response = await _send(_client, 'GET', '/read', query: path);
    _check(response, '/read', path);
    final dest = File(localPath);
    await dest.parent.create(recursive: true);
    final sink = dest.openWrite();
    try {
      await response.pipe(sink);
    } finally {
      await sink.close();
    }
  }

  @override
  Future<bool> delete(String path) async {
    final body = await _json(_client, 'DELETE', '/delete', query: path);
    return (body as Map<String, Object?>)['deleted'] == true;
  }

  /// Tell the toy to drop its access point, then hand the phone back its own
  /// network. Both halves are best-effort: the toy gives up on its own after a
  /// few quiet minutes, and any button on it does the same.
  @override
  Future<void> release() async {
    try {
      await _send(_client, 'POST', '/done').then((r) => r.drain<void>());
    } catch (_) {
      // It may already be gone — that is the outcome we wanted anyway.
    }
    _client.close(force: true);
    try {
      await _channel.invokeMethod<void>('leave');
    } on MissingPluginException {
      // Nothing to unbind on this platform.
    }
  }

  // ------------------------------------------------------------- plumbing

  /// What /info says, in the shape the rest of the app reads. `removable` and
  /// `atRoot` are both true because a card inside the toy is neither of the
  /// mistakes those flags exist to catch.
  static CardInfo _infoFrom(Map<String, dynamic> map) => CardInfo(
    handle: 'toy',
    name: (map['name'] as String?) ?? 'Bookie',
    freeBytes: (map['freeBytes'] as num?)?.toInt(),
    totalBytes: (map['totalBytes'] as num?)?.toInt(),
    location: 'the toy, over WiFi',
    removable: true,
    atRoot: true,
  );

  Future<void> _put(String path, Stream<List<int>> body, int length) async {
    final request = await _open(_client, 'PUT', '/write', query: path);
    request.headers.contentType = ContentType.binary;
    request.contentLength = length;
    await request.addStream(body);
    final response = await request.close().timeout(
      // A 4 MB clip over an ESP32's SoftAP, onto SPI, is tens of seconds.
      Duration(seconds: 30 + length ~/ 20000),
      onTimeout: () => throw CardUnavailable('The toy stopped listening while writing $path.'),
    );
    _check(response, '/write', path);
    await response.drain<void>();
  }

  static Future<HttpClientRequest> _open(
    HttpClient client,
    String method,
    String endpoint, {
    String? query,
  }) async {
    final uri = query == null
        ? _toy.replace(path: endpoint)
        : _toy.replace(path: endpoint, queryParameters: {'path': query});
    try {
      return await client.openUrl(method, uri);
    } on SocketException catch (e) {
      throw CardUnavailable(
        'The toy is not answering — it may have dropped its WiFi. '
        'Hold language and press volume up again. (${e.osError?.message ?? e.message})',
      );
    }
  }

  static Future<HttpClientResponse> _send(
    HttpClient client,
    String method,
    String endpoint, {
    String? query,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final request = await _open(client, method, endpoint, query: query);
    return request.close().timeout(
      timeout,
      onTimeout: () => throw CardUnavailable('The toy took too long to answer $endpoint.'),
    );
  }

  static Future<Object?> _json(
    HttpClient client,
    String method,
    String endpoint, {
    String? query,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final response = await _send(client, method, endpoint, query: query, timeout: timeout);
    final body = utf8.decode(await _collect(response), allowMalformed: true);
    _check(response, endpoint, query, body: body);
    return jsonDecode(body);
  }

  static Future<Uint8List> _collect(HttpClientResponse response) async {
    final chunks = <int>[];
    await for (final chunk in response) {
      chunks.addAll(chunk);
    }
    return Uint8List.fromList(chunks);
  }

  /// The firmware answers every failure with `{"error": "..."}`, which is
  /// written to be read by a person, so pass it straight through.
  static void _check(
    HttpClientResponse response,
    String endpoint,
    String? path, {
    String? body,
  }) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    String detail = 'HTTP ${response.statusCode}';
    if (body != null) {
      try {
        final message = (jsonDecode(body) as Map)['error'];
        if (message is String) detail = message;
      } catch (_) {
        // Not JSON; the status code is all we have.
      }
    }
    throw CardUnavailable('The toy refused ${path ?? endpoint}: $detail');
  }
}

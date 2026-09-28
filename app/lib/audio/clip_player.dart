/// Previewing a clip, and finding out how long it is.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

class ClipPlayer extends ChangeNotifier {
  final _player = AudioPlayer();
  String? _path;

  String? get playingPath => _playing ? _path : null;
  bool _playing = false;

  ClipPlayer() {
    _player.playerStateStream.listen((state) {
      final playing =
          state.playing && state.processingState != ProcessingState.completed;
      if (playing != _playing) {
        _playing = playing;
        notifyListeners();
      }
      if (state.processingState == ProcessingState.completed) {
        _player.seek(Duration.zero);
        _player.pause();
      }
    });
  }

  Stream<Duration> get position => _player.positionStream;
  Duration? get duration => _player.duration;

  Future<void> toggle(File file) async {
    if (_path == file.path && _playing) {
      await _player.pause();
      return;
    }
    if (_path != file.path) {
      _path = file.path;
      await _player.setFilePath(file.path);
    }
    await _player.seek(Duration.zero);
    await _player.play();
  }

  Future<void> stop() async {
    await _player.stop();
    _path = null;
    _playing = false;
    notifyListeners();
  }

  /// How long a file is, without playing it. Null when the file will not open —
  /// which is itself worth knowing before it reaches the card.
  static Future<Duration?> probe(File file) async {
    final player = AudioPlayer();
    try {
      return await player.setFilePath(file.path);
    } on Object catch (e) {
      debugPrint('audio: cannot read ${file.path} ($e)');
      return null;
    } finally {
      await player.dispose();
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}

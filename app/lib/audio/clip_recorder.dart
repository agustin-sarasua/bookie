/// Recording a clip, in the format the toy wants, with no conversion step.
///
/// `sdcard/README.md` asks for "PCM, 8 or 16 bit. Mono, 22050 Hz keeps files
/// small and the decoder cool" — which is precisely what we ask the platform
/// recorder for, so nothing has to be transcoded afterwards. 22.05 kHz mono
/// 16-bit is 44 kB/s: a one-minute page is 2.6 MB.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'wav.dart';

const recordingSampleRate = 22050;

class ClipRecorder {
  final _recorder = AudioRecorder();
  String? _path;
  DateTime? _startedAt;
  Duration _before = Duration.zero;

  Stream<Amplitude> levels() =>
      _recorder.onAmplitudeChanged(const Duration(milliseconds: 120));

  Future<bool> hasPermission() => _recorder.hasPermission();

  Duration get elapsed => _startedAt == null
      ? _before
      : _before + DateTime.now().difference(_startedAt!);

  Future<void> start() async {
    final tmp = await getTemporaryDirectory();
    final path = p.join(
      tmp.path,
      'take-${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: recordingSampleRate,
        numChannels: 1,
        // A parent recording a bedtime story is not in a studio, and the toy
        // has one small speaker, so let the platform even things out.
        autoGain: true,
        noiseSuppress: true,
        echoCancel: false,
      ),
      path: path,
    );
    _path = path;
    _startedAt = DateTime.now();
    _before = Duration.zero;
  }

  Future<void> pause() async {
    if (!await _recorder.isRecording()) return;
    await _recorder.pause();
    if (_startedAt != null) _before += DateTime.now().difference(_startedAt!);
    _startedAt = null;
  }

  Future<void> resume() async {
    await _recorder.resume();
    _startedAt = DateTime.now();
  }

  /// Returns the finished file, padded and ready for the card, or null if the
  /// take produced nothing.
  Future<RecordedTake?> stop() async {
    final path = await _recorder.stop();
    _startedAt = null;
    _path = null;
    if (path == null) return null;

    final file = File(path);
    if (!await file.exists() || await file.length() <= 44) {
      await _quietDelete(file);
      return null;
    }

    await padWithSilence(file);
    final info = readWavHeader(await file.readAsBytes());
    return RecordedTake(file: file, duration: info?.duration ?? _before);
  }

  Future<void> cancel() async {
    final path = _path;
    _startedAt = null;
    _path = null;
    try {
      await _recorder.cancel();
    } on Object {
      // The recorder was not running; nothing to unwind.
    }
    if (path != null) await _quietDelete(File(path));
  }

  Future<void> dispose() => _recorder.dispose();

  Future<void> _quietDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A leftover in the temp directory is not worth failing a recording over.
    }
  }
}

class RecordedTake {
  const RecordedTake({required this.file, required this.duration});
  final File file;
  final Duration duration;
}

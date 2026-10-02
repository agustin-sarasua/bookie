/// Stitching generated speech into one clip the toy can play.
///
/// The TTS model answers in 24 kHz mono 16-bit PCM, one piece per request. We
/// join the pieces with a breath of silence between them, bring the result
/// down to the 22.05 kHz the firmware is tuned for, and write a plain PCM WAV
/// — `audioFormat` 1, 16-bit mono — which is exactly what `audio.cpp` wants.
library;

import 'dart:typed_data';

import 'wav.dart';

/// Mono 16-bit samples at a known rate.
class Pcm {
  Pcm(this.samples, this.sampleRate);

  final Int16List samples;
  final int sampleRate;

  Duration get duration => Duration(
    microseconds: sampleRate == 0
        ? 0
        : (samples.length * 1000000 / sampleRate).round(),
  );

  /// From a WAV file's bytes, or from raw little-endian L16 when [mimeType]
  /// says so (`audio/l16;rate=24000`, `audio/pcm`). Stereo is folded to mono.
  /// Returns null for anything else.
  static Pcm? decode(Uint8List bytes, {String? mimeType, int fallbackRate = 24000}) {
    final info = readWavHeader(bytes);
    if (info != null) {
      if (info.bitsPerSample != 16) return null;
      return _fromInterleaved(
        ByteData.sublistView(
          bytes,
          info.dataOffset,
          info.dataOffset + info.dataLength,
        ),
        info.channels,
        info.sampleRate,
      );
    }

    final mime = (mimeType ?? '').toLowerCase();
    if (mime.contains('l16') || mime.contains('pcm') || mime.isEmpty) {
      final rate =
          int.tryParse(RegExp(r'rate=(\d+)').firstMatch(mime)?.group(1) ?? '') ??
          fallbackRate;
      return _fromInterleaved(ByteData.sublistView(bytes), 1, rate);
    }
    return null;
  }

  static Pcm _fromInterleaved(ByteData data, int channels, int rate) {
    final frames = data.lengthInBytes ~/ (2 * channels);
    final out = Int16List(frames);
    for (var i = 0; i < frames; i++) {
      var sum = 0;
      for (var c = 0; c < channels; c++) {
        sum += data.getInt16((i * channels + c) * 2, Endian.little);
      }
      out[i] = sum ~/ channels;
    }
    return Pcm(out, rate);
  }

  /// Linear interpolation. Speech at 24 → 22.05 kHz loses nothing audible, and
  /// it spares the toy a sample rate it was not tuned for.
  Pcm resampled(int rate) {
    if (rate == sampleRate || samples.isEmpty) return this;
    final length = (samples.length * rate / sampleRate).floor();
    final out = Int16List(length);
    final step = sampleRate / rate;
    for (var i = 0; i < length; i++) {
      final pos = i * step;
      final j = pos.floor();
      final frac = pos - j;
      final a = samples[j];
      final b = j + 1 < samples.length ? samples[j + 1] : a;
      out[i] = (a + (b - a) * frac).round();
    }
    return Pcm(out, rate);
  }

  /// A canonical 44-byte-header PCM WAV.
  Uint8List toWav() {
    final dataBytes = samples.length * 2;
    final out = Uint8List(44 + dataBytes);
    final v = ByteData.sublistView(out);
    void tag(int at, String s) {
      for (var i = 0; i < 4; i++) {
        out[at + i] = s.codeUnitAt(i);
      }
    }

    tag(0, 'RIFF');
    v.setUint32(4, 36 + dataBytes, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    v.setUint32(16, 16, Endian.little);
    v.setUint16(20, 1, Endian.little); // PCM
    v.setUint16(22, 1, Endian.little); // mono
    v.setUint32(24, sampleRate, Endian.little);
    v.setUint32(28, sampleRate * 2, Endian.little);
    v.setUint16(32, 2, Endian.little);
    v.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    v.setUint32(40, dataBytes, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      v.setInt16(44 + i * 2, samples[i], Endian.little);
    }
    return out;
  }
}

/// Join [pieces] in order with [gap] of silence between them, and [tail] at
/// the end — the same quarter-second `prepare_audio.sh` pads with, so the I²S
/// buffers cannot swallow the last word. Every piece is brought to [rate].
Pcm joinPcm(
  List<Pcm> pieces, {
  int rate = 22050,
  Duration gap = const Duration(milliseconds: 350),
  Duration lead = const Duration(milliseconds: 150),
  Duration tail = const Duration(milliseconds: 400),
}) {
  int frames(Duration d) => (rate * d.inMicroseconds / 1000000).round();
  final resampled = [for (final p in pieces) p.resampled(rate)];
  final total =
      frames(lead) +
      resampled.fold<int>(0, (n, p) => n + p.samples.length) +
      frames(gap) * (resampled.isEmpty ? 0 : resampled.length - 1) +
      frames(tail);

  final out = Int16List(total);
  var at = frames(lead);
  for (var i = 0; i < resampled.length; i++) {
    if (i > 0) at += frames(gap);
    out.setRange(at, at + resampled[i].samples.length, resampled[i].samples);
    at += resampled[i].samples.length;
  }
  return Pcm(out, rate);
}

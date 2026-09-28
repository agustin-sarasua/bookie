/// Just enough WAV to do what `tools/prepare_audio.sh` does for us on a phone.
///
/// The shell tool ends every clip with `apad=pad_dur=0.25` because the I²S DMA
/// ring in `audio.cpp` holds about 70 ms of slack and the amplifier lingers for
/// another 1.5 s — without a little silence at the end the last syllable can be
/// cut. We record straight to PCM, so adding that pad is arithmetic, not a
/// transcode, and there is no ffmpeg on iOS to do it any other way.
library;

import 'dart:io';
import 'dart:typed_data';

class WavInfo {
  const WavInfo({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.dataOffset,
    required this.dataLength,
  });

  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final int dataOffset;
  final int dataLength;

  Duration get duration {
    final bytesPerFrame = channels * (bitsPerSample ~/ 8);
    if (bytesPerFrame == 0 || sampleRate == 0) return Duration.zero;
    final frames = dataLength ~/ bytesPerFrame;
    return Duration(microseconds: (frames * 1000000 / sampleRate).round());
  }
}

/// Returns null when the bytes are not a PCM WAV we understand — an mp3, or a
/// float or compressed WAV. The caller then simply leaves the file alone.
WavInfo? readWavHeader(Uint8List bytes) {
  if (bytes.length < 44) return null;
  final view = ByteData.sublistView(bytes);
  if (_tag(bytes, 0) != 'RIFF' || _tag(bytes, 8) != 'WAVE') return null;

  int? sampleRate, channels, bitsPerSample, format;
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = _tag(bytes, offset);
    final size = view.getUint32(offset + 4, Endian.little);
    final body = offset + 8;

    if (id == 'fmt ' && body + 16 <= bytes.length) {
      format = view.getUint16(body, Endian.little);
      channels = view.getUint16(body + 2, Endian.little);
      sampleRate = view.getUint32(body + 4, Endian.little);
      bitsPerSample = view.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      if (format != 1 ||
          channels == null ||
          sampleRate == null ||
          bitsPerSample == null) {
        return null; // not plain PCM, or the header came in an order we cannot read
      }
      // Some writers leave the data size at 0 or lie about it while streaming.
      final actual = bytes.length - body;
      return WavInfo(
        sampleRate: sampleRate,
        channels: channels,
        bitsPerSample: bitsPerSample,
        dataOffset: body,
        dataLength: size == 0 || size > actual ? actual : size,
      );
    }
    offset = body + size + (size.isOdd ? 1 : 0); // chunks are word-aligned
  }
  return null;
}

/// Append [pad] of silence and rewrite the two size fields. A no-op, silently,
/// for anything that is not a PCM WAV.
Future<void> padWithSilence(
  File file, {
  Duration pad = const Duration(milliseconds: 250),
}) async {
  final bytes = await file.readAsBytes();
  final info = readWavHeader(bytes);
  if (info == null || pad <= Duration.zero) return;

  final bytesPerFrame = info.channels * (info.bitsPerSample ~/ 8);
  if (bytesPerFrame == 0) return;
  final frames = (info.sampleRate * pad.inMicroseconds / 1000000).round();
  final silence = Uint8List(frames * bytesPerFrame);
  // 16-bit PCM is signed, so silence is zero; 8-bit is unsigned, so it is 128.
  if (info.bitsPerSample == 8) silence.fillRange(0, silence.length, 128);

  final head = bytes.sublist(0, info.dataOffset + info.dataLength);
  final out = Uint8List(head.length + silence.length)
    ..setRange(0, head.length, head)
    ..setRange(head.length, head.length + silence.length, silence);

  final view = ByteData.sublistView(out);
  view.setUint32(4, out.length - 8, Endian.little); // RIFF chunk size
  view.setUint32(
    info.dataOffset - 4,
    info.dataLength + silence.length,
    Endian.little,
  );

  await file.writeAsBytes(out, flush: true);
}

String _tag(Uint8List bytes, int offset) =>
    String.fromCharCodes(bytes.sublist(offset, offset + 4));

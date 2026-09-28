/// The rules here are not ours — they are what `library.cpp` and `config.h` do.
/// If one of these ever fails, the app is writing a card the toy will misread.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:bookie_studio/audio/wav.dart';
import 'package:bookie_studio/card/toy_card.dart';
import 'package:bookie_studio/model/project.dart';
import 'package:bookie_studio/model/tags_csv.dart';
import 'package:bookie_studio/model/uid.dart';
import 'package:flutter_test/flutter_test.dart';

/// config.h itself, so the constants below are read rather than remembered.
String _firmwareConfig() {
  for (final path in ['../firmware/src/config.h', 'firmware/src/config.h']) {
    final file = File(path);
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('config.h not found — run this from the app package or the repo root');
}

void main() {
  group('link mode agrees with config.h', () {
    final config = _firmwareConfig();

    String literal(String name) {
      final match = RegExp('$name\\[\\]\\s*=\\s*"([^"]*)"').firstMatch(config);
      expect(match, isNotNull, reason: '$name is not in config.h any more');
      return match!.group(1)!;
    }

    // The phone joins a network it cannot see the name of until it is there,
    // using a password nobody types. Both sides have to agree in advance.
    test('the network name and password are the same on both sides', () {
      expect(toyApPrefix, literal('LINK_AP_PREFIX'));
      expect(toyApPassword, literal('LINK_AP_PASSWORD'));
    });

    test('the password is long enough for WPA2', () {
      expect(toyApPassword.length, greaterThanOrEqualTo(8));
    });

    test('a clip path fits in what toylink.cpp will accept', () {
      final match = RegExp(r'LINK_PATH_MAX\s*=\s*(\d+)').firstMatch(config);
      expect(match, isNotNull);
      // Every path the app writes goes through /write?path=…, and the firmware
      // refuses anything longer than this.
      expect(int.parse(match!.group(1)!), greaterThan(96));
    });
  });

  group('UID normalisation matches library.cpp', () {
    test('keeps hex digits and upper-cases them', () {
      expect(normaliseUid('04:a2:24:aa:5c:61:80'), '04A224AA5C6180');
      expect(normaliseUid('04 A2 24 AA'), '04A224AA');
      expect(
        normaliseUid('0x04a224aa'),
        '004A224AA',
      ); // the x goes, the 0 stays
    });

    test('drops everything that is not a hex digit', () {
      expect(normaliseUid('hello'), 'E');
      expect(normaliseUid('----'), '');
    });

    test('round-trips through bytes', () {
      expect(
        uidFromBytes(Uint8List.fromList([0x04, 0xA2, 0x24, 0xAA])),
        '04A224AA',
      );
      expect(uidFromBytes(Uint8List.fromList([0x00, 0x0F])), '000F');
    });

    test('pretty form is only for the eye', () {
      expect(prettyUid('04A224AA5C6180'), '04:A2:24:AA:5C:61:80');
    });
  });

  group('tags.csv', () {
    test('parses the way reloadTags() does', () {
      final tags = parseTagsCsv('''
# a comment
   # an indented comment

04A224AA5C6180,bear
04b1339b5c6181,  fox
,noUid
04FF,
notacsvline
''');
      expect(tags.length, 2);
      expect(tags[0].uid, '04A224AA5C6180');
      expect(tags[0].name, 'bear');
      // Lower-case UIDs are normalised, and the name is trimmed.
      expect(tags[1].uid, '04B1339B5C6181');
      expect(tags[1].name, 'fox');
    });

    test('takes everything after the first comma as the name', () {
      // This is exactly why we never write trailing comments.
      final tags = parseTagsCsv('04AA,bear, the brown one');
      expect(tags.single.name, 'bear, the brown one');
    });

    test('what we render is what the firmware reads back', () {
      final project = Project(languages: ['en', 'es']);
      final bear = BookieTag(
        uid: '04A224AA5C6180',
        name: 'bear',
        label: 'Page 4 — the bear',
      );
      bear.clips['en'] = const Clip(
        fileName: 'bear.mp3',
        bytes: 1000,
        source: ClipSource.imported,
      );
      project.tags.add(bear);
      project.tags.add(BookieTag(uid: '04B1339B5C6181', name: 'fox'));

      final parsed = parseTagsCsv(renderTagsCsv(project));
      expect(parsed.length, 2);
      expect(parsed.map((t) => t.name), containsAll(['bear', 'fox']));
      // The label must not leak into the name the toy looks for.
      expect(parsed.firstWhere((t) => t.uid == '04A224AA5C6180').name, 'bear');
    });
  });

  group('file names', () {
    test('follow the prepare_audio.sh convention', () {
      expect(sanitiseStem('The Brown Bear'), 'the-brown-bear');
      expect(sanitiseStem('  Página 3!  '), 'pagina-3');
      expect(sanitiseStem('La Forêt'), 'la-foret');
      expect(sanitiseStem('Mañana'), 'manana');
      expect(sanitiseStem('a---b'), 'a-b');
      expect(sanitiseStem('***'), '');
    });

    test('stay inside AUDIO_PATH_MAX', () {
      // config.h: AUDIO_PATH_MAX is 96 bytes for "/audio/<lang>/<stem>.mp3".
      final limit = maxStemLength(['en', 'es']);
      final path = '/audio/es/${'x' * limit}.mp3';
      expect(path.length, lessThan(96));

      // The worst case the app allows: the longest language code a user can
      // create next to the longest stem we will hand out.
      final worstLang = 'x' * sanitiseLanguage('x' * 40).length;
      final worstStem = 'x' * maxStemLength([worstLang]);
      expect('/audio/$worstLang/$worstStem.mp3'.length, lessThan(96));
    });

    test('never collide, because a collision silently shares a clip', () {
      final project = Project();
      project.tags.add(BookieTag(uid: 'AA', name: 'bear'));
      project.tags.add(BookieTag(uid: 'BB', name: 'bear-2'));

      expect(uniqueStem('Bear', project), 'bear-3');
      // Renaming a tag may keep its own name.
      expect(uniqueStem('bear', project, exceptUid: 'AA'), 'bear');
    });

    test('an unnamed tag keeps the UID spelling the firmware falls back to', () {
      // library.cpp: trackFor() ends with resolveStem(base + key), where key is
      // the normalised — upper case — UID. A lower-cased stem would only work
      // by the grace of FAT being case-insensitive.
      const uid = '04A224AA5C6180';
      expect(sanitiseStem(uid), isNot(uid), reason: 'sanitiseStem lower-cases');
      // So addTag must not route an unnamed tag through it; see Workspace.addTag.
      expect(normaliseUid(uid), uid);
    });

    test('language codes are folder names too', () {
      expect(sanitiseLanguage('EN'), 'en');
      expect(sanitiseLanguage('pt BR'), 'pt-br');
    });
  });

  group('WAV padding', () {
    Uint8List wav({
      int sampleRate = 22050,
      int channels = 1,
      int bits = 16,
      int frames = 100,
    }) {
      final dataBytes = frames * channels * (bits ~/ 8);
      final out = Uint8List(44 + dataBytes);
      final view = ByteData.sublistView(out);
      out.setRange(0, 4, 'RIFF'.codeUnits);
      view.setUint32(4, out.length - 8, Endian.little);
      out.setRange(8, 12, 'WAVE'.codeUnits);
      out.setRange(12, 16, 'fmt '.codeUnits);
      view.setUint32(16, 16, Endian.little);
      view.setUint16(20, 1, Endian.little); // PCM
      view.setUint16(22, channels, Endian.little);
      view.setUint32(24, sampleRate, Endian.little);
      view.setUint32(28, sampleRate * channels * (bits ~/ 8), Endian.little);
      view.setUint16(32, channels * (bits ~/ 8), Endian.little);
      view.setUint16(34, bits, Endian.little);
      out.setRange(36, 40, 'data'.codeUnits);
      view.setUint32(40, dataBytes, Endian.little);
      return out;
    }

    test('reads the header the firmware cares about', () {
      final info = readWavHeader(wav(frames: 22050))!;
      expect(info.sampleRate, 22050);
      expect(info.channels, 1);
      expect(info.bitsPerSample, 16);
      expect(info.duration.inMilliseconds, 1000);
    });

    test('refuses anything that is not PCM', () {
      final bytes = wav();
      ByteData.sublistView(bytes).setUint16(20, 3, Endian.little); // IEEE float
      expect(readWavHeader(bytes), isNull);
      expect(
        readWavHeader(Uint8List.fromList('not a wav at all'.codeUnits)),
        isNull,
      );
    });
  });
}

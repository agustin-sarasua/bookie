// The story assistant, end to end against a fake Gemini: what we send, how we
// read what comes back, and that the clip at the end is one the toy can play.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bookie_studio/ai/gemini_client.dart';
import 'package:bookie_studio/ai/story.dart';
import 'package:bookie_studio/ai/story_engine.dart';
import 'package:bookie_studio/audio/pcm.dart';
import 'package:bookie_studio/audio/wav.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A second of 24 kHz tone, as the TTS model would answer.
Uint8List _toneWav({int ms = 1000, int rate = 24000}) {
  final n = rate * ms ~/ 1000;
  final samples = Int16List(n);
  for (var i = 0; i < n; i++) {
    samples[i] = ((i % 48) < 24 ? 8000 : -8000);
  }
  return Pcm(samples, rate).toWav();
}

Map<String, dynamic> _textResponse(Map<String, dynamic> json) => {
  'candidates': [
    {
      'content': {
        'parts': [
          {'text': 'ignored thought', 'thought': true},
          {'text': jsonEncode(json)},
        ],
      },
      'finishReason': 'STOP',
    },
  ],
};

Map<String, dynamic> _audioResponse() => {
  'id': 'int_1',
  'status': 'completed',
  'steps': [
    {
      'type': 'model_output',
      'content': [
        {
          'type': 'audio',
          'mime_type': 'audio/wav',
          'data': base64Encode(_toneWav()),
          'channels': 1,
          'sample_rate': 24000,
        },
      ],
    },
  ],
};

final _written = {
  'title': 'El oso dormilón',
  'summary': 'A sleepy bear is woken by a curious fox.',
  'narrator': {'voice': 'Sulafat', 'style': 'Warm and cosy.'},
  'characters': [
    {
      'id': 'Bear',
      'name': 'Oso',
      'description': 'A big brown bear',
      'gender': 'male',
      'voice': 'Algenib',
      'style': 'Slow and rumbling.',
    },
    {
      'id': 'fox',
      'name': 'Zorro',
      'description': 'A small red fox',
      'gender': 'female',
      // The narrator already has this voice — the engine must recast.
      'voice': 'Sulafat',
      'style': 'Quick and curious.',
    },
    {
      'id': 'owl',
      'name': 'Búho',
      'description': 'An owl in the tree',
      'gender': 'neutral',
      'voice': 'NotAVoice',
      'style': 'Wise.',
    },
  ],
  'lines': [
    {'speaker': 'narrator', 'text': 'Había una vez un oso.'},
    {'speaker': 'Bear', 'text': '<sigh> Tengo sueño.', 'delivery': 'yawning'},
    {'speaker': 'fox', 'text': '¡Despierta, oso!'},
    {'speaker': 'Oso', 'text': 'Cinco minutos más.'},
    {'speaker': 'owl', 'text': 'Silencio, por favor.'},
    {'speaker': 'narrator', 'text': 'Y todos se durmieron.'},
    {'speaker': 'narrator', 'text': '   '},
  ],
};

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  group('Pcm', () {
    test('24 kHz in, 22.05 kHz 16-bit mono WAV out, padded at the ends', () {
      final a = Pcm.decode(_toneWav())!;
      final b = Pcm.decode(_toneWav(ms: 500))!;
      expect(a.sampleRate, 24000);
      expect(a.samples.length, 24000);

      final joined = joinPcm([a, b]);
      final wav = joined.toWav();
      final info = readWavHeader(wav)!;
      expect(info.sampleRate, 22050);
      expect(info.channels, 1);
      expect(info.bitsPerSample, 16);
      // 1.5 s of speech, 0.35 s gap, 0.15 s lead, 0.4 s tail.
      expect(info.duration.inMilliseconds, closeTo(2400, 5));
    });

    test('raw L16 is read at the rate the mime type gives', () {
      final raw = Uint8List(4800 * 2);
      final pcm = Pcm.decode(raw, mimeType: 'audio/L16;codec=pcm;rate=48000')!;
      expect(pcm.sampleRate, 48000);
      expect(pcm.duration.inMilliseconds, 100);
    });

    test('stereo folds to mono', () {
      final wav = Pcm(Int16List.fromList([100, 300, 100, 300]), 22050).toWav();
      // Rewrite as 2 channels, 2 frames.
      final view = ByteData.sublistView(wav);
      view.setUint16(22, 2, Endian.little);
      final pcm = Pcm.decode(wav)!;
      expect(pcm.samples, [200, 200]);
    });
  });

  group('chunking', () {
    ScriptLine l(String s, [int len = 10]) => ScriptLine(speaker: s, text: 'x' * len);

    test('never more than two speakers in one request', () {
      final chunks = StoryEngine.chunk([
        l('narrator'),
        l('bear'),
        l('narrator'),
        l('fox'),
        l('bear'),
        l('narrator'),
      ]);
      for (final c in chunks) {
        expect({for (final line in c) line.speaker}.length, lessThanOrEqualTo(2));
      }
      expect(chunks.expand((c) => c).length, 6);
      expect(chunks.first.length, 3); // narrator, bear, narrator
    });

    test('long runs are split by length and empty lines dropped', () {
      final chunks = StoryEngine.chunk([
        for (var i = 0; i < 5; i++) l('narrator', 600),
        ScriptLine(speaker: 'narrator', text: '  '),
      ]);
      expect(chunks.length, 3);
      expect(chunks.expand((c) => c).length, 5);
    });
  });

  group('engine against a fake Gemini', () {
    late Directory tmp;
    late File page;
    final requests = <http.Request>[];

    setUp(() async {
      requests.clear();
      tmp = await Directory.systemTemp.createTemp('story-test');
      page = File('${tmp.path}/page.jpg')..writeAsBytesSync([0xff, 0xd8, 0xff, 0xd9]);
    });
    tearDown(() => tmp.delete(recursive: true));

    StoryEngine engine(Future<http.Response> Function(http.Request) handler) => StoryEngine(
      client: GeminiClient(
        apiKey: 'test-key',
        client: MockClient((r) {
          requests.add(r);
          return handler(r);
        }),
      ),
      storyModel: 'gemini-3.8-flash',
      speechModel: 'gemini-3.8-flash-tts',
    );

    Future<http.Response> gemini(http.Request r) async {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.url.path.endsWith(':generateContent')) {
        final prompt = jsonEncode(body['contents']);
        if (prompt.contains('Retell this story script')) {
          return _json(
              _textResponse({
                'title': 'The Sleepy Bear',
                'lines': [
                  {'speaker': 'narrator', 'text': 'Once there was a bear.'},
                  {'speaker': 'bear', 'text': 'I am sleepy.'},
                  {'speaker': 'stranger', 'text': 'Who am I?'},
                ],
              }),
          );
        }
        return _json(_textResponse(_written));
      }
      if (r.url.path.endsWith('/interactions')) {
        return _json(_audioResponse());
      }
      return http.Response('{}', 404);
    }

    test('writes, casts distinct voices, translates and narrates', () async {
      final e = engine(gemini);
      final story = Story(instructions: 'Make it funny.', mode: StoryMode.retold);
      await e.write(story, [page], 'es');

      // The request carried the photo, the key, the schema and the user's words.
      final write = requests.single;
      expect(write.headers['x-goog-api-key'], 'test-key');
      final body = jsonDecode(write.body) as Map<String, dynamic>;
      final parts = (body['contents'] as List).first['parts'] as List;
      expect(parts.first['inline_data']['mime_type'], 'image/jpeg');
      expect(body['generationConfig']['responseMimeType'], 'application/json');
      expect(jsonEncode(body['systemInstruction']), contains('Make it funny.'));

      // Cast: narrator first, ids tidied, every voice different and real.
      expect(story.cast.map((m) => m.id), ['narrator', 'bear', 'fox', 'owl']);
      final voices = story.cast.map((m) => m.voice).toList();
      expect(voices.toSet().length, voices.length);
      expect(story.member('fox')!.voice, isNot('Sulafat'));
      expect(story.member('owl')!.voice, isNot('NotAVoice'));

      // Lines: speakers resolved by id or name, blanks dropped.
      final es = story.scripts['es']!;
      expect(es.title, 'El oso dormilón');
      expect(es.lines.map((l) => l.speaker), ['narrator', 'bear', 'fox', 'bear', 'owl', 'narrator']);
      expect(es.lines[1].delivery, 'yawning');

      // A second language keeps the cast; an unknown speaker falls to the narrator.
      await e.translate(story, 'en');
      expect(story.scripts['en']!.lines.map((l) => l.speaker), ['narrator', 'bear', 'narrator']);
      expect(story.cast.length, 4);

      // Narration: one request per ≤2-speaker run, stitched in order.
      requests.clear();
      final progress = <int>[];
      final pcm = await e.narrate(story, 'es', onProgress: (d, _) => progress.add(d));
      final chunks = StoryEngine.chunk(es.lines);
      expect(requests.length, chunks.length);
      expect(progress.last, chunks.length);
      expect(pcm.sampleRate, 22050);
      expect(pcm.duration.inMilliseconds, greaterThan(chunks.length * 1000 - 50));

      for (final r in requests) {
        final b = jsonDecode(r.body) as Map<String, dynamic>;
        expect(b['model'], 'gemini-3.8-flash-tts');
        expect(b['response_format'], {'type': 'audio'});
        final config = b['generation_config']['speech_config'];
        final blocks = (b['input'] as List).first['content'] as List;
        if (config is Map) {
          expect(config['mode'], 'conversational');
          final speakers = [for (final s in config['speakers'] as List) s['speaker']];
          expect(speakers.length, 2);
          for (final block in blocks) {
            expect(speakers, contains(block['annotations'][0]['speaker']));
          }
        } else {
          expect((config as List).single['voice'], isA<String>());
        }
        for (final block in blocks) {
          expect(block['annotations'][0]['type'], 'speech_metadata');
          expect(block['text'], isNot(contains('Now:')));
        }
      }
    });

    test('a refused key is explained, not retried', () async {
      final e = engine(
        (_) async => http.Response(
          jsonEncode({
            'error': {'code': 400, 'message': 'API key not valid. Please pass a valid API key.'},
          }),
          400,
        ),
      );
      await expectLater(
        e.write(Story(), [page], 'en'),
        throwsA(isA<AiException>().having((x) => x.message, 'message', contains('API key'))),
      );
      expect(requests.length, 1);
    });

    test('rate limits are retried', () async {
      var calls = 0;
      final e = engine((r) async {
        calls++;
        if (calls == 1) return http.Response('{"error":{"message":"quota"}}', 429);
        return gemini(r);
      });
      await e.write(Story(), [page], 'en');
      expect(calls, 2);
    });
  });

  test('story json round-trips', () {
    final story = Story(
      pages: ['a.jpg'],
      instructions: 'x',
      mode: StoryMode.invented,
      length: StoryLength.long,
      cast: [
        CastMember(id: 'narrator', name: 'N', description: '', voice: 'Kore', style: 's', isNarrator: true),
      ],
      scripts: {
        'en': StoryScript(
          title: 't',
          lines: [ScriptLine(speaker: 'narrator', text: 'hi')],
          narration: Narration(castSignature: 'c', scriptSignature: 's', durationMs: 5, createdAt: DateTime(2026)),
        ),
      },
    );
    final back = Story.fromJson(jsonDecode(jsonEncode(story.toJson())) as Map<String, dynamic>);
    expect(back.toJson(), story.toJson());
    expect(back.narrator.isNarrator, isTrue);
  });
}

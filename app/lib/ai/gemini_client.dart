/// The two Gemini calls the story assistant makes, straight from the phone.
///
/// * `generateContent` on the Flash model: pictures in, a JSON story out,
///   constrained by a response schema so it parses the same way every time.
/// * `interactions` on the Flash TTS model: script in, WAV out. One request
///   speaks for one voice, or holds a conversation between two — the model's
///   limit — so the engine above cuts a story into pieces that fit.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../audio/pcm.dart';

const _base = 'https://generativelanguage.googleapis.com/v1beta';

class AiException implements Exception {
  AiException(this.message, {this.retryable = false});
  final String message;
  final bool retryable;
  @override
  String toString() => message;
}

class InlineImage {
  const InlineImage(this.bytes, this.mimeType);
  final Uint8List bytes;
  final String mimeType;
}

/// One block of a TTS request: words, who says them, and how.
class SpeechBlock {
  const SpeechBlock({required this.text, required this.speaker, this.style = ''});
  final String text;
  final String speaker;
  final String style;
}

class GeminiClient {
  GeminiClient({required this.apiKey, http.Client? client})
    : _http = client ?? http.Client();

  final String apiKey;
  final http.Client _http;

  /// Whether the key works and can see [model] — a free metadata call, made
  /// from the settings sheet so a typo shows up there and not mid-story.
  Future<void> check(String model) async {
    try {
      final response = await _http
          .get(
            Uri.parse('$_base/models/$model'),
            headers: {'x-goog-api-key': apiKey},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw _explain(response);
    } on TimeoutException {
      throw AiException('Gemini did not answer. Check the connection.');
    } on SocketException {
      throw AiException('No internet connection.');
    }
  }

  // ------------------------------------------------------------ text

  /// Ask [model] for JSON matching [schema]. [system] is the system
  /// instruction; [prompt] and [images] make up the single user turn.
  Future<Map<String, dynamic>> generateJson({
    required String model,
    required String system,
    required String prompt,
    required Map<String, dynamic> schema,
    List<InlineImage> images = const [],
    double temperature = 0.9,
  }) async {
    final body = {
      'systemInstruction': {
        'parts': [
          {'text': system},
        ],
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            for (final image in images)
              {
                'inline_data': {
                  'mime_type': image.mimeType,
                  'data': base64Encode(image.bytes),
                },
              },
            {'text': prompt},
          ],
        },
      ],
      'generationConfig': {
        'temperature': temperature,
        'responseMimeType': 'application/json',
        'responseSchema': schema,
      },
    };

    final json = await _post(
      '$_base/models/$model:generateContent',
      body,
      timeout: const Duration(minutes: 3),
    );

    final candidates = (json['candidates'] as List?) ?? const [];
    if (candidates.isEmpty) {
      final reason = (json['promptFeedback'] as Map?)?['blockReason'];
      throw AiException(
        reason == null
            ? 'The story model returned nothing. Try again.'
            : 'The story model declined these pictures ($reason). Try other pages.',
      );
    }
    final first = (candidates.first as Map).cast<String, dynamic>();
    final parts = ((first['content'] as Map?)?['parts'] as List?) ?? const [];
    final text = parts
        .whereType<Map>()
        .where((p) => p['thought'] != true)
        .map((p) => p['text'] as String? ?? '')
        .join();
    if (text.trim().isEmpty) {
      throw AiException(
        'The story model stopped early (${first['finishReason'] ?? 'no reason given'}). '
        'Try again.',
        retryable: true,
      );
    }
    try {
      return (jsonDecode(_stripFences(text)) as Map).cast<String, dynamic>();
    } on FormatException {
      throw AiException(
        'The story came back garbled. Try again.',
        retryable: true,
      );
    }
  }

  // ------------------------------------------------------------ speech

  /// Speak [blocks]. With one voice in [voices] it is a single-speaker read;
  /// with two, a conversation where each block's [SpeechBlock.speaker] picks
  /// the voice. More than two is the caller's mistake.
  Future<Pcm> speak({
    required String model,
    required List<SpeechBlock> blocks,
    required Map<String, String> voices,
  }) async {
    assert(voices.isNotEmpty && voices.length <= 2);
    final multi = voices.length > 1;

    final body = {
      'model': model,
      'input': [
        {
          'type': 'user_input',
          'content': [
            for (final block in blocks)
              {
                'type': 'text',
                'text': block.text,
                'annotations': [
                  {
                    'type': 'speech_metadata',
                    if (multi) 'speaker': block.speaker,
                    if (block.style.isNotEmpty) 'style': block.style,
                  },
                ],
              },
          ],
        },
      ],
      'response_format': {'type': 'audio'},
      'generation_config': {
        'speech_config': multi
            ? {
                'mode': 'conversational',
                'speakers': [
                  for (final e in voices.entries)
                    {'speaker': e.key, 'voice': e.value},
                ],
              }
            : [
                {'voice': voices.values.single},
              ],
      },
    };

    final json = await _post(
      '$_base/interactions',
      body,
      timeout: const Duration(minutes: 4),
    );

    final status = json['status'];
    if (status == 'failed' || status == 'cancelled') {
      throw AiException(
        'The voice model could not read this part ($status). Try again.',
        retryable: true,
      );
    }

    final audio = _findAudio(json);
    if (audio == null) {
      throw AiException(
        'The voice model answered without audio. Try again.',
        retryable: true,
      );
    }
    final pcm = Pcm.decode(base64Decode(audio.data), mimeType: audio.mimeType);
    if (pcm == null || pcm.samples.isEmpty) {
      throw AiException(
        'The voice model sent audio in a format we cannot read (${audio.mimeType}).',
      );
    }
    return pcm;
  }

  /// Wherever the audio block landed — `steps[].content[]`, `outputs[]`, or a
  /// `generateContent`-style `inlineData` — it is the first map carrying
  /// base64 `data` with an audio type.
  static ({String data, String mimeType})? _findAudio(Object? node) {
    if (node is Map) {
      final data = node['data'];
      final mime = (node['mime_type'] ?? node['mimeType'] ?? '') as Object;
      if (data is String &&
          data.length > 64 &&
          (node['type'] == 'audio' || '$mime'.startsWith('audio/'))) {
        return (data: data, mimeType: '$mime');
      }
      for (final value in node.values) {
        final found = _findAudio(value);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final value in node) {
        final found = _findAudio(value);
        if (found != null) return found;
      }
    }
    return null;
  }

  // ------------------------------------------------------------ transport

  /// POST with retries on the errors worth retrying: rate limits, overload,
  /// and the network dropping out for a moment.
  Future<Map<String, dynamic>> _post(
    String url,
    Map<String, dynamic> body, {
    required Duration timeout,
    int attempts = 3,
  }) async {
    final encoded = jsonEncode(body);
    AiException? last;
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(
          Duration(milliseconds: 1500 * pow(2, attempt - 1).toInt()),
        );
      }
      try {
        final response = await _http
            .post(
              Uri.parse(url),
              headers: {
                'x-goog-api-key': apiKey,
                'Content-Type': 'application/json',
              },
              body: encoded,
            )
            .timeout(timeout);
        if (response.statusCode == 200) {
          try {
            return (jsonDecode(utf8.decode(response.bodyBytes)) as Map)
                .cast<String, dynamic>();
          } on FormatException {
            throw AiException('Gemini sent an answer we could not read. Try again.');
          }
        }
        last = _explain(response);
        if (!last.retryable) throw last;
      } on TimeoutException {
        last = AiException(
          'Gemini took too long to answer. Check the connection and try again.',
          retryable: true,
        );
      } on SocketException {
        last = AiException(
          'No internet connection. If the phone is on the toy\'s WiFi, '
          'switch back to your own network to create stories.',
          retryable: true,
        );
      } on http.ClientException {
        last = AiException(
          'The connection to Gemini dropped. Try again.',
          retryable: true,
        );
      }
    }
    throw last!;
  }

  static AiException _explain(http.Response response) {
    String detail = '';
    try {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is Map) {
        final error = json['error'];
        detail = (error is Map ? error['message'] : json['message'])?.toString() ?? '';
      }
    } on Object {
      // Not JSON; the status code will have to do.
    }
    final lower = detail.toLowerCase();

    if (response.statusCode == 400 && lower.contains('api key')) {
      return AiException('Gemini did not accept the API key. Check it in AI settings.');
    }
    switch (response.statusCode) {
      case 401:
      case 403:
        return AiException(
          'Gemini refused the API key${detail.isEmpty ? '' : ': $detail'}. '
          'Check it in AI settings.',
        );
      case 404:
        return AiException(
          'Gemini does not know that model${detail.isEmpty ? '' : ' ($detail)'}. '
          'Check the model names in AI settings.',
        );
      case 429:
        return AiException(
          'Gemini is rate-limiting this key. Wait a minute and try again.',
          retryable: true,
        );
      case 500:
      case 502:
      case 503:
      case 504:
        return AiException(
          'Gemini is busy right now. Try again in a moment.',
          retryable: true,
        );
    }
    return AiException(
      detail.isEmpty
          ? 'Gemini answered with an error (${response.statusCode}).'
          : detail,
    );
  }

  static String _stripFences(String text) {
    final t = text.trim();
    if (!t.startsWith('```')) return t;
    return t
        .replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '')
        .replaceFirst(RegExp(r'```\s*$'), '');
  }

  void close() => _http.close();
}

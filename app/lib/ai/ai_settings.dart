/// The Gemini API key and model names.
///
/// There is no backend: the phone talks to the Gemini API directly, so the key
/// lives on the phone, in the app's private support directory — outside the
/// workspace, so it can never be written to the card.
///
/// A key can also be baked into a development build with
/// `--dart-define=GEMINI_API_KEY=...`; one saved in the app wins over it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const defaultStoryModel = 'gemini-3.8-flash';
const defaultSpeechModel = 'gemini-3.8-flash-tts';
const _bakedKey = String.fromEnvironment('GEMINI_API_KEY');

class AiSettings extends ChangeNotifier {
  AiSettings._(this._file);

  final File _file;

  String _apiKey = '';
  String _storyModel = defaultStoryModel;
  String _speechModel = defaultSpeechModel;

  String get apiKey => _apiKey.isNotEmpty ? _apiKey : _bakedKey;
  bool get hasKey => apiKey.isNotEmpty;

  /// True when the key came from the build rather than the user.
  bool get usingBakedKey => _apiKey.isEmpty && _bakedKey.isNotEmpty;

  String get storyModel => _storyModel;
  String get speechModel => _speechModel;

  static Future<AiSettings> load() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final settings = AiSettings._(File(p.join(dir.path, 'ai-settings.json')));
    try {
      if (await settings._file.exists()) {
        final json =
            jsonDecode(await settings._file.readAsString()) as Map<String, dynamic>;
        settings._apiKey = (json['apiKey'] as String? ?? '').trim();
        settings._storyModel = _orDefault(json['storyModel'], defaultStoryModel);
        settings._speechModel = _orDefault(json['speechModel'], defaultSpeechModel);
      }
    } on Object catch (e) {
      debugPrint('ai: settings unreadable ($e), using defaults');
    }
    return settings;
  }

  Future<void> update({String? apiKey, String? storyModel, String? speechModel}) async {
    if (apiKey != null) _apiKey = apiKey.trim();
    if (storyModel != null) _storyModel = _orDefault(storyModel, defaultStoryModel);
    if (speechModel != null) {
      _speechModel = _orDefault(speechModel, defaultSpeechModel);
    }
    await _file.writeAsString(
      jsonEncode({
        'apiKey': _apiKey,
        'storyModel': _storyModel,
        'speechModel': _speechModel,
      }),
      flush: true,
    );
    notifyListeners();
  }

  static String _orDefault(Object? value, String fallback) {
    final s = (value as String? ?? '').trim();
    return s.isEmpty ? fallback : s;
  }
}

/// Where AI stories live, and the work that runs on them.
///
/// A story takes a minute or two to make, so the work belongs to the app, not
/// to a screen: leave the studio mid-way and the job carries on, and coming
/// back shows where it has got to. One [StoryJob] per tag, kept for the
/// session.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../model/project.dart';
import '../store/workspace.dart';
import 'ai_settings.dart';
import 'gemini_client.dart';
import 'story.dart';
import 'story_engine.dart';

enum StoryPhase { idle, writing, translating, narrating }

class StoryService extends ChangeNotifier {
  StoryService(this.workspace, this.settings) {
    settings.addListener(notifyListeners);
  }

  final Workspace workspace;
  final AiSettings settings;
  final Map<String, StoryJob> _jobs = {};

  Directory dirFor(String uid) => Directory(p.join(workspace.root.path, 'stories', uid));

  StoryJob job(String uid) => _jobs.putIfAbsent(uid, () {
    final job = StoryJob._(this, uid);
    job.addListener(notifyListeners);
    return job;
  });

  /// Tags that have a written story, whether or not its job is loaded — the
  /// Languages page asks this when a new language arrives.
  Future<List<String>> storyTags() async {
    final out = <String>[];
    for (final tag in workspace.project.tags) {
      if (await File(p.join(dirFor(tag.uid).path, 'story.json')).exists()) {
        out.add(tag.uid);
      }
    }
    return out;
  }

  StoryEngine _engine() {
    if (!settings.hasKey) {
      throw AiException('Add your Gemini API key in AI settings first.');
    }
    return StoryEngine(
      client: GeminiClient(apiKey: settings.apiKey),
      storyModel: settings.storyModel,
      speechModel: settings.speechModel,
    );
  }

  /// Forget a tag's story entirely — called when the tag is deleted.
  Future<void> discard(String uid) async {
    _jobs.remove(uid)?.removeListener(notifyListeners);
    final dir = dirFor(uid);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  @override
  void dispose() {
    settings.removeListener(notifyListeners);
    super.dispose();
  }
}

class StoryJob extends ChangeNotifier {
  StoryJob._(this._service, this.uid);

  final StoryService _service;
  final String uid;

  Story? _story;
  bool _loaded = false;
  StoryPhase _phase = StoryPhase.idle;
  String? _activeLanguage;
  int _done = 0, _total = 0;
  String? _error;
  String? _sampling;

  Story get story => _story ??= Story();
  bool get loaded => _loaded;
  StoryPhase get phase => _phase;
  bool get busy => _phase != StoryPhase.idle;
  String? get activeLanguage => _activeLanguage;
  String? get error => _error;

  /// Which cast member's voice sample is being made, if any.
  String? get sampling => _sampling;

  /// 0..1 while narrating; null when the step has no measurable progress.
  double? get progress => _phase == StoryPhase.narrating && _total > 0 ? _done / _total : null;
  String get progressLabel => _total == 0 ? '' : 'Part ${_done.clamp(1, _total)} of $_total';

  Directory get dir => _service.dirFor(uid);
  Directory get pagesDir => Directory(p.join(dir.path, 'pages'));
  File get _file => File(p.join(dir.path, 'story.json'));
  File pageFile(String name) => File(p.join(pagesDir.path, name));

  Workspace get _workspace => _service.workspace;
  BookieTag? get tag => _workspace.project.tagByUid(uid);

  Future<void> load() async {
    if (_loaded) return;
    try {
      if (await _file.exists()) {
        _story = Story.fromJson(
          (jsonDecode(await _file.readAsString()) as Map).cast<String, dynamic>(),
        );
        // Photos deleted from under us are just gone.
        _story!.pages.removeWhere((name) => !pageFile(name).existsSync());
      }
    } on Object catch (e) {
      debugPrint('story: $uid unreadable ($e), starting fresh');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> save() async {
    await dir.create(recursive: true);
    await _file.writeAsString(const JsonEncoder.withIndent('  ').convert(story.toJson()));
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  // ------------------------------------------------------------ pages

  Future<void> addPages(List<File> files) async {
    await pagesDir.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < files.length; i++) {
      final ext = p.extension(files[i].path).toLowerCase();
      final name = 'page-$stamp-$i${ext.isEmpty ? '.jpg' : ext}';
      await files[i].copy(pageFile(name).path);
      story.pages.add(name);
    }
    await save();
  }

  Future<void> removePage(String name) async {
    story.pages.remove(name);
    try {
      await pageFile(name).delete();
    } on FileSystemException {
      // Already gone.
    }
    await save();
  }

  Future<void> movePage(int from, int to) async {
    final name = story.pages.removeAt(from);
    story.pages.insert(to.clamp(0, story.pages.length), name);
    await save();
  }

  // ------------------------------------------------------------ the work

  /// Everything, start to finish: write in the first of [languages], translate
  /// into the rest, and narrate each one straight onto the tag.
  Future<void> create(List<String> languages) async {
    if (languages.isEmpty || busy) return;
    await _run(() async {
      final engine = _service._engine();
      _enter(StoryPhase.writing, languages.first);
      await engine.write(
        story,
        [for (final name in story.pages) pageFile(name)],
        languages.first,
      );
      await save();

      for (final lang in languages) {
        await _produce(engine, lang);
      }
    });
  }

  /// A language the story does not have yet — or one whose audio is stale.
  Future<void> produce(String language) async {
    if (busy) return;
    await _run(() async => _produce(_service._engine(), language));
  }

  /// Keep the script, re-record the audio: after a voice change or an edit.
  Future<void> renarrate(String language) async {
    if (busy) return;
    await _run(() async => _narrate(_service._engine(), language));
  }

  /// Translate (if needed) and narrate.
  Future<void> _produce(StoryEngine engine, String language) async {
    if (!story.scripts.containsKey(language)) {
      _enter(StoryPhase.translating, language);
      await engine.translate(story, language);
      await save();
    }
    await _narrate(engine, language);
  }

  Future<void> _narrate(StoryEngine engine, String language) async {
    final tag = this.tag;
    if (tag == null) throw AiException('This tag was removed.');
    final script = story.scripts[language]!;

    _enter(StoryPhase.narrating, language);
    final pcm = await engine.narrate(
      story,
      language,
      onProgress: (done, total) {
        _done = done;
        _total = total;
        notifyListeners();
      },
    );

    final file = await writeTempWav(pcm, tag.name);
    try {
      await _workspace.setClip(
        tag,
        language,
        file,
        origin: ClipSource.generated,
        durationMs: pcm.duration.inMilliseconds,
        originalName: script.title,
      );
    } finally {
      try {
        await file.parent.delete(recursive: true);
      } on FileSystemException {
        // Temp; the OS will get to it.
      }
    }
    script.narration = Narration(
      castSignature: story.castSignature,
      scriptSignature: scriptSignature(script),
      durationMs: pcm.duration.inMilliseconds,
      createdAt: DateTime.now(),
    );
    await save();
  }

  /// A short sample of one voice, written next to the story and returned for
  /// playing. Cached by voice and style, so tapping play twice is free.
  Future<File?> sample(CastMember member) async {
    final safe = '${member.id}-${member.voice}-${member.style.hashCode.toUnsigned(32)}';
    final file = File(p.join(dir.path, 'samples', '$safe.wav'));
    if (await file.exists()) return file;

    _sampling = member.id;
    _error = null;
    notifyListeners();
    try {
      final pcm = await _service._engine().sample(story, member);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(pcm.resampled(22050).toWav(), flush: true);
      return file;
    } on AiException catch (e) {
      _error = e.message;
      return null;
    } finally {
      _sampling = null;
      notifyListeners();
    }
  }

  /// Whether the [language] audio on the tag still matches the script and cast.
  bool isStale(String language) {
    final script = story.scripts[language];
    final narration = script?.narration;
    if (script == null || narration == null) return false;
    return narration.castSignature != story.castSignature ||
        narration.scriptSignature != scriptSignature(script);
  }

  Future<void> _run(Future<void> Function() work) async {
    _error = null;
    try {
      await work();
    } on AiException catch (e) {
      _error = e.message;
    } on Object catch (e) {
      debugPrint('story: $uid failed ($e)');
      _error = 'Something went wrong: $e';
    } finally {
      _phase = StoryPhase.idle;
      _activeLanguage = null;
      _done = _total = 0;
      notifyListeners();
    }
  }

  void _enter(StoryPhase phase, String language) {
    _phase = phase;
    _activeLanguage = language;
    _done = _total = 0;
    notifyListeners();
  }
}

/// The story assistant: photograph the pages, say how it should sound, and
/// get a narrated, multi-voice story on the tag — in every language.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../ai/story.dart';
import '../../ai/story_service.dart';
import '../../ai/voices.dart';
import '../../app_state.dart';
import '../../audio/clip_player.dart';
import '../../model/project.dart';
import '../theme.dart';
import '../widgets/format.dart';
import 'ai_settings_sheet.dart';
import 'cast_sheet.dart';
import 'script_page.dart';
import 'story_widgets.dart';

const _maxPages = 20;

Future<void> openStoryStudio(BuildContext context, String uid) async {
  if (!await ensureAiReady(context)) return;
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => StoryStudioPage(uid: uid)),
  );
}

class StoryStudioPage extends StatefulWidget {
  const StoryStudioPage({super.key, required this.uid});
  final String uid;

  @override
  State<StoryStudioPage> createState() => _StoryStudioPageState();
}

class _StoryStudioPageState extends State<StoryStudioPage> {
  final _player = ClipPlayer();
  final _picker = ImagePicker();
  late final StoryJob _job = AppScope.read(context).stories.job(widget.uid);
  late final _instructions = TextEditingController();
  Set<String>? _languages;
  bool _directionOpen = false;

  @override
  void initState() {
    super.initState();
    _job.load().then((_) {
      if (mounted) _instructions.text = _job.story.instructions;
    });
  }

  @override
  void dispose() {
    _player.dispose();
    _instructions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final tag = state.workspace.project.tagByUid(widget.uid);
    final languages = state.workspace.project.languages;

    return AnimatedBuilder(
      animation: _job,
      builder: (context, _) {
        if (tag == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(
              icon: Icons.help_outline,
              title: 'This tag is gone',
              message: 'It was removed from the project.',
            ),
          );
        }
        final story = _job.story;
        final written = story.isWritten;
        final selected = _languages ??= {...languages};
        final anyAudio = languages.any((l) => tag.clips[l]?.source == ClipSource.generated);

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('AI story'),
                Text(
                  tag.displayName,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'AI settings',
                onPressed: () => showAiSettings(context),
                icon: const Icon(Icons.tune_rounded),
              ),
            ],
          ),
          bottomNavigationBar: written && anyAudio && !_job.busy
              ? SafeArea(
                  minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: FilledButton.icon(
                    onPressed: _sendToToy,
                    icon: const Icon(Icons.send_rounded),
                    label: const Text('Send to the toy'),
                  ),
                )
              : null,
          body: !_job.loaded
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  children: [
                    if (_job.busy) ...[
                      WorkingCard(job: _job),
                      const SizedBox(height: 12),
                    ],
                    if (_job.error != null) ...[
                      ErrorCard(message: _job.error!, onDismiss: _job.clearError),
                      const SizedBox(height: 12),
                    ],
                    if (!written && !_job.busy) const _Intro(),
                    _pagesSection(story),
                    if (written) ...[
                      _storyCard(story),
                      _castSection(story),
                      _languagesSection(story, tag, languages),
                    ],
                    _directionSection(story, languages, selected, written),
                  ],
                ),
        );
      },
    );
  }

  // ------------------------------------------------------------ pages

  Widget _pagesSection(Story story) {
    final theme = Theme.of(context);
    final pages = story.pages;
    final locked = _job.busy;

    return Section(
      title: '1 · The pages',
      subtitle: pages.isEmpty
          ? 'Photograph each page of the book, in order.'
          : '${plural(pages.length, 'page')} · hold and drag to reorder',
      children: [
        if (pages.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Icon(Icons.menu_book_rounded, size: 40, color: theme.colorScheme.primary),
                const SizedBox(height: 10),
                Text(
                  'The assistant looks at the pictures — and the words, if there are any — '
                  'to find the characters and tell the story.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 14),
                _addButtons(locked),
              ],
            ),
          )
        else ...[
          SizedBox(
            height: 150,
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              buildDefaultDragHandles: !locked,
              itemCount: pages.length,
              onReorder: (from, to) => _job.movePage(from, to > from ? to - 1 : to),
              proxyDecorator: (child, _, _) => Material(color: Colors.transparent, child: child),
              itemBuilder: (context, i) => PageThumb(
                key: ValueKey(pages[i]),
                file: _job.pageFile(pages[i]),
                number: i + 1,
                onOpen: () => _viewPage(pages[i], i + 1),
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(padding: const EdgeInsets.all(12), child: _addButtons(locked || pages.length >= _maxPages)),
        ],
      ],
    );
  }

  Widget _addButtons(bool disabled) => Row(
    children: [
      Expanded(
        child: FilledButton.tonalIcon(
          onPressed: disabled ? null : _takePhoto,
          icon: const Icon(Icons.photo_camera_rounded),
          label: const Text('Take photo'),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: OutlinedButton.icon(
          onPressed: disabled ? null : _pickPhotos,
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('From photos'),
        ),
      ),
    ],
  );

  Future<void> _takePhoto() async {
    final shot = await _safePick(
      () => _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 82,
      ),
    );
    if (shot == null) return;
    await _job.addPages([File(shot.path)]);
    if (!mounted) return;
    final count = _job.story.pages.length;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Page $count added'),
          action: count < _maxPages ? SnackBarAction(label: 'Next page', onPressed: _takePhoto) : null,
        ),
      );
  }

  Future<void> _pickPhotos() async {
    final picked = await _safePick(
      () => _picker.pickMultiImage(maxWidth: 1600, maxHeight: 1600, imageQuality: 82),
    );
    if (picked == null || picked.isEmpty) return;
    final room = _maxPages - _job.story.pages.length;
    await _job.addPages([for (final x in picked.take(room)) File(x.path)]);
    if (picked.length > room && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Kept the first $room — a story takes up to $_maxPages pages.')),
      );
    }
  }

  Future<T?> _safePick<T>(Future<T?> Function() pick) async {
    try {
      return await pick();
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open the camera or photos ($e)')),
        );
      }
      return null;
    }
  }

  Future<void> _viewPage(String name, int number) async {
    final remove = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PageViewer(file: _job.pageFile(name), number: number, canRemove: !_job.busy),
      ),
    );
    if (remove == true) await _job.removePage(name);
  }

  // ------------------------------------------------------------ direction

  Widget _directionSection(Story story, List<String> languages, Set<String> selected, bool written) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canCreate = story.pages.isNotEmpty && selected.isNotEmpty && !_job.busy;
    final ordered = languages.where(selected.contains).toList();

    final body = Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FieldLabel('How closely to follow the book'),
          SegmentedButton<StoryMode>(
            segments: [
              for (final m in StoryMode.values) ButtonSegment(value: m, label: Text(m.label, maxLines: 1)),
            ],
            selected: {story.mode},
            showSelectedIcon: false,
            onSelectionChanged: _job.busy ? null : (s) => setState(() => story.mode = s.first),
          ),
          const SizedBox(height: 16),
          const FieldLabel('Length'),
          SegmentedButton<StoryLength>(
            segments: [
              for (final l in StoryLength.values)
                ButtonSegment(
                  value: l,
                  label: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(l.label, maxLines: 1),
                        Text(l.hint, maxLines: 1, style: theme.textTheme.labelSmall),
                      ],
                    ),
                  ),
                ),
            ],
            selected: {story.length},
            showSelectedIcon: false,
            onSelectionChanged: _job.busy ? null : (s) => setState(() => story.length = s.first),
          ),
          const SizedBox(height: 16),
          const FieldLabel('Your instructions (optional)'),
          TextField(
            controller: _instructions,
            enabled: !_job.busy,
            minLines: 2,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'e.g. "Make the fox a little clumsy and funny, and end with everyone going to sleep."',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final idea in const [
                'Calm bedtime story',
                'Make it funny',
                'Lots of dialogue',
                'Gentle rhymes',
                'For a 3-year-old',
                'A lesson about sharing',
                "Use the child's name: ",
              ])
                ActionChip(
                  label: Text(idea.trim()),
                  visualDensity: VisualDensity.compact,
                  onPressed: _job.busy ? null : () => _appendIdea(idea),
                ),
            ],
          ),
          const SizedBox(height: 16),
          FieldLabel(
            languages.length > 1 ? 'Languages · written in the first, retold in the others' : 'Language',
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final lang in languages)
                FilterChip(
                  label: Text('${languageName(lang)} ($lang)'),
                  selected: selected.contains(lang),
                  onSelected: _job.busy
                      ? null
                      : (on) => setState(() => on ? selected.add(lang) : selected.remove(lang)),
                ),
            ],
          ),
          const SizedBox(height: 20),
          GradientButton(
            onPressed: canCreate ? () => _create(ordered, written) : null,
            icon: Icons.auto_awesome,
            label: written ? 'Write a new story' : 'Create the story',
          ),
          if (story.pages.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Add at least one page first.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            )
          else if (!written)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Takes a minute or two. You can leave this screen — it keeps going.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );

    if (!written) return Section(title: '2 · How it should sound', children: [body]);

    return Section(
      title: 'Start over',
      children: [
        Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: _directionOpen,
            onExpansionChanged: (open) => _directionOpen = open,
            leading: const Icon(Icons.edit_note_rounded),
            title: const Text('Change the direction and rewrite'),
            subtitle: Text(
              '${story.mode.label} · ${story.length.label}'
              '${story.instructions.isEmpty ? '' : ' · with your instructions'}',
            ),
            children: [body],
          ),
        ),
      ],
    );
  }

  void _appendIdea(String idea) {
    final current = _instructions.text.trim();
    final sep = current.isEmpty ? '' : (current.endsWith('.') ? ' ' : '. ');
    _instructions.text = '$current$sep$idea';
    _instructions.selection = TextSelection.collapsed(offset: _instructions.text.length);
  }

  Future<void> _create(List<String> languages, bool rewriting) async {
    if (rewriting) {
      final ok = await confirm(
        context,
        title: 'Write a new story?',
        message:
            'The current script and cast are replaced, and the audio on this tag is '
            're-recorded for ${languages.join(', ')}.',
        action: 'Rewrite',
      );
      if (!ok) return;
    }
    if (!mounted || !await ensureAiReady(context)) return;
    _job.story.instructions = _instructions.text.trim();
    await _player.stop();
    await _job.create(languages);
  }

  // ------------------------------------------------------------ result

  Widget _storyCard(Story story) {
    final theme = Theme.of(context);
    final title = story.scripts[story.sourceLanguage]?.title ?? '';
    final speakers = story.cast.length - 1;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Container(
        decoration: BoxDecoration(gradient: storyGradient(theme.colorScheme), borderRadius: BorderRadius.circular(20)),
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_stories_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 6),
                Text(
                  'YOUR STORY',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white70,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              title.isEmpty ? 'Untitled' : title,
              style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
            ),
            if (story.summary.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(story.summary, style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.92))),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                GlassPill(icon: Icons.record_voice_over_rounded, label: 'Narrator + ${plural(speakers, 'character')}'),
                GlassPill(icon: Icons.translate_rounded, label: plural(story.scripts.length, 'language')),
                GlassPill(icon: Icons.photo_rounded, label: plural(story.pages.length, 'page')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _castSection(Story story) {
    return Section(
      title: '2 · The voices',
      subtitle: 'Tap a voice to hear it. Tap a character to recast them.',
      children: [
        for (var i = 0; i < story.cast.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 72, endIndent: 16),
          CastTile(
            member: story.cast[i],
            color: speakerColor(Theme.of(context).colorScheme, i),
            lineCount: story.scripts[story.sourceLanguage]?.lines
                    .where((l) => l.speaker == story.cast[i].id)
                    .length ??
                0,
            player: _player,
            sampling: _job.sampling == story.cast[i].id,
            onPreview: () => _preview(story.cast[i]),
            onEdit: _job.busy ? null : () => _editMember(story, i),
          ),
        ],
      ],
    );
  }

  Future<void> _preview(CastMember member) async {
    if (_job.sampling != null) return;
    final file = await _job.sample(member);
    if (file != null && mounted) await _player.toggle(file);
  }

  Future<void> _editMember(Story story, int index) async {
    await _player.stop();
    if (!mounted) return;
    final changed = await showCastSheet(
      context,
      job: _job,
      member: story.cast[index],
      color: speakerColor(Theme.of(context).colorScheme, index),
      taken: {for (final m in story.cast) if (m != story.cast[index]) m.voice},
    );
    if (changed == true) await _job.save();
  }

  Widget _languagesSection(Story story, BookieTag tag, List<String> languages) {
    final workspace = AppScope.read(context).workspace;
    return Section(
      title: '3 · On the tag',
      subtitle: 'Each language is its own clip. The toy plays the one it is set to.',
      children: [
        for (var i = 0; i < languages.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
          LanguageStoryRow(
            language: languages[i],
            script: story.scripts[languages[i]],
            clip: tag.clips[languages[i]],
            file: workspace.clipFile(tag, languages[i]),
            player: _player,
            stale: _job.isStale(languages[i]),
            working: _job.activeLanguage == languages[i],
            locked: _job.busy,
            onCreate: () => _job.produce(languages[i]),
            onRenarrate: () => _renarrate(languages[i]),
            onReadScript: story.scripts[languages[i]] == null
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => ScriptPage(job: _job, language: languages[i])),
                  ),
          ),
        ],
      ],
    );
  }

  Future<void> _renarrate(String language) async {
    await _player.stop();
    await _job.renarrate(language);
  }

  void _sendToToy() {
    final state = AppScope.read(context);
    Navigator.of(context).popUntil((route) => route.isFirst);
    state.tab.value = 2;
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget step(IconData icon, String text) => Expanded(
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(height: 6),
          Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.white, height: 1.25),
          ),
        ],
      ),
    );

    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(gradient: storyGradient(scheme), borderRadius: BorderRadius.circular(20)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Turn any book into an audio story',
            style: theme.textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'A narrator and a voice for every character — all made by AI.',
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.9)),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              step(Icons.photo_camera_rounded, 'Snap the pages'),
              step(Icons.theater_comedy_rounded, 'AI casts the voices'),
              step(Icons.graphic_eq_rounded, 'Narrated in every language'),
              step(Icons.toys_rounded, 'Tap the book'),
            ],
          ),
        ],
      ),
    );
  }
}

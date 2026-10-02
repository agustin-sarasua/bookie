/// The ways into the story assistant from the rest of the app.
library;

import 'package:flutter/material.dart';

import '../../ai/story_service.dart';
import '../../ai/voices.dart';
import '../../app_state.dart';
import '../../model/project.dart';
import '../scan_sheet.dart';
import '../theme.dart';
import '../widgets/format.dart';
import 'story_studio_page.dart';
import 'story_widgets.dart';

/// On a tag's page: "make one" when there is no story, "here it is" when
/// there is, and a live progress bar while one is being made.
class StoryEntryCard extends StatefulWidget {
  const StoryEntryCard({super.key, required this.uid});
  final String uid;

  @override
  State<StoryEntryCard> createState() => _StoryEntryCardState();
}

class _StoryEntryCardState extends State<StoryEntryCard> {
  late final StoryJob _job = AppScope.read(context).stories.job(widget.uid);

  @override
  void initState() {
    super.initState();
    _job.load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final languages = AppScope.of(context).workspace.project.languages;

    return AnimatedBuilder(
      animation: _job,
      builder: (context, _) {
        final story = _job.story;
        final written = story.isWritten;
        final missing = languages.where((l) => !story.scripts.containsKey(l)).toList();
        final title = story.scripts[story.sourceLanguage]?.title ?? '';

        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Material(
            color: Colors.transparent,
            child: Ink(
              decoration: BoxDecoration(gradient: storyGradient(scheme), borderRadius: BorderRadius.circular(20)),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => openStoryStudio(context, widget.uid),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              written ? Icons.auto_stories_rounded : Icons.auto_awesome,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  written ? (title.isEmpty ? 'AI story' : title) : 'Create a story with AI',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _job.busy
                                      ? 'Working on it…'
                                      : written
                                      ? 'Narrator + ${plural(story.cast.length - 1, 'character')} · '
                                            '${story.scripts.keys.join(', ')}'
                                      : 'Snap the pages — AI writes it and gives every character a voice.',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: Colors.white.withValues(alpha: 0.9),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded, color: Colors.white),
                        ],
                      ),
                      if (_job.busy) ...[
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: _job.progress,
                            minHeight: 5,
                            color: Colors.white,
                            backgroundColor: Colors.white24,
                          ),
                        ),
                      ] else if (written && missing.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final lang in missing)
                              Material(
                                color: Colors.white.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(20),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(20),
                                  onTap: () => _job.produce(lang),
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.add_rounded, size: 16, color: Colors.white),
                                        const SizedBox(width: 4),
                                        Text(
                                          'Tell it in ${languageName(lang)}',
                                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                      if (_job.error != null && !_job.busy) ...[
                        const SizedBox(height: 10),
                        Text(
                          _job.error!,
                          style: theme.textTheme.bodySmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// From the Tags page: which tag is this story for? Offers a new scan first,
/// since a new book usually means new stickers.
Future<void> pickTagForStory(BuildContext context) async {
  final uid = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _TagPicker(),
  );
  if (uid != null && context.mounted) await openStoryStudio(context, uid);
}

class _TagPicker extends StatelessWidget {
  const _TagPicker();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final project = AppScope.of(context).workspace.project;
    // Tags with nothing to play first: they are the ones waiting for a story.
    final tags = [...project.tags]
      ..sort((a, b) {
        final byEmpty = a.clips.length.compareTo(b.clips.length);
        return byEmpty != 0 ? byEmpty : a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
      });

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Text('Which tag is the story for?', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'The story plays when the child taps this tag.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: () async {
              final before = {for (final t in project.tags) t.uid};
              await showScanSheet(context);
              if (!context.mounted) return;
              final fresh = AppScope.read(context).workspace.project.tags.where((t) => !before.contains(t.uid));
              if (fresh.isNotEmpty) Navigator.pop(context, fresh.last.uid);
            },
            icon: const Icon(Icons.nfc),
            label: const Text('Scan a new tag'),
          ),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 16),
            const FieldLabel('Or choose one'),
            Card(
              child: Column(
                children: [
                  for (var i = 0; i < tags.length; i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: Icon(
                        tags[i].clips.values.any((c) => c.source == ClipSource.generated)
                            ? Icons.auto_stories_rounded
                            : tags[i].clips.isEmpty
                            ? Icons.volume_off_outlined
                            : Icons.graphic_eq,
                      ),
                      title: Text(tags[i].displayName, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        tags[i].clips.isEmpty ? 'Nothing to play yet' : plural(tags[i].clips.length, 'clip'),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.pop(context, tags[i].uid),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

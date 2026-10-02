/// The script in one language, as a play: who says what. Every line can be
/// reworded or handed to someone else before the voices are recorded again.
library;

import 'package:flutter/material.dart';

import '../../ai/story.dart';
import '../../ai/story_service.dart';
import '../../ai/voices.dart';
import '../theme.dart';
import '../widgets/format.dart';
import 'story_widgets.dart';

class ScriptPage extends StatelessWidget {
  const ScriptPage({super.key, required this.job, required this.language});
  final StoryJob job;
  final String language;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: job,
      builder: (context, _) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final story = job.story;
        final script = story.scripts[language];
        if (script == null) {
          return Scaffold(appBar: AppBar(), body: const SizedBox.shrink());
        }
        final stale = job.isStale(language);
        final minutes = (script.wordCount / 150).clamp(0.2, 99);

        return Scaffold(
          appBar: AppBar(
            title: Text(script.title.isEmpty ? 'Script' : script.title, overflow: TextOverflow.ellipsis),
          ),
          bottomNavigationBar: stale
              ? SafeArea(
                  minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: GradientButton(
                    onPressed: job.busy
                        ? null
                        : () {
                            job.renarrate(language);
                            Navigator.pop(context);
                          },
                    icon: Icons.mic_rounded,
                    label: 'Record the voices again',
                  ),
                )
              : null,
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text(
                  '${languageName(language)} · ${plural(script.lines.length, 'line')} · '
                  '${plural(script.wordCount, 'word')} · ${minutes < 1 ? 'under a minute' : 'about ${minutes.round()} min'}. '
                  'Tap a line to change it.',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              for (var i = 0; i < script.lines.length; i++)
                _LineTile(
                  line: script.lines[i],
                  story: story,
                  onTap: job.busy ? null : () => _edit(context, story, script, i),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _edit(BuildContext context, Story story, StoryScript script, int index) async {
    final line = script.lines[index];
    final text = TextEditingController(text: line.text);
    var speaker = line.speaker;

    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Edit line'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                initialValue: story.member(speaker) == null ? story.narrator.id : speaker,
                decoration: const InputDecoration(labelText: 'Who says it', isDense: true),
                items: [
                  for (final m in story.cast) DropdownMenuItem(value: m.id, child: Text(m.name)),
                ],
                onChanged: (v) => setState(() => speaker = v ?? speaker),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: text,
                autofocus: true,
                minLines: 2,
                maxLines: 8,
                textCapitalization: TextCapitalization.sentences,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, '\u0000delete'),
              child: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, text.text), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (result == null) return;
    if (result == '\u0000delete') {
      script.lines.removeAt(index);
    } else if (result.trim().isNotEmpty) {
      line
        ..text = result.trim()
        ..speaker = speaker;
    }
    await job.save();
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({required this.line, required this.story, required this.onTap});
  final ScriptLine line;
  final Story story;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final index = story.cast.indexWhere((m) => m.id == line.speaker);
    final member = index < 0 ? story.narrator : story.cast[index];
    final color = speakerColor(scheme, index < 0 ? 0 : index);
    final narrator = member.isNarrator;

    return Padding(
      padding: EdgeInsets.only(bottom: 8, left: narrator ? 0 : 20),
      child: Material(
        color: narrator ? theme.cardTheme.color : color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SpeakerAvatar(member: member, color: color, size: 30),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            member.name,
                            style: theme.textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w700),
                          ),
                          if (line.delivery.isNotEmpty)
                            Flexible(
                              child: Text(
                                '  ·  ${line.delivery}',
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        line.text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontStyle: narrator ? null : FontStyle.normal,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

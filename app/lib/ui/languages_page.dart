import 'package:flutter/material.dart';

import '../ai/voices.dart';
import '../app_state.dart';
import '../audio/clip_player.dart';
import '../model/project.dart';
import '../store/workspace.dart';
import 'clip_actions.dart';
import 'theme.dart';
import 'widgets/clip_row.dart';
import 'widgets/format.dart';

class LanguagesPage extends StatelessWidget {
  const LanguagesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final project = state.workspace.project;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Languages')),
      floatingActionButton: FloatingActionButton.extended(
        // The tabs live in an IndexedStack, so every page's FAB is in the tree
        // at once; without distinct tags they collide as Heroes on any push.
        heroTag: 'fab-languages',
        onPressed: () => _addLanguage(context, state.workspace),
        icon: const Icon(Icons.add),
        label: const Text('Add a language'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.5,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Each language is a folder under /audio on the card. The language '
                    'button on the toy walks through them in alphabetical order and wraps '
                    'around, so the name you choose here is what it cycles.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),

          Section(
            title: 'On the card',
            children: [
              for (var i = 0; i < project.languages.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
                _LanguageTile(code: project.languages[i], project: project),
              ],
            ],
          ),
        ],
      ),
    );
  }

  static Future<void> _addLanguage(
    BuildContext context,
    Workspace workspace,
  ) async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a language'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'A short folder name — en, es, fr. It is what you will see cycling past '
              'when you press the language button, so keep it short and obvious.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'es'),
              onSubmitted: (value) => Navigator.pop(context, value),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final code in const ['en', 'es', 'fr', 'de', 'it', 'pt', 'nl', 'ca'])
                  if (!workspace.project.languages.contains(code))
                    ActionChip(
                      label: Text('${languageName(code)} · $code'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.pop(context, code),
                    ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    final clean = sanitiseLanguage(code ?? '');
    if (clean.isEmpty) return;
    if (workspace.project.languages.contains(clean)) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('"$clean" is already there.')));
      }
      return;
    }
    await workspace.addLanguage(clean);
    if (context.mounted) await _offerStories(context, clean);
  }

  /// A new language on a toy that already has AI stories: the assistant can
  /// retell every one of them in it, with the same cast and voices.
  static Future<void> _offerStories(BuildContext context, String lang) async {
    final state = AppScope.read(context);
    final uids = await state.stories.storyTags();
    if (uids.isEmpty || !context.mounted) return;

    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.auto_awesome),
        title: Text('Tell your AI stories in ${languageName(lang)}?'),
        content: Text(
          uids.length == 1
              ? 'One tag has an AI story. The assistant can retell it in $lang with '
                    'the same characters and voices.'
              : '${uids.length} tags have AI stories. The assistant can retell each of '
                    'them in $lang with the same characters and voices.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Create them')),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    if (!state.ai.hasKey) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add a Gemini API key first — the ✨ button on the Tags tab.')),
      );
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text('Creating ${uids.length == 1 ? 'the story' : '${uids.length} stories'} in $lang…')),
    );
    var ok = 0;
    for (final uid in uids) {
      final job = state.stories.job(uid);
      await job.load();
      if (!job.story.isWritten) continue;
      await job.produce(lang);
      if (job.error == null) ok++;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok == uids.length
              ? 'Done — every AI story now speaks ${languageName(lang)}.'
              : '$ok of ${uids.length} done. Open a tag to see what went wrong.',
        ),
      ),
    );
  }
}

class _LanguageTile extends StatelessWidget {
  const _LanguageTile({required this.code, required this.project});

  final String code;
  final Project project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final have = project.tags.where((t) => t.clips.containsKey(code)).length;
    final missing = project.missingIn(code);
    final prompts = project.system[code]?.length ?? 0;

    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      leading: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          code,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: code.length > 3 ? 11 : 14,
            color: theme.colorScheme.primary,
          ),
        ),
      ),
      title: Row(
        children: [
          Text(
            '/audio/$code',
            style: monoStyle(
              context,
              size: 14,
              color: theme.colorScheme.onSurface,
            ),
          ),
          if (code == fallbackLanguage) ...[
            const SizedBox(width: 8),
            const Pill('fallback', filled: true),
          ],
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            Pill(plural(have, 'clip'), filled: have > 0),
            if (missing > 0)
              Pill('$missing missing', icon: Icons.warning_amber_rounded),
            Pill(
              '$prompts/${systemClipIds.length} prompts',
              filled: prompts > 0,
            ),
          ],
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => LanguageDetailPage(code: code))),
    );
  }
}

class LanguageDetailPage extends StatefulWidget {
  const LanguageDetailPage({super.key, required this.code});

  final String code;

  @override
  State<LanguageDetailPage> createState() => _LanguageDetailPageState();
}

class _LanguageDetailPageState extends State<LanguageDetailPage> {
  final _player = ClipPlayer();

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final workspace = state.workspace;
    final project = workspace.project;
    final theme = Theme.of(context);

    if (!project.languages.contains(widget.code)) {
      return Scaffold(appBar: AppBar(), body: const SizedBox.shrink());
    }

    final isOnlyLanguage = project.languages.length == 1;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.code),
        actions: [
          IconButton(
            tooltip: isOnlyLanguage
                ? 'The toy needs at least one language'
                : 'Remove',
            onPressed: isOnlyLanguage ? null : () => _confirmRemove(workspace),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          Section(
            title: 'Spoken prompts',
            subtitle:
                'All four are optional — a missing one is simply skipped.',
            children: [
              for (var i = 0; i < systemClipIds.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
                ClipRow(
                  label: systemClipIds[i],
                  note: systemClipBlurbs[systemClipIds[i]],
                  clip: project.system[widget.code]?[systemClipIds[i]],
                  file: workspace.systemFile(widget.code, systemClipIds[i]),
                  player: _player,
                  onRecord: () => _attach(
                    workspace,
                    systemClipIds[i],
                    () => recordClip(
                      context,
                      title: 'Record "${systemClipIds[i]}"',
                      subtitle: systemClipBlurbs[systemClipIds[i]],
                    ),
                  ),
                  onImport: () => _attach(
                    workspace,
                    systemClipIds[i],
                    () => importClip(context),
                  ),
                  onRemove: () =>
                      workspace.removeSystemClip(widget.code, systemClipIds[i]),
                ),
              ],
            ],
          ),

          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              widget.code == fallbackLanguage
                  ? 'These live at /system/${widget.code}/. Every other language falls back '
                        'to this one when it has no prompt of its own, so it is worth filling in.'
                  : 'These live at /system/${widget.code}/. Anything left empty here falls back '
                        'to /system/$fallbackLanguage/.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _attach(
    Workspace workspace,
    String clipId,
    Future<PickedClip?> Function() acquire,
  ) async {
    final picked = await acquire();
    if (picked == null) return;
    await workspace.setSystemClip(
      widget.code,
      clipId,
      picked.file,
      origin: picked.source,
      durationMs: picked.durationMs,
    );
    await picked.discard();
  }

  Future<void> _confirmRemove(Workspace workspace) async {
    final affected = workspace.project.tags
        .where((t) => t.clips.containsKey(widget.code))
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${widget.code}?'),
        content: Text(
          affected == 0
              ? 'Nothing is recorded in this language yet.'
              : 'This deletes ${plural(affected, 'clip')} in $affected '
                    'tag(s) from this phone. The card keeps them until the next write, '
                    'where you can also clear them out.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _player.stop();
    await workspace.removeLanguage(widget.code);
    if (mounted) Navigator.of(context).pop();
  }
}

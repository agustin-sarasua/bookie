import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../audio/clip_player.dart';
import '../model/project.dart';
import '../model/uid.dart';
import '../store/workspace.dart';
import 'clip_actions.dart';
import 'theme.dart';
import 'widgets/clip_row.dart';
import 'widgets/format.dart';

class TagDetailPage extends StatefulWidget {
  const TagDetailPage({super.key, required this.uid});

  final String uid;

  @override
  State<TagDetailPage> createState() => _TagDetailPageState();
}

class _TagDetailPageState extends State<TagDetailPage> {
  final _player = ClipPlayer();
  bool _busy = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final workspace = state.workspace;
    final tag = workspace.project.tagByUid(widget.uid);

    if (tag == null) {
      // Deleted from under us.
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.help_outline,
          title: 'This tag is gone',
          message: 'It was removed from the project.',
        ),
      );
    }

    final languages = workspace.project.languages;

    return Scaffold(
      appBar: AppBar(
        title: Text(tag.displayName, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Delete this tag',
            onPressed: () => _confirmDelete(tag),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('Name'),
                  subtitle: Text(
                    tag.label?.trim().isNotEmpty == true
                        ? tag.label!
                        : 'Not named yet',
                    style: TextStyle(
                      color: tag.label?.trim().isNotEmpty == true
                          ? null
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: const Icon(Icons.edit_outlined, size: 20),
                  onTap: () => _editLabel(workspace, tag),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  title: const Text('File name'),
                  subtitle: Text(
                    '${tag.name}.mp3 / .wav',
                    style: monoStyle(context),
                  ),
                  trailing: const Icon(Icons.edit_outlined, size: 20),
                  onTap: () => _editStem(workspace, tag),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  title: const Text('Tag UID'),
                  subtitle: Text(prettyUid(tag.uid), style: monoStyle(context)),
                  trailing: const Icon(Icons.copy_all_outlined, size: 20),
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: tag.uid));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('UID copied')));
                  },
                ),
              ],
            ),
          ),

          Section(
            title: 'What it plays',
            subtitle:
                'One clip per language. The toy picks the one it is set to.',
            children: [
              for (var i = 0; i < languages.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
                ClipRow(
                  label: languages[i],
                  clip: tag.clips[languages[i]],
                  file: workspace.clipFile(tag, languages[i]),
                  player: _player,
                  onRecord: () => _attach(
                    workspace,
                    tag,
                    languages[i],
                    () => recordClip(
                      context,
                      title: 'Record ${tag.displayName}',
                      subtitle: 'In ${languages[i]}',
                    ),
                  ),
                  onImport: () => _attach(
                    workspace,
                    tag,
                    languages[i],
                    () => importClip(context),
                  ),
                  onRemove: () => _remove(workspace, tag, languages[i]),
                ),
              ],
            ],
          ),

          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'On the card this tag becomes a line in tags.csv — '
              '${tag.uid},${tag.name} — and one file per language at '
              '/audio/<language>/${tag.name}.…',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Future<void> _attach(
    Workspace workspace,
    BookieTag tag,
    String lang,
    Future<PickedClip?> Function() acquire,
  ) async {
    final picked = await acquire();
    if (picked == null) return;

    setState(() => _busy = true);
    try {
      await workspace.setClip(
        tag,
        lang,
        picked.file,
        origin: picked.source,
        durationMs: picked.durationMs,
        originalName: picked.originalName,
      );
      await picked.discard();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(Workspace workspace, BookieTag tag, String lang) async {
    await _player.stop();
    await workspace.removeClip(tag, lang);
  }

  Future<void> _editLabel(Workspace workspace, BookieTag tag) async {
    final value = await _prompt(
      title: 'Name this tag',
      help:
          'Just for you — "Page 4, the bear wakes up". The toy never sees it.',
      initial: tag.label ?? '',
    );
    if (value == null) return;

    // A tag that still carries its UID as a file name has never been named, so
    // the first name it gets should become the file name too.
    final derive = tag.name == tag.uid;
    await workspace.renameTag(
      tag,
      label: value,
      stem: derive && value.trim().isNotEmpty ? sanitiseStem(value) : null,
    );
  }

  Future<void> _editStem(Workspace workspace, BookieTag tag) async {
    final limit = maxStemLength(workspace.project.languages);
    final value = await _prompt(
      title: 'File name',
      help:
          'This is the file the toy looks for: /audio/<language>/<name>.mp3. '
          'Lower case, no spaces, at most $limit characters.',
      initial: tag.name,
      mono: true,
    );
    if (value == null || value.trim().isEmpty) return;
    await workspace.renameTag(tag, stem: value);

    if (!mounted) return;
    final settled = workspace.project.tagByUid(tag.uid)?.name;
    if (settled != null && settled != sanitiseStem(value)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('That name was taken, so it became "$settled".'),
        ),
      );
    }
  }

  Future<String?> _prompt({
    required String title,
    required String help,
    required String initial,
    bool mono = false,
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(help, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              style: mono ? monoStyle(context, size: 15, color: null) : null,
              onSubmitted: (value) => Navigator.pop(context, value),
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
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BookieTag tag) async {
    final workspace = AppScope.read(context).workspace;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${tag.displayName}?'),
        content: Text(
          tag.clips.isEmpty
              ? 'The tag itself is not touched — this only removes it from the project.'
              : 'This also deletes its ${plural(tag.clips.length, 'clip')} from this phone. '
                    'Anything already on the card stays there until the next write.',
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _player.stop();
    await workspace.removeTag(tag);
    if (mounted) Navigator.of(context).pop();
  }
}

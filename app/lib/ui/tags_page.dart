import 'package:flutter/material.dart';

import '../app_state.dart';
import '../model/project.dart';
import '../model/uid.dart';
import 'scan_sheet.dart';
import 'tag_detail_page.dart';
import 'theme.dart';
import 'widgets/format.dart';

class TagsPage extends StatefulWidget {
  const TagsPage({super.key});

  @override
  State<TagsPage> createState() => _TagsPageState();
}

class _TagsPageState extends State<TagsPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final project = state.workspace.project;

    final tags = [...project.tags]
      ..sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );
    final visible = _query.isEmpty
        ? tags
        : tags.where((t) {
            final q = _query.toLowerCase();
            return t.displayName.toLowerCase().contains(q) ||
                t.name.toLowerCase().contains(q) ||
                t.uid.toLowerCase().contains(
                  normaliseUid(_query).toLowerCase(),
                );
          }).toList();

    final clips = tags.fold<int>(0, (sum, t) => sum + t.clips.length);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tags'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                tags.isEmpty
                    ? 'Nothing configured yet'
                    : '${plural(tags.length, 'tag')} · ${plural(clips, 'clip')} · '
                          '${plural(project.languages.length, 'language')}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
      // The empty state already offers this, front and centre.
      floatingActionButton: tags.isEmpty
          ? null
          : FloatingActionButton.extended(
              heroTag: 'fab-tags',
              onPressed: () => _scan(context),
              icon: const Icon(Icons.nfc),
              label: const Text('Scan a tag'),
            ),
      body: tags.isEmpty
          ? EmptyState(
              icon: Icons.style_outlined,
              title: 'No tags yet',
              message:
                  'Stick an NFC tag on a page, hold your phone against it, and give it '
                  'something to say.',
              action: FilledButton.icon(
                onPressed: () => _scan(context),
                icon: const Icon(Icons.nfc),
                label: const Text('Scan a tag'),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
              children: [
                if (tags.length > 6)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      decoration: const InputDecoration(
                        hintText: 'Search by name or UID',
                        prefixIcon: Icon(Icons.search),
                        isDense: true,
                      ),
                      onChanged: (value) => setState(() => _query = value),
                    ),
                  ),
                if (visible.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 48),
                    child: Text(
                      'No tag matches "$_query".',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                Card(
                  child: Column(
                    children: [
                      for (var i = 0; i < visible.length; i++) ...[
                        if (i > 0)
                          const Divider(height: 1, indent: 16, endIndent: 16),
                        _TagTile(tag: visible[i], languages: project.languages),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (_query.isEmpty && project.languages.length > 1)
                  _CoverageNote(project: project),
              ],
            ),
    );
  }

  Future<void> _scan(BuildContext context) => showScanSheet(context);
}

class _TagTile extends StatelessWidget {
  const _TagTile({required this.tag, required this.languages});

  final BookieTag tag;
  final List<String> languages;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = languages.where(tag.clips.containsKey).length;

    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => TagDetailPage(uid: tag.uid))),
      leading: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: ready == 0
              ? theme.colorScheme.surfaceContainerHighest
              : theme.colorScheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(
          ready == 0 ? Icons.volume_off_outlined : Icons.graphic_eq,
          size: 20,
          color: ready == 0
              ? theme.colorScheme.outline
              : theme.colorScheme.primary,
        ),
      ),
      title: Text(
        tag.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(prettyUid(tag.uid), style: monoStyle(context, size: 11.5)),
            const SizedBox(height: 7),
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                for (final lang in languages)
                  Pill(lang, filled: tag.clips.containsKey(lang)),
              ],
            ),
          ],
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}

/// A nudge, not a nag: the language button cycles every folder under /audio,
/// so a language with holes in it means the toy will say "unknown" mid-book.
class _CoverageNote extends StatelessWidget {
  const _CoverageNote({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final gaps = {
      for (final lang in project.languages)
        if (project.missingIn(lang) > 0) lang: project.missingIn(lang),
    };
    if (gaps.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
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
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Gaps: ${gaps.entries.map((e) => '${e.value} in ${e.key}').join(', ')}. '
              'The toy plays the "unknown" prompt for a tag with no clip in the '
              'language it is set to.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../model/project.dart';
import '../model/uid.dart';
import 'ai/ai_settings_sheet.dart';
import 'ai/story_entry.dart';
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
        actions: [
          IconButton(
            tooltip: 'Story assistant settings',
            onPressed: () => showAiSettings(context),
            icon: const Icon(Icons.auto_awesome_outlined),
          ),
        ],
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
          ? const _Welcome()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
              children: [
                const _StoryBanner(),
                const SizedBox(height: 12),
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
          ready == 0
              ? Icons.volume_off_outlined
              : tag.clips.values.any((c) => c.source == ClipSource.generated)
              ? Icons.auto_stories_rounded
              : Icons.graphic_eq,
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

/// Across the top of the list: the fastest way to fill a tag.
class _StoryBanner extends StatelessWidget {
  const _StoryBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          gradient: storyGradient(theme.colorScheme),
          borderRadius: BorderRadius.circular(18),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => pickTagForStory(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Create a story with AI',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'Photograph a book — get it narrated, with a voice for every character.',
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
          ),
        ),
      ),
    );
  }
}

/// First run: what the app is for, in three steps, and the two ways to start.
class _Welcome extends StatelessWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget step(int n, IconData icon, String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: scheme.primary, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$n. $title', style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        Icon(Icons.menu_book_rounded, size: 52, color: scheme.primary),
        const SizedBox(height: 12),
        Text(
          'Make any book talk',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          'Stick an NFC tag on a page, give it a story, and the toy plays it '
          'whenever a little hand taps the book.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 28),
        step(1, Icons.nfc, 'Scan a tag', 'Hold the phone against the sticker.'),
        step(
          2,
          Icons.auto_awesome,
          'Give it a story',
          'Let AI narrate it from photos of the book, record your own voice, or import a file.',
        ),
        step(
          3,
          Icons.send_rounded,
          'Send it to the toy',
          'Connect to the toy from the Card tab and update it — the card stays inside.',
        ),
        const SizedBox(height: 12),
        GradientStartButton(onPressed: () => pickTagForStory(context)),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => showScanSheet(context),
          icon: const Icon(Icons.nfc),
          label: const Text('Scan a tag'),
        ),
      ],
    );
  }
}

class GradientStartButton extends StatelessWidget {
  const GradientStartButton({super.key, required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: storyGradient(Theme.of(context).colorScheme),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onPressed,
        child: const SizedBox(
          height: 52,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.auto_awesome, color: Colors.white),
              SizedBox(width: 10),
              Text(
                'Create a story with AI',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

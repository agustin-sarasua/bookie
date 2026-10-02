/// The toy's card: connect over the toy's WiFi, see what it holds, and bring
/// it in line with the app — new and changed clips written, anything no tag
/// uses removed.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../ai/voices.dart';
import '../app_state.dart';
import '../card/card_import.dart';
import '../card/card_sync.dart';
import '../card/card_target.dart';
import '../card/toy_card.dart';
import '../model/project.dart';
import 'widgets/format.dart';

class CardPage extends StatefulWidget {
  const CardPage({super.key, this.isVisible = true});

  /// Whether this tab is the one on screen. The page is kept alive in an
  /// IndexedStack, so without this it would re-read the card on every edit made
  /// on another tab — and a plan costs one directory listing per language.
  final bool isVisible;

  @override
  State<CardPage> createState() => _CardPageState();
}

class _CardPageState extends State<CardPage> {
  SyncPlan? _plan;
  bool _planning = false;
  String? _error;

  SyncProgress? _progress;
  bool get _writing => _progress != null;

  String? _plannedFor;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final connected = state.cardState == CardState.connected;

    // Re-plan when the card changes underneath us, and when the project has
    // been edited since the plan was made.
    final signature = '${state.cardInfo?.handle}#${state.workspace.revision}';
    if (widget.isVisible && connected && signature != _plannedFor && !_planning) {
      _plannedFor = signature;
      WidgetsBinding.instance.addPostFrameCallback((_) => _replan());
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Card'),
        actions: [
          if (connected)
            IconButton(
              tooltip: 'Read the card again',
              onPressed: _writing || _planning
                  ? null
                  : () async {
                      await state.refreshCard();
                      await _replan();
                    },
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          _ToyStatus(
            state: state,
            onConnect: _writing ? null : () => _connect(state),
            onDisconnect: _writing ? null : () => _disconnect(state),
          ),

          if (_error != null) ...[
            const SizedBox(height: 16),
            _Banner(
              icon: Icons.error_outline,
              tone: _Tone.error,
              title: 'That did not work',
              message: _error!,
            ),
          ],

          if (connected) ..._cardSection(state),
        ],
      ),
    );
  }

  List<Widget> _cardSection(AppState state) {
    final plan = _plan;
    if (_writing) return [const SizedBox(height: 16), _Progress(progress: _progress!)];
    if (plan == null || _planning) {
      return [
        const SizedBox(height: 40),
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 12),
        Center(child: Text('Reading the card…', style: Theme.of(context).textTheme.bodySmall)),
      ];
    }

    final free = state.cardInfo?.freeBytes;
    final tooBig = free != null && plan.totalBytes > free;
    final project = state.workspace.project;

    return [
      const SizedBox(height: 16),
      _Summary(
        plan: plan,
        tooBig: tooBig,
        free: free,
        onUpdate: plan.isEmpty || tooBig ? null : () => _write(state, plan),
      ),

      if (plan.missingLocally.isNotEmpty) ...[
        const SizedBox(height: 12),
        _Banner(
          icon: Icons.warning_amber_rounded,
          tone: _Tone.warning,
          title: '${plural(plan.missingLocally.length, 'clip')} missing on this phone',
          message:
              '${plan.missingLocally.map((p) => p.split('/').last).join(', ')} '
              'could not be found here, so they are skipped. Record or create them again.',
        ),
      ],

      _TagsOnCard(project: project, plan: plan),

      if (plan.deletions.isNotEmpty || plan.folders.isNotEmpty) _Removals(plan: plan),

      const SizedBox(height: 24),
      OutlinedButton.icon(
        onPressed: () => _import(state),
        icon: const Icon(Icons.download_outlined),
        label: const Text('Copy the card into the app'),
      ),
      const SizedBox(height: 6),
      Text(
        'For a toy set up on another phone: replaces the app\'s tags and clips with '
        'what is on the card.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ];
  }

  // ------------------------------------------------------------ actions

  Future<void> _connect(AppState state) async {
    setState(() => _error = null);
    await state.connectToy();
    if (!mounted) return;

    if (state.cardState == CardState.connected) {
      _plannedFor = null;
      await _replan();
      return;
    }

    // Either the phone would not join, the user declined, or link mode is not
    // running on the toy. All three look the same from here and have the same
    // two answers, so say both rather than guessing.
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.wifi_find_outlined),
        title: const Text('The toy did not answer'),
        content: Text(
          'On the toy: hold the language button and press volume up. It says so out '
          'loud if it has a "link" clip.\n\n'
          'On the phone: if nothing offered to join, open WiFi settings and pick the '
          "network starting '$toyApPrefix' — the password is '$toyApPassword'. Then "
          'tap "Connect to the toy" again.'
          '${state.lastError == null ? '' : '\n\n${state.lastError}'}',
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _disconnect(AppState state) async {
    await state.disconnect();
    if (mounted) {
      setState(() {
        _plan = null;
        _plannedFor = null;
        _error = null;
      });
    }
  }

  Future<void> _replan() async {
    final state = AppScope.read(context);
    final card = state.card;
    if (card == null) return;

    setState(() {
      _planning = true;
      _error = null;
    });
    try {
      final plan = await CardSync.plan(state.workspace, card);
      if (mounted) setState(() => _plan = plan);
    } on CardUnavailable catch (e) {
      if (mounted) setState(() => _error = e.message);
      await state.refreshCard();
    } finally {
      if (mounted) setState(() => _planning = false);
    }
  }

  Future<void> _write(AppState state, SyncPlan plan) async {
    final card = state.card;
    if (card == null) return;

    setState(() => _error = null);
    try {
      await for (final progress in CardSync.apply(card, plan)) {
        if (!mounted) return;
        setState(() => _progress = progress);
      }
      if (!mounted) return;
      setState(() => _progress = null);
      _plannedFor = null;

      await state.refreshCard();
      await _replan();
      if (!mounted) return;

      // Read back rather than trust the success codes: the fresh plan should
      // have nothing left to do.
      final left = _plan;
      if (left != null && left.writes.isNotEmpty) {
        setState(
          () => _error =
              '${plural(left.writes.length, 'file')} did not land on the card. '
              'Tap "Update the toy" to try again.',
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The toy is up to date. Disconnect and it is ready to play.'),
          duration: Duration(seconds: 4),
        ),
      );
    } on CardUnavailable catch (e) {
      if (!mounted) return;
      setState(() {
        _progress = null;
        _error =
            '${e.message} Some files may already be written — connect again and '
            'update once more to finish.';
      });
      await state.refreshCard();
    }
  }

  Future<void> _import(AppState state) async {
    final card = state.card;
    if (card == null) return;

    setState(() => _planning = true);
    final plausible = await CardImport.looksLikeCard(card);
    if (mounted) setState(() => _planning = false);
    if (!mounted) return;
    if (!plausible) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.help_outline),
          title: const Text('The card is empty'),
          content: const Text(
            'There are no tags or clips on it to copy, so nothing was changed.',
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
          ],
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Copy the card into the app?'),
        content: const Text(
          'This replaces everything in the app with what is on the card — tags, '
          'languages and clips. Use it to pick up a toy set up on another phone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Replace')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _planning = true;
      _error = null;
    });
    try {
      final summary = await CardImport.pullInto(state.workspace, card);
      if (!mounted) return;
      _plannedFor = null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Copied ${plural(summary.tags, 'tag')} and ${plural(summary.clipsCopied, 'clip')} '
            'from the card.',
          ),
        ),
      );
    } on CardUnavailable catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _planning = false);
      await _replan();
    }
  }
}

// ------------------------------------------------------------ pieces

class _ToyStatus extends StatelessWidget {
  const _ToyStatus({required this.state, required this.onConnect, required this.onDisconnect});

  final AppState state;
  final VoidCallback? onConnect;
  final VoidCallback? onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final info = state.cardInfo;
    final cardState = state.cardState;
    final connected = cardState == CardState.connected;

    if (connected) {
      final free = info?.freeBytes;
      final total = info?.totalBytes;
      return Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 8, 16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(Icons.wifi_tethering, color: scheme.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Connected to the toy', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 3),
                    Text(
                      free == null
                          ? (info?.name ?? 'Bookie')
                          : '${formatBytes(free)} free${total == null ? '' : ' of ${formatBytes(total)}'}',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    if (free != null && total != null && total > 0) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: (1 - free / total).clamp(0, 1),
                          minHeight: 5,
                          backgroundColor: scheme.surfaceContainerHighest,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              TextButton(onPressed: onDisconnect, child: const Text('Disconnect')),
            ],
          ),
        ),
      );
    }

    final connecting = cardState == CardState.connecting;
    final lost = cardState == CardState.missing;

    Widget step(int n, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: scheme.primary.withValues(alpha: 0.14),
            child: Text(
              '$n',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.primary),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              lost ? Icons.wifi_off_rounded : Icons.toys_rounded,
              size: 44,
              color: lost ? scheme.tertiary : scheme.primary,
            ),
            const SizedBox(height: 10),
            Text(
              lost ? 'The toy went to sleep' : 'Connect to the toy',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              lost
                  ? 'It drops its WiFi after a few quiet minutes or when a button is pressed.'
                  : 'The card stays inside — the phone talks to it over the toy\'s own WiFi.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            step(1, 'On the toy, hold the language button and press volume up.'),
            step(2, 'Tap Connect and let the phone join the toy\'s WiFi.'),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: connecting ? null : onConnect,
              icon: connecting
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering),
              label: Text(connecting ? 'Connecting…' : (lost ? 'Connect again' : 'Connect')),
            ),
          ],
        ),
      ),
    );
  }
}

/// Up to date, or what one tap will change.
class _Summary extends StatelessWidget {
  const _Summary({required this.plan, required this.tooBig, required this.free, required this.onUpdate});

  final SyncPlan plan;
  final bool tooBig;
  final int? free;
  final VoidCallback? onUpdate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (plan.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF3F8F6B).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: Color(0xFF3F8F6B), size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('The toy is up to date', style: theme.textTheme.titleMedium),
                  Text(
                    'Everything the app has is on the card, and nothing else.',
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final removals = plan.deletions.length;
    final chips = <Widget>[
      if (plan.added > 0) _Change(Icons.add_rounded, '${plan.added} new', scheme.primary),
      if (plan.updated > 0) _Change(Icons.sync_rounded, '${plan.updated} changed', scheme.primary),
      if (removals > 0) _Change(Icons.remove_rounded, '$removals to remove', scheme.error),
      if (plan.tagListChanged && plan.added == 0 && plan.updated == 0 && removals == 0)
        _Change(Icons.label_outline_rounded, 'Tag names', scheme.primary),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Changes to send', style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: chips),
            if (tooBig) ...[
              const SizedBox(height: 10),
              Text(
                'Not enough room: ${formatBytes(plan.totalBytes)} to write, ${formatBytes(free)} free.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onUpdate,
              icon: const Icon(Icons.send_rounded),
              label: Text(
                plan.totalBytes > 0 ? 'Update the toy · ${formatBytes(plan.totalBytes)}' : 'Update the toy',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Change extends StatelessWidget {
  const _Change(this.icon, this.label, this.color);
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(8, 5, 11, 5),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12.5)),
      ],
    ),
  );
}

enum _ClipState { onCard, toSend, none }

/// Every tag, and for each language whether the toy already has it.
class _TagsOnCard extends StatelessWidget {
  const _TagsOnCard({required this.project, required this.plan});

  final Project project;
  final SyncPlan plan;

  _ClipState _stateOf(BookieTag tag, String lang) {
    final clip = tag.clips[lang];
    if (clip == null) return _ClipState.none;
    final path = '/audio/$lang/${clip.fileName}';
    if (plan.isSynced(path)) return _ClipState.onCard;
    if (plan.missingLocally.contains(path)) return _ClipState.none;
    return _ClipState.toSend;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tags = [...project.tags]
      ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    final onCard = plan.onCard.keys.where((p) => p.startsWith('/audio/')).length -
        plan.deletions.where((p) => p.startsWith('/audio/')).length;

    return Section(
      title: 'On the toy',
      subtitle: tags.isEmpty
          ? 'No tags yet — add some on the Tags tab.'
          : '${plural(onCard, 'clip')} on the card. Green is already there; an arrow '
                'means it goes with the next update.',
      children: [
        if (tags.isEmpty)
          const ListTile(
            leading: Icon(Icons.style_outlined),
            title: Text('Nothing to put on the toy yet'),
          ),
        for (var i = 0; i < tags.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tags[i].displayName,
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Wrap(
                  spacing: 5,
                  children: [
                    for (final lang in project.languages)
                      _LangState(lang: lang, state: _stateOf(tags[i], lang)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _LangState extends StatelessWidget {
  const _LangState({required this.lang, required this.state});
  final String lang;
  final _ClipState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, filled, tip) = switch (state) {
      _ClipState.onCard => (Icons.check_rounded, const Color(0xFF3F8F6B), true, 'On the toy'),
      _ClipState.toSend => (Icons.arrow_upward_rounded, scheme.primary, true, 'Will be sent'),
      _ClipState.none => (null, scheme.outline, false, 'No clip in ${languageName(lang)}'),
    };
    return Tooltip(
      message: tip,
      child: Pill(lang, filled: filled, color: color, icon: icon),
    );
  }
}

/// What the update will take off the card, in words rather than paths.
class _Removals extends StatelessWidget {
  const _Removals({required this.plan});
  final SyncPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shown = plan.deletions.take(12).toList();
    final removedLanguages = plan.folders.map((f) => f.split('/').last).toList();

    return Section(
      title: 'Will be removed',
      subtitle: 'On the card, but not used by any tag in the app.',
      children: [
        for (final path in shown)
          ListTile(
            dense: true,
            leading: Icon(Icons.remove_circle_outline, color: scheme.error, size: 20),
            title: Text(path.split('/').last, overflow: TextOverflow.ellipsis),
            trailing: Text(
              path.split('/')[2],
              style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        if (plan.deletions.length > shown.length)
          ListTile(
            dense: true,
            title: Text(
              '…and ${plan.deletions.length - shown.length} more',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (removedLanguages.isNotEmpty)
          ListTile(
            dense: true,
            leading: Icon(Icons.translate_rounded, color: scheme.error, size: 20),
            title: Text(
              'Language ${removedLanguages.join(', ')}',
            ),
            subtitle: const Text('Not in the app any more — the language button stops offering it'),
          ),
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.progress});

  final SyncProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = progress.current.split('/').last;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Updating the toy', style: theme.textTheme.titleSmall),
                Text('${progress.done} / ${progress.total}', style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(value: progress.fraction, minHeight: 8),
            ),
            const SizedBox(height: 12),
            Text(
              current,
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              '${formatBytes(progress.bytesDone)} of ${formatBytes(progress.bytesTotal)} · '
              'keep the phone near the toy',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

enum _Tone { warning, error }

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.tone, required this.title, required this.message});

  final IconData icon;
  final _Tone tone;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = tone == _Tone.error ? scheme.error : scheme.tertiary;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(message, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

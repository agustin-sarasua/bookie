import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../card/card_import.dart';
import '../card/card_sync.dart';
import '../card/card_target.dart';
import '../card/toy_card.dart';
import '../card/zip_export.dart';
import 'theme.dart';
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
  bool _removeOrphans = false;
  String? _error;

  SyncProgress? _progress;
  bool get _writing => _progress != null;

  String? _plannedFor;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);

    // Re-plan when the card changes underneath us, and when the project has
    // been edited since the plan was made.
    final signature = '${state.cardInfo?.handle}#${state.workspace.revision}';
    if (widget.isVisible &&
        state.cardState == CardState.connected &&
        signature != _plannedFor &&
        !_planning) {
      _plannedFor = signature;
      WidgetsBinding.instance.addPostFrameCallback((_) => _replan());
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Card'),
        actions: [
          if (state.cardState == CardState.connected)
            IconButton(
              tooltip: 'Check the card again',
              onPressed: _writing
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
          _CardStatus(
            state: state,
            onConnect: _writing ? null : () => _connect(state),
            onConnectToy: _writing ? null : () => _connectToy(state),
            onForget: _writing ? null : () => _forget(state),
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

          if (state.cardInfo?.looksWrong ?? false) ...[
            const SizedBox(height: 16),
            _Banner(
              icon: Icons.wrong_location_outlined,
              tone: _Tone.warning,
              title: state.cardInfo!.removable == false
                  ? 'That folder is on the phone'
                  : 'That is a folder on the card, not the card',
              message: state.cardInfo!.removable == false
                  ? 'Writing there works, and the toy will never see any of it. '
                        'Choose the card again and pick the reader\'s volume — '
                        '${state.cardInfo!.location} is this phone\'s own storage.'
                  : 'The toy looks for /audio and /tags.csv at the very top of the '
                        'card. Choose the card again and stop at the volume itself, '
                        'without opening ${state.cardInfo!.location}.',
            ),
          ],

          if (state.cardState == CardState.connected) ..._writeSection(state),

          Section(
            title: 'Without a reader',
            subtitle:
                'Build the same card layout as a zip and copy it across from a computer.',
            children: [
              ListTile(
                leading: const Icon(Icons.folder_zip_outlined),
                title: const Text('Export bookie-card.zip'),
                subtitle: const Text('Unzip onto the root of a FAT32 card'),
                trailing: const Icon(Icons.ios_share),
                onTap: _writing ? null : _export,
              ),
            ],
          ),

          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              state.cardIsToy
                  ? 'Files are compared by size, the same shortcut "make card" takes. '
                        'The toy drops its WiFi on any button, and rescans the card as '
                        'soon as it does.'
                  : 'Files are compared by size, the same shortcut "make card" takes — '
                        'FAT32 timestamps are too coarse to be worth trusting. Eject the '
                        'card before pulling it out.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _writeSection(AppState state) {
    final plan = _plan;
    final free = state.cardInfo?.freeBytes;
    final tooBig = plan != null && free != null && plan.totalBytes > free;

    return [
      if (_writing) ...[
        const SizedBox(height: 20),
        _Progress(progress: _progress!),
      ] else if (_planning) ...[
        const SizedBox(height: 32),
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 12),
        Center(
          child: Text(
            'Reading the card…',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ] else if (plan != null) ...[
        if (plan.missingLocally.isNotEmpty) ...[
          const SizedBox(height: 16),
          _Banner(
            icon: Icons.warning_amber_rounded,
            tone: _Tone.warning,
            title:
                '${plural(plan.missingLocally.length, 'clip')} missing on this phone',
            message:
                'The project lists them but the files are gone: '
                '${plan.missingLocally.map((p) => p.split('/').last).join(', ')}. '
                'Record them again, or they will simply be skipped.',
          ),
        ],
        if (tooBig) ...[
          const SizedBox(height: 16),
          _Banner(
            icon: Icons.sd_card_alert_outlined,
            tone: _Tone.error,
            title: 'Not enough room',
            message:
                '${formatBytes(plan.totalBytes)} to write, ${formatBytes(free)} free.',
          ),
        ],

        Section(
          title: 'To write',
          subtitle: plan.isEmpty
              ? 'The card already matches the project.'
              : '${plural(plan.writes.length, 'file')} · ${formatBytes(plan.totalBytes)}',
          children: [
            if (plan.isEmpty)
              const ListTile(
                leading: Icon(Icons.check_circle_outline),
                title: Text('Nothing to do'),
                subtitle: Text(
                  'Every clip, tags.csv and bookie.json are up to date.',
                ),
              )
            else ...[
              for (final write in plan.writes.take(8))
                ListTile(
                  dense: true,
                  leading: Icon(
                    write.inline != null
                        ? Icons.description_outlined
                        : Icons.audiotrack_outlined,
                    size: 20,
                  ),
                  title: Text(
                    write.cardPath,
                    style: monoStyle(context, size: 12.5),
                  ),
                  trailing: Text(
                    formatBytes(write.bytes),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (plan.writes.length > 8)
                ListTile(
                  dense: true,
                  title: Text(
                    '…and ${plan.writes.length - 8} more',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
            if (plan.shadowing.isNotEmpty)
              ListTile(
                dense: true,
                leading: Icon(
                  Icons.layers_clear_outlined,
                  size: 20,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
                title: Text(
                  '${plural(plan.shadowing.length, 'stale file')} to clear',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                subtitle: const Text(
                  'Same name, other format. The toy prefers .mp3, so leaving them '
                  'would be a coin toss.',
                ),
              ),
          ],
        ),

        if (plan.orphans.isNotEmpty)
          Section(
            title: 'Already on the card',
            subtitle:
                '${plural(plan.orphans.length, 'file')} the project does not know about — '
                'clips for tags you deleted, or a language you removed.',
            children: [
              SwitchListTile(
                value: _removeOrphans,
                onChanged: (value) => setState(() => _removeOrphans = value),
                title: const Text('Delete them too'),
                subtitle: Text(
                  plan.orphans
                          .take(3)
                          .map((p) => p.split('/').last)
                          .join(', ') +
                      (plan.orphans.length > 3 ? ', …' : ''),
                  style: monoStyle(context, size: 11.5),
                ),
              ),
            ],
          ),

        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed:
              (plan.isEmpty && !(_removeOrphans && plan.orphans.isNotEmpty)) ||
                  tooBig
              ? null
              : () => _write(state, plan),
          icon: const Icon(Icons.sd_card_outlined),
          label: Text(
            plan.isEmpty && _removeOrphans && plan.orphans.isNotEmpty
                ? 'Clean up the card'
                : 'Write to the card',
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => _import(state),
          icon: const Icon(Icons.download_outlined),
          label: const Text('Load what is already on the card'),
        ),
      ],
    ];
  }

  // ------------------------------------------------------------ actions

  Future<void> _connect(AppState state) async {
    setState(() => _error = null);
    final ok = await state.connectCard();
    if (!ok && state.lastError != null && mounted) {
      setState(() => _error = state.lastError);
    }
    if (ok) {
      _plannedFor = null;
      await _replan();
    }
  }

  Future<void> _connectToy(AppState state) async {
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
          'On the toy: hold the language button and press volume up. It '
          'says so out loud if it has a "link" clip, and the serial monitor '
          'prints the network name.\n\n'
          'On the phone: if nothing offered to join, open WiFi settings and pick '
          "the network starting '$toyApPrefix' — the password is '$toyApPassword'. "
          'Then tap "Connect to the toy" again.'
          '${state.lastError == null ? '' : '\n\n${state.lastError}'}',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Right'),
          ),
        ],
      ),
    );
  }

  Future<void> _forget(AppState state) async {
    await state.forgetCard();
    if (mounted) {
      setState(() {
        _plan = null;
        _plannedFor = null;
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
      await for (final progress in CardSync.apply(
        card,
        plan,
        removeOrphans: _removeOrphans,
      )) {
        if (!mounted) return;
        setState(() => _progress = progress);
      }
      if (!mounted) return;
      setState(() => _progress = null);
      _plannedFor = null;

      // Every write reported success — but a provider that quietly dropped them
      // reports success too, and the first you would hear of it is a silent toy.
      // tags.csv is written last-but-one and always, so reading it straight back
      // is the cheapest proof that anything at all landed on the card.
      final written = await card.readFile('/tags.csv');
      await state.refreshCard();
      await _replan();
      if (!mounted) return;
      if (written == null) {
        setState(
          () => _error =
              'Every file was written without an error, and /tags.csv is not '
              'there when read back. The folder you chose is not really the '
              'card — choose the card again from the reader.',
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            state.cardIsToy
                ? 'Card written. Disconnect and the toy will pick it up.'
                : 'Card written. Eject it before pulling it out.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } on CardUnavailable catch (e) {
      if (!mounted) return;
      setState(() {
        _progress = null;
        _error =
            '${e.message} Some files may have been written already — '
            'plug it back in and write again.';
      });
      await state.refreshCard();
    }
  }

  Future<void> _import(AppState state) async {
    final card = state.card;
    if (card == null) return;

    // Refuse before asking, rather than emptying the project into a folder
    // that was never a card.
    setState(() => _planning = true);
    final plausible = await CardImport.looksLikeCard(card);
    if (mounted) setState(() => _planning = false);
    if (!plausible) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.help_outline),
          title: const Text('That does not look like a card'),
          content: Text(
            '${state.cardInfo?.name ?? 'This folder'} has no tags.csv, no '
            'bookie.json and no /audio folder. Loading from it would empty the '
            'app, so nothing was changed.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Right'),
            ),
          ],
        ),
      );
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Load from the card?'),
        content: const Text(
          'This replaces everything in the app with what is on the card — tags, '
          'languages and clips. Use it to pick up a card configured elsewhere, or '
          'to start again on a new phone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Load'),
          ),
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
            'Loaded ${plural(summary.tags, 'tag')} and ${plural(summary.clipsCopied, 'clip')} '
            'from ${summary.source}.',
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

  Future<void> _export() async {
    setState(() => _error = null);
    try {
      final zip = await ZipExport.build(AppScope.read(context).workspace);
      await ZipExport.share(zip);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }
}

// ------------------------------------------------------------ pieces

class _CardStatus extends StatelessWidget {
  const _CardStatus({
    required this.state,
    required this.onConnect,
    required this.onConnectToy,
    required this.onForget,
  });

  final AppState state;
  final VoidCallback? onConnect;
  final VoidCallback? onConnectToy;
  final VoidCallback? onForget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final info = state.cardInfo;

    final connected = state.cardState == CardState.connected;
    final missing = state.cardState == CardState.missing;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: connected
                        ? scheme.primary.withValues(alpha: 0.13)
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    connected ? Icons.sd_card : Icons.sd_card_alert_outlined,
                    color: connected ? scheme.primary : scheme.outline,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        connected
                            ? (info?.name ?? 'Card')
                            : (missing ? 'Card not found' : 'No card'),
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        switch (state.cardState) {
                          CardState.connected =>
                            info?.freeBytes == null
                                ? 'Connected'
                                : '${formatBytes(info!.freeBytes)} free'
                                      '${info.totalBytes != null ? ' of ${formatBytes(info.totalBytes)}' : ''}',
                          CardState.connecting => 'Looking…',
                          CardState.missing =>
                            'Plug the reader back in, or choose the card again.',
                          CardState.none =>
                            'Plug a card reader into your phone and point the app at '
                                'the card.',
                        },
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      if (connected && info?.location != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          info!.location!,
                          style: monoStyle(context, size: 11.5).copyWith(
                            color: info.looksWrong
                                ? scheme.error
                                : scheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: onConnect,
                    child: Text(
                      connected ? 'Choose another card' : 'Choose the card',
                    ),
                  ),
                ),
                if (connected || missing) ...[
                  const SizedBox(width: 10),
                  IconButton(
                    onPressed: onForget,
                    tooltip: state.cardIsToy
                        ? 'Disconnect from the toy'
                        : 'Forget this card',
                    icon: const Icon(Icons.link_off),
                  ),
                ],
              ],
            ),
            if (!state.cardIsToy) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: onConnectToy,
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('Connect to the toy instead'),
              ),
              const SizedBox(height: 8),
              Text(
                'Hold the language button and press volume up on the toy, '
                'then tap this — the card can stay where it is.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.progress});

  final SyncProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Writing', style: theme.textTheme.titleSmall),
                Text(
                  '${progress.done} / ${progress.total}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progress.fraction,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              progress.current,
              style: monoStyle(context, size: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              '${formatBytes(progress.bytesDone)} of ${formatBytes(progress.bytesTotal)} · '
              'keep the reader plugged in',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _Tone { warning, error }

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.tone,
    required this.title,
    required this.message,
  });

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
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
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

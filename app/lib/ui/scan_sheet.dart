/// Holding the phone against a tag.
///
/// The sheet stays open so a whole book can be tagged in one pass: each new UID
/// is added to the project straight away, named after itself, and listed here to
/// be opened and given a voice.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nfc_manager/nfc_manager.dart';

import '../app_state.dart';
import '../model/project.dart';
import '../model/uid.dart';
import '../nfc/tag_scanner.dart';
import 'tag_detail_page.dart';
import 'theme.dart';

Future<void> showScanSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _ScanSheet(),
  );
}

class _ScanSheet extends StatefulWidget {
  const _ScanSheet();

  @override
  State<_ScanSheet> createState() => _ScanSheetState();
}

class _Seen {
  _Seen(this.tag, {required this.isNew});
  final BookieTag tag;
  final bool isNew;
}

class _ScanSheetState extends State<_ScanSheet> {
  final _scanner = TagScanner();
  StreamSubscription<String>? _subscription;

  NfcAvailability? _availability;
  final List<_Seen> _seen = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _scanner.stop();
    super.dispose();
  }

  Future<void> _begin() async {
    final availability = await TagScanner.availability();
    if (!mounted) return;
    setState(() => _availability = availability);
    if (availability != NfcAvailability.enabled) return;

    _subscription = _scanner
        .scan(prompt: 'Hold your phone against the tag on the page.')
        .listen(
          _onUid,
          onError: (Object e) {
            if (mounted) setState(() => _error = '$e');
          },
        );
  }

  Future<void> _onUid(String uid) async {
    final workspace = AppScope.read(context).workspace;
    if (_seen.any((s) => s.tag.uid == uid)) {
      await HapticFeedback.selectionClick();
      return;
    }

    final existing = workspace.project.tagByUid(uid);
    final tag = existing ?? await workspace.addTag(uid);
    await HapticFeedback.mediumImpact();
    if (!mounted) return;
    setState(() => _seen.insert(0, _Seen(tag, isNew: existing == null)));
  }

  Future<void> _addByHand() async {
    final controller = TextEditingController();
    final uid = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enter a UID'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Open the serial monitor and type "uid", then copy what it prints. '
              'Separators do not matter.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(hintText: '04A224AA5C6180'),
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

    final clean = normaliseUid(uid ?? '');
    if (clean.length < 8) {
      if (clean.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That is too short to be a tag UID.')),
        );
      }
      return;
    }
    await _onUid(clean);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),
            _Status(
              availability: _availability,
              error: _error,
              scanning: _scanner.isRunning,
            ),
            const SizedBox(height: 24),

            if (_seen.isNotEmpty)
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _seen.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final seen = _seen[i];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundColor: seen.isNew
                            ? scheme.primary.withValues(alpha: 0.15)
                            : scheme.surfaceContainerHighest,
                        child: Icon(
                          seen.isNew ? Icons.add : Icons.check,
                          size: 18,
                          color: seen.isNew
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                      title: Text(seen.tag.displayName),
                      subtitle: Text(
                        seen.isNew
                            ? 'New tag · ${prettyUid(seen.tag.uid)}'
                            : '${seen.tag.clips.length} clip(s) · ${prettyUid(seen.tag.uid)}',
                        style: monoStyle(context, size: 11),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        await _scanner.stop();
                        if (!context.mounted) return;
                        Navigator.of(context).pop();
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => TagDetailPage(uid: seen.tag.uid),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),

            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _addByHand,
                    icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
                    label: const Text('Type a UID'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(_seen.isEmpty ? 'Cancel' : 'Done'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({
    required this.availability,
    required this.error,
    required this.scanning,
  });

  final NfcAvailability? availability;
  final String? error;
  final bool scanning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (
      IconData icon,
      String title,
      String message,
      bool pulse,
    ) = switch (availability) {
      null => (
        Icons.hourglass_empty,
        'Starting…',
        'Waking the reader up.',
        false,
      ),
      NfcAvailability.enabled when error != null => (
        Icons.error_outline,
        'The reader stopped',
        error!,
        false,
      ),
      NfcAvailability.enabled => (
        Icons.nfc,
        'Ready',
        'Hold the top of your phone against the tag. Keep going for as many '
            'tags as you like.',
        true,
      ),
      NfcAvailability.disabled => (
        Icons.nfc,
        'NFC is switched off',
        'Turn NFC on in system settings, or type the UID from the serial monitor.',
        false,
      ),
      NfcAvailability.unsupported => (
        Icons.no_cell_outlined,
        'No NFC on this phone',
        'You can still add tags by typing the UID that "uid" prints in the '
            'serial monitor.',
        false,
      ),
    };

    return Column(
      children: [
        _Pulse(
          active: pulse,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: pulse
                  ? scheme.primary.withValues(alpha: 0.13)
                  : scheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              size: 28,
              color: pulse ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(_Pulse old) {
    super.didUpdateWidget(old);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    final scheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 64 + 56 * t,
              height: 64 + 56 * t,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: scheme.primary.withValues(alpha: (1 - t) * 0.35),
                ),
              ),
            ),
            child!,
          ],
        );
      },
      child: widget.child,
    );
  }
}

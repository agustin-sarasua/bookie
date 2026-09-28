/// The record-a-clip sheet.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../../audio/clip_recorder.dart';
import 'format.dart';

class RecordResult {
  const RecordResult(this.file, this.duration);
  final File file;
  final Duration duration;
}

/// Returns the take to keep, or null if the sheet was dismissed. A discarded
/// take deletes its own temp file on the way out.
Future<RecordResult?> showRecordSheet(
  BuildContext context, {
  required String title,
  String? subtitle,
}) {
  return showModalBottomSheet<RecordResult>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => _RecordSheet(title: title, subtitle: subtitle),
  );
}

class _RecordSheet extends StatefulWidget {
  const _RecordSheet({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  State<_RecordSheet> createState() => _RecordSheetState();
}

enum _Phase { idle, recording, paused, denied }

class _RecordSheetState extends State<_RecordSheet> {
  final _recorder = ClipRecorder();

  _Phase _phase = _Phase.idle;
  Duration _elapsed = Duration.zero;
  double _level = 0;
  Timer? _ticker;
  StreamSubscription<Amplitude>? _levels;
  String? _error;

  @override
  void dispose() {
    _ticker?.cancel();
    _levels?.cancel();
    _recorder.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!await _recorder.hasPermission()) {
      setState(() => _phase = _Phase.denied);
      return;
    }
    try {
      await _recorder.start();
    } on Object catch (e) {
      setState(() => _error = '$e');
      return;
    }
    _levels = _recorder.levels().listen((amplitude) {
      // dBFS, so roughly -45 (a quiet room) to 0 (clipping).
      final normalised = ((amplitude.current + 45) / 45).clamp(0.0, 1.0);
      if (mounted) setState(() => _level = normalised);
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() => _elapsed = _recorder.elapsed);
    });
    setState(() {
      _phase = _Phase.recording;
      _error = null;
    });
  }

  Future<void> _togglePause() async {
    if (_phase == _Phase.recording) {
      await _recorder.pause();
      setState(() => _phase = _Phase.paused);
    } else {
      await _recorder.resume();
      setState(() => _phase = _Phase.recording);
    }
  }

  Future<void> _finish() async {
    _ticker?.cancel();
    await _levels?.cancel();
    final take = await _recorder.stop();
    if (!mounted) return;
    if (take == null) {
      setState(() {
        _phase = _Phase.idle;
        _elapsed = Duration.zero;
        _error = 'That take was empty — nothing was recorded.';
      });
      return;
    }
    Navigator.of(context).pop(RecordResult(take.file, take.duration));
  }

  Future<void> _cancel() async {
    _ticker?.cancel();
    await _levels?.cancel();
    await _recorder.cancel();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final recording = _phase == _Phase.recording;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
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
            const SizedBox(height: 20),
            Text(widget.title, style: theme.textTheme.titleMedium),
            if (widget.subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                widget.subtitle!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 28),

            _Meter(level: recording ? _level : 0, active: recording),
            const SizedBox(height: 20),

            Text(
              formatDuration(_elapsed),
              style: theme.textTheme.displaySmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w300,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Mono · ${recordingSampleRate ~/ 1000}.05 kHz · 16-bit WAV',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),

            if (_phase == _Phase.denied) ...[
              const SizedBox(height: 16),
              Text(
                'The microphone permission was declined. Grant it in Settings and try again.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],

            const SizedBox(height: 28),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _cancel,
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                if (_phase == _Phase.idle || _phase == _Phase.denied)
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _start,
                      icon: const Icon(Icons.fiber_manual_record, size: 16),
                      label: const Text('Record'),
                    ),
                  )
                else ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _togglePause,
                      icon: Icon(
                        recording ? Icons.pause : Icons.play_arrow,
                        size: 18,
                      ),
                      label: Text(recording ? 'Pause' : 'Resume'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _elapsed.inMilliseconds < 300 ? null : _finish,
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Use'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A row of bars that lean on the input level — enough to tell you the
/// microphone is hearing you, which is the only question at this point.
class _Meter extends StatelessWidget {
  const _Meter({required this.level, required this.active});

  final double level;
  final bool active;

  static const _bars = 21;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 56,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(_bars, (i) {
          // Tallest in the middle, so it reads as a voice rather than a chart.
          final distance = (i - (_bars - 1) / 2).abs() / ((_bars - 1) / 2);
          final shape = 1 - (distance * distance) * 0.75;
          final height = active
              ? (6 + level * 48 * shape).clamp(6.0, 56.0)
              : 6.0;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            width: 5,
            height: height,
            margin: const EdgeInsets.symmetric(horizontal: 2.5),
            decoration: BoxDecoration(
              color: active
                  ? Color.lerp(
                      scheme.primary,
                      scheme.error,
                      level > 0.92 ? 1 : 0,
                    )
                  : scheme.outlineVariant,
              borderRadius: BorderRadius.circular(3),
            ),
          );
        }),
      ),
    );
  }
}

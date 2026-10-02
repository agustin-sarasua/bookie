/// Recasting one speaker: pick another voice, rewrite their direction, and
/// hear the result before committing to it.
library;

import 'package:flutter/material.dart';

import '../../ai/story.dart';
import '../../ai/story_service.dart';
import '../../ai/voices.dart';
import '../../audio/clip_player.dart';
import 'story_widgets.dart';

/// Returns true when [member] was changed (and the caller should save).
Future<bool?> showCastSheet(
  BuildContext context, {
  required StoryJob job,
  required CastMember member,
  required Color color,
  required Set<String> taken,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _CastSheet(job: job, member: member, color: color, taken: taken),
  );
}

class _CastSheet extends StatefulWidget {
  const _CastSheet({required this.job, required this.member, required this.color, required this.taken});
  final StoryJob job;
  final CastMember member;
  final Color color;
  final Set<String> taken;

  @override
  State<_CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<_CastSheet> {
  final _player = ClipPlayer();
  late String _voice = widget.member.voice;
  late final _style = TextEditingController(text: widget.member.style);
  VoiceGender? _filter;
  String? _loadingVoice;

  @override
  void dispose() {
    _player.dispose();
    _style.dispose();
    super.dispose();
  }

  CastMember _draft(String voice) => CastMember(
    id: widget.member.id,
    name: widget.member.name,
    description: widget.member.description,
    voice: voice,
    style: _style.text.trim(),
    isNarrator: widget.member.isNarrator,
  );

  Future<void> _hear(String voice) async {
    if (_loadingVoice != null) return;
    setState(() => _loadingVoice = voice);
    final file = await widget.job.sample(_draft(voice));
    if (!mounted) return;
    setState(() => _loadingVoice = null);
    if (file != null) {
      await _player.toggle(file);
    } else if (widget.job.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(widget.job.error!)));
      widget.job.clearError();
    }
  }

  void _done() {
    final style = _style.text.trim();
    final changed = _voice != widget.member.voice || style != widget.member.style;
    widget.member
      ..voice = _voice
      ..style = style;
    Navigator.pop(context, changed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final voices = storyVoices.where((v) => _filter == null || v.gender == _filter).toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  SpeakerAvatar(member: widget.member, color: widget.color, size: 52),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.member.name, style: theme.textTheme.titleLarge),
                        if (widget.member.description.isNotEmpty)
                          Text(
                            widget.member.description,
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                children: [
                  const FieldLabel('How they sound'),
                  TextField(
                    controller: _style,
                    minLines: 2,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'e.g. "A slow, sleepy, rumbling old bear who yawns a lot"',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Expanded(child: FieldLabel('Voice')),
                      SegmentedButton<VoiceGender?>(
                        segments: const [
                          ButtonSegment(value: null, label: Text('All')),
                          ButtonSegment(value: VoiceGender.female, label: Text('Female')),
                          ButtonSegment(value: VoiceGender.male, label: Text('Male')),
                        ],
                        selected: {_filter},
                        showSelectedIcon: false,
                        style: const ButtonStyle(visualDensity: VisualDensity.compact),
                        onSelectionChanged: (s) => setState(() => _filter = s.first),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  AnimatedBuilder(
                    animation: _player,
                    builder: (context, _) => Column(
                      children: [
                        for (final v in voices)
                          _VoiceRow(
                            voice: v,
                            selected: v.name == _voice,
                            takenByOther: widget.taken.contains(v.name),
                            loading: _loadingVoice == v.name,
                            playing: _player.playingPath?.contains('-${v.name}-') ?? false,
                            color: widget.color,
                            onSelect: () => setState(() => _voice = v.name),
                            onHear: () => _hear(v.name),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: FilledButton(onPressed: _done, child: const Text('Done')),
            ),
          ],
        ),
      ),
    );
  }
}

class _VoiceRow extends StatelessWidget {
  const _VoiceRow({
    required this.voice,
    required this.selected,
    required this.takenByOther,
    required this.loading,
    required this.playing,
    required this.color,
    required this.onSelect,
    required this.onHear,
  });

  final StoryVoice voice;
  final bool selected;
  final bool takenByOther;
  final bool loading;
  final bool playing;
  final Color color;
  final VoidCallback onSelect;
  final VoidCallback onHear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: selected ? color.withValues(alpha: 0.12) : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? color : Colors.transparent, width: 1.5),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onSelect,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  color: selected ? color : scheme.outline,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(voice.name, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                      Text(
                        '${voice.tone} · ${voice.gender.name}${takenByOther ? ' · used by another speaker' : ''}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: takenByOther ? scheme.tertiary : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (loading)
                  const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else
                  IconButton(
                    tooltip: 'Hear ${voice.name}',
                    onPressed: onHear,
                    icon: Icon(playing ? Icons.volume_up_rounded : Icons.play_circle_outline_rounded),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The pieces the story studio is built from.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../ai/story.dart';
import '../../ai/story_service.dart';
import '../../ai/voices.dart';
import '../../audio/clip_player.dart';
import '../../model/project.dart';
import '../theme.dart';
import '../widgets/format.dart';

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
      ],
    ),
  );
  return ok == true;
}

class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// The one big "make it happen" button, in the story gradient.
class GradientButton extends StatelessWidget {
  const GradientButton({super.key, required this.onPressed, required this.icon, required this.label});

  final VoidCallback? onPressed;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: storyGradient(scheme),
          borderRadius: BorderRadius.circular(16),
          boxShadow: enabled
              ? [BoxShadow(color: const Color(0xFFD9607A).withValues(alpha: 0.35), blurRadius: 16, offset: const Offset(0, 6))]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onPressed,
            child: SizedBox(
              height: 56,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: Colors.white),
                  const SizedBox(width: 10),
                  Text(
                    label,
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GlassPill extends StatelessWidget {
  const GlassPill({super.key, required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.2),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: Colors.white),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
      ],
    ),
  );
}

/// What is happening right now, while the assistant works.
class WorkingCard extends StatefulWidget {
  const WorkingCard({super.key, required this.job});
  final StoryJob job;

  @override
  State<WorkingCard> createState() => _WorkingCardState();
}

class _WorkingCardState extends State<WorkingCard> with SingleTickerProviderStateMixin {
  late final _spin = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final job = widget.job;
    final lang = job.activeLanguage == null ? '' : languageName(job.activeLanguage!);

    final (title, detail) = switch (job.phase) {
      StoryPhase.writing => (
        'Reading the pages…',
        'Finding the characters, casting their voices and writing the story in $lang.',
      ),
      StoryPhase.translating => ('Retelling it in $lang…', 'Same story, same voices, a new language.'),
      StoryPhase.narrating => (
        'Recording the voices in $lang…',
        job.progressLabel.isEmpty ? 'Warming up the narrator.' : job.progressLabel,
      ),
      StoryPhase.idle => ('', ''),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                RotationTransition(
                  turns: _spin,
                  child: ShaderMask(
                    shaderCallback: (r) => storyGradient(theme.colorScheme).createShader(r),
                    child: const Icon(Icons.auto_awesome, color: Colors.white, size: 28),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(value: job.progress, minHeight: 6),
            ),
          ],
        ),
      ),
    );
  }
}

class ErrorCard extends StatelessWidget {
  const ErrorCard({super.key, required this.message, required this.onDismiss});
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: TextStyle(color: scheme.onErrorContainer))),
          IconButton(
            onPressed: onDismiss,
            icon: Icon(Icons.close_rounded, color: scheme.onErrorContainer),
            tooltip: 'Dismiss',
          ),
        ],
      ),
    );
  }
}

class PageThumb extends StatelessWidget {
  const PageThumb({super.key, required this.file, required this.number, required this.onOpen});
  final File file;
  final int number;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: GestureDetector(
        onTap: onOpen,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: [
              Image.file(
                file,
                width: 94,
                height: 126,
                fit: BoxFit.cover,
                cacheWidth: 240,
                errorBuilder: (_, _, _) => Container(
                  width: 94,
                  height: 126,
                  color: scheme.surfaceContainerHighest,
                  child: const Icon(Icons.broken_image_outlined),
                ),
              ),
              Positioned(
                left: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                  child: Text(
                    '$number',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A page, full screen. Pops `true` when the user removes it.
class PageViewer extends StatelessWidget {
  const PageViewer({super.key, required this.file, required this.number, required this.canRemove});
  final File file;
  final int number;
  final bool canRemove;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        foregroundColor: Colors.white,
        title: Text('Page $number', style: const TextStyle(color: Colors.white)),
        actions: [
          if (canRemove)
            TextButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.delete_outline, color: Colors.white),
              label: const Text('Remove', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: Center(child: InteractiveViewer(maxScale: 5, child: Image.file(file))),
    );
  }
}

/// A round badge with a speaker's initial, in their script colour.
class SpeakerAvatar extends StatelessWidget {
  const SpeakerAvatar({super.key, required this.member, required this.color, this.size = 44});
  final CastMember member;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
    child: member.isNarrator
        ? Icon(Icons.auto_stories_rounded, color: color, size: size * 0.46)
        : Text(
            member.name.isEmpty ? '?' : member.name.characters.first.toUpperCase(),
            style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: size * 0.4),
          ),
  );
}

class CastTile extends StatelessWidget {
  const CastTile({
    super.key,
    required this.member,
    required this.color,
    required this.lineCount,
    required this.player,
    required this.sampling,
    required this.onPreview,
    required this.onEdit,
  });

  final CastMember member;
  final Color color;
  final int lineCount;
  final ClipPlayer player;
  final bool sampling;
  final VoidCallback onPreview;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final voice = member.voiceInfo;
    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            SpeakerAvatar(member: member, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          member.name,
                          style: theme.textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Pill(
                        '${member.voice}${voice == null ? '' : ' · ${voice.tone}'}',
                        filled: true,
                        color: color,
                        icon: Icons.graphic_eq_rounded,
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    member.style.isNotEmpty ? member.style : member.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if (!member.isNarrator && lineCount == 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        'Appears, but does not speak',
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ),
                ],
              ),
            ),
            SamplePlayButton(player: player, sampling: sampling, onPressed: onPreview),
          ],
        ),
      ),
    );
  }
}

/// Plays a voice sample; spins while one is being made.
class SamplePlayButton extends StatelessWidget {
  const SamplePlayButton({super.key, required this.player, required this.sampling, required this.onPressed});
  final ClipPlayer player;
  final bool sampling;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (sampling) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final playing = player.playingPath?.contains('${Platform.pathSeparator}samples${Platform.pathSeparator}') ?? false;
        return IconButton(
          tooltip: 'Hear this voice',
          onPressed: onPressed,
          icon: Icon(playing ? Icons.volume_up_rounded : Icons.play_circle_outline_rounded),
        );
      },
    );
  }
}

/// One language of the story: its title, whether the tag has the audio, and
/// what can be done about it.
class LanguageStoryRow extends StatelessWidget {
  const LanguageStoryRow({
    super.key,
    required this.language,
    required this.script,
    required this.clip,
    required this.file,
    required this.player,
    required this.stale,
    required this.working,
    required this.locked,
    required this.onCreate,
    required this.onRenarrate,
    required this.onReadScript,
  });

  final String language;
  final StoryScript? script;
  final Clip? clip;
  final File? file;
  final ClipPlayer player;
  final bool stale;
  final bool working;
  final bool locked;
  final VoidCallback onCreate;
  final VoidCallback onRenarrate;
  final VoidCallback? onReadScript;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final narrated = script?.narration != null && clip?.source == ClipSource.generated;
    final replacedByUser = script?.narration != null && clip != null && clip!.source != ClipSource.generated;

    final String status;
    Color statusColor = scheme.onSurfaceVariant;
    if (working) {
      status = 'Working on it…';
      statusColor = scheme.primary;
    } else if (narrated && stale) {
      status = 'Voices or words changed — record again to update';
      statusColor = scheme.tertiary;
    } else if (narrated) {
      status = '${formatMillis(clip!.durationMs)} · ready on the tag';
    } else if (replacedByUser) {
      status = 'The tag plays your own ${clip!.source.name} clip';
    } else if (script != null) {
      status = 'Script written · no audio yet';
    } else {
      status = 'Not in this language yet';
    }

    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final playing = file != null && player.playingPath == file!.path;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: narrated ? scheme.primary.withValues(alpha: 0.13) : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  language,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: language.length > 3 ? 11 : 13,
                    color: narrated ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      script?.title.isNotEmpty == true ? script!.title : languageName(language),
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(status, style: theme.textTheme.bodySmall?.copyWith(color: statusColor)),
                  ],
                ),
              ),
              if (clip != null && file != null)
                IconButton(
                  onPressed: () => player.toggle(file!),
                  tooltip: playing ? 'Stop' : 'Play',
                  icon: Icon(playing ? Icons.stop_circle_outlined : Icons.play_circle_fill_rounded),
                  color: scheme.primary,
                  iconSize: 30,
                ),
              if (!narrated && !working && !replacedByUser)
                FilledButton.tonal(
                  onPressed: locked ? null : (script == null ? onCreate : onRenarrate),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
                  child: Text(script == null ? 'Create' : 'Record'),
                )
              else
                MenuAnchor(
                  menuChildren: [
                    if (onReadScript != null)
                      MenuItemButton(
                        leadingIcon: const Icon(Icons.article_outlined, size: 20),
                        onPressed: onReadScript,
                        child: const Text('Read & edit the script'),
                      ),
                    MenuItemButton(
                      leadingIcon: const Icon(Icons.refresh_rounded, size: 20),
                      onPressed: locked ? null : onRenarrate,
                      child: Text(replacedByUser ? 'Use the AI story again' : 'Record the voices again'),
                    ),
                  ],
                  builder: (context, controller, _) => IconButton(
                    onPressed: () => controller.isOpen ? controller.close() : controller.open(),
                    icon: Badge(
                      isLabelVisible: stale,
                      smallSize: 8,
                      child: const Icon(Icons.more_horiz),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

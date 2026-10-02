/// One row of "here is a slot, here is what is in it".
///
/// Used both for a tag's clip in a language and for the four `/system` prompts,
/// because they are the same thing from the card's point of view.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../audio/clip_player.dart';
import '../../model/project.dart';
import 'format.dart';

class ClipRow extends StatelessWidget {
  const ClipRow({
    super.key,
    required this.label,
    required this.player,
    this.note,
    this.clip,
    this.file,
    required this.onRecord,
    required this.onImport,
    this.onGenerate,
    this.onRemove,
    this.highlight = false,
  });

  final String label;
  final String? note;
  final Clip? clip;
  final File? file;
  final ClipPlayer player;
  final VoidCallback onRecord;
  final VoidCallback onImport;

  /// The story assistant, when this slot can use it.
  final VoidCallback? onGenerate;
  final VoidCallback? onRemove;

  /// Marks the slot as the one that matters — the fallback language for
  /// `/system` clips, say.
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final has = clip != null;

    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final playing = file != null && player.playingPath == file!.path;

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              _Slug(label: label, filled: has, highlight: highlight),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      has ? clip!.fileName : 'Nothing yet',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: has ? FontWeight.w500 : FontWeight.w400,
                        color: has ? null : scheme.onSurfaceVariant,
                        fontStyle: has ? null : FontStyle.italic,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      has
                          ? '${formatMillis(clip!.durationMs)} · ${formatBytes(clip!.bytes)}'
                                '${switch (clip!.source) {
                                  ClipSource.recorded => ' · recorded',
                                  ClipSource.generated => ' · AI story',
                                  ClipSource.imported => '',
                                }}'
                          : (note ?? 'Record or import a clip'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (has && file != null)
                IconButton(
                  onPressed: () => player.toggle(file!),
                  tooltip: playing ? 'Stop' : 'Play',
                  icon: Icon(
                    playing
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline,
                  ),
                  color: playing ? scheme.primary : null,
                ),
              MenuAnchor(
                menuChildren: [
                  if (onGenerate != null)
                    MenuItemButton(
                      leadingIcon: const Icon(Icons.auto_awesome, size: 20),
                      onPressed: onGenerate,
                      child: const Text('Create with AI'),
                    ),
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.mic_none, size: 20),
                    onPressed: onRecord,
                    child: Text(has ? 'Record again' : 'Record'),
                  ),
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.folder_open, size: 20),
                    onPressed: onImport,
                    child: Text(has ? 'Replace with a file' : 'Import a file'),
                  ),
                  if (has && onRemove != null)
                    MenuItemButton(
                      leadingIcon: Icon(
                        Icons.delete_outline,
                        size: 20,
                        color: scheme.error,
                      ),
                      onPressed: onRemove,
                      child: Text(
                        'Remove',
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                ],
                builder: (context, controller, _) => IconButton(
                  onPressed: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                  icon: Icon(has ? Icons.more_horiz : Icons.add_circle_outline),
                  tooltip: has ? 'Change' : 'Add a clip',
                  color: has ? null : scheme.primary,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The little square that carries the language code or the prompt's name.
class _Slug extends StatelessWidget {
  const _Slug({
    required this.label,
    required this.filled,
    required this.highlight,
  });

  final String label;
  final bool filled;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final short = label.length <= 4;
    return Container(
      width: short ? 40 : null,
      height: 40,
      padding: short ? null : const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: filled
            ? scheme.primary.withValues(alpha: 0.13)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: highlight
            ? Border.all(color: scheme.primary.withValues(alpha: 0.5))
            : null,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: short ? 13 : 12,
          fontWeight: FontWeight.w600,
          color: filled ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

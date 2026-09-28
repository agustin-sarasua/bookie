/// Getting audio from a microphone or the file system, and checking that the
/// toy will actually be able to play it.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../audio/clip_player.dart';
import '../audio/wav.dart';
import '../model/project.dart';
import 'widgets/record_sheet.dart';

class PickedClip {
  const PickedClip({
    required this.file,
    required this.source,
    this.durationMs,
    this.originalName,
  });

  final File file;
  final ClipSource source;
  final int? durationMs;
  final String? originalName;

  /// A recorded take is ours and lives in the temp directory; an imported file
  /// belongs to the user, or to the picker's cache, and is left alone.
  bool get isTemporary => source == ClipSource.recorded;

  /// Call once the workspace has its own copy.
  Future<void> discard() async {
    if (!isTemporary) return;
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // The temp directory is the OS's problem from here.
    }
  }
}

Future<PickedClip?> recordClip(
  BuildContext context, {
  required String title,
  String? subtitle,
}) async {
  final take = await showRecordSheet(context, title: title, subtitle: subtitle);
  if (take == null) return null;
  return PickedClip(
    file: take.file,
    source: ClipSource.recorded,
    durationMs: take.duration.inMilliseconds,
  );
}

Future<PickedClip?> importClip(BuildContext context) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['mp3', 'wav'],
    dialogTitle: 'Pick an mp3 or wav',
  );
  final path = result?.files.single.path;
  if (path == null) return null;

  final file = File(path);
  if (!context.mounted) return null;

  final complaint = await _inspect(file);
  if (complaint != null) {
    if (!context.mounted) return null;
    final proceed = await _confirmAnyway(context, complaint);
    if (proceed != true) return null;
  }

  final duration = await ClipPlayer.probe(file);
  return PickedClip(
    file: file,
    source: ClipSource.imported,
    durationMs: duration?.inMilliseconds,
    originalName: p.basename(path),
  );
}

/// What `audio.cpp` can and cannot decode, checked before it reaches the card
/// rather than discovered as silence from the toy.
Future<String?> _inspect(File file) async {
  final ext = p.extension(file.path).replaceFirst('.', '').toLowerCase();
  if (ext != 'wav' && ext != 'mp3') {
    return 'The toy only reads .mp3 and .wav — this is a .$ext.';
  }
  if (ext == 'mp3') return null;

  final bytes = await file.readAsBytes();
  final info = readWavHeader(bytes);
  if (info == null) {
    return 'This WAV is not plain PCM. The toy decodes 8- or 16-bit PCM only, '
        'so it would play as silence or noise.';
  }
  if (info.bitsPerSample != 8 && info.bitsPerSample != 16) {
    return 'This WAV is ${info.bitsPerSample}-bit. The toy reads 8- or 16-bit PCM.';
  }
  if (info.channels > 2) {
    return 'This WAV has ${info.channels} channels. The toy plays mono or stereo.';
  }
  if (info.sampleRate > 48000) {
    return 'This WAV is ${(info.sampleRate / 1000).toStringAsFixed(1)} kHz. That will play, '
        'but it fills the card fast — 22.05 kHz mono is what the toy is tuned for.';
  }
  return null;
}

Future<bool?> _confirmAnyway(BuildContext context, String complaint) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded),
      title: const Text('The toy may not play this'),
      content: Text(complaint),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Pick another'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Use it anyway'),
        ),
      ],
    ),
  );
}

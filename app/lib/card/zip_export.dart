/// The fallback for when there is no card reader on the phone.
///
/// Produces a zip whose contents are the card's root, so unzipping it onto a
/// freshly formatted FAT32 card is the whole job — the same thing
/// `make card CARD=/Volumes/BOOKIE` does from a Mac.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../model/project.dart';
import '../model/tags_csv.dart';
import '../store/workspace.dart';

class ZipExport {
  /// Build the archive and hand it to the share sheet. Returns the file, or
  /// null if the user dismissed the sheet.
  static Future<File> build(Workspace workspace) async {
    final tmp = await getTemporaryDirectory();
    final staging = Directory(p.join(tmp.path, 'card-export'));
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);

    final project = workspace.project;

    for (final entry in workspace.desiredFiles().entries) {
      if (!await entry.value.exists()) continue;
      final dest = File(p.join(staging.path, entry.key.substring(1)));
      await dest.parent.create(recursive: true);
      await entry.value.copy(dest.path);
    }

    await File(
      p.join(staging.path, 'tags.csv'),
    ).writeAsString(renderTagsCsv(project));
    await File(p.join(staging.path, 'bookie.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(project.toJson()),
    );
    await File(
      p.join(staging.path, 'README.txt'),
    ).writeAsString(_readme(project));

    // Empty language folders would vanish into the zip otherwise, and the
    // firmware decides which languages exist by listing /audio.
    for (final lang in project.languages) {
      await Directory(
        p.join(staging.path, 'audio', lang),
      ).create(recursive: true);
    }

    final zipPath = p.join(tmp.path, 'bookie-card.zip');
    final zip = File(zipPath);
    if (await zip.exists()) await zip.delete();

    final encoder = ZipFileEncoder();
    encoder.create(zipPath);
    await encoder.addDirectory(staging, includeDirName: false);
    await encoder.close();

    await staging.delete(recursive: true);
    return zip;
  }

  static Future<void> share(File zip) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(zip.path, mimeType: 'application/zip')],
        fileNameOverrides: const ['bookie-card.zip'],
        subject: 'Bookie card',
        text: 'Unzip onto the root of a FAT32 microSD card.',
      ),
    );
  }

  static String _readme(Project project) {
    final clips = project.tags.fold<int>(0, (sum, t) => sum + t.clips.length);
    return '''
Bookie card
===========

Unzip the contents of this archive onto the root of a FAT32 microSD card, so
the card ends up looking like:

  /audio/${project.languages.first}/...
  /system/${project.languages.first}/...
  /tags.csv
  /bookie.json

  ${project.tags.length} tag(s), ${project.languages.length} language(s), $clips clip(s).
  Languages: ${project.languages.join(', ')}

tags.csv is what the toy reads. bookie.json is written by Bookie Studio so the
card can be opened again in the app with its labels intact; the firmware never
looks at it, and deleting it costs you nothing but those labels. You can delete
this README too.
''';
  }
}

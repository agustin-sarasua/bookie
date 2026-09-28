/// Reading and writing `/tags.csv`.
///
/// The parser deliberately mirrors `library.cpp::reloadTags()`: trim the line,
/// skip blanks and `#` comments, split on the *first* comma, normalise the UID,
/// trim the name, and drop the entry if either half came out empty. If this app
/// accepts a line the firmware would ignore, the card lies to you.
///
/// Note what the firmware does *not* do: everything after the first comma is
/// the name, trimmed. There are no trailing comments — `04AA,bear  # page 3`
/// would have the toy look for `bear  # page 3.mp3`. So data lines here carry
/// nothing but `UID,name`, and anything we want to say goes in the header or on
/// its own `#` line.
library;

import 'project.dart';
import 'uid.dart';

class CsvTag {
  const CsvTag(this.uid, this.name);
  final String uid;
  final String name;
}

List<CsvTag> parseTagsCsv(String contents) {
  final out = <CsvTag>[];
  for (var line in contents.split('\n')) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final comma = line.indexOf(',');
    if (comma <= 0) continue;
    final uid = normaliseUid(line.substring(0, comma));
    final name = line.substring(comma + 1).trim();
    if (uid.isEmpty || name.isEmpty) continue;
    out.add(CsvTag(uid, name));
  }
  return out;
}

String renderTagsCsv(Project project) {
  final buffer = StringBuffer()
    ..writeln('# Bookie tag map — one line per tag: UID,name')
    ..writeln('#')
    ..writeln('# Written by Bookie Studio. The name is the file name (without')
    ..writeln('# extension) looked up inside every /audio/<lang>/ folder.')
    ..writeln('# Everything after the first comma is the name, so no trailing')
    ..writeln('# comments on these lines.')
    ..writeln('#');

  final sorted = [...project.tags]..sort((a, b) => a.name.compareTo(b.name));
  for (final tag in sorted) {
    final languages = project.languages.where(tag.clips.containsKey).toList();
    buffer.writeln(
      languages.isEmpty
          ? '# ${tag.name}: no clip on the card yet'
          : '# ${tag.name}: ${languages.join(' ')}',
    );
    buffer.writeln('${tag.uid},${tag.name}');
  }
  return buffer.toString();
}

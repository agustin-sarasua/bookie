/// Tag UIDs, in the one form the firmware understands.
///
/// `library.cpp::normaliseUid()` keeps the hex digits of a line in `tags.csv`
/// and upper-cases them, so `04:a2:24:aa` and `04A224AA` are the same tag. We
/// do exactly that, and store the normalised form everywhere.
library;

import 'dart:typed_data';

String normaliseUid(String raw) {
  final out = StringBuffer();
  for (final unit in raw.codeUnits) {
    final c = String.fromCharCode(unit);
    if (_isHexDigit(c)) out.write(c.toUpperCase());
  }
  return out.toString();
}

bool _isHexDigit(String c) =>
    (c.compareTo('0') >= 0 && c.compareTo('9') <= 0) ||
    (c.toLowerCase().compareTo('a') >= 0 &&
        c.toLowerCase().compareTo('f') <= 0);

/// What the PN532 prints and what we store: `04A224AA5C6180`.
String uidFromBytes(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join();

/// Same UID, easier on the eye: `04:A2:24:AA:5C:61:80`.
String prettyUid(String uid) {
  final pairs = <String>[];
  for (var i = 0; i + 1 < uid.length; i += 2) {
    pairs.add(uid.substring(i, i + 2));
  }
  return pairs.join(':');
}

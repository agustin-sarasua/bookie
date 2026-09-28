// What is on the card: which languages exist, and which file a tag maps to.
//
// Layout:
//   /audio/<lang>/<name>.mp3|wav   one clip per tag
//   /system/<lang>/<clip>.mp3|wav  spoken prompts (ready, language, unknown, low-battery)
//   /tags.csv                      optional "uid,name" lines so files can have readable names
#pragma once

#include <Arduino.h>
#include <vector>

namespace library {

bool begin();

const std::vector<String> &languages();
bool hasLanguage(const String &code);
String nextLanguage(const String &current);

void reloadTags();
size_t tagCount();
String tagName(const String &uid);  // "" when the tag is not listed

// Absolute path of the clip for this tag in this language, or "" if missing.
String trackFor(const String &uid, const String &lang);

// Absolute path of a system prompt, or "" if that language has no such clip.
String systemClip(const String &lang, const char *clip);

}  // namespace library

#include "library.h"

#include <SD.h>
#include <algorithm>

#include "config.h"
#include "log.h"
#include "sdfs.h"

namespace library {
namespace {

struct TagEntry {
  String uid;
  String name;
};

std::vector<String> g_languages;
std::vector<TagEntry> g_tags;

String normaliseUid(const String &uid) {
  String out;
  out.reserve(uid.length());
  for (size_t i = 0; i < uid.length(); i++) {
    const char c = uid[i];
    if (isxdigit((unsigned char)c)) {
      out += (char)toupper(c);
    }
  }
  return out;
}

// Same stem, either container. MP3 wins because that is what most people have.
String resolveStem(const String &stem) {
  const char *extensions[] = {".mp3", ".wav"};
  for (const char *ext : extensions) {
    const String candidate = stem + ext;
    if (sdfs::exists(candidate.c_str())) {
      return candidate;
    }
  }
  return String();
}

void scanLanguages() {
  g_languages.clear();

  sdfs::Guard guard;
  File dir = SD.open(DIR_AUDIO);
  if (!dir || !dir.isDirectory()) {
    LOGE("%s missing on the card", DIR_AUDIO);
    return;
  }
  for (File entry = dir.openNextFile(); entry; entry = dir.openNextFile()) {
    if (entry.isDirectory()) {
      String name = String(entry.name());
      const int slash = name.lastIndexOf('/');
      if (slash >= 0) {
        name = name.substring(slash + 1);
      }
      if (name.length() && !name.startsWith(".")) {
        g_languages.push_back(name);
      }
    }
    entry.close();
  }
  dir.close();

  std::sort(g_languages.begin(), g_languages.end(),
            [](const String &a, const String &b) { return strcmp(a.c_str(), b.c_str()) < 0; });
}

}  // namespace

bool begin() {
  scanLanguages();
  reloadTags();

  if (g_languages.empty()) {
    LOGE("no language folders under %s — the toy will have nothing to say", DIR_AUDIO);
    return false;
  }

  String list;
  for (const String &lang : g_languages) {
    list += lang + " ";
  }
  LOGI("languages: %s(%u tags named in %s)", list.c_str(), (unsigned)g_tags.size(), FILE_TAGS);
  return true;
}

const std::vector<String> &languages() { return g_languages; }

bool hasLanguage(const String &code) {
  return std::find(g_languages.begin(), g_languages.end(), code) != g_languages.end();
}

String nextLanguage(const String &current) {
  if (g_languages.empty()) {
    return current;
  }
  auto it = std::find(g_languages.begin(), g_languages.end(), current);
  if (it == g_languages.end() || ++it == g_languages.end()) {
    return g_languages.front();
  }
  return *it;
}

void reloadTags() {
  g_tags.clear();

  sdfs::Guard guard;
  File file = SD.open(FILE_TAGS);
  if (!file) {
    LOGD("%s not present, falling back to UID file names", FILE_TAGS);
    return;
  }
  while (file.available()) {
    String line = file.readStringUntil('\n');
    line.trim();
    if (line.length() == 0 || line.startsWith("#")) {
      continue;
    }
    const int comma = line.indexOf(',');
    if (comma <= 0) {
      continue;
    }
    TagEntry entry;
    entry.uid = normaliseUid(line.substring(0, comma));
    entry.name = line.substring(comma + 1);
    entry.name.trim();
    if (entry.uid.length() && entry.name.length()) {
      g_tags.push_back(entry);
    }
  }
  file.close();
}

size_t tagCount() { return g_tags.size(); }

String tagName(const String &uid) {
  const String key = normaliseUid(uid);
  for (const TagEntry &entry : g_tags) {
    if (entry.uid == key) {
      return entry.name;
    }
  }
  return String();
}

String trackFor(const String &uid, const String &lang) {
  const String key = normaliseUid(uid);
  const String name = tagName(key);
  const String base = String(DIR_AUDIO) + "/" + lang + "/";

  if (name.length()) {
    const String path = resolveStem(base + name);
    if (path.length()) {
      return path;
    }
    LOGD("tag %s is named '%s' but %s%s.mp3/.wav is missing", key.c_str(), name.c_str(),
         base.c_str(), name.c_str());
  }
  return resolveStem(base + key);  // unnamed tags simply use their UID as the file name
}

String systemClip(const String &lang, const char *clip) {
  const String path = resolveStem(String(DIR_SYSTEM) + "/" + lang + "/" + clip);
  if (path.length()) {
    return path;
  }
  return resolveStem(String(DIR_SYSTEM) + "/" + LANG_FALLBACK + "/" + clip);
}

}  // namespace library

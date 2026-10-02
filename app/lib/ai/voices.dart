/// The prebuilt Gemini TTS voices, and the language names the models are told.
///
/// Each character's voice is one of these plus a `style` — a sentence of
/// delivery direction the story model writes ("a squeaky, breathless little
/// mouse"). The voice gives the timbre; the style gives the character.
library;

enum VoiceGender { female, male }

class StoryVoice {
  const StoryVoice(this.name, this.tone, this.gender);

  /// The id the TTS model takes: `Kore`, `Puck`, …
  final String name;

  /// Google's one-word descriptor for it.
  final String tone;

  /// How it usually reads. The models do not enforce this; it is a hint for
  /// casting, so the grandmother does not get the gravelly baritone.
  final VoiceGender gender;
}

const storyVoices = <StoryVoice>[
  StoryVoice('Zephyr', 'Bright', VoiceGender.female),
  StoryVoice('Puck', 'Upbeat', VoiceGender.male),
  StoryVoice('Charon', 'Informative', VoiceGender.male),
  StoryVoice('Kore', 'Firm', VoiceGender.female),
  StoryVoice('Fenrir', 'Excitable', VoiceGender.male),
  StoryVoice('Leda', 'Youthful', VoiceGender.female),
  StoryVoice('Orus', 'Firm', VoiceGender.male),
  StoryVoice('Aoede', 'Breezy', VoiceGender.female),
  StoryVoice('Callirrhoe', 'Easy-going', VoiceGender.female),
  StoryVoice('Autonoe', 'Bright', VoiceGender.female),
  StoryVoice('Enceladus', 'Breathy', VoiceGender.male),
  StoryVoice('Iapetus', 'Clear', VoiceGender.male),
  StoryVoice('Umbriel', 'Easy-going', VoiceGender.male),
  StoryVoice('Algieba', 'Smooth', VoiceGender.male),
  StoryVoice('Despina', 'Smooth', VoiceGender.female),
  StoryVoice('Erinome', 'Clear', VoiceGender.female),
  StoryVoice('Algenib', 'Gravelly', VoiceGender.male),
  StoryVoice('Rasalgethi', 'Informative', VoiceGender.male),
  StoryVoice('Laomedeia', 'Upbeat', VoiceGender.female),
  StoryVoice('Achernar', 'Soft', VoiceGender.female),
  StoryVoice('Alnilam', 'Firm', VoiceGender.male),
  StoryVoice('Schedar', 'Even', VoiceGender.male),
  StoryVoice('Gacrux', 'Mature', VoiceGender.female),
  StoryVoice('Pulcherrima', 'Forward', VoiceGender.female),
  StoryVoice('Achird', 'Friendly', VoiceGender.male),
  StoryVoice('Zubenelgenubi', 'Casual', VoiceGender.male),
  StoryVoice('Vindemiatrix', 'Gentle', VoiceGender.female),
  StoryVoice('Sadachbia', 'Lively', VoiceGender.male),
  StoryVoice('Sadaltager', 'Knowledgeable', VoiceGender.male),
  StoryVoice('Sulafat', 'Warm', VoiceGender.female),
];

StoryVoice? voiceNamed(String? name) {
  if (name == null) return null;
  final key = name.trim().toLowerCase();
  for (final v in storyVoices) {
    if (v.name.toLowerCase() == key) return v;
  }
  return null;
}

/// Language folders are short codes the user typed — `en`, `es`, `pt-br`.
/// The models write better when told "Spanish" than "es", so the common ones
/// are spelled out; anything else is passed through and the model is trusted
/// to recognise it.
const _languageNames = <String, String>{
  'en': 'English',
  'en-us': 'American English',
  'en-gb': 'British English',
  'es': 'Spanish',
  'es-es': 'Spanish (Spain)',
  'es-mx': 'Mexican Spanish',
  'es-ar': 'Rioplatense Spanish',
  'es-uy': 'Rioplatense Spanish (Uruguay)',
  'fr': 'French',
  'de': 'German',
  'it': 'Italian',
  'pt': 'Portuguese',
  'pt-br': 'Brazilian Portuguese',
  'pt-pt': 'European Portuguese',
  'nl': 'Dutch',
  'ca': 'Catalan',
  'eu': 'Basque',
  'gl': 'Galician',
  'sv': 'Swedish',
  'no': 'Norwegian',
  'nb': 'Norwegian',
  'da': 'Danish',
  'fi': 'Finnish',
  'pl': 'Polish',
  'cs': 'Czech',
  'ro': 'Romanian',
  'hu': 'Hungarian',
  'el': 'Greek',
  'tr': 'Turkish',
  'ru': 'Russian',
  'uk': 'Ukrainian',
  'ar': 'Arabic',
  'he': 'Hebrew',
  'hi': 'Hindi',
  'bn': 'Bengali',
  'ja': 'Japanese',
  'ko': 'Korean',
  'zh': 'Mandarin Chinese',
  'id': 'Indonesian',
  'vi': 'Vietnamese',
  'th': 'Thai',
};

/// "Spanish", or the code itself when we do not know it.
String languageName(String code) => _languageNames[code.toLowerCase()] ?? code;

/// "Spanish (es)" — what the prompts say, so an unusual code still has context.
String languageForPrompt(String code) {
  final name = _languageNames[code.toLowerCase()];
  return name == null
      ? 'the language with code "$code"'
      : '$name ($code)';
}

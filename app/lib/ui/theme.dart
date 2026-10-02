import 'package:flutter/material.dart';

/// Warm paper and ink — it is a toy for a picture book, not a control panel.
const _seed = Color(0xFFB4632A);

ThemeData bookieTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: brightness == Brightness.light
        ? const Color(0xFFFDF8F3)
        : scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      color: brightness == Brightness.light
          ? Colors.white
          : scheme.surfaceContainerHigh,
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}

/// UIDs and file names are read character by character, so they get a face
/// where a 0 cannot be mistaken for an O.
const monoFamily = 'monospace';

TextStyle monoStyle(BuildContext context, {double size = 13, Color? color}) =>
    TextStyle(
      fontFamily: monoFamily,
      fontSize: size,
      letterSpacing: 0.2,
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
    );

/// The story assistant's accent: a dusk-to-ember sweep, so anything AI-made is
/// recognisable at a glance without shouting over the rest of the app.
LinearGradient storyGradient(ColorScheme scheme) => const LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF7B5CD6), Color(0xFFD9607A), Color(0xFFF0A04B)],
);

/// One colour per speaker in a script, stable by position in the cast — the
/// narrator first, in the app's own ink.
Color speakerColor(ColorScheme scheme, int index) {
  if (index == 0) return scheme.primary;
  const palette = [
    Color(0xFF3F8F6B),
    Color(0xFF7B5CD6),
    Color(0xFFCB4F72),
    Color(0xFF2F7FB5),
    Color(0xFFB88A1F),
    Color(0xFF8E5A3C),
    Color(0xFF4A6FA5),
    Color(0xFF9A4DB0),
  ];
  return palette[(index - 1) % palette.length];
}

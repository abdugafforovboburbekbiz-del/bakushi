/// Warm dark + red music-production theme + stem color map.
///
/// Color theory for "creation out of depression": calm, warm near-black
/// backgrounds (no pure black - every surface carries a red undertone)
/// and ONE hot crimson primary for energy and passion. Amber is the
/// warm secondary. Text is warm white, never cold blue-white.
library;

import 'package:flutter/material.dart';

/// Named theme tokens - the single source of truth for colors. UI code
/// must use these instead of hardcoded hexes.
abstract final class BakushiTokens {
  BakushiTokens._();

  // Warm near-black base (red undertone, never pure black).
  static const Color bg = Color(0xFF171113);
  static const Color panel = Color(0xFF201619);
  static const Color panel2 = Color(0xFF2A1C20);
  static const Color border = Color(0xFF3A262C);
  static const Color borderSoft = Color(0xFF2C1E23);

  // Brand: crimson primary + warm amber secondary.
  static const Color red = Color(0xFFFF4D57);
  static const Color redSoft = Color(0xFFFF7A82);
  static const Color amber = Color(0xFFFFB224);
  static const Color gold = Color(0xFFFFC53D);

  // Warm white text scale.
  static const Color text = Color(0xFFF5EFE9);
  static const Color textDim = Color(0xFFB8AAA3);
  static const Color textFaint = Color(0xFF7C6A64);

  // Semantic.
  static const Color danger = Color(0xFFFF5D5D);
  static const Color ok = Color(0xFF3DC98A);
}

/// Per-stem semantic colors, retuned to sit warm-compatible against the
/// dark red base.
class StemColors {
  StemColors._();

  static const Color vocals = Color(0xFFFF6B70);
  static const Color drums = Color(0xFFFFB224);
  static const Color bass = Color(0xFF5FB07D);
  static const Color other = Color(0xFF9A7DF0);
  static const Color guitar = Color(0xFF57B98A);
  static const Color piano = Color(0xFFFFC53D);
  static const Color original = Color(0xFF9B8D86);

  /// Phase C: user-uploaded custom samples.
  static const Color custom = Color(0xFF47B8CC);

  /// Phase C: built-in starter-kit sounds.
  static const Color starterKit = Color(0xFFF97316);

  /// Sampler Polish: original-song chops (full mix, no separation).
  static const Color originalChop = Color(0xFF35BFA8);

  static Color forStem(String name) {
    switch (name) {
      case 'vocals':
        return vocals;
      case 'drums':
        return drums;
      case 'bass':
        return bass;
      case 'other':
        return other;
      case 'guitar':
        return guitar;
      case 'piano':
        return piano;
      default:
        return original;
    }
  }
}

ThemeData buildDarkTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: BakushiTokens.bg,
    colorScheme: const ColorScheme.dark(
      primary: BakushiTokens.red,
      secondary: BakushiTokens.amber,
      surface: BakushiTokens.panel,
      error: BakushiTokens.danger,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: BakushiTokens.text,
      displayColor: BakushiTokens.text,
    ),
    cardTheme: CardThemeData(
      color: BakushiTokens.panel,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: BakushiTokens.border),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: BakushiTokens.panel2,
        foregroundColor: BakushiTokens.text,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: BakushiTokens.text,
        side: const BorderSide(color: BakushiTokens.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: BakushiTokens.red,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: BakushiTokens.panel2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 3,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
      activeTrackColor: BakushiTokens.red,
      thumbColor: BakushiTokens.redSoft,
    ),
    dividerTheme: const DividerThemeData(color: BakushiTokens.border),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: BakushiTokens.panel2,
      contentTextStyle: const TextStyle(
        color: BakushiTokens.text,
        fontSize: 13,
      ),
    ),
  );
}

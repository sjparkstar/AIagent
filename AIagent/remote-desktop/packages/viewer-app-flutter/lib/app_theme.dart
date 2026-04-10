import 'package:flutter/material.dart';

const bgPrimary = Color(0xFF0f1117);
const bgSecondary = Color(0xFF1a1d27);
const bgCard = Color(0xFF1e2130);
const borderColor = Color(0xFF2e3347);
const textPrimary = Color(0xFFe8eaf0);
const textSecondary = Color(0xFF8b90a4);
const accent = Color(0xFF4f8ef7);
const danger = Color(0xFFe05252);
const success = Color(0xFF4caf7d);
const warning = Color(0xFFf0a83a);

ThemeData buildAppTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: bgPrimary,
    colorScheme: const ColorScheme.dark(
      surface: bgCard,
      primary: accent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: bgCard,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: borderColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: accent),
      ),
      labelStyle: const TextStyle(color: textSecondary),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
  );
}

import 'package:flutter/material.dart';

class AppTheme {
  static const Color background = Color(0xFFF7F6F4);
  static const Color card = Colors.white;
  static const Color textPrimary = Color(0xFF1A1A1A);
  static const Color textMuted = Color(0xFF8E8E93);
  static const Color border = Color(0xFFE8E4DF);
  static const Color primary = Color(0xFFFF6B1A);
  static const Color primarySoft = Color(0xFFFFF1E7);
  static const Color success = Color(0xFF26A65B);
  static const Color successSoft = Color(0xFFEAF8EF);
  static const Color warning = Color(0xFFF2B84B);
  static const Color warningSoft = Color(0xFFFFF6DE);
  static const Color danger = Color(0xFFE66A6A);
  static const Color dangerSoft = Color(0xFFFFEBEB);
  static const Color info = Color(0xFF4E8DFF);
  static const Color infoSoft = Color(0xFFEAF2FF);

  static ThemeData get lightTheme {
    final ThemeData base = ThemeData(useMaterial3: true);

    return base.copyWith(
      scaffoldBackgroundColor: background,
      colorScheme: base.colorScheme.copyWith(
        primary: primary,
        secondary: primary,
        surface: card,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        foregroundColor: textPrimary,
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        hintStyle: const TextStyle(color: textMuted),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: primary, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: danger),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        side: const BorderSide(color: border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(30),
        ),
      ),
      dividerColor: border,
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Colors.white,
        selectedItemColor: primary,
        unselectedItemColor: textMuted,
        elevation: 10,
        type: BottomNavigationBarType.fixed,
      ),
    );
  }
}
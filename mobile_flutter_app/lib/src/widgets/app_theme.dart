import 'package:flutter/material.dart';

class AppTheme {
  static const Color background = Color(0xFFF7F7F4);
  static const Color card = Colors.white;
  static const Color textPrimary = Color(0xFF202124);
  static const Color textMuted = Color(0xFF8A8D94);
  static const Color border = Color(0xFFEDE9E4);
  static const Color primary = Color(0xFFFF4B1F);
  static const Color primaryDark = Color(0xFFE93412);
  static const Color primarySoft = Color(0xFFFFF0E9);
  static const Color success = Color(0xFF22A45D);
  static const Color successSoft = Color(0xFFEAF8EF);
  static const Color warning = Color(0xFFF0AA2A);
  static const Color warningSoft = Color(0xFFFFF5DD);
  static const Color danger = Color(0xFFE85454);
  static const Color dangerSoft = Color(0xFFFFECEB);
  static const Color info = Color(0xFF3578F6);
  static const Color infoSoft = Color(0xFFEAF1FF);
  static const Color softGrey = Color(0xFFF3F3F1);

  static LinearGradient get primaryGradient => const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[primary, primaryDark],
      );

  static ThemeData get lightTheme {
    final ThemeData base = ThemeData(useMaterial3: true);

    return base.copyWith(
      scaffoldBackgroundColor: background,
      colorScheme: base.colorScheme.copyWith(
        primary: primary,
        secondary: primary,
        surface: card,
        error: danger,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
        fontFamily: 'Roboto',
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        foregroundColor: textPrimary,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w900,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 64,
        elevation: 12,
        backgroundColor: Colors.white,
        indicatorColor: primarySoft,
        iconTheme: MaterialStateProperty.resolveWith<IconThemeData>((states) {
          final selected = states.contains(MaterialState.selected);
          return IconThemeData(
            color: selected ? primary : textMuted,
            size: selected ? 24 : 22,
          );
        }),
        labelTextStyle: MaterialStateProperty.resolveWith<TextStyle>((states) {
          final selected = states.contains(MaterialState.selected);
          return TextStyle(
            color: selected ? primary : textMuted,
            fontSize: 11,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
          );
        }),
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        hintStyle: const TextStyle(color: textMuted, fontSize: 13),
        labelStyle: const TextStyle(color: textMuted, fontWeight: FontWeight.w700),
        prefixIconColor: textMuted,
        suffixIconColor: textMuted,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: primary, width: 1.2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: danger),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        side: const BorderSide(color: border),
        labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      dividerColor: border,
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 4,
      ),
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

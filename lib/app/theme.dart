import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Warm, gender-neutral palette: apricot/terracotta, sage and cream.
abstract final class AppColors {
  static const apricot = Color(0xFFC7785B);
  static const apricotLight = Color(0xFFE8A88C);
  static const sage = Color(0xFF7FA38E);
  static const sand = Color(0xFFF3E9DC);
  static const cream = Color(0xFFFBF8F4);
  static const ink = Color(0xFF2F2A26);
  static const lavender = Color(0xFFB7A6C9);
  static const honey = Color(0xFFE2B866);

  static const darkBackground = Color(0xFF151311);
  static const darkSurface = Color(0xFF1F1C19);

  /// Distinct accents for timeline entry types.
  static const memory = apricot;
  static const milestone = honey;
  static const letter = lavender;
  static const photo = sage;
}

abstract final class AppTheme {
  static const _radius = 20.0;

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.apricot,
      brightness: Brightness.light,
    ).copyWith(
      primary: AppColors.apricot,
      onPrimary: Colors.white,
      secondary: AppColors.sage,
      onSecondary: Colors.white,
      tertiary: AppColors.lavender,
      surface: Colors.white,
      onSurface: AppColors.ink,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFFDFAF7),
      surfaceContainer: const Color(0xFFF8F2EB),
      surfaceContainerHigh: AppColors.sand,
      surfaceContainerHighest: const Color(0xFFEDE1D2),
    );
    return _build(scheme, AppColors.cream);
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.apricot,
      brightness: Brightness.dark,
    ).copyWith(
      primary: AppColors.apricotLight,
      onPrimary: const Color(0xFF3A1E12),
      secondary: const Color(0xFFA5C4B1),
      tertiary: const Color(0xFFCFC0E0),
      surface: AppColors.darkSurface,
      onSurface: const Color(0xFFF1EAE3),
      surfaceContainerLowest: const Color(0xFF12100E),
      surfaceContainerLow: const Color(0xFF1B1916),
      surfaceContainer: const Color(0xFF24211D),
      surfaceContainerHigh: const Color(0xFF2C2824),
      surfaceContainerHighest: const Color(0xFF36312C),
    );
    return _build(scheme, AppColors.darkBackground);
  }

  static ThemeData _build(ColorScheme scheme, Color background) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'Nunito',
      scaffoldBackgroundColor: background,
    );
    final text = base.textTheme;
    TextStyle? serif(TextStyle? s, {FontWeight weight = FontWeight.w600}) =>
        s?.copyWith(fontFamily: 'Lora', fontWeight: weight, letterSpacing: -0.2);

    return base.copyWith(
      textTheme: text.copyWith(
        displayLarge: serif(text.displayLarge),
        displayMedium: serif(text.displayMedium),
        displaySmall: serif(text.displaySmall),
        headlineLarge: serif(text.headlineLarge),
        headlineMedium: serif(text.headlineMedium),
        headlineSmall: serif(text.headlineSmall),
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        bodyLarge: text.bodyLarge?.copyWith(height: 1.45),
        bodyMedium: text.bodyMedium?.copyWith(height: 1.45),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(
          fontFamily: 'Lora',
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radius),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontFamily: 'Nunito', fontWeight: FontWeight.w800, fontSize: 16),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontFamily: 'Nunito', fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(fontFamily: 'Nunito', fontWeight: FontWeight.w700, fontSize: 12, color: scheme.onSurface),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}

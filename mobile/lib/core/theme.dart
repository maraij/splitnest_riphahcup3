import 'package:flutter/material.dart';

// Design system — LIGHT THEME ONLY, "Hisaab Kitaab" style
// (user decision 2026-11-05, confirmed).
// Primary is TEAL #0F766E (dark teal header / brand area, primary
// actions), lighter teal #14B8A6 sparingly, gold #EEC558 (logo coins)
// as a sparing accent. NAVY #1D2D44 is for headings and dark text
// ONLY — never as primary. Background white, surfaces white / #F7F9FC
// for filled inputs. (The pre-November teal is gone.)
// Status colours stay the DESIGN.md light values:
// success #166534, warning #92400E, error #B91C1C.
// Type: title 24, section 18, body 16, supporting 14. 8pt spacing rhythm,
// 16pt screen padding, 12pt card radius, 48pt minimum touch targets.
// There is no dark theme in this app: MaterialApp sets themeMode
// ThemeMode.light, so the app always renders light even on devices
// set to dark mode.
class SplitNestTheme {
  static const Color primary = Color(0xFF0F766E);
  static const Color primaryLight = Color(0xFF14B8A6);
  static const Color ink = Color(0xFF1D2D44); // navy: headings/dark text only
  static const Color background = Colors.white;
  static const Color goldAccent = Color(0xFFEEC558);
  static const Color surface = Colors.white;
  static const Color text = ink;

  // Status colours — always paired with an icon + text label, never
  // colour alone (DESIGN.md).
  static const Color success = Color(0xFF166534);
  static const Color warning = Color(0xFF92400E);
  static const Color error = Color(0xFFB91C1C);

  static const double screenPadding = 16;
  static const double cardRadius = 12;
  static const double spacing = 8;
  static const double minTouchTarget = 48;

  static const TextStyle titleStyle =
      TextStyle(fontSize: 24, fontWeight: FontWeight.w700, height: 1.25);
  static const TextStyle sectionStyle =
      TextStyle(fontSize: 18, fontWeight: FontWeight.w700, height: 1.3);
  static const TextStyle bodyStyle =
      TextStyle(fontSize: 16, fontWeight: FontWeight.w400, height: 1.45);
  static const TextStyle supportingStyle =
      TextStyle(fontSize: 14, fontWeight: FontWeight.w400, height: 1.4);

  static ThemeData light() {
    const scheme = ColorScheme.light(
      primary: primary,
      onPrimary: Colors.white,
      secondary: primaryLight,
      onSecondary: Colors.white,
      surface: surface,
      onSurface: text,
      surfaceContainerLow: Color(0xFFF7F9FC),
      surfaceContainerHighest: Color(0xFFE8EDF3),
      outline: Color(0xFFD1D5DB),
      error: error,
      onError: Colors.white,
      tertiary: success,
      onTertiary: Colors.white,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      textTheme: TextTheme(
        titleLarge: titleStyle.copyWith(color: scheme.onSurface),
        titleMedium: sectionStyle.copyWith(color: scheme.onSurface),
        bodyLarge: bodyStyle.copyWith(color: scheme.onSurface),
        bodyMedium: supportingStyle.copyWith(color: scheme.onSurface),
        labelLarge: bodyStyle.copyWith(fontWeight: FontWeight.w600),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: titleStyle.copyWith(color: Colors.white),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 1,
        shadowColor: Colors.black.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: const BorderSide(color: Color(0xFFE5E7EB)),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          borderSide: BorderSide(color: scheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          borderSide: BorderSide(color: scheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          borderSide: BorderSide(color: scheme.error),
        ),
        labelStyle: supportingStyle.copyWith(color: scheme.onSurfaceVariant),
        hintStyle: supportingStyle.copyWith(color: scheme.onSurfaceVariant),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(0, minTouchTarget),
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          textStyle: bodyStyle.copyWith(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(cardRadius)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, minTouchTarget),
          textStyle: bodyStyle.copyWith(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(cardRadius)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, minTouchTarget),
          textStyle: bodyStyle.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999)),
        side: BorderSide(color: scheme.outline),
        labelStyle: supportingStyle.copyWith(fontWeight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, minTouchTarget)),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(cardRadius))),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => supportingStyle.copyWith(
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w400,
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: primary,
        contentTextStyle: bodyStyle.copyWith(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(cardRadius)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      dividerTheme: DividerThemeData(color: scheme.outline.withValues(alpha: 0.6)),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      extensions: const [
        StatusColors(success: success, warning: warning, error: error),
      ],
    );
  }
}

/// Status colours carried as a theme extension so screens can resolve
/// success / warning / error without hard-coding them.
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({
    required this.success,
    required this.warning,
    required this.error,
  });
  final Color success;
  final Color warning;
  final Color error;

  @override
  StatusColors copyWith({Color? success, Color? warning, Color? error}) =>
      StatusColors(
        success: success ?? this.success,
        warning: warning ?? this.warning,
        error: error ?? this.error,
      );

  @override
  StatusColors lerp(StatusColors? other, double t) {
    if (other is! StatusColors) return this;
    return StatusColors(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      error: Color.lerp(error, other.error, t)!,
    );
  }

  static StatusColors of(BuildContext context) =>
      Theme.of(context).extension<StatusColors>()!;
}

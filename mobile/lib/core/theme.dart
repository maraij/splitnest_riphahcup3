import 'package:flutter/material.dart';

// Design system — "Hisaab Kitaab" light theme + Coolors dark theme
// (user decision 2026-11-05, dark mode added 2026-11-05).
//
// LIGHT (polished 2026-11-05): primary DEEP TEAL-GREEN #123C38
// (header / brand area, primary actions), ledger GOLD #C9A227 as a
// sparing accent (ring highlight, logo-adjacent elements). Warm
// cream #FAF6EF background, white card surfaces. NAVY #1D2D44 is
// for headings and dark text ONLY — never as primary. Status
// colours stay the DESIGN.md light values:
// success #166534, warning #92400E, error #B91C1C.
// The lighter teal #2E7D6B is used sparingly as a secondary accent.
//
// DARK (Coolors palette https://coolors.co/palette/d7dedc-cfcfcd-
// 9a879d-7a3b69-563440): background dark plum-brown #563440; cards
// #63364E (a 35% blend of the two palette plums, for depth against
// the background); deep plum #7A3B69 for the app bar and primary
// buttons; muted mauve #9A879D for secondary text/borders/inactive;
// text pale #D7DEDC, secondary text #CFCFCD. Status colours are
// lightened for contrast on plum (success #86EFAC, warning #FCD34D,
// error #FCA5A5) — the palette has no status colours of its own.
// Type: title 24, section 18, body 16, supporting 14. 8pt spacing rhythm,
// 16pt screen padding, 12pt card radius, 48pt minimum touch targets.
class SplitNestTheme {
  static const Color primary = Color(0xFF123C38);
  static const Color primaryLight = Color(0xFF2E7D6B);
  static const Color ink = Color(0xFF1D2D44); // navy: headings/dark text only
  static const Color background = Color(0xFFFAF6EF); // warm cream
  static const Color goldAccent = Color(0xFFC9A227); // ledger gold
  static const Color surface = Colors.white;
  static const Color text = ink;

  // Status colours — always paired with an icon + text label, never
  // colour alone (DESIGN.md).
  static const Color success = Color(0xFF166534);
  static const Color warning = Color(0xFF92400E);
  static const Color error = Color(0xFFB91C1C);

  // Dark-mode palette (Coolors).
  static const Color darkBackground = Color(0xFF563440); // plum-brown
  static const Color darkSurface = Color(0xFF63364E); // 35% blend of the plums
  static const Color darkPrimary = Color(0xFF7A3B69); // deep plum
  static const Color darkSecondary = Color(0xFF9A879D); // muted mauve
  static const Color darkText = Color(0xFFD7DEDC); // pale grey-green
  static const Color darkTextSecondary = Color(0xFFCFCFCD); // light grey
  static const Color darkSuccess = Color(0xFF86EFAC);
  static const Color darkWarning = Color(0xFFFCD34D);
  static const Color darkError = Color(0xFFFCA5A5);

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
      // Warm dark grey for secondary text — readable on cream.
      onSurfaceVariant: Color(0xFF57534A),
      surfaceContainerLow: Color(0xFFF4EEE1),
      surfaceContainerHighest: Color(0xFFEAE2D0),
      outline: Color(0xFFD9D2C0),
      error: error,
      onError: Colors.white,
      tertiary: success,
      onTertiary: Colors.white,
    );
    return _build(
      scheme: scheme,
      scaffoldBackground: background,
      cardBorder: const Color(0xFFE7DFCE),
      shadowColor: Colors.black.withValues(alpha: 0.06),
      status: const StatusColors(
          success: success, warning: warning, error: error),
    );
  }

  /// Dark theme from the Coolors palette: plum-brown background,
  /// deep-plum app bar / primary buttons, mauve secondary elements,
  /// pale text. Light theme is untouched.
  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: darkPrimary,
      onPrimary: darkText,
      secondary: darkSecondary,
      onSecondary: darkBackground,
      surface: darkSurface,
      onSurface: darkText,
      onSurfaceVariant: darkTextSecondary,
      surfaceContainerLow: darkPrimary,
      surfaceContainerHighest: Color(0xFF845279),
      outline: darkSecondary,
      error: darkError,
      onError: darkBackground,
      tertiary: darkSuccess,
      onTertiary: darkBackground,
    );
    return _build(
      scheme: scheme,
      scaffoldBackground: darkBackground,
      cardBorder: darkSecondary.withValues(alpha: 0.4),
      shadowColor: Colors.black.withValues(alpha: 0.3),
      status: const StatusColors(
          success: darkSuccess, warning: darkWarning, error: darkError),
    );
  }

  /// Shared ThemeData construction — both themes differ only in their
  /// ColorScheme (+ scaffold/card chrome). Every widget colour comes
  /// from the scheme, so switching themeMode re-themes the whole app.
  static ThemeData _build({
    required ColorScheme scheme,
    required Color scaffoldBackground,
    required Color cardBorder,
    required Color shadowColor,
    required StatusColors status,
  }) {
    return ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffoldBackground,
      textTheme: TextTheme(
        titleLarge: titleStyle.copyWith(color: scheme.onSurface),
        titleMedium: sectionStyle.copyWith(color: scheme.onSurface),
        bodyLarge: bodyStyle.copyWith(color: scheme.onSurface),
        bodyMedium: supportingStyle.copyWith(color: scheme.onSurface),
        labelLarge: bodyStyle.copyWith(fontWeight: FontWeight.w600),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: titleStyle.copyWith(color: scheme.onPrimary),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 1,
        shadowColor: shadowColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: BorderSide(color: cardBorder),
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
          // Pressed: slightly deeper primary; disabled: muted, not
          // just faded — the label must stay readable.
          disabledBackgroundColor:
              scheme.onSurface.withValues(alpha: 0.12),
          disabledForegroundColor:
              scheme.onSurface.withValues(alpha: 0.38),
          textStyle: bodyStyle.copyWith(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(cardRadius)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, minTouchTarget),
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          disabledBackgroundColor:
              scheme.onSurface.withValues(alpha: 0.12),
          disabledForegroundColor:
              scheme.onSurface.withValues(alpha: 0.38),
          textStyle: bodyStyle.copyWith(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(cardRadius)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, minTouchTarget),
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.primary),
          disabledForegroundColor:
              scheme.onSurface.withValues(alpha: 0.38),
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
        backgroundColor: scheme.primary,
        contentTextStyle: bodyStyle.copyWith(color: scheme.onPrimary),
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
      extensions: [status],
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

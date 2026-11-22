import 'package:material_ui/material_ui.dart';
import 'package:google_fonts/google_fonts.dart';

/// Teak + peacock teal — distinct from default AI purple / cream templates.
class AppColors {
  static const teak = Color(0xFF2A1A12);
  static const teakDeep = Color(0xFF140C08);
  static const peacock = Color(0xFF0E5C63);
  static const peacockBright = Color(0xFF1A8A8F);
  static const gold = Color(0xFFD4A24C);
  static const goldSoft = Color(0xFFE8C97A);
  static const sand = Color(0xFFE6D5B8);
  static const mist = Color(0xFFB7C9C7);
}

ThemeData buildAppTheme() {
  final display = GoogleFonts.fraunces(
    color: AppColors.sand,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
  );
  final body = GoogleFonts.sourceSans3(
    color: AppColors.mist,
    fontWeight: FontWeight.w400,
    height: 1.35,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.teakDeep,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.gold,
      secondary: AppColors.peacockBright,
      surface: AppColors.teak,
      onPrimary: AppColors.teakDeep,
      onSecondary: AppColors.sand,
      onSurface: AppColors.sand,
    ),
  );

  return base.copyWith(
    textTheme: TextTheme(
      displayLarge: display.copyWith(fontSize: 56),
      displayMedium: display.copyWith(fontSize: 40),
      headlineMedium: display.copyWith(fontSize: 28),
      titleLarge: display.copyWith(fontSize: 22),
      bodyLarge: body.copyWith(fontSize: 17),
      bodyMedium: body.copyWith(fontSize: 15),
      labelLarge: body.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
        color: AppColors.goldSoft,
      ),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: AppColors.gold,
      inactiveTrackColor: AppColors.peacock.withValues(alpha: 0.35),
      thumbColor: AppColors.goldSoft,
      overlayColor: AppColors.gold.withValues(alpha: 0.15),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.selected)) return AppColors.goldSoft;
        return AppColors.mist;
      }),
      trackColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.selected)) return AppColors.peacock;
        return AppColors.teak;
      }),
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// AegisCare centralized design system.
/// Every screen MUST reference these tokens — never scatter raw
/// Color(...) values inside widgets. This file is the single source
/// of truth for color, typography, spacing, and shape across the app.
class AppColors {
  AppColors._();

  // Brand
  static const primary = Color(0xFF176B87);
  static const primaryDark = Color(0xFF0F4C5C);
  static const secondaryTeal = Color(0xFF2A9D8F);

  // Surfaces
  static const background = Color(0xFFF5F8FA);
  static const card = Color(0xFFFFFFFF);

  // Text
  static const textPrimary = Color(0xFF172B4D);
  static const textSecondary = Color(0xFF667085);

  // Semantic status — reserved strictly for safety/risk meaning,
  // never used decoratively elsewhere in the app.
  static const safe = Color(0xFF16A34A);
  static const warning = Color(0xFFF59E0B);
  static const emergency = Color(0xFFDC2626);

  // Light tints for icon containers / status chips (derived, not new hues)
  static const safeLight = Color(0xFFE7F7EE);
  static const warningLight = Color(0xFFFEF3E2);
  static const emergencyLight = Color(0xFFFBE9E9);
  static const primaryLight = Color(0xFFE7F1F4);

  static const border = Color(0xFFE3E8EC);

  // ---------------------------------------------------------------
  // BACKWARD-COMPATIBLE ALIASES
  // This app is being rebuilt screen-by-screen (Phase 1: theme + core
  // widgets + Home Dashboard). Screens not yet rebuilt still reference
  // the OLD navy/blue token names below. These aliases keep them
  // compiling and visually coherent until each is migrated in a later
  // phase. New/rebuilt screens should use ONLY the tokens above —
  // do not write new code against these aliases.
  // ---------------------------------------------------------------
  static const navy = primaryDark;
  static const cyan = secondaryTeal;
  static const accentBlue = primary;
  static const surface = card;
  static const surfaceMuted = background;
  static const textMuted = textSecondary;
  static const low = safe;
  static const lowLight = safeLight;
  static const medium = warning;
  static const mediumLight = warningLight;
  static const high = Color(0xFFCB5A25);
  static const critical = emergency;
  static const criticalLight = emergencyLight;
  static const info = primary;
  static const infoLight = primaryLight;
  static const purple = Color(0xFF8C5FD1);
  static const purpleLight = Color(0xFFF1EAFB);
  static const pink = Color(0xFFE85A79);
  static const pinkLight = Color(0xFFFDE8EC);
  static const amberSoft = warningLight;

  /// Old helper used by several not-yet-rebuilt screens to map a
  /// severity string to a color. Preserved for compatibility.
  static Color severity(String? level) {
    switch ((level ?? "").toUpperCase()) {
      case "LOW":
        return low;
      case "MEDIUM":
        return medium;
      case "HIGH":
        return high;
      case "CRITICAL":
        return critical;
      default:
        return textSecondary;
    }
  }

  static Color severityLight(String? level) {
    switch ((level ?? "").toUpperCase()) {
      case "LOW":
        return lowLight;
      case "MEDIUM":
        return mediumLight;
      case "HIGH":
        return mediumLight;
      case "CRITICAL":
        return criticalLight;
      default:
        return border;
    }
  }

  /// Maps an alert type string ("Voice Alert" / "Caregiver Alert" /
  /// "Emergency Alert") to a color — used by not-yet-rebuilt alert
  /// screens.
  static Color alertType(String? type) {
    final t = type ?? "";
    if (t.contains("Emergency")) return critical;
    if (t.contains("Caregiver")) return medium;
    return info;
  }
}

/// Spacing scale — use these constants instead of arbitrary numbers.
class AppSpacing {
  AppSpacing._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const xxxl = 32.0;
}

class AppRadius {
  AppRadius._();
  static const card = 18.0;
  static const button = 40.0;
  static const chip = 40.0;
}

/// Semantic status used throughout (safety cards, badges, alert cards).
/// Centralizing this enum avoids each screen inventing its own strings.
enum SafetyStatus { safe, warning, emergency, unknown }

extension SafetyStatusX on SafetyStatus {
  Color get color {
    switch (this) {
      case SafetyStatus.safe:
        return AppColors.safe;
      case SafetyStatus.warning:
        return AppColors.warning;
      case SafetyStatus.emergency:
        return AppColors.emergency;
      case SafetyStatus.unknown:
        return AppColors.textSecondary;
    }
  }

  Color get lightColor {
    switch (this) {
      case SafetyStatus.safe:
        return AppColors.safeLight;
      case SafetyStatus.warning:
        return AppColors.warningLight;
      case SafetyStatus.emergency:
        return AppColors.emergencyLight;
      case SafetyStatus.unknown:
        return AppColors.border;
    }
  }

  IconData get icon {
    switch (this) {
      case SafetyStatus.safe:
        return Icons.check_circle;
      case SafetyStatus.warning:
        return Icons.warning;
      case SafetyStatus.emergency:
        return Icons.emergency;
      case SafetyStatus.unknown:
        return Icons.help_outline;
    }
  }

  String get label {
    switch (this) {
      case SafetyStatus.safe:
        return "Safe";
      case SafetyStatus.warning:
        return "Attention";
      case SafetyStatus.emergency:
        return "Emergency";
      case SafetyStatus.unknown:
        return "Unknown";
    }
  }
}

class AppTheme {
  AppTheme._();

  static ThemeData get light {
    final base = ThemeData.light(useMaterial3: true);
    final textTheme = GoogleFonts.interTextTheme(base.textTheme).copyWith(
      headlineMedium: GoogleFonts.inter(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary),
      titleLarge: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary),
      titleMedium: GoogleFonts.inter(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary),
      bodyLarge: GoogleFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w400,
          color: AppColors.textPrimary),
      bodyMedium: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: AppColors.textSecondary),
      bodySmall: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: AppColors.textSecondary),
      labelLarge: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
    );

    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      textTheme: textTheme,
      colorScheme: base.colorScheme.copyWith(
        primary: AppColors.primary,
        secondary: AppColors.secondaryTeal,
        error: AppColors.emergency,
        surface: AppColors.card,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.primaryDark,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.inter(
            fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white),
      ),
      cardTheme: CardThemeData(
        color: AppColors.card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: const BorderSide(color: AppColors.border),
        ),
        margin: EdgeInsets.zero,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.button)),
          textStyle:
              GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          minimumSize: const Size(0, 48),
          side: const BorderSide(color: AppColors.primary, width: 1.5),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.button)),
          textStyle:
              GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: AppColors.card,
        selectedItemColor: AppColors.primary,
        unselectedItemColor: AppColors.textSecondary,
        showUnselectedLabels: true,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle:
            GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600),
        unselectedLabelStyle:
            GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w400),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.background,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }
}

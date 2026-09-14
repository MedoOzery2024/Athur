import 'package:flutter/material.dart';

/// Athur brand palette.
///
/// Primary identity: **black** surfaces with **gold** accents.
/// All colors are defined once here so screens never hardcode hex values.
///
/// Contrast notes (WCAG AA target for body text):
/// - [gold] on [black]           → very high contrast, safe for text/icons.
/// - [textPrimary] on [black]    → high contrast, safe for body text.
/// - [textSecondary] on [surface]→ ~7:1, safe for secondary text.
/// - [textMuted] is intended only for non-essential hints (≥18pt or bold).
abstract final class AthurColors {
  AthurColors._();

  // ---------------------------------------------------------------------------
  // Base surfaces (black dominant)
  // ---------------------------------------------------------------------------

  /// App-wide background. True black keeps OLED power usage low.
  static const Color black = Color(0x000ff000);

  /// Slightly lifted background (used behind cards to create depth).
  static const Color background = Color(0xFF0A0A0B);

  /// Default card / sheet surface.
  static const Color surface = Color(0xFF141416);

  /// Elevated surface (menus, popovers, highlighted cards).
  static const Color surfaceElevated = Color(0xFF1C1C1F);

  /// Input fields and recessed containers.
  static const Color surfaceInput = Color(0xFF1A1A1D);

  /// Hairline separators / borders.
  static const Color border = Color(0xFF2A2A2E);

  /// Stronger border for focused/selected states.
  static const Color borderStrong = Color(0xFF3A3A40);

  // ---------------------------------------------------------------------------
  // Gold accent
  // ---------------------------------------------------------------------------

  /// Primary accent used for buttons, rings, highlights.
  static const Color gold = Color(0xFFD4AF37);

  /// Brighter gold for hover/pressed feedback and gradients.
  static const Color goldBright = Color(0xFFF5D67B);

  /// Deep gold for pressed states and borders on gold surfaces.
  static const Color goldDeep = Color(0xFF9C7C1E);

  /// Very low-opacity gold wash for tinted containers.
  static const Color goldWash = Color(0x1AD4AF37); // 10% gold

  /// Gold glow/tint for shadows and focus rings.
  static const Color goldGlow = Color(0x66D4AF37); // 40% gold

  // ---------------------------------------------------------------------------
  // Text
  // ---------------------------------------------------------------------------

  static const Color textPrimary = Color(0xFFF5F5F7);
  static const Color textSecondary = Color(0xFFB0B0B6);
  static const Color textMuted = Color(0xFF7A7A82);

  /// Text/icon color used *on top of* gold surfaces.
  static const Color textOnGold = Color(0xFF0A0A0B);

  // ---------------------------------------------------------------------------
  // Semantic status colors
  // (chosen to remain distinguishable on black for color-blind users too —
  //  each is also paired with an icon/label in the UI, never color alone)
  // ---------------------------------------------------------------------------

  /// Online / connected / success.
  static const Color success = Color(0xFF32D74B);

  /// Warning / connecting / fair quality.
  static const Color warning = Color(0xFFFFB020);

  /// Error / failed / destructive actions.
  static const Color danger = Color(0xFFFF453A);

  /// Informational / neutral emphasis.
  static const Color info = Color(0xFF4EA8FF);

  // ---------------------------------------------------------------------------
  // Call-quality tiers (deterministic thresholds live in quality_thresholds.dart)
  // ---------------------------------------------------------------------------

  static const Color qualityExcellent = success;
  static const Color qualityGood = Color(0xFF9BE15D);
  static const Color qualityFair = warning;
  static const Color qualityPoor = Color(0xFFFF9500);
  static const Color qualityCritical = danger;

  // ---------------------------------------------------------------------------
  // Gradients
  // ---------------------------------------------------------------------------

  /// Subtle premium gold sheen used sparingly on hero/brand areas.
  static const LinearGradient goldSheen = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [goldBright, gold, goldDeep],
  );

  /// Faint vertical fade used behind headers / bottom bars.
  static const LinearGradient surfaceFade = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [surface, black],
  );
}

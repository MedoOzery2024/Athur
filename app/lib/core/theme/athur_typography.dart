import 'package:flutter/material.dart';

import 'athur_colors.dart';

/// Athur typography.
///
/// Phase 1 intentionally uses the platform default font family so we do not
/// ship a font dependency before it is justified. All sizes/weights are
/// defined here, so swapping to a bundled brand font later is a one-line
/// change in [AthurTypography.textTheme] (set `fontFamily`).
///
/// Accessibility: the theme respects the user's OS text-scale factor because
/// sizes are expressed in logical pixels via TextTheme (Flutter scales them
/// automatically through MediaQuery.textScaler).
abstract final class AthurTypography {
  AthurTypography._();

  /// Brand wordmark family (falls back to default until a font is bundled).
  static const String? fontFamily = null;

  /// Large display used on splash / onboarding headers.
  static const TextStyle display = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.4,
    color: AthurColors.textPrimary,
    height: 1.15,
  );

  /// Screen titles.
  static const TextStyle headline = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.2,
    color: AthurColors.textPrimary,
    height: 1.2,
  );

  /// Section headers / app bar titles.
  static const TextStyle title = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: AthurColors.textPrimary,
    height: 1.25,
  );

  /// List tile primary line (chat name, contact name).
  static const TextStyle bodyStrong = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: AthurColors.textPrimary,
    height: 1.3,
  );

  /// Default body copy.
  static const TextStyle body = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    color: AthurColors.textPrimary,
    height: 1.4,
  );

  /// Secondary line (message preview, subtitle).
  static const TextStyle bodySecondary = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: AthurColors.textSecondary,
    height: 1.35,
  );

  /// Small labels (timestamps, badges).
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: AthurColors.textMuted,
    height: 1.3,
  );

  /// Button label.
  static const TextStyle button = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.3,
    color: AthurColors.textOnGold,
    height: 1.2,
  );

  /// Builds the Material [TextTheme] from the tokens above.
  static TextTheme get textTheme => const TextTheme(
    displayLarge: display,
    displayMedium: display,
    headlineLarge: headline,
    headlineMedium: headline,
    titleLarge: title,
    titleMedium: bodyStrong,
    bodyLarge: body,
    bodyMedium: bodySecondary,
    labelLarge: button,
    labelMedium: caption,
    labelSmall: caption,
  );
}

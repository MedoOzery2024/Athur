import 'package:flutter/material.dart';

/// Spacing scale — a single source of truth so layouts stay consistent.
///
/// Uses a 4pt base grid. Prefer these over magic numbers in widgets.
abstract final class AthurSpacing {
  AthurSpacing._();

  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;

  /// Standard horizontal page padding.
  static const EdgeInsets pagePadding = EdgeInsets.symmetric(horizontal: lg);

  /// Padding inside cards.
  static const EdgeInsets cardPadding = EdgeInsets.all(lg);

  /// Padding inside list tiles.
  static const EdgeInsets tilePadding =
      EdgeInsets.symmetric(horizontal: lg, vertical: md);
}

/// Corner radii tokens.
abstract final class AthurRadius {
  AthurRadius._();

  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 28;

  /// Fully rounded (pills, avatars, FABs).
  static const double pill = 999;

  static const BorderRadius rXs = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius rSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius rMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius rLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius rXl = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius rPill = BorderRadius.all(Radius.circular(pill));
}

/// Animation durations — keeps motion coherent across the app.
///
/// Durations are deliberately short: Athur favours performance and
/// responsiveness over decorative animation.
abstract final class AthurDurations {
  AthurDurations._();

  /// Immediate feedback (button press, ripple).
  static const Duration instant = Duration(milliseconds: 100);

  /// Standard UI transition (page push, sheet open).
  static const Duration fast = Duration(milliseconds: 180);

  /// Default emphasis transition (cards, reveals).
  static const Duration normal = Duration(milliseconds: 280);

  /// Slower, larger transitions (splash → home).
  static const Duration slow = Duration(milliseconds: 450);

  /// Minimum time the splash stays visible so it does not flash.
  static const Duration splashMinimum = Duration(milliseconds: 1200);
}

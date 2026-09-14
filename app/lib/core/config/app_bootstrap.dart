import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../theme/athur_theme.dart' show athurOverlayStyle;

/// Critical, fast startup work performed **before** the first real UI frame.
///
/// Design principle (performance requirement): initialize only what the first
/// screen truly needs, synchronously and quickly. Everything non-critical
/// (analytics-free error reporting, push registration, presence sockets,
/// caching warm-up) is started *after* the UI is visible so cold start stays
/// fast.
///
/// Phase 1 does: orientation/reset, system UI chrome, and asset pre-load of the
/// brand logo so the splash has no first-frame flicker. Later phases append
/// their own critical steps here and register non-critical ones in
/// [deferredStartup].
class AppBootstrap {
  const AppBootstrap();

  /// Work that must finish before showing the app shell.
  Future<void> runCritical() async {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    SystemChrome.setSystemUIOverlayStyle(athurOverlayStyle);

    // Pre-cache the brand logo so the splash renders instantly.
    // (Uses the asset bundle directly — no BuildContext needed.)
    try {
      await rootBundle.load('assets/images/logo.png');
    } catch (error) {
      // Non-fatal: the logo will simply load on demand.
      debugPrint('[Athur][bootstrap] logo precache skipped: $error');
    }
  }

  /// Work that may start after the UI is on screen. Kept for later phases.
  ///
  /// Nothing heavy runs here in Phase 1. When WebSocket/push/cache services
  /// arrive they will be launched from here so they never block startup.
  Future<void> runDeferred() async {
    // Intentionally empty until those subsystems exist.
  }
}

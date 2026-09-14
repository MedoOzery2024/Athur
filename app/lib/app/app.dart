import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/config/app_bootstrap.dart';
import '../core/theme/athur_theme.dart';
import '../features/auth/presentation/auth_gate.dart';
import '../features/splash/presentation/splash_screen.dart';

/// Root widget.
///
/// Phase 1 behaviour:
///   Splash (runs critical bootstrap) → AuthGate (decides auth vs home).
///
/// The splash screen always shows first for branding + bootstrap.
/// After it finishes, [AuthGate] checks authentication state and either
/// shows the phone input screen or the main [HomeShell].
enum _Stage { splash, auth }

class AthurApp extends StatefulWidget {
  const AthurApp({super.key});

  @override
  State<AthurApp> createState() => _AthurAppState();
}

class _AthurAppState extends State<AthurApp> {
  _Stage _stage = _Stage.splash;
  final _bootstrap = const AppBootstrap();

  void _onSplashFinished() {
    if (!mounted) return;
    setState(() => _stage = _Stage.auth);
    // Non-critical services start only after the UI is visible so they never
    // delay cold start.
    _bootstrap.runDeferred();
  }

  @override
  Widget build(BuildContext context) {
    // Ensure the status bar chrome matches Athur's black theme on every page.
    SystemChrome.setSystemUIOverlayStyle(athurOverlayStyle);

    return MaterialApp(
      title: 'Athur',
      debugShowCheckedModeBanner: false,
      theme: AthurTheme.dark,
      // Dark-only app: the dark theme is used regardless of OS setting.
      themeMode: ThemeMode.dark,
      home: switch (_stage) {
        _Stage.splash => SplashScreen(
          onFinished: _onSplashFinished,
          bootstrap: _bootstrap.runCritical,
        ),
        _Stage.auth => const AuthGate(),
      },
    );
  }
}

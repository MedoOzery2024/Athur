import 'package:flutter/material.dart';

import '../../../core/theme/athur_colors.dart';
import '../../../core/theme/athur_tokens.dart';
import '../../../core/widgets/athur_logo.dart';

/// The first thing Athur shows.
///
/// Responsibilities (Phase 1):
/// - Present the brand while the app performs *critical* startup work only
///   (see [AppBootstrap]). Non-critical services start after the UI is shown,
///   keeping cold start fast.
/// - Never block indefinitely: it has a minimum display time so the logo does
///   not flash, and it hands control to the router when bootstrap completes.
///
/// Phase 3+ will replace the callback target with auth-state routing.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.onFinished, this.bootstrap});

  /// Called once bootstrap + minimum display time have both completed.
  final VoidCallback onFinished;

  /// Critical startup work. Injected so tests can supply a fake.
  /// If null, the splash simply waits the minimum duration.
  final Future<void> Function()? bootstrap;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;
  String? _startupError;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AthurDurations.slow,
    );
    _fade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0, 0.7, curve: Curves.easeOut),
    );
    _scale = Tween<double>(
      begin: 0.92,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));
    _controller.forward();
    _runStartup();
  }

  Future<void> _runStartup() async {
    final minimumDelay = Future<void>.delayed(AthurDurations.splashMinimum);
    try {
      await Future.wait<void>([
        widget.bootstrap?.call() ?? Future<void>.value(),
        minimumDelay,
      ]);
    } catch (error, stack) {
      // Do not silently swallow: surface a readable message and log details.
      debugPrint('[Athur][startup] failed: $error\n$stack');
      _startupError = error.toString();
    }
    if (!mounted) return;
    widget.onFinished();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AthurColors.black,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          // Faint radial gold wash behind the mark — premium, not noisy.
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 0.9,
            colors: [Color(0x14D4AF37), AthurColors.black],
          ),
        ),
        child: Center(
          child: FadeTransition(
            opacity: _fade,
            child: ScaleTransition(
              scale: _scale,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AthurBrandLockup(logoSize: 120, showTagline: true),
                  const SizedBox(height: AthurSpacing.xxl),
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: AthurColors.gold,
                    ),
                  ),
                  if (_startupError != null) ...[
                    const SizedBox(height: AthurSpacing.lg),
                    Padding(
                      padding: AthurSpacing.pagePadding,
                      child: Text(
                        'Startup problem: $_startupError',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AthurColors.danger,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

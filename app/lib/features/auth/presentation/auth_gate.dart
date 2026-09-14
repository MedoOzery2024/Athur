import 'package:flutter/material.dart';

import '../../../core/services/auth_controller.dart';
import '../../../core/theme/athur_colors.dart';
import '../../home/presentation/home_shell.dart';
import 'phone_screen.dart';

/// Root widget that switches between auth screens and the main app
/// based on the current [AuthState].
///
/// This replaces the hardcoded `_Stage` enum in [AthurApp] with a
/// reactive auth-based navigation.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final AuthController _authController;

  @override
  void initState() {
    super.initState();
    _authController = AuthController();
    _authController.addListener(_onAuthChanged);
    // Check for existing session on startup.
    _authController.init();
  }

  @override
  void dispose() {
    _authController.removeListener(_onAuthChanged);
    _authController.dispose();
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = _authController.state;

    // Loading state — show splash-like loader.
    if (state.status == AuthStatus.loading ||
        state.status == AuthStatus.initial) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFFD4AF37)),
        ),
      );
    }

    // Unauthenticated — show phone input.
    if (state.isUnauthenticated) {
      return PhoneScreen(
        onAuthenticated: () => setState(() {}),
      );
    }

    // Authenticated — show main app.
    if (state.isAuthenticated) {
      return const HomeShell();
    }

    // Fallback.
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Text(
          'Something went wrong.',
          style: TextStyle(color: Colors.white54),
        ),
      ),
    );
  }
}

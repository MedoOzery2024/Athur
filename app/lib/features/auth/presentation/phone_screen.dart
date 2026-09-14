import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/athur_colors.dart';
import '../../home/presentation/home_shell.dart';
import 'otp_screen.dart';

/// Phone number input screen — first step of authentication.
///
/// The user enters their phone number in E.164 format (+1234567890).
/// Firebase Authentication sends an SMS with the OTP code.
class PhoneScreen extends StatefulWidget {
  const PhoneScreen({super.key, this.onAuthenticated});

  /// Called when the user is fully authenticated (after OTP + optional profile).
  final VoidCallback? onAuthenticated;

  @override
  State<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends State<PhoneScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final phone = _controller.text.trim();
    if (phone.isEmpty) {
      setState(() => _error = 'Please enter your phone number.');
      return;
    }

    // Basic E.164 validation.
    if (!RegExp(r'^\+[1-9]\d{6,14}$').hasMatch(phone)) {
      setState(() => _error = 'Phone must include country code (e.g. +1234567890).');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Use Firebase Authentication to verify phone number.
      debugPrint('[Athur][auth] Sending SMS to $phone');
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: phone,
        timeout: const Duration(seconds: 120),
        forceResendingToken: null,
        verificationCompleted: (PhoneAuthCredential credential) async {
          // Auto-retrieval or instant verification.
          debugPrint('[Athur][auth] ✅ Auto-verification completed');
          await FirebaseAuth.instance.signInWithCredential(credential);
          if (mounted) {
            Navigator.of(context).popUntil((route) => route.isFirst);
          }
        },
        verificationFailed: (FirebaseAuthException e) {
          debugPrint('[Athur][auth] ❌ Verification failed: ${e.code} - ${e.message}');
          if (mounted) {
            setState(() {
              _error = _getErrorMessage(e);
              _isLoading = false;
            });
          }
        },
        codeSent: (String verificationId, int? resendToken) {
          debugPrint('[Athur][auth] ✅ Code sent to $phone');
          if (mounted) {
            setState(() => _isLoading = false);
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => OtpScreen(
                  phoneNumber: phone,
                  verificationId: verificationId,
                ),
              ),
            );
          }
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          debugPrint('[Athur][auth] ⏱️ Auto-retrieval timeout');
        },
      );
    } catch (e) {
      debugPrint('[Athur][auth] ❌ Error: $e');
      if (mounted) {
        setState(() {
          _error = 'Failed to send code. Please try again.';
          _isLoading = false;
        });
      }
    }
  }

  String _getErrorMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-phone-number':
        return 'The phone number is invalid.';
      case 'too-many-requests':
        return 'Too many requests. Please try again later.';
      case 'quota-exceeded':
        return 'SMS quota exceeded. Please try again later.';
      case 'operation-not-allowed':
        return 'Phone sign-in is not enabled. Please enable it in Firebase Console → Authentication → Sign-in method → Phone.';
      default:
        return e.message ?? 'An error occurred. Please try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white70),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 48),

              // Title
              const Text(
                'Enter your phone number',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                "We'll send you a verification code via SMS.",
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 40),

              // Phone input
              TextField(
                controller: _controller,
                focusNode: _focusNode,
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: Colors.white),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\+0-9]')),
                ],
                decoration: InputDecoration(
                  hintText: '+1 234 567 8900',
                  hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                  ),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.05),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: const Icon(
                    Icons.phone_outlined,
                    color: Colors.white38,
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),

              // Error
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AthurColors.danger.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: AthurColors.danger),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],

              const SizedBox(height: 24),

              // Continue button
              ElevatedButton(
                onPressed: _isLoading ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AthurColors.gold,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  disabledBackgroundColor: AthurColors.gold.withValues(alpha: 0.5),
                ),
                child: _isLoading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Text(
                        'Continue',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),

              // Skip button (for testing)
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  // Skip to home for testing.
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                      builder: (_) => const HomeShell(),
                    ),
                  );
                },
                child: Text(
                  'Skip for testing',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 14,
                  ),
                ),
              ),

              const Spacer(),

              // Footer
              Padding(
                padding: const EdgeInsets.only(bottom: 32),
                child: Text(
                  'By continuing, you agree to our Terms of Service and Privacy Policy.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 12,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

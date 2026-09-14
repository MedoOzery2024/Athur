import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/services/api_client.dart';
import '../../../core/services/auth_controller.dart';
import '../../../core/theme/athur_colors.dart';
import 'profile_setup_screen.dart';

/// OTP verification screen — user enters the 6-digit code sent via SMS.
///
/// Features:
/// - 6-digit code input with auto-submit
/// - Resend timer (60 seconds)
/// - Error display
/// - Firebase Authentication integration
class OtpScreen extends StatefulWidget {
  const OtpScreen({
    super.key,
    required this.phoneNumber,
    required this.verificationId,
  });

  final String phoneNumber;
  final String verificationId;

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final _controllers = List.generate(6, (_) => TextEditingController());
  final _focusNodes = List.generate(6, (_) => FocusNode());
  bool _isLoading = false;
  String? _error;
  int _resendSeconds = 60;
  Timer? _resendTimer;
  String? _verificationId;

  @override
  void initState() {
    super.initState();
    _verificationId = widget.verificationId;
    _startResendTimer();
    // Auto-focus the first field.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNodes[0].requestFocus();
    });
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  void _startResendTimer() {
    _resendSeconds = 60;
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _resendSeconds--;
        if (_resendSeconds <= 0) timer.cancel();
      });
    });
  }

  String get _code => _controllers.map((c) => c.text).join();

  void _onDigitChanged(int index, String value) {
    if (value.length == 1 && index < 5) {
      _focusNodes[index + 1].requestFocus();
    }

    // Auto-submit when all 6 digits are entered.
    if (_code.length == 6) {
      _verify();
    }
  }

  void _onKeyPress(int index, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.backspace &&
        _controllers[index].text.isEmpty &&
        index > 0) {
      _focusNodes[index - 1].requestFocus();
      _controllers[index - 1].clear();
    }
  }

  Future<void> _verify() async {
    final code = _code;
    if (code.length != 6) {
      setState(() => _error = 'Please enter the full 6-digit code.');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Create a PhoneAuthCredential with the code.
      final credential = PhoneAuthProvider.credential(
        verificationId: _verificationId!,
        smsCode: code,
      );

      // Sign in with Firebase.
      final userCredential = await FirebaseAuth.instance.signInWithCredential(credential);

      if (userCredential.user == null) {
        throw Exception('Failed to sign in with Firebase');
      }

      // Get the Firebase ID token.
      final idToken = await userCredential.user!.getIdToken();

      // Register with our backend.
      final api = ApiClient.instance;
      final response = await api.post('/api/v1/auth/verify-otp', body: {
        'phone_number': widget.phoneNumber,
        'code': code,
        'firebase_token': idToken,
      });

      final accessToken = response['access_token'] as String;
      final refreshToken = response['refresh_token'] as String;
      final userId = response['user_id'] as String;
      final isNewUser = response['is_new_user'] as bool;

      // Save tokens.
      final authController = AuthController();
      await authController.completeLogin(
        accessToken: accessToken,
        refreshToken: refreshToken,
        userId: userId,
      );

      if (!mounted) return;

      if (isNewUser) {
        // Navigate to profile setup.
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ProfileSetupScreen(
              phoneNumber: widget.phoneNumber,
              code: code,
            ),
          ),
        );
      } else {
        // User already has profile, pop back to auth gate.
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } on FirebaseAuthException catch (e) {
      debugPrint('[Athur][auth] Firebase error: ${e.message}');
      if (mounted) {
        setState(() {
          _error = _getFirebaseErrorMessage(e);
          _clearCode();
        });
      }
    } catch (e) {
      debugPrint('[Athur][auth] Error: $e');
      if (mounted) {
        setState(() {
          _error = 'Invalid code. Please try again.';
          _clearCode();
        });
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _clearCode() {
    for (final c in _controllers) {
      c.clear();
    }
    _focusNodes[0].requestFocus();
  }

  String _getFirebaseErrorMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-verification-code':
        return 'The verification code is invalid.';
      case 'invalid-verification-id':
        return 'The verification ID is invalid. Please request a new code.';
      case 'session-expired':
        return 'The session has expired. Please request a new code.';
      case 'quota-exceeded':
        return 'SMS quota exceeded. Please try again later.';
      default:
        return e.message ?? 'An error occurred. Please try again.';
    }
  }

  Future<void> _resend() async {
    if (_resendSeconds > 0) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Resend SMS via Firebase Authentication.
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: widget.phoneNumber,
        timeout: const Duration(seconds: 60),
        forceResendingToken: null,
        verificationCompleted: (PhoneAuthCredential credential) async {
          // Auto-retrieval or instant verification.
          debugPrint('[Athur][auth] Auto-verification completed on resend');
          await FirebaseAuth.instance.signInWithCredential(credential);
          if (mounted) {
            Navigator.of(context).popUntil((route) => route.isFirst);
          }
        },
        verificationFailed: (FirebaseAuthException e) {
          debugPrint('[Athur][auth] Verification failed: ${e.message}');
          if (mounted) {
            setState(() {
              _error = _getFirebaseErrorMessage(e);
              _isLoading = false;
            });
          }
        },
        codeSent: (String verificationId, int? resendToken) {
          debugPrint('[Athur][auth] Code resent to ${widget.phoneNumber}');
          if (mounted) {
            setState(() {
              _verificationId = verificationId;
              _isLoading = false;
            });
            _startResendTimer();
          }
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          debugPrint('[Athur][auth] Auto-retrieval timeout');
        },
      );
    } catch (e) {
      debugPrint('[Athur][auth] Resend error: $e');
      if (mounted) {
        setState(() {
          _error = 'Failed to resend code. Please try again.';
          _isLoading = false;
        });
      }
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
              const SizedBox(height: 32),

              // Title
              const Text(
                'Verify your phone',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Enter the 6-digit code sent to',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 14,
                ),
              ),
              Text(
                widget.phoneNumber,
                style: const TextStyle(
                  color: AthurColors.gold,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 40),

              // OTP input fields
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(6, (index) {
                  return SizedBox(
                    width: 50,
                    height: 60,
                    child: KeyboardListener(
                      focusNode: FocusNode(),
                      onKeyEvent: (event) => _onKeyPress(index, event),
                      child: TextField(
                        controller: _controllers[index],
                        focusNode: _focusNodes[index],
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        maxLength: 1,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                        decoration: InputDecoration(
                          counterText: '',
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.05),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: AthurColors.gold,
                              width: 2,
                            ),
                          ),
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: (value) => _onDigitChanged(index, value),
                      ),
                    ),
                  );
                }),
              ),

              // Error
              if (_error != null) ...[
                const SizedBox(height: 20),
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

              const SizedBox(height: 32),

              // Verify button
              ElevatedButton(
                onPressed: (_isLoading || _code.length != 6) ? null : _verify,
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
                        'Verify',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),

              const SizedBox(height: 24),

              // Resend code
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    "Didn't receive the code? ",
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 14,
                    ),
                  ),
                  if (_resendSeconds > 0)
                    Text(
                      'Resend in ${_resendSeconds}s',
                      style: const TextStyle(
                        color: AthurColors.gold,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    )
                  else
                    GestureDetector(
                      onTap: _isLoading ? null : _resend,
                      child: const Text(
                        'Resend',
                        style: TextStyle(
                          color: AthurColors.gold,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),

              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

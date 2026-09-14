import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config/api_config.dart';
import '../services/api_client.dart';
import '../services/presence_service.dart';
import '../services/secure_storage.dart';
import '../services/websocket_service.dart';

/// Manages authentication state across the app.
///
/// Exposes a [ValueListenable] for the current [AuthState] so the UI
/// can reactively build based on whether the user is logged in,
/// loading, or needs to complete onboarding.
class AuthController extends ChangeNotifier {
  AuthController({ApiClient? api})
      // Host is chosen per platform by [ApiConfig] (web/emulator/device).
      : _api = api ?? ApiClient(baseUrl: ApiConfig.httpBaseUrl) {
    // Set the singleton instance for use across the app.
    ApiClient.instance = _api;
  }

  final ApiClient _api;
  final _storage = SecureStorage.instance;

  AuthState _state = const AuthState.initial();
  AuthState get state => _state;

  /// The API client, exposed so screens can make authenticated calls.
  ApiClient get api => _api;

  // ────────────────────────── Lifecycle ──────────────────────────

  /// Checks stored tokens and restores session if valid.
  Future<void> init() async {
    _setState(const AuthState.loading());

    try {
      final hasTokens = await _storage.hasTokens();
      if (!hasTokens) {
        _setState(const AuthState.unauthenticated());
        return;
      }

      final accessToken = await _storage.getAccessToken();
      final userId = await _storage.getUserId();

      if (accessToken == null || userId == null) {
        await _storage.clearAuthData();
        _setState(const AuthState.unauthenticated());
        return;
      }

      // Set the token on the API client for future requests.
      _api.setAccessToken(accessToken);

      // Verify the token is still valid by fetching /auth/me.
      final response = await _api.get('/api/v1/auth/me');
      final user = AuthUser.fromMap(response);

      _setState(AuthState.authenticated(user: user));
    } catch (e) {
      // Token expired or invalid — clear and go to unauthenticated.
      await _storage.clearAuthData();
      _api.setAccessToken(null);
      _setState(const AuthState.unauthenticated());
    }
  }

  // ────────────────────────── Auth Actions ──────────────────────────

  /// Requests an OTP code for the given phone number.
  Future<void> requestOtp(String phoneNumber) async {
    _setState(state.copyWith(isLoading: true));

    try {
      await _api.post('/api/v1/auth/request-otp', body: {
        'phone_number': phoneNumber,
      });
    } on ApiError catch (e) {
      _setState(state.copyWith(error: e.message));
      rethrow;
    } finally {
      _setState(state.copyWith(isLoading: false));
    }
  }

  /// Verifies the OTP and logs in / creates the user.
  Future<void> verifyOtp({
    required String phoneNumber,
    required String code,
    String? displayName,
  }) async {
    _setState(state.copyWith(isLoading: true));

    try {
      final deviceId = await _getDeviceId();
      final response = await _api.post('/api/v1/auth/verify-otp', body: {
        'phone_number': phoneNumber,
        'code': code,
        'device_id': deviceId,
        // ignore: use_null_aware_elements
        if (displayName case final name?) 'display_name': name,
      });

      final accessToken = response['access_token'] as String;
      final refreshToken = response['refresh_token'] as String;
      final userId = response['user_id'] as String;
      final isNewUser = response['is_new_user'] as bool;

      // Persist tokens.
      await _storage.saveAuthData(
        accessToken: accessToken,
        refreshToken: refreshToken,
        userId: userId,
      );
      _api.setAccessToken(accessToken);

      // Fetch full user profile.
      final meResponse = await _api.get('/api/v1/auth/me');
      final user = AuthUser.fromMap(meResponse);

      _setState(AuthState.authenticated(user: user, isNewUser: isNewUser));

      // Connect WebSocket and start presence listening.
      WebSocketService.instance.connect(userId: user.id, token: accessToken);
      PresenceService.instance.startListening();
    } on ApiError catch (e) {
      _setState(state.copyWith(error: e.message));
      rethrow;
    } finally {
      _setState(state.copyWith(isLoading: false));
    }
  }

  /// Completes login with tokens from Firebase Authentication flow.
  Future<void> completeLogin({
    required String accessToken,
    required String refreshToken,
    required String userId,
  }) async {
    _setState(state.copyWith(isLoading: true));

    try {
      // Persist tokens.
      await _storage.saveAuthData(
        accessToken: accessToken,
        refreshToken: refreshToken,
        userId: userId,
      );
      _api.setAccessToken(accessToken);

      // Fetch full user profile.
      final meResponse = await _api.get('/api/v1/auth/me');
      final user = AuthUser.fromMap(meResponse);

      _setState(AuthState.authenticated(user: user));

      // Connect WebSocket and start presence listening.
      WebSocketService.instance.connect(userId: user.id, token: accessToken);
      PresenceService.instance.startListening();
    } on ApiError catch (e) {
      _setState(state.copyWith(error: e.message));
      rethrow;
    } finally {
      _setState(state.copyWith(isLoading: false));
    }
  }

  /// Refreshes the access token using the stored refresh token.
  Future<bool> refreshTokens() async {
    try {
      final refreshToken = await _storage.getRefreshToken();
      if (refreshToken == null) return false;

      final deviceId = await _getDeviceId();
      final response = await _api.post('/api/v1/auth/refresh', body: {
        'refresh_token': refreshToken,
        'device_id': deviceId,
      });

      final newAccessToken = response['access_token'] as String;
      final newRefreshToken = response['refresh_token'] as String;

      await _storage.saveAccessToken(newAccessToken);
      await _storage.saveRefreshToken(newRefreshToken);
      _api.setAccessToken(newAccessToken);

      return true;
    } catch (e) {
      return false;
    }
  }

  /// Logs out and clears all stored data.
  Future<void> logout() async {
    try {
      final deviceId = await _getDeviceId();
      await _api.post('/api/v1/auth/logout', body: {
        'device_id': deviceId,
      });
    } catch (_) {
      // Ignore logout errors — clear local state regardless.
    }

    await _storage.clearAuthData();
    _api.setAccessToken(null);
    _setState(const AuthState.unauthenticated());
  }

  // ────────────────────────── Private ──────────────────────────

  void _setState(AuthState newState) {
    _state = newState;
    notifyListeners();
  }

  Future<String> _getDeviceId() async {
    var deviceId = await _storage.getDeviceId();
    if (deviceId == null) {
      // Generate a stable device ID (UUID v4).
      deviceId = _generateDeviceId();
      await _storage.saveDeviceId(deviceId);
    }
    return deviceId;
  }

  String _generateDeviceId() {
    // Simple UUID v4 generator without external dependency.
    final timestamp = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    return 'athur-$timestamp';
  }
}

/// Authentication state.
class AuthState {
  const AuthState({
    this.status = AuthStatus.initial,
    this.user,
    this.isLoading = false,
    this.error,
    this.isNewUser = false,
  });

  const AuthState.initial()
      : status = AuthStatus.initial,
        user = null,
        isLoading = false,
        error = null,
        isNewUser = false;

  const AuthState.loading()
      : status = AuthStatus.loading,
        user = null,
        isLoading = true,
        error = null,
        isNewUser = false;

  const AuthState.unauthenticated()
      : status = AuthStatus.unauthenticated,
        user = null,
        isLoading = false,
        error = null,
        isNewUser = false;

  const AuthState.authenticated({
    required AuthUser this.user,
    this.isNewUser = false,
  })  : status = AuthStatus.authenticated,
        isLoading = false,
        error = null;

  final AuthStatus status;
  final AuthUser? user;
  final bool isLoading;
  final String? error;
  final bool isNewUser;

  bool get isAuthenticated => status == AuthStatus.authenticated;
  bool get isUnauthenticated => status == AuthStatus.unauthenticated;

  AuthState copyWith({
    AuthStatus? status,
    AuthUser? user,
    bool? isLoading,
    String? error,
    bool? isNewUser,
  }) {
    return AuthState(
      status: status ?? this.status,
      user: user ?? this.user,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      isNewUser: isNewUser ?? this.isNewUser,
    );
  }
}

enum AuthStatus { initial, loading, authenticated, unauthenticated }

/// User model returned from /auth/me.
class AuthUser {
  const AuthUser({
    required this.id,
    required this.username,
    required this.status,
    this.displayName,
    this.bio,
    this.avatarKey,
  });

  factory AuthUser.fromMap(Map<String, Object?> map) {
    return AuthUser(
      id: map['id'] as String,
      username: map['username'] as String? ?? '',
      status: map['status'] as String? ?? 'active',
      displayName: map['display_name'] as String?,
      bio: map['bio'] as String?,
      avatarKey: map['avatar_key'] as String?,
    );
  }

  final String id;
  final String username;
  final String status;
  final String? displayName;
  final String? bio;
  final String? avatarKey;

  String get effectiveDisplayName => displayName ?? username;
}

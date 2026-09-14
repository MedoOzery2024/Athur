import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure storage for sensitive auth data (JWT tokens, user ID).
///
/// Uses [FlutterSecureStorage] which encrypts data on both Android (EncryptedSharedPreferences)
/// and iOS (Keychain). Tokens are never stored in plain SharedPreferences.
class SecureStorage {
  SecureStorage._();

  static final SecureStorage instance = SecureStorage._();

  static const _accessTokenKey = 'athur_access_token';
  static const _refreshTokenKey = 'athur_refresh_token';
  static const _userIdKey = 'athur_user_id';
  static const _deviceIdKey = 'athur_device_id';

  final _storage = const FlutterSecureStorage();

  // ────────────────────────── Access Token ──────────────────────────

  Future<void> saveAccessToken(String token) =>
      _storage.write(key: _accessTokenKey, value: token);

  Future<String?> getAccessToken() =>
      _storage.read(key: _accessTokenKey);

  Future<void> deleteAccessToken() =>
      _storage.delete(key: _accessTokenKey);

  // ────────────────────────── Refresh Token ──────────────────────────

  Future<void> saveRefreshToken(String token) =>
      _storage.write(key: _refreshTokenKey, value: token);

  Future<String?> getRefreshToken() =>
      _storage.read(key: _refreshTokenKey);

  Future<void> deleteRefreshToken() =>
      _storage.delete(key: _refreshTokenKey);

  // ────────────────────────── User ID ──────────────────────────

  Future<void> saveUserId(String userId) =>
      _storage.write(key: _userIdKey, value: userId);

  Future<String?> getUserId() =>
      _storage.read(key: _userIdKey);

  Future<void> deleteUserId() =>
      _storage.delete(key: _userIdKey);

  // ────────────────────────── Device ID ──────────────────────────

  Future<void> saveDeviceId(String deviceId) =>
      _storage.write(key: _deviceIdKey, value: deviceId);

  Future<String?> getDeviceId() =>
      _storage.read(key: _deviceIdKey);

  // ────────────────────────── Bulk Operations ──────────────────────────

  /// Saves all tokens and user ID after successful auth.
  Future<void> saveAuthData({
    required String accessToken,
    required String refreshToken,
    required String userId,
  }) async {
    await Future.wait([
      saveAccessToken(accessToken),
      saveRefreshToken(refreshToken),
      saveUserId(userId),
    ]);
  }

  /// Clears all auth data on logout.
  Future<void> clearAuthData() async {
    await Future.wait([
      deleteAccessToken(),
      deleteRefreshToken(),
      deleteUserId(),
    ]);
  }

  /// Returns true if the user has stored tokens (likely logged in).
  Future<bool> hasTokens() async {
    final token = await getAccessToken();
    return token != null && token.isNotEmpty;
  }
}

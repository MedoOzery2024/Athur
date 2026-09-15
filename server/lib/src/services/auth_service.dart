import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';

/// Core authentication logic: OTP generation/verification, JWT minting,
/// password hashing, and user creation. Stateless — no sessions stored
/// in memory; everything is in PostgreSQL.
class AuthService {
  AuthService({required this.db, required this.jwtSecret});

  final Database db;
  final String jwtSecret;

  static const _uuid = Uuid();
  static const _otpLength = 6;
  static const _otpExpiryMinutes = 10;
  static const _otpMaxAttempts = 5;
  static const _accessTokenTtlMinutes = 15;
  static const _refreshTokenTtlDays = 30;

  // ────────────────────────── OTP ──────────────────────────

  /// Generates a numeric OTP, hashes it, stores it in `otp_challenges`,
  /// and returns the plaintext code (to be sent via SMS/email).
  Future<String> createOtp({
    required String phoneNumber,
    String purpose = 'signup',
  }) async {
    final code = _generateOtpCode();

    // Rate-limit: reject if an unexpired challenge was created in the last
    // minute for this destination.
    // NOTE: the schema column is `destination` (+ `channel`), not
    // `phone_number` — using the wrong name made every OTP request fail.
    final recent = await db.execute(
      'SELECT 1 FROM otp_challenges '
      'WHERE destination = @phone '
      "AND channel = 'phone' "
      'AND purpose = @purpose '
      "AND created_at > now() - interval '1 minute'",
      parameters: {'phone': phoneNumber, 'purpose': purpose},
    );
    if (recent.isNotEmpty) {
      throw const AuthError(
        statusCode: 429,
        code: 'RATE_LIMITED',
        message: 'Please wait before requesting a new code.',
      );
    }

    // `salt` is required by the schema (NOT NULL). A per-challenge random salt
    // is generated here and stored; verification re-hashes with it below.
    final salt = _generateSalt();
    final saltedHash =
        sha256.convert(utf8.encode('$salt$code')).toString();

    await db.execute(
      'INSERT INTO otp_challenges '
      '(channel, destination, purpose, code_hash, salt, max_attempts, expires_at) '
      "VALUES ('phone', @phone, @purpose, @hash, @salt, @maxAttempts, "
      "now() + interval '$_otpExpiryMinutes minutes')",
      parameters: {
        'phone': phoneNumber,
        'purpose': purpose,
        'hash': saltedHash,
        'salt': salt,
        'maxAttempts': _otpMaxAttempts,
      },
    );

    return code;
  }

  /// Verifies an OTP code. Returns the phone number on success.
  Future<String> verifyOtp({
    required String phoneNumber,
    required String code,
    String purpose = 'signup',
  }) async {
    final rows = await db.execute(
      'SELECT id, code_hash, salt, attempts, expires_at, consumed_at '
      'FROM otp_challenges '
      'WHERE destination = @phone AND channel = \'phone\' AND purpose = @purpose '
      'ORDER BY created_at DESC LIMIT 1',
      parameters: {'phone': phoneNumber, 'purpose': purpose},
    );

    if (rows.isEmpty) {
      throw const AuthError(
        statusCode: 400,
        code: 'OTP_NOT_FOUND',
        message: 'No verification code found. Please request a new one.',
      );
    }

    final row = rows.first;
    final storedHash = row[1] as String;
    final salt = row[2] as String;
    final attempts = row[3] as int;
    final expiresAt = row[4] as DateTime;
    final consumedAt = row[5];

    // A challenge can only be used once.
    if (consumedAt != null) {
      throw const AuthError(
        statusCode: 400,
        code: 'OTP_ALREADY_USED',
        message: 'This code has already been used. Request a new one.',
      );
    }

    if (attempts >= _otpMaxAttempts) {
      throw const AuthError(
        statusCode: 429,
        code: 'OTP_MAX_ATTEMPTS',
        message: 'Too many attempts. Please request a new code.',
      );
    }

    if (DateTime.now().toUtc().isAfter(expiresAt)) {
      throw const AuthError(
        statusCode: 400,
        code: 'OTP_EXPIRED',
        message: 'Verification code has expired. Please request a new one.',
      );
    }

    // Increment the attempt counter BEFORE checking, so a wrong code always
    // consumes an attempt (brute-force protection).
    await db.execute(
      'UPDATE otp_challenges SET attempts = attempts + 1 WHERE id = @id',
      parameters: {'id': row[0]},
    );

    final inputHash =
        sha256.convert(utf8.encode('$salt$code')).toString();
    if (inputHash != storedHash) {
      throw const AuthError(
        statusCode: 400,
        code: 'OTP_INVALID',
        message: 'Invalid verification code.',
      );
    }

    // Mark consumed (single-use) instead of deleting, so the record remains
    // for audit and replay detection.
    await db.execute(
      'UPDATE otp_challenges SET consumed_at = now() WHERE id = @id',
      parameters: {'id': row[0]},
    );

    return phoneNumber;
  }

  // ────────────────────────── User ──────────────────────────

  /// Creates a new user with phone number. Returns userId.
  Future<String> createUser({
    required String phoneNumber,
    String? displayName,
  }) async {
    final userId = _uuid.v4();

    await db.transaction<void>((session) async {
      // Insert user.
      // NOTE: `users.username` has a CHECK constraint requiring the shape
      // ^[a-z0-9_]{3,32}$ — a raw phone number (contains '+' and is too long)
      // violates it. We generate a valid placeholder that is unique.
      await session.execute(
        'INSERT INTO users (id, username, status) VALUES (@id, @username, @status)',
        parameters: {
          'id': userId,
          'username': _generatePlaceholderUsername(),
          'status': 'active',
        },
      );

      // Insert profile.
      await session.execute(
        'INSERT INTO user_profiles (user_id, display_name) VALUES (@id, @name)',
        parameters: {
          'id': userId,
          'name': displayName ?? _generateDefaultName(phoneNumber),
        },
      );

      // Insert phone number. The column is `e164`, not `phone_number`.
      await session.execute(
        'INSERT INTO phone_numbers (user_id, e164, is_primary, is_verified, verified_at) '
        'VALUES (@id, @phone, true, true, now())',
        parameters: {'id': userId, 'phone': phoneNumber},
      );

      // Insert auth identity. `auth_identities` has no `is_primary` column.
      await session.execute(
        'INSERT INTO auth_identities (user_id, provider, provider_uid, is_verified) '
        'VALUES (@id, @provider, @uid, true)',
        parameters: {
          'id': userId,
          'provider': 'phone',
          'uid': phoneNumber,
        },
      );
    });

    return userId;
  }

  /// Finds an existing user by phone number.
  Future<String?> findUserByPhone(String phoneNumber) async {
    // Column is `e164`.
    final rows = await db.execute(
      'SELECT user_id FROM phone_numbers WHERE e164 = @phone LIMIT 1',
      parameters: {'phone': phoneNumber},
    );
    return rows.isEmpty ? null : rows.first[0].toString();
  }

  // ────────────────────────── JWT ──────────────────────────

  /// Mints an access + refresh token pair for a user.
  Future<TokenPair> mintTokens({
    required String userId,
    required String deviceId,
  }) async {
    final accessToken = _mintJwt(
      subject: userId,
      type: 'access',
      extra: {'device_id': deviceId},
      ttlMinutes: _accessTokenTtlMinutes,
    );

    final refreshToken = _mintJwt(
      subject: userId,
      type: 'refresh',
      extra: {'device_id': deviceId},
      ttlMinutes: _refreshTokenTtlDays * 24 * 60,
    );

    // Persist the session chain: device → session → refresh token.
    //
    // Schema reality: `refresh_tokens` has NO `device_id` column — the device
    // is reached through `session_id` → `sessions.device_id`. Storing tokens
    // with the wrong column made every login fail.
    final sessionId = await _ensureSession(
      userId: userId,
      deviceId: deviceId,
    );

    final tokenHash = sha256.convert(utf8.encode(refreshToken)).toString();
    await db.execute(
      'INSERT INTO refresh_tokens (session_id, user_id, token_hash, expires_at) '
      'VALUES (@session, @uid, @hash, now() + interval \'$_refreshTokenTtlDays days\')',
      parameters: {
        'session': sessionId,
        'uid': userId,
        'hash': tokenHash,
      },
    );

    return TokenPair(accessToken: accessToken, refreshToken: refreshToken);
  }

  /// Finds or creates the device row for [deviceId], then opens a fresh
  /// session for it. Returns the session id.
  ///
  /// `deviceId` here is the client's stable install id, which maps to
  /// `devices.install_id` (unique per user).
  Future<String> _ensureSession({
    required String userId,
    required String deviceId,
  }) async {
    // Reuse the device row if this install already registered.
    final existing = await db.execute(
      'SELECT id FROM devices WHERE user_id = @uid AND install_id = @install LIMIT 1',
      parameters: {'uid': userId, 'install': deviceId},
    );

    final String deviceRowId;
    if (existing.isNotEmpty) {
      deviceRowId = existing.first[0].toString();
      // Refresh last-activity so presence/session screens stay accurate.
      await db.execute(
        'UPDATE devices SET last_active_at = now(), updated_at = now() '
        'WHERE id = @id',
        parameters: {'id': deviceRowId},
      );
    } else {
      deviceRowId = _uuid.v4();
      await db.execute(
        'INSERT INTO devices (id, user_id, install_id, platform) '
        "VALUES (@id, @uid, @install, 'android')",
        parameters: {
          'id': deviceRowId,
          'uid': userId,
          'install': deviceId,
        },
      );
    }

    // Open a new session for this device.
    final sessionId = _uuid.v4();
    await db.execute(
      'INSERT INTO sessions (id, user_id, device_id) VALUES (@id, @uid, @device)',
      parameters: {
        'id': sessionId,
        'uid': userId,
        'device': deviceRowId,
      },
    );
    return sessionId;
  }

  /// Verifies an access token and returns the userId.
  Future<String> verifyAccessToken(String token) async {
    try {
      final jwt = JWT.verify(token, SecretKey(jwtSecret));
      if (jwt.payload['type'] != 'access') {
        throw const AuthError(
          statusCode: 401,
          code: 'INVALID_TOKEN',
          message: 'Invalid token type.',
        );
      }
      return jwt.payload['sub'] as String;
    } catch (e) {
      throw const AuthError(
        statusCode: 401,
        code: 'TOKEN_EXPIRED',
        message: 'Access token has expired.',
      );
    }
  }

  /// Rotates refresh token: verifies old one, mints new pair, deletes old.
  Future<TokenPair> refreshTokens({
    required String refreshToken,
    required String deviceId,
  }) async {
    // Verify the JWT.
    String userId;
    try {
      final jwt = JWT.verify(refreshToken, SecretKey(jwtSecret));
      if (jwt.payload['type'] != 'refresh') {
        throw const AuthError(
          statusCode: 401,
          code: 'INVALID_TOKEN',
          message: 'Invalid token type.',
        );
      }
      userId = jwt.payload['sub'] as String;
    } catch (e) {
      throw const AuthError(
        statusCode: 401,
        code: 'TOKEN_EXPIRED',
        message: 'Refresh token has expired.',
      );
    }

    // Check if the token hash exists and is still usable (replay detection).
    final tokenHash = sha256.convert(utf8.encode(refreshToken)).toString();
    final rows = await db.execute(
      'SELECT id, session_id FROM refresh_tokens '
      'WHERE token_hash = @hash AND user_id = @uid '
      'AND revoked_at IS NULL AND rotated_at IS NULL',
      parameters: {'hash': tokenHash, 'uid': userId},
    );

    if (rows.isEmpty) {
      // The token is unknown or already used: likely replay/theft. Revoke every
      // live refresh token for this user's device, forcing a fresh login.
      await db.execute(
        'UPDATE refresh_tokens SET revoked_at = now(), revoked_reason = \'reuse_detected\' '
        'WHERE user_id = @uid AND session_id IN '
        '(SELECT id FROM sessions WHERE user_id = @uid AND device_id IN '
        '(SELECT id FROM devices WHERE user_id = @uid AND install_id = @install))',
        parameters: {'uid': userId, 'install': deviceId},
      );
      throw const AuthError(
        statusCode: 401,
        code: 'TOKEN_REUSED',
        message: 'Refresh token has been revoked.',
      );
    }

    // Rotate: mark the old token as used and link nothing yet (the successor is
    // recorded below by updating this row's `rotated_at`).
    final oldTokenId = rows.first[0].toString();
    await db.execute(
      'UPDATE refresh_tokens SET rotated_at = now() WHERE id = @id',
      parameters: {'id': oldTokenId},
    );

    // Mint a new pair (which opens a new session for the device).
    return mintTokens(userId: userId, deviceId: deviceId);
  }

  /// Logs out: revokes the device's live refresh tokens and ends its sessions.
  ///
  /// We revoke rather than delete so the security audit trail survives.
  Future<void> logout({
    required String userId,
    required String deviceId,
  }) async {
    // Revoke refresh tokens that belong to any session of this device.
    await db.execute(
      'UPDATE refresh_tokens SET revoked_at = now(), revoked_reason = \'logout\' '
      'WHERE user_id = @uid AND revoked_at IS NULL AND session_id IN '
      '(SELECT s.id FROM sessions s JOIN devices d ON d.id = s.device_id '
      ' WHERE s.user_id = @uid AND d.install_id = @install)',
      parameters: {'uid': userId, 'install': deviceId},
    );

    // End the device's open sessions.
    await db.execute(
      'UPDATE sessions SET ended_at = now(), ended_reason = \'logout\' '
      'WHERE user_id = @uid AND ended_at IS NULL AND device_id IN '
      '(SELECT id FROM devices WHERE user_id = @uid AND install_id = @install)',
      parameters: {'uid': userId, 'install': deviceId},
    );
  }

  // ────────────────────────── Private ──────────────────────────

  String _generateOtpCode() {
    final random = Random.secure();
    final code = List.generate(_otpLength, (_) => random.nextInt(10)).join();
    return code;
  }

  /// A per-challenge random salt (hex), stored alongside the code hash.
  String _generateSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Generates a valid, unique placeholder username.
  ///
  /// Must satisfy the schema CHECK `^[a-z0-9_]{3,32}$`. The real username is
  /// chosen by the user during profile setup.
  String _generatePlaceholderUsername() {
    final random = Random.secure();
    final suffix = List.generate(10, (_) => random.nextInt(10)).join();
    return 'athur_$suffix';
  }

  String _mintJwt({
    required String subject,
    required String type,
    required Map<String, Object?> extra,
    required int ttlMinutes,
  }) {
    final jwt = JWT({
      'sub': subject,
      'type': type,
      ...extra,
      'iat': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
      'exp': DateTime.now()
          .toUtc()
          .add(Duration(minutes: ttlMinutes))
          .millisecondsSinceEpoch ~/
          1000,
    });
    return jwt.sign(SecretKey(jwtSecret));
  }

  String _generateDefaultName(String phoneNumber) {
    // Mask phone: +1234***5678
    if (phoneNumber.length > 7) {
      return '${phoneNumber.substring(0, 4)}***${phoneNumber.substring(phoneNumber.length - 4)}';
    }
    return phoneNumber;
  }
}

/// Token pair returned after authentication.
class TokenPair {
  const TokenPair({required this.accessToken, required this.refreshToken});
  final String accessToken;
  final String refreshToken;

  Map<String, Object?> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
  };
}

/// Auth-specific error.
class AuthError implements Exception {
  const AuthError({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() => 'AuthError($statusCode $code): $message';
}

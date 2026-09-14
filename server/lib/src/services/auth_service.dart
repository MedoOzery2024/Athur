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
    final codeHash = sha256.convert(utf8.encode(code)).toString();

    // Rate-limit: reject if there's an unexpired challenge in the last minute.
    final recent = await db.execute(
      'SELECT 1 FROM otp_challenges '
      'WHERE phone_number = @phone '
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

    await db.execute(
      'INSERT INTO otp_challenges (phone_number, purpose, code_hash, expires_at) '
      'VALUES (@phone, @purpose, @hash, now() + interval \'$_otpExpiryMinutes minutes\')',
      parameters: {
        'phone': phoneNumber,
        'purpose': purpose,
        'hash': codeHash,
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
      'SELECT id, code_hash, attempts, expires_at FROM otp_challenges '
      'WHERE phone_number = @phone AND purpose = @purpose '
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
    final attempts = row[2] as int;
    final expiresAt = row[3] as DateTime;

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

    // Increment attempts.
    await db.execute(
      'UPDATE otp_challenges SET attempts = attempts + 1 WHERE id = @id',
      parameters: {'id': row[0]},
    );

    final inputHash = sha256.convert(utf8.encode(code)).toString();
    if (inputHash != row[1]) {
      throw const AuthError(
        statusCode: 400,
        code: 'OTP_INVALID',
        message: 'Invalid verification code.',
      );
    }

    // Delete used OTP to prevent replay.
    await db.execute(
      'DELETE FROM otp_challenges WHERE id = @id',
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
      await session.execute(
        'INSERT INTO users (id, username, status) VALUES (@id, @username, @status)',
        parameters: {
          'id': userId,
          'username': phoneNumber, // temporary; updated in profile setup
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

      // Insert phone number.
      await session.execute(
        'INSERT INTO phone_numbers (user_id, phone_number, is_primary, is_verified) '
        'VALUES (@id, @phone, true, true)',
        parameters: {'id': userId, 'phone': phoneNumber},
      );

      // Insert auth identity.
      await session.execute(
        'INSERT INTO auth_identities (user_id, provider, provider_uid, is_primary) '
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
    final rows = await db.execute(
      'SELECT user_id FROM phone_numbers WHERE phone_number = @phone LIMIT 1',
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

    // Store hashed refresh token in DB.
    final tokenHash = sha256.convert(utf8.encode(refreshToken)).toString();
    await db.execute(
      'INSERT INTO refresh_tokens (user_id, token_hash, device_id, expires_at) '
      'VALUES (@uid, @hash, @device, now() + interval \'$_refreshTokenTtlDays days\')',
      parameters: {
        'uid': userId,
        'hash': tokenHash,
        'device': deviceId,
      },
    );

    return TokenPair(accessToken: accessToken, refreshToken: refreshToken);
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

    // Check if the token hash exists in DB (replay detection).
    final tokenHash = sha256.convert(utf8.encode(refreshToken)).toString();
    final rows = await db.execute(
      'SELECT id FROM refresh_tokens WHERE token_hash = @hash AND user_id = @uid',
      parameters: {'hash': tokenHash, 'uid': userId},
    );

    if (rows.isEmpty) {
      // Possible token reuse — delete all tokens for this device.
      await db.execute(
        'DELETE FROM refresh_tokens WHERE device_id = @device AND user_id = @uid',
        parameters: {'device': deviceId, 'uid': userId},
      );
      throw const AuthError(
        statusCode: 401,
        code: 'TOKEN_REUSED',
        message: 'Refresh token has been revoked.',
      );
    }

    // Delete the used token.
    await db.execute(
      'DELETE FROM refresh_tokens WHERE id = @id',
      parameters: {'id': rows.first[0]},
    );

    // Mint new pair.
    return mintTokens(userId: userId, deviceId: deviceId);
  }

  /// Logs out: deletes all refresh tokens for a device.
  Future<void> logout({
    required String userId,
    required String deviceId,
  }) async {
    await db.execute(
      'DELETE FROM refresh_tokens WHERE user_id = @uid AND device_id = @device',
      parameters: {'uid': userId, 'device': deviceId},
    );
  }

  // ────────────────────────── Private ──────────────────────────

  String _generateOtpCode() {
    final random = Random.secure();
    final code = List.generate(_otpLength, (_) => random.nextInt(10)).join();
    return code;
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

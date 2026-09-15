import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../api/json.dart';
import '../../core/errors/api_error.dart';
import '../../services/auth_service.dart';
import '../middleware/auth_middleware.dart';

/// Authentication endpoints: signup, login (OTP), token refresh, logout.
///
/// Routes:
/// - `POST /api/v1/auth/request-otp`  → send OTP to phone
/// - `POST /api/v1/auth/verify-otp`   → verify OTP + create/login user
/// - `POST /api/v1/auth/refresh`      → rotate refresh token
/// - `POST /api/v1/auth/logout`       → revoke refresh tokens
/// - `GET  /api/v1/auth/me`           → current user info (requires auth)
/// - `PUT  /api/v1/auth/profile`      → update display name and bio
class AuthRoutes {
  AuthRoutes({required this.authService});

  final AuthService authService;

  Router get router {
    final router = Router();
    final auth = authMiddleware(authService);

    // ── Request OTP (public) ────────────────────────────────
    router.post('/auth/request-otp', _requestOtp);

    // ── Verify OTP (public) ─────────────────────────────────
    router.post('/auth/verify-otp', _verifyOtp);

    // ── Refresh tokens (public) ─────────────────────────────
    router.post('/auth/refresh', _refresh);

    // ── Logout (authenticated) ──────────────────────────────
    router.post('/auth/logout', auth(_logout));

    // ── Current user (authenticated) ────────────────────────
    router.get('/auth/me', auth(_me));

    // ── Update profile (authenticated) ──────────────────────
    router.put('/auth/profile', auth(_updateProfile));

    return router;
  }

  // ───────────────────────── Handlers ──────────────────────────

  Future<Response> _requestOtp(Request request) async {
    final body = await Json.readObject(request);
    final phone = body['phone_number'] as String?;

    if (phone == null || phone.trim().isEmpty) {
      throw const ApiError.badRequest('phone_number is required.');
    }

    final phoneRegex = RegExp(r'^\+[1-9]\d{6,14}$');
    if (!phoneRegex.hasMatch(phone)) {
      throw const ApiError.badRequest(
        'phone_number must be in E.164 format (e.g. +1234567890).',
      );
    }

    final code = await authService.createOtp(phoneNumber: phone);

    // TODO: send SMS via provider (Twilio, etc.)
    // For development, log the OTP so it can be tested.
    // ignore: avoid_print
    print('[AUTH] OTP for $phone: $code');

    return Json.ok({
      'message': 'Verification code sent.',
      // Include code in development for testing. Remove in production!
      'dev_otp': code,
    });
  }

  Future<Response> _verifyOtp(Request request) async {
    final body = await Json.readObject(request);
    final phone = body['phone_number'] as String?;
    final code = body['code'] as String?;
    final deviceId = body['device_id'] as String?;
    final displayName = body['display_name'] as String?;

    if (phone == null || phone.trim().isEmpty) {
      throw const ApiError.badRequest('phone_number is required.');
    }
    if (code == null || code.trim().isEmpty) {
      throw const ApiError.badRequest('code is required.');
    }
    if (deviceId == null || deviceId.trim().isEmpty) {
      throw const ApiError.badRequest('device_id is required.');
    }

    // Verify the OTP.
    await authService.verifyOtp(phoneNumber: phone, code: code);

    // Find or create user.
    var userId = await authService.findUserByPhone(phone);
    var isNewUser = false;

    if (userId == null) {
      userId = await authService.createUser(
        phoneNumber: phone,
        displayName: displayName,
      );
      isNewUser = true;
    }

    // Mint tokens.
    final tokens = await authService.mintTokens(
      userId: userId,
      deviceId: deviceId,
    );

    return Json.ok({
      'user_id': userId,
      'is_new_user': isNewUser,
      ...tokens.toJson(),
    });
  }

  Future<Response> _refresh(Request request) async {
    final body = await Json.readObject(request);
    final refreshToken = body['refresh_token'] as String?;
    final deviceId = body['device_id'] as String?;

    if (refreshToken == null || refreshToken.trim().isEmpty) {
      throw const ApiError.badRequest('refresh_token is required.');
    }
    if (deviceId == null || deviceId.trim().isEmpty) {
      throw const ApiError.badRequest('device_id is required.');
    }

    final tokens = await authService.refreshTokens(
      refreshToken: refreshToken,
      deviceId: deviceId,
    );

    return Json.ok(tokens.toJson());
  }

  Future<Response> _logout(Request request) async {
    final body = await Json.readObject(request);
    final deviceId = body['device_id'] as String?;

    if (deviceId == null || deviceId.trim().isEmpty) {
      throw const ApiError.badRequest('device_id is required.');
    }

    // Extract userId from access token (if present).
    final authHeader = request.headers['authorization'];
    String? userId;
    if (authHeader != null && authHeader.startsWith('Bearer ')) {
      try {
        userId = await authService.verifyAccessToken(
          authHeader.substring(7),
        );
      } catch (_) {
        // Token might be expired — still allow logout.
      }
    }

    if (userId != null) {
      await authService.logout(userId: userId, deviceId: deviceId);
    }

    return Json.ok({'message': 'Logged out successfully.'});
  }

  Future<Response> _me(Request request) async {
    // UserId is injected by auth middleware.
    final userId = request.context['userId'] as String?;

    if (userId == null) {
      throw const ApiError.unauthorized();
    }

    // Fetch user + profile from DB.
    final rows = await authService.db.execute(
      'SELECT u.id, u.username, u.status, p.display_name, p.bio, p.avatar_key '
      'FROM users u '
      'LEFT JOIN user_profiles p ON p.user_id = u.id '
      'WHERE u.id = @id',
      parameters: {'id': userId},
    );

    if (rows.isEmpty) {
      throw const ApiError.notFound('User not found.');
    }

    final row = rows.first;
    // The driver returns some columns as raw UTF-8 bytes when it cannot infer a
    // concrete type (notably values from a LEFT JOIN). Decoding explicitly
    // avoids "Converting object to an encodable object failed: Instance of
    // 'UndecodedBytes'" when the response is JSON-encoded.
    final avatarKey = _asText(row[5]);
    final host = request.headers['host'] ?? 'localhost:8080';
    // Serve media over the same scheme the request arrived on (https via a
    // tunnel/reverse proxy, http locally).
    final scheme = request.headers['x-forwarded-proto'] ?? 'http';
    final avatarUrl =
        avatarKey != null ? '$scheme://$host/api/v1/media/$avatarKey' : null;
    return Json.ok({
      'id': _asText(row[0]),
      'username': _asText(row[1]),
      'status': _asText(row[2]),
      'display_name': _asText(row[3]),
      'bio': _asText(row[4]),
      'avatar_url': avatarUrl,
    });
  }

  /// Converts a database value to a JSON-safe string.
  ///
  /// Handles `UndecodedBytes` (raw UTF-8 from the driver), null and other
  /// scalar types so responses never fail to encode.
  static String? _asText(Object? value) {
    if (value == null) return null;
    if (value is String) return value;
    if (value is List<int>) return utf8.decode(value);
    // The postgres driver may hand back an `UndecodedBytes` wrapper instead of
    // a String. Its `toString()` is useless, so decode it via its bytes when
    // available, falling back to its textual form only as a last resort.
    // `UndecodedBytes` exposes its raw bytes through a getter; reach it
    // reflectively via `dynamic` so this file does not depend on the driver's
    // internal type. If that fails, fall back to a plain toString().
    try {
      // ignore: avoid_dynamic_calls
      final Object? bytes = (value as dynamic).bytes as Object?;
      if (bytes is List<int>) return utf8.decode(bytes);
    } catch (_) {
      // Not byte-backed — fall through.
    }
    return value.toString();
  }

  Future<Response> _updateProfile(Request request) async {
    final userId = request.context['userId'] as String?;

    if (userId == null) {
      throw const ApiError.unauthorized();
    }

    final body = await Json.readObject(request);
    final displayName = body['display_name'] as String?;
    final bio = body['bio'] as String?;
    final avatarUrl = body['avatar_url'] as String?;

    // Validate display name length.
    if (displayName != null && (displayName.isEmpty || displayName.length > 64)) {
      throw const ApiError.badRequest('display_name must be between 1 and 64 characters.');
    }

    // Validate bio length.
    if (bio != null && bio.length > 500) {
      throw const ApiError.badRequest('bio must be at most 500 characters.');
    }

    // Extract storage key from avatar URL if provided.
    String? avatarKey;
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      // Extract the media ID from the URL (e.g., /api/v1/media/{id})
      final uri = Uri.parse(avatarUrl);
      final pathSegments = uri.pathSegments;
      if (pathSegments.length >= 3 && pathSegments[pathSegments.length - 2] == 'media') {
        avatarKey = pathSegments.last;
      } else {
        avatarKey = avatarUrl;
      }
    }

    // Update or insert profile.
    await authService.db.execute(
      '''
      INSERT INTO user_profiles (user_id, display_name, bio, avatar_key, created_at, updated_at)
      VALUES (@userId, @displayName, @bio, @avatarKey, NOW(), NOW())
      ON CONFLICT (user_id) DO UPDATE
      SET display_name = COALESCE(@displayName, user_profiles.display_name),
          bio = COALESCE(@bio, user_profiles.bio),
          avatar_key = COALESCE(@avatarKey, user_profiles.avatar_key),
          updated_at = NOW()
      ''',
      parameters: {
        'userId': userId,
        'displayName': displayName,
        'bio': bio,
        'avatarKey': avatarKey,
      },
    );

    return Json.ok({'message': 'Profile updated successfully.'});
  }
}

import 'package:shelf/shelf.dart';

import '../../services/auth_service.dart';

/// Extension to easily access authenticated user ID from request context.
extension AuthRequestExtension on Request {
  /// Returns the authenticated user ID, or null if not authenticated.
  String? get userId => context['userId'] as String?;
}

/// Middleware that verifies the JWT access token and injects `userId`
/// into the request context. Routes that require authentication use this.
///
/// Usage:
/// ```dart
/// router.get('/protected', authMiddleware(_handler));
/// ```
Middleware authMiddleware(AuthService authService) {
  return (Handler inner) {
    return (Request request) async {
      final authHeader = request.headers['authorization'];

      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return Response(
          401,
          body: '{"error":{"code":"UNAUTHORIZED","message":"Missing or invalid Authorization header."}}',
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }

      final token = authHeader.substring(7);
      try {
        final userId = await authService.verifyAccessToken(token);
        // Inject userId into request context for downstream handlers.
        final updatedRequest = request.change(context: {'userId': userId});
        return await inner(updatedRequest);
      } on AuthError catch (e) {
        return Response(
          e.statusCode,
          body: '{"error":{"code":"${e.code}","message":"${e.message}"}}',
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
    };
  };
}

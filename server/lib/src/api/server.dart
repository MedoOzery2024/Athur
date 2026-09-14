import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../config/server_config.dart';
import '../core/errors/api_error.dart';
import '../data/database.dart';
import '../integrations/fcm/fcm_service.dart';
import '../integrations/turn/turn_credential_service.dart';
import '../services/auth_service.dart';
import 'middleware/cors_middleware.dart';
import 'middleware/error_handler.dart';
import 'routes/auth_routes.dart';
import 'routes/friend_routes.dart';
import 'routes/health_routes.dart';
import 'routes/media_routes.dart';
import 'routes/push_routes.dart';
import 'routes/rtc_routes.dart';
import 'routes/story_routes.dart';
import 'routes/ws_routes.dart';

/// Builds the fully-wired HTTP application (middleware pipeline + routes).
///
/// Separated from `bin/server.dart` so it can be exercised by tests without
/// binding a real port or opening a real database — tests inject a fake
/// [Database].
///
/// Middleware order (outermost first) matters:
///   1. [errorHandler]  — must wrap everything so no error escapes unstructured.
///   2. logging          — records method/path/status/duration.
///   3. [jsonHeaders]    — guarantees a JSON content type on responses.
class AthurServer {
  AthurServer._(this.handler);

  final Handler handler;

  /// Compose the pipeline.
  ///
  /// [checkDatabase] is injected (not the [Database] itself) so callers/tests
  /// decide how readiness is determined.
  factory AthurServer.build({
    required ServerConfig config,
    required Database database,
    required String jwtSecret,
    required Future<bool> Function() checkDatabase,
    required String serverVersion,
    TurnCredentialService? turnService,
    FcmService? fcmService,
  }) {
    final health = HealthRoutes(
      checkDatabase: checkDatabase,
      serverVersion: serverVersion,
    );

    final authService = AuthService(db: database, jwtSecret: jwtSecret);

    // Mount all version-1 routes under /api/v1. Health lives at the root so
    // infrastructure probes do not need the version prefix.
    final apiV1 = Router()
      ..mount(
        '/api/v1',
        _apiV1Router(
          turnService: turnService,
          fcmService: fcmService,
          authService: authService,
          database: database,
          requireAuth: config.isProduction,
        ).call,
      );

    final root = Router()
      ..mount('/', health.router.call)
      ..mount('/', apiV1.call)
      // Catch-all lives on the outer router so /api/v1/* is not swallowed
      // by the health router before RTC/push routes can match.
      ..all('/<ignored|.*>', (Request request) {
        throw ApiError.notFound('No such endpoint: /${request.url.path}');
      });

    final pipeline = const Pipeline()
        .addMiddleware(errorHandler(isProduction: config.isProduction))
        // CORS must sit early so even error responses carry the headers and
        // the browser can read them; it also short-circuits OPTIONS preflight.
        .addMiddleware(
          corsMiddleware(
            isProduction: config.isProduction,
            allowedOrigins: config.allowedOrigins,
          ),
        )
        .addMiddleware(_requestLogger())
        .addMiddleware(jsonHeaders())
        // Basic hardening headers. (Full security middleware — rate limiting,
        // auth — is added in its dedicated phase.)
        .addMiddleware(_securityHeaders())
        .addHandler(root.call);

    return AthurServer._(pipeline);
  }

  /// Version-1 API surface. Routes are added phase by phase.
  static Router _apiV1Router({
    TurnCredentialService? turnService,
    FcmService? fcmService,
    required AuthService authService,
    required Database database,
    required bool requireAuth,
  }) {
    final wsRoutes = WsRoutes(
      db: database,
      authService: authService,
    );

    final mediaRoutes = MediaRoutes(db: database);

    final friendRoutes = FriendRoutes(db: database);

    final storyRoutes = StoryRoutes(db: database);

    final router = Router()
      // Auth routes (public — no token required).
      ..mount(
        '/',
        AuthRoutes(authService: authService).router.call,
      )
      ..mount(
        '/',
        RtcRoutes(
          turnService: turnService,
          requireAuth: requireAuth,
        ).router.call,
      )
      ..mount(
        '/',
        PushRoutes(
          fcmService: fcmService,
          requireAuth: requireAuth,
        ).router.call,
      )
      ..mount(
        '/',
        wsRoutes.router.call,
      )
      ..mount(
        '/',
        mediaRoutes.router.call,
      )
      ..mount(
        '/',
        friendRoutes.router.call,
      )
      ..mount(
        '/',
        storyRoutes.router.call,
      );
    // Messaging, calls, etc. mount here in their own phases.
    return router;
  }
}

/// Logs one line per request with status and duration.
Middleware _requestLogger() {
  return (Handler inner) {
    return (Request request) async {
      final watch = Stopwatch()..start();
      final response = await inner(request);
      watch.stop();
      stderrLog(
        '${request.method.padRight(5)} /${request.url.path} '
        '→ ${response.statusCode} (${watch.elapsedMilliseconds}ms)',
      );
      return response;
    };
  };
}

/// Minimal hardening headers. Safe defaults that do not break the API.
///
/// TLS termination happens at the deployment edge (reverse proxy); these
/// headers complement it. HSTS is only added in production.
Middleware _securityHeaders() {
  return (Handler inner) {
    return (Request request) async {
      final response = await inner(request);
      return response.change(
        headers: {
          'x-content-type-options': 'nosniff',
          'x-frame-options': 'DENY',
          'referrer-policy': 'no-referrer',
          ...response.headers,
        },
      );
    };
  };
}

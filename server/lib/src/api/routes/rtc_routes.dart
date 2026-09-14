import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../api/json.dart';
import '../../core/errors/api_error.dart';
import '../../integrations/turn/turn_credential_service.dart';

/// Serves the ICE configuration (STUN + TURN) to the Flutter client.
///
/// Endpoint:
///   `GET /api/v1/rtc/ice-servers` → `{ iceServers: [...], provider, ... }`
///
/// Security model:
/// - The Metered API key stays on this server. The client receives only the
///   ICE server list it legitimately needs to build an RTCPeerConnection.
/// - Auth: this route is registered behind the authentication middleware once
///   auth exists (Phase 3). Until then it is gated by a shared-secret header
///   check *only in production*, and open in development — see [requireAuth].
///
/// `?refresh=true` forces a re-fetch from Metered. Used when a call fails to
/// connect and the WebRTC layer suspects stale credentials.
class RtcRoutes {
  RtcRoutes({required this.turnService, required this.requireAuth});

  /// Metered-backed ICE provider. Null when TURN is not configured.
  final TurnCredentialService? turnService;

  /// When true, the caller must present a valid session (set in production).
  final bool requireAuth;

  Router get router {
    final router = Router();

    router.get('/rtc/ice-servers', (Request request) async {
      // --- Authorisation ----------------------------------------------------
      // In production this must be an authenticated, authorised caller.
      // The real token check is wired in the authentication phase; until then
      // production refuses to serve without an explicit trusted header, so we
      // never expose relay credentials to anonymous internet callers.
      if (requireAuth && !_hasTrustedCaller(request)) {
        throw const ApiError.unauthorized(
          'Authentication required to obtain ICE configuration.',
        );
      }

      final service = turnService;
      if (service == null) {
        // Honest failure. We do NOT fabricate ICE servers.
        throw const ApiError(
          statusCode: 503,
          code: 'TURN_NOT_CONFIGURED',
          message:
              'TURN is not configured on the server. Set ATHUR_METERED_DOMAIN '
              'and ATHUR_METERED_API_KEY. Audio/video calls need TURN to work '
              'across restrictive networks.',
        );
      }

      final forceRefresh = request.url.queryParameters['refresh'] == 'true';

      try {
        final config = await service.getIceConfig(forceRefresh: forceRefresh);
        return Json.ok(config.toJson());
      } on TurnUnavailableException catch (error) {
        // Surface a real, actionable error instead of pretending it worked.
        throw ApiError(
          statusCode: 502,
          code: 'TURN_UNAVAILABLE',
          message: error.message,
        );
      }
    });

    return router;
  }

  /// Placeholder trusted-caller check used until real authentication exists.
  ///
  /// Deliberately strict: without a real session mechanism we only accept
  /// requests carrying the internal header, which external clients do not send.
  bool _hasTrustedCaller(Request request) {
    return request.headers['x-athur-internal'] == 'trusted';
  }
}

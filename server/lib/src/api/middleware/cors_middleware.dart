import 'package:shelf/shelf.dart';

/// Cross-Origin Resource Sharing middleware.
///
/// Why this is required: a Flutter **web** build runs inside a browser, and the
/// browser blocks cross-origin requests unless the server explicitly allows
/// them. Without CORS headers every API call and the WebSocket upgrade from the
/// web app is rejected before it reaches our code.
///
/// Policy
/// ------
/// - **Development**: allows the common local Flutter web dev origins
///   (`localhost` / `127.0.0.1` on any port) so `flutter run -d chrome` works.
/// - **Production**: allows only the explicit origins in [allowedOrigins].
///   Never a wildcard, because the API is authenticated with bearer tokens and
///   credentials must not be exposed to arbitrary sites.
///
/// It also answers `OPTIONS` preflight requests directly with 204, so route
/// handlers never have to think about CORS.
Middleware corsMiddleware({
  required bool isProduction,
  List<String> allowedOrigins = const <String>[],
  bool allowAnyOrigin = false,
}) {
  return (Handler inner) {
    return (Request request) async {
      final origin = request.headers['origin'];

      // Determine the allowed origin for this request.
      final String? allowOrigin;
      if (origin == null) {
        // Not a browser cross-origin request (mobile, curl, tests).
        allowOrigin = null;
      } else if (!isProduction && _isLocalDevOrigin(origin)) {
        allowOrigin = origin;
      } else if (allowAnyOrigin) {
        // Opt-in only (e.g. a controlled staging environment). Never default.
        allowOrigin = origin;
      } else if (allowedOrigins.contains(origin)) {
        allowOrigin = origin;
      } else {
        allowOrigin = null;
      }

      // Preflight: answer immediately and do not run the handler.
      if (request.method == 'OPTIONS') {
        return Response(204, headers: _corsHeaders(allowOrigin));
      }

      final response = await inner(request);
      if (allowOrigin == null) return response;
      return response.change(headers: _corsHeaders(allowOrigin));
    };
  };
}

Map<String, String> _corsHeaders(String? origin) => {
  if (origin != null && origin.isNotEmpty)
    'access-control-allow-origin': origin,
  'access-control-allow-methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
  'access-control-allow-headers':
      'Authorization, Content-Type, Accept, X-Requested-With',
  // Cache the preflight result to cut down on round-trips.
  'access-control-max-age': '86400',
  // Responses vary by origin, so caches must key on it.
  'vary': 'Origin',
  // Note: Access-Control-Allow-Credentials is intentionally omitted. The
  // app authenticates with a Bearer token, not cookies, so credential
  // sharing is not needed and leaving it off is the safer default.
};

/// True for origins a local Flutter web dev server uses
/// (`http://localhost:<port>` / `http://127.0.0.1:<port>`).
bool _isLocalDevOrigin(String origin) {
  final uri = Uri.tryParse(origin);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  return uri.host == 'localhost' ||
      uri.host == '127.0.0.1' ||
      uri.host == '::1';
}

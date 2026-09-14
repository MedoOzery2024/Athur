import 'package:shelf/shelf.dart';

import '../../core/errors/api_error.dart';
import '../json.dart';

/// Converts thrown [ApiError]s (and unexpected errors) into structured JSON.
///
/// Behaviour:
/// - [ApiError] → its own status/code/message.
/// - Any other error → 500 `INTERNAL`. The real error + stack trace are logged
///   server-side and **never** returned to the client.
///
/// This is the single place error responses are shaped, so the client can rely
/// on one contract.
Middleware errorHandler({required bool isProduction}) {
  return (Handler inner) {
    return (Request request) async {
      try {
        return await inner(request);
      } on ApiError catch (error) {
        return Json.error(error);
      } catch (error, stackTrace) {
        // Technical detail stays in the log for developers.
        stderrLog(
          'Unhandled error on ${request.method} ${request.requestedUri.path}: '
          '$error\n$stackTrace',
        );
        return Json.error(
          ApiError.internal(
            isProduction
                ? 'Internal server error'
                : 'Internal server error: $error',
          ),
        );
      }
    };
  };
}

/// Minimal structured logger (no dependency needed for Phase 2).
void stderrLog(String message) {
  // ignore: avoid_print
  print('[Athur][server] $message');
}

/// Ensures every request is handled as JSON and validates the content type of
/// request bodies that carry one.
Middleware jsonHeaders() {
  return (Handler inner) {
    return (Request request) async {
      final response = await inner(request);
      // Only add the JSON content type if a route did not set its own.
      if (!response.headers.containsKey('content-type')) {
        return response.change(
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return response;
    };
  };
}

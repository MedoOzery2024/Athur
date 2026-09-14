import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../core/errors/api_error.dart';

/// Helpers for consistent JSON handling across all routes.
abstract final class Json {
  Json._();

  static const _contentType = {
    'content-type': 'application/json; charset=utf-8',
  };

  /// A successful JSON response.
  static Response ok(Object? body, {int status = 200}) =>
      Response(status, body: jsonEncode(body), headers: _contentType);

  static Response created(Object? body) => ok(body, status: 201);

  static Response noContent() => Response(204);

  /// A structured error response (never leaks internals).
  static Response error(ApiError error) => Response(
    error.statusCode,
    body: jsonEncode(error.toJson()),
    headers: _contentType,
  );

  /// Decodes a JSON object from a raw string.
  ///
  /// Throws [FormatException] on invalid JSON. Used by tests and by internal
  /// callers that already have the body as a string.
  static Map<String, Object?> decodeObject(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Expected a JSON object.');
    }
    return decoded;
  }

  /// Reads and decodes a JSON request body.
  ///
  /// Throws [ApiError.badRequest] on invalid JSON so callers can rely on the
  /// global error middleware instead of repeating try/catch everywhere.
  static Future<Map<String, Object?>> readObject(Request request) async {
    try {
      final raw = await request.readAsString();
      if (raw.trim().isEmpty) return <String, Object?>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        throw const ApiError.badRequest('Request body must be a JSON object.');
      }
      return decoded;
    } on FormatException {
      throw const ApiError.badRequest('Request body is not valid JSON.');
    }
  }
}

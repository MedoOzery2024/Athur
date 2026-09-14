/// A stable, machine-readable API error.
///
/// The Flutter client depends on this shape, so every error response from the
/// server has the same structure:
/// ```json
/// { "error": { "code": "NOT_FOUND", "message": "Chat not found" } }
/// ```
/// `code` is stable and safe to switch on; `message` is human-readable and may
/// change. Internal details (stack traces, SQL) are **never** sent to clients
/// in production — they are logged server-side instead.
class ApiError implements Exception {
  const ApiError({
    required this.statusCode,
    required this.code,
    required this.message,
    this.details,
  });

  final int statusCode;
  final String code;
  final String message;

  /// Optional structured, non-sensitive extra info (e.g. validation fields).
  final Map<String, Object?>? details;

  Map<String, Object?> toJson() => {
    'error': {
      'code': code,
      'message': message,
      if (details != null) 'details': details,
    },
  };

  // --- Common constructors ---------------------------------------------------

  const ApiError.badRequest(String message, {Map<String, Object?>? details})
    : this(
        statusCode: 400,
        code: 'BAD_REQUEST',
        message: message,
        details: details,
      );

  const ApiError.unauthorized([String message = 'Authentication required'])
    : this(statusCode: 401, code: 'UNAUTHORIZED', message: message);

  const ApiError.forbidden([String message = 'Not allowed'])
    : this(statusCode: 403, code: 'FORBIDDEN', message: message);

  const ApiError.notFound([String message = 'Resource not found'])
    : this(statusCode: 404, code: 'NOT_FOUND', message: message);

  const ApiError.conflict(String message)
    : this(statusCode: 409, code: 'CONFLICT', message: message);

  const ApiError.tooManyRequests([String message = 'Too many requests'])
    : this(statusCode: 429, code: 'RATE_LIMITED', message: message);

  const ApiError.internal([String message = 'Internal server error'])
    : this(statusCode: 500, code: 'INTERNAL', message: message);

  @override
  String toString() => 'ApiError($statusCode $code): $message';
}

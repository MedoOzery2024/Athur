import 'dart:convert';

import 'package:http/http.dart' as http;

/// HTTP client for the Athur backend API.
///
/// Handles:
/// - Base URL configuration
/// - JSON content type
/// - Authorization header injection
/// - Error parsing
class ApiClient {
  ApiClient({required this.baseUrl});

  /// Singleton instance.
  static late final ApiClient instance;

  final String baseUrl;
  String? _accessToken;

  /// Sets the access token for authenticated requests.
  void setAccessToken(String? token) => _accessToken = token;

  /// GET request.
  Future<Map<String, Object?>> get(String path) async {
    final response = await http.get(
      Uri.parse('$baseUrl$path'),
      headers: _headers(),
    );
    return _handleResponse(response);
  }

  /// POST request with JSON body.
  Future<Map<String, Object?>> post(
    String path, {
    Map<String, Object?>? body,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl$path'),
      headers: _headers(),
      body: body != null ? jsonEncode(body) : null,
    );
    return _handleResponse(response);
  }

  /// PUT request with JSON body.
  Future<Map<String, Object?>> put(
    String path, {
    Map<String, Object?>? body,
  }) async {
    final response = await http.put(
      Uri.parse('$baseUrl$path'),
      headers: _headers(),
      body: body != null ? jsonEncode(body) : null,
    );
    return _handleResponse(response);
  }

  /// DELETE request.
  Future<Map<String, Object?>> delete(String path) async {
    final response = await http.delete(
      Uri.parse('$baseUrl$path'),
      headers: _headers(),
    );
    return _handleResponse(response);
  }

  Map<String, String> _headers() {
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      'Accept': 'application/json',
    };
    if (_accessToken != null) {
      headers['Authorization'] = 'Bearer $_accessToken';
    }
    return headers;
  }

  Map<String, Object?> _handleResponse(http.Response response) {
    final body = jsonDecode(response.body);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return body as Map<String, Object?>;
    }

    // Parse error response.
    final error = body['error'] as Map<String, Object?>?;
    throw ApiError(
      statusCode: response.statusCode,
      code: error?['code'] as String? ?? 'UNKNOWN',
      message: error?['message'] as String? ?? 'An error occurred.',
    );
  }
}

/// API error thrown by [ApiClient].
class ApiError implements Exception {
  const ApiError({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() => 'ApiError($statusCode $code): $message';
}

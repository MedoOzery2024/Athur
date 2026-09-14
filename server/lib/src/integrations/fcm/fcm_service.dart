import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';

/// A push payload the Athur server can send through FCM HTTP v1.
class FcmMessage {
  const FcmMessage({
    required this.token,
    this.title,
    this.body,
    this.kind = 'system',
    this.data = const {},
    this.highPriority = false,
    this.androidChannelId = 'athur_messages',
  });

  /// Device registration token from the Flutter app.
  final String token;

  final String? title;
  final String? body;

  /// Stable kind used for deep-link routing (matches `notifications.kind`).
  final String kind;

  /// Extra string data. All values must be strings (FCM requirement).
  final Map<String, String> data;

  /// Incoming calls and time-sensitive alerts use high priority.
  final bool highPriority;

  final String androidChannelId;

  /// JSON body for `messages:send`. Pure function of the fields — unit-tested.
  Map<String, Object?> toV1Body() {
    final dataPayload = <String, String>{
      'kind': kind,
      ...data,
    };

    return {
      'message': {
        'token': token,
        'data': dataPayload,
        if (title != null || body != null)
          'notification': {
            if (title != null) 'title': title,
            if (body != null) 'body': body,
          },
        'android': {
          'priority': highPriority ? 'HIGH' : 'NORMAL',
          if (title != null || body != null)
            'notification': {
              'channel_id': androidChannelId,
              'sound': 'default',
            },
        },
        'apns': {
          'headers': {
            'apns-priority': highPriority ? '10' : '5',
          },
          'payload': {
            'aps': {
              if (title != null || body != null) 'sound': 'default',
              'content-available': 1,
            },
          },
        },
      },
    };
  }
}

class FcmSendResult {
  const FcmSendResult({required this.name});

  /// FCM resource name, e.g. `projects/athur-91a41/messages/0:123`.
  final String name;
}

/// Thrown when FCM cannot send. Safe to log — never contains the private key.
class FcmException implements Exception {
  const FcmException(this.message, {this.statusCode, this.fcmStatus});

  final String message;
  final int? statusCode;

  /// Google RPC status, e.g. `INVALID_ARGUMENT`, `UNAUTHENTICATED`.
  final String? fcmStatus;

  @override
  String toString() => 'FcmException: $message';
}

typedef FcmAccessToken = Future<String> Function();

/// Sends FCM HTTP v1 messages. The service-account private key never leaves
/// this process and is never logged.
class FcmService {
  FcmService({
    required this.projectId,
    required this._accessToken,
    HttpClient? httpClient,
    this.clientEmail,
    this._onDispose,
  }) : _httpClient = httpClient ?? HttpClient(),
       _ownsHttpClient = httpClient == null;

  /// Loads credentials from a service-account JSON **path** (never from source).
  factory FcmService.fromServiceAccountFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw FcmException(
        'Firebase service-account file not found. Set '
        'ATHUR_FIREBASE_SERVICE_ACCOUNT to the real path.',
      );
    }

    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) {
      throw const FcmException('Service-account file is not a JSON object.');
    }
    final json = Map<String, Object?>.from(decoded);

    final projectId = json['project_id'] as String?;
    final clientEmail = json['client_email'] as String?;
    final type = json['type'] as String?;
    if (projectId == null || projectId.isEmpty) {
      throw const FcmException('Service-account JSON is missing project_id.');
    }
    if (type != 'service_account') {
      throw const FcmException(
        'Service-account JSON type must be "service_account".',
      );
    }

    final credentials = ServiceAccountCredentials.fromJson(json);
    AutoRefreshingAuthClient? authClient;

    return FcmService(
      projectId: projectId,
      clientEmail: clientEmail,
      accessToken: () async {
        authClient ??= await clientViaServiceAccount(credentials, const [
          'https://www.googleapis.com/auth/firebase.messaging',
        ]);
        return authClient!.credentials.accessToken.data;
      },
      onDispose: () => authClient?.close(),
    );
  }

  final String projectId;

  /// Present only so status endpoints can show *which* account is used,
  /// never the private key.
  final String? clientEmail;

  final FcmAccessToken _accessToken;
  final HttpClient _httpClient;
  final bool _ownsHttpClient;
  final void Function()? _onDispose;

  Uri get _sendUri => Uri.https(
    'fcm.googleapis.com',
    '/v1/projects/$projectId/messages:send',
  );

  Future<FcmSendResult> send(FcmMessage message) async {
    final token = message.token.trim();
    if (token.isEmpty) {
      throw const FcmException('FCM device token is empty.');
    }

    final accessToken = await _accessToken();
    try {
      final request = await _httpClient.postUrl(_sendUri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
      request.add(utf8.encode(jsonEncode(message.toV1Body())));

      final response = await request.close().timeout(const Duration(seconds: 15));
      final body = await response.transform(utf8.decoder).join();
      return _parseResponse(response.statusCode, body);
    } on FcmException {
      rethrow;
    } on SocketException catch (error) {
      throw FcmException('Could not reach FCM (${error.message}).');
    } catch (error) {
      throw FcmException('FCM send failed: $error');
    }
  }

  static FcmSendResult _parseResponse(int statusCode, String body) {
    Object? decoded;
    try {
      decoded = body.trim().isEmpty ? null : jsonDecode(body);
    } on FormatException {
      throw FcmException(
        'FCM returned HTTP $statusCode with a non-JSON body.',
        statusCode: statusCode,
      );
    }

    if (statusCode >= 200 && statusCode < 300) {
      if (decoded is Map && decoded['name'] is String) {
        return FcmSendResult(name: decoded['name'] as String);
      }
      throw FcmException(
        'FCM returned HTTP $statusCode without a message name.',
        statusCode: statusCode,
      );
    }

    var fcmStatus = 'UNKNOWN';
    var message = 'FCM returned HTTP $statusCode.';
    if (decoded is Map && decoded['error'] is Map) {
      final error = Map<String, Object?>.from(decoded['error'] as Map);
      fcmStatus = (error['status'] as String?) ?? fcmStatus;
      message = (error['message'] as String?) ?? message;
    }

    throw FcmException(message, statusCode: statusCode, fcmStatus: fcmStatus);
  }

  void dispose() {
    _onDispose?.call();
    if (_ownsHttpClient) {
      _httpClient.close(force: true);
    }
  }
}

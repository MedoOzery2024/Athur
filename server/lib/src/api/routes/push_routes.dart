import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../api/json.dart';
import '../../core/errors/api_error.dart';
import '../../integrations/fcm/fcm_service.dart';

/// Push-notification endpoints.
///
///   `GET  /api/v1/push/status` — whether FCM is configured (no secrets).
///   `POST /api/v1/push/test`   — send a real test notification to a device
///                                token. Development helper until auth exists.
class PushRoutes {
  PushRoutes({required this.fcmService, required this.requireAuth});

  final FcmService? fcmService;
  final bool requireAuth;

  Router get router {
    final router = Router();

    router.get('/push/status', (Request request) {
      final service = fcmService;
      return Json.ok({
        'configured': service != null,
        'provider': 'fcm',
        if (service != null) 'projectId': service.projectId,
      });
    });

    router.post('/push/test', (Request request) async {
      if (requireAuth && !_hasTrustedCaller(request)) {
        throw const ApiError.unauthorized(
          'Authentication required to send a test push.',
        );
      }

      final service = fcmService;
      if (service == null) {
        throw const ApiError(
          statusCode: 503,
          code: 'FCM_NOT_CONFIGURED',
          message:
              'Firebase Cloud Messaging is not configured. Set '
              'ATHUR_FIREBASE_SERVICE_ACCOUNT to the service-account JSON path '
              '(file stays outside the repository).',
        );
      }

      final body = await Json.readObject(request);
      final token = body['token'];
      if (token is! String || token.trim().isEmpty) {
        throw const ApiError.badRequest(
          'JSON body must include a non-empty "token" string.',
        );
      }

      final title = body['title'];
      final messageBody = body['body'];
      final kind = body['kind'];

      try {
        final result = await service.send(
          FcmMessage(
            token: token.trim(),
            title: title is String && title.isNotEmpty ? title : 'Athur',
            body: messageBody is String && messageBody.isNotEmpty
                ? messageBody
                : 'Test notification',
            kind: kind is String && kind.isNotEmpty ? kind : 'system',
          ),
        );
        return Json.ok({'sent': true, 'name': result.name});
      } on FcmException catch (error) {
        throw ApiError(
          statusCode: error.statusCode == 401 || error.statusCode == 403
              ? 502
              : 502,
          code: 'FCM_SEND_FAILED',
          message: error.message,
          details: {
            if (error.fcmStatus != null) 'fcmStatus': error.fcmStatus,
          },
        );
      }
    });

    return router;
  }

  bool _hasTrustedCaller(Request request) {
    return request.headers['x-athur-internal'] == 'trusted';
  }
}

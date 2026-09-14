import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../api/json.dart';

/// Health & readiness endpoints.
///
/// These are **real** endpoints used by the deployment/CI system and by the
/// Flutter client to verify it can reach the backend. They are not mock data:
/// `/health/ready` performs a genuine database round-trip and reports failure
/// honestly if PostgreSQL is unreachable.
///
/// Routes:
/// - `GET /health`        → liveness (process is up). Cheap, no dependencies.
/// - `GET /health/ready`  → readiness (database reachable + queryable).
/// - `GET /version`       → server build info.
class HealthRoutes {
  HealthRoutes({required this.checkDatabase, required this.serverVersion});

  /// Returns true when the database answered a real query.
  final Future<bool> Function() checkDatabase;

  final String serverVersion;

  Router get router {
    final router = Router();

    router.get('/health', (Request request) {
      return Json.ok({
        'status': 'ok',
        'service': 'athur-server',
        'time': DateTime.now().toUtc().toIso8601String(),
      });
    });

    router.get('/health/ready', (Request request) async {
      final databaseOk = await checkDatabase();
      if (!databaseOk) {
        // 503 tells load balancers / clients the instance cannot serve yet.
        return Response(
          503,
          body:
              '{"error":{"code":"NOT_READY","message":"Database unreachable"}}',
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return Json.ok({
        'status': 'ready',
        'database': 'up',
        'time': DateTime.now().toUtc().toIso8601String(),
      });
    });

    router.get('/version', (Request request) {
      return Json.ok({'service': 'athur-server', 'version': serverVersion});
    });

    return router;
  }
}

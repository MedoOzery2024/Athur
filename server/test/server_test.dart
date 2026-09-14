import 'package:athur_server/athur_server.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Builds a handler with a fake database readiness check so no real PostgreSQL
/// connection is needed. This proves the routing/middleware contract, not the
/// database itself.
Handler _buildApp({required bool dbReady}) {
  final config = ServerConfig(
    host: 'localhost',
    port: 0,
    databaseUrl: 'postgresql://user:pass@localhost:5432/athur',
    environment: 'development',
    jwtSecret: 'test-jwt-secret-for-testing-only-32chars!',
  );
  // Use a fake Database for tests — the tests only check routing/middleware,
  // not real database operations. The auth service needs a Database instance
  // but the test routes don't exercise auth endpoints.
  return AthurServer.build(
    config: config,
    database: Database.fake(),
    jwtSecret: config.jwtSecret,
    checkDatabase: () async => dbReady,
    serverVersion: '1.0.0',
  ).handler;
}

Future<Map<String, Object?>> _json(Response response) async {
  return Json.decodeObject(await response.readAsString());
}

void main() {
  group('parsePostgresUrl', () {
    test('parses a full URL', () {
      final endpoint = parsePostgresUrl(
        'postgresql://athur:secret@db.example.com:5433/athur_prod',
      );
      expect(endpoint.host, 'db.example.com');
      expect(endpoint.port, 5433);
      expect(endpoint.database, 'athur_prod');
      expect(endpoint.username, 'athur');
      expect(endpoint.password, 'secret');
    });

    test('defaults the port to 5432', () {
      final endpoint = parsePostgresUrl(
        'postgresql://athur:pw@localhost/athur',
      );
      expect(endpoint.port, 5432);
    });

    test('decodes percent-encoded credentials', () {
      final endpoint = parsePostgresUrl(
        'postgresql://user%40mail:p%40ss@localhost/athur',
      );
      expect(endpoint.username, 'user@mail');
      expect(endpoint.password, 'p@ss');
    });

    test('rejects a non-postgres scheme', () {
      expect(
        () => parsePostgresUrl('mysql://localhost/athur'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a URL without a database name', () {
      expect(
        () => parsePostgresUrl('postgresql://localhost'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('sslModeFromUrl', () {
    test('maps require / verify-full / disable', () {
      expect(
        sslModeFromUrl('postgresql://h/d?sslmode=require'),
        SslMode.require,
      );
      expect(
        sslModeFromUrl('postgresql://h/d?sslmode=verify-full'),
        SslMode.verifyFull,
      );
      expect(
        sslModeFromUrl('postgresql://h/d?sslmode=disable'),
        SslMode.disable,
      );
    });

    test('returns null when unspecified', () {
      expect(sslModeFromUrl('postgresql://h/d'), isNull);
    });
  });

  group('GET /health', () {
    test('returns ok without touching the database', () async {
      final app = _buildApp(dbReady: false);
      final response = await app(
        Request('GET', Uri.parse('http://localhost/health')),
      );
      expect(response.statusCode, 200);
      final body = await _json(response);
      expect(body['status'], 'ok');
      expect(body['service'], 'athur-server');
    });
  });

  group('GET /health/ready', () {
    test('returns 200 when the database is reachable', () async {
      final app = _buildApp(dbReady: true);
      final response = await app(
        Request('GET', Uri.parse('http://localhost/health/ready')),
      );
      expect(response.statusCode, 200);
      final body = await _json(response);
      expect(body['status'], 'ready');
      expect(body['database'], 'up');
    });

    test('returns 503 when the database is down', () async {
      final app = _buildApp(dbReady: false);
      final response = await app(
        Request('GET', Uri.parse('http://localhost/health/ready')),
      );
      expect(response.statusCode, 503);
      final body = await _json(response);
      final error = body['error'] as Map<String, Object?>;
      expect(error['code'], 'NOT_READY');
    });
  });

  group('GET /version', () {
    test('reports the server version', () async {
      final app = _buildApp(dbReady: true);
      final response = await app(
        Request('GET', Uri.parse('http://localhost/version')),
      );
      expect(response.statusCode, 200);
      final body = await _json(response);
      expect(body['version'], '1.0.0');
    });
  });

  group('unknown route', () {
    test('returns a structured 404 JSON error', () async {
      final app = _buildApp(dbReady: true);
      final response = await app(
        Request('GET', Uri.parse('http://localhost/api/v1/does-not-exist')),
      );
      expect(response.statusCode, 404);
      expect(response.headers['content-type'], contains('application/json'));
      final body = await _json(response);
      final error = body['error'] as Map<String, Object?>;
      expect(error['code'], 'NOT_FOUND');
    });
  });

  group('security headers', () {
    test('are present on responses', () async {
      final app = _buildApp(dbReady: true);
      final response = await app(
        Request('GET', Uri.parse('http://localhost/health')),
      );
      expect(response.headers['x-content-type-options'], 'nosniff');
      expect(response.headers['x-frame-options'], 'DENY');
    });
  });

  group('ServerConfig', () {
    test('redacts the database URL in the safe map', () {
      final config = ServerConfig(
        host: '0.0.0.0',
        port: 8080,
        databaseUrl: 'postgresql://athur:supersecret@localhost:5432/athur',
        environment: 'development',
        jwtSecret: 'test-secret',
      );
      final safe = config.toSafeMap().toString();
      expect(safe.contains('supersecret'), isFalse);
      expect(safe.contains('***'), isTrue);
    });
  });
}

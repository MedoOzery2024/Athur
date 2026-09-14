import 'dart:convert';
import 'dart:io';

import 'package:athur_server/athur_server.dart';
import 'package:test/test.dart';

/// Unit tests for ICE server parsing — no network required.
void main() {
  group('IceServer.fromJson', () {
    test('parses a single string url', () {
      final server = IceServer.fromJson({
        'urls': 'stun:stun.l.google.com:19302',
      });
      expect(server.urls, ['stun:stun.l.google.com:19302']);
      expect(server.isStun, isTrue);
      expect(server.isTurn, isFalse);
    });

    test('parses a list of urls', () {
      final server = IceServer.fromJson({
        'urls': ['turn:a.example:3478', 'turn:a.example:443?transport=tcp'],
        'username': 'u',
        'credential': 'c',
      });
      expect(server.urls.length, 2);
      expect(server.isTurn, isTrue);
      expect(server.username, 'u');
      expect(server.credential, 'c');
    });

    test('rejects an entry with no urls', () {
      expect(
        () => IceServer.fromJson({'urls': <String>[]}),
        throwsA(isA<FormatException>()),
      );
    });

    test('serialises back with a single url as a string', () {
      const server = IceServer(urls: ['stun:x:3478']);
      expect(server.toJson()['urls'], 'stun:x:3478');
    });

    test('serialises multiple urls as a list', () {
      const server = IceServer(
        urls: ['turn:x:3478', 'turn:x:443'],
        username: 'u',
        credential: 'c',
      );
      expect(server.toJson()['urls'], isA<List<String>>());
    });
  });

  group('TurnCredentialService caching', () {
    test(
      'caches a successful response and refetches when invalidated',
      () async {
        var requests = 0;
        final server = await _CannedServer.start((request) {
          requests++;
          return _iceServersJson;
        });
        addTearDown(server.stop);

        final service = TurnCredentialService(
          domain: server.domain,
          apiKey: 'test-key',
          cacheTtl: const Duration(minutes: 5),
          useHttps: false,
        );
        addTearDown(service.dispose);

        final first = await service.getIceConfig();
        expect(first.turnCount, greaterThan(0));
        expect(requests, 1);

        // Second call is served from cache.
        await service.getIceConfig();
        expect(requests, 1);

        // Forced refresh hits the network again.
        await service.getIceConfig(forceRefresh: true);
        expect(requests, 2);
      },
    );

    test('adds Google STUN servers when the provider omits them', () async {
      final server = await _CannedServer.start((request) => _turnOnlyJson);
      addTearDown(server.stop);

      final service = TurnCredentialService(
        domain: server.domain,
        apiKey: 'test-key',
        useHttps: false,
      );
      addTearDown(service.dispose);

      final config = await service.getIceConfig();
      final allUrls = config.iceServers.expand((s) => s.urls).toList();
      expect(
        allUrls.any((u) => u.contains('stun.l.google.com')),
        isTrue,
        reason: 'Google STUN must be present in the ICE configuration',
      );
    });

    test('does not duplicate Google STUN when already present', () async {
      final server = await _CannedServer.start(
        (request) => _withGoogleStunJson,
      );
      addTearDown(server.stop);

      final service = TurnCredentialService(
        domain: server.domain,
        apiKey: 'test-key',
        useHttps: false,
      );
      addTearDown(service.dispose);

      final config = await service.getIceConfig();
      final googleCount = config.iceServers
          .expand((s) => s.urls)
          .where((u) => u.contains('stun.l.google.com'))
          .length;
      expect(googleCount, 1);
    });

    test('throws a clear error on 401', () async {
      final server = await _CannedServer.start(
        (request) => null,
        statusCode: 401,
      );
      addTearDown(server.stop);

      final service = TurnCredentialService(
        domain: server.domain,
        apiKey: 'bad-key',
        useHttps: false,
      );
      addTearDown(service.dispose);

      await expectLater(
        service.getIceConfig(),
        throwsA(
          isA<TurnUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('rejected the API key'),
          ),
        ),
      );
    });

    test('throws when the payload is not a JSON array', () async {
      final server = await _CannedServer.start((request) => '{"nope":true}');
      addTearDown(server.stop);

      final service = TurnCredentialService(
        domain: server.domain,
        apiKey: 'test-key',
        useHttps: false,
      );
      addTearDown(service.dispose);

      await expectLater(
        service.getIceConfig(),
        throwsA(isA<TurnUnavailableException>()),
      );
    });

    test('throws when the array is empty', () async {
      final server = await _CannedServer.start((request) => '[]');
      addTearDown(server.stop);

      final service = TurnCredentialService(
        domain: server.domain,
        apiKey: 'test-key',
        useHttps: false,
      );
      addTearDown(service.dispose);

      await expectLater(
        service.getIceConfig(),
        throwsA(isA<TurnUnavailableException>()),
      );
    });

    test('the error message never contains the API key', () async {
      const secret = 'super-secret-key-value';
      final server = await _CannedServer.start(
        (request) => null,
        statusCode: 401,
      );
      addTearDown(server.stop);

      final service = TurnCredentialService(
        domain: server.domain,
        apiKey: secret,
        useHttps: false,
      );
      addTearDown(service.dispose);

      try {
        await service.getIceConfig();
        fail('expected TurnUnavailableException');
      } on TurnUnavailableException catch (error) {
        expect(error.message.contains(secret), isFalse);
        expect(error.toString().contains(secret), isFalse);
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Test fixtures: a tiny local HTTP server that answers like Metered does.
// ---------------------------------------------------------------------------

const _iceServersJson = '''
[
  {"urls":"stun:stun.relay.metered.ca:80"},
  {"urls":"turn:global.relay.metered.ca:80","username":"u1","credential":"c1"},
  {"urls":"turn:global.relay.metered.ca:443?transport=tcp","username":"u1","credential":"c1"}
]
''';

const _turnOnlyJson = '''
[
  {"urls":"turn:global.relay.metered.ca:80","username":"u1","credential":"c1"}
]
''';

const _withGoogleStunJson = '''
[
  {"urls":"stun:stun.l.google.com:19302"},
  {"urls":"turn:global.relay.metered.ca:80","username":"u1","credential":"c1"}
]
''';

/// Starts a local HTTP server that mimics the Metered credentials endpoint.
///
/// Using a real socket (not a mocked client) means the service's actual HTTP
/// code path, JSON decoding and error handling are exercised.
class _CannedServer {
  _CannedServer._(this._server);

  final HttpServer _server;

  int get port => _server.port;
  String get domain => '127.0.0.1:$port';

  static Future<_CannedServer> start(
    String? Function(HttpRequest request) body, {
    int statusCode = 200,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final payload = body(request);
      if (payload == null) {
        request.response.statusCode = statusCode;
      } else {
        request.response.statusCode = statusCode;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(jsonDecode(payload)));
      }
      await request.response.close();
    });
    return _CannedServer._(server);
  }

  Future<void> stop() => _server.close(force: true);
}

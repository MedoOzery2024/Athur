import 'dart:io';

import 'package:athur_server/athur_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Athur backend entry point.
///
/// Run (from the `server/` directory) with the required environment variable:
/// ```powershell
/// $env:ATHUR_DATABASE_URL = "postgresql://athur:password@localhost:5432/athur"
/// dart run bin/server.dart
/// ```
///
/// The server refuses to start without a database URL — it never falls back to
/// a hardcoded credential (project spec §21, §29).
Future<void> main(List<String> args) async {
  final ServerConfig config;
  try {
    final fileEnv = loadDotEnvFile(findDotEnvFile());
    config = ServerConfig.fromEnvironment(
      mergeEnvironment(fileEnv: fileEnv),
    );
  } on ConfigurationException catch (error) {
    stderr.writeln('[Athur][server] Startup aborted: ${error.message}');
    exitCode = 78; // EX_CONFIG
    return;
  }

  stdout.writeln('[Athur][server] Starting with config: ${config.toSafeMap()}');

  // Connect to PostgreSQL. Fatal if unreachable — no silent degradation.
  final Database database;
  try {
    database = await Database.connect(url: config.databaseUrl);
    stdout.writeln('[Athur][server] PostgreSQL connected.');
  } catch (error) {
    stderr.writeln('[Athur][server] Could not connect to PostgreSQL: $error');
    exitCode = 69; // EX_UNAVAILABLE
    return;
  }

  // TURN/STUN provider. Constructed only when configured, so a deployment
  // without TURN runs with STUN only and reports that honestly via the API.
  TurnCredentialService? turnService;
  if (config.turnConfigured) {
    turnService = TurnCredentialService(
      domain: config.meteredDomain!,
      apiKey: config.meteredApiKey!,
    );
    stdout.writeln(
      '[Athur][server] TURN enabled via ${config.meteredDomain} (Metered).',
    );
  } else {
    stdout.writeln(
      '[Athur][server] TURN not configured — calls will be STUN-only.\n'
      '                Set ATHUR_METERED_DOMAIN and ATHUR_METERED_API_KEY.',
    );
  }

  FcmService? fcmService;
  if (config.fcmPathConfigured) {
    final path = config.firebaseServiceAccountPath!.trim();
    try {
      fcmService = FcmService.fromServiceAccountFile(path);
      stdout.writeln(
        '[Athur][server] FCM enabled for project ${fcmService.projectId}.',
      );
    } on FcmException catch (error) {
      if (config.isProduction) {
        stderr.writeln('[Athur][server] FCM startup aborted: ${error.message}');
        await database.close();
        turnService?.dispose();
        exitCode = 78;
        return;
      }
      stdout.writeln(
        '[Athur][server] FCM not active: ${error.message}\n'
        '                Push notifications will stay off until the '
        'service-account file is in place.',
      );
    }
  } else {
    stdout.writeln(
      '[Athur][server] FCM not configured — set ATHUR_FIREBASE_SERVICE_ACCOUNT.',
    );
  }

  final app = AthurServer.build(
    config: config,
    database: database,
    jwtSecret: config.jwtSecret,
    checkDatabase: database.ping,
    serverVersion: '1.0.0',
    turnService: turnService,
    fcmService: fcmService,
  );

  final server = await shelf_io.serve(app.handler, config.host, config.port);
  server.autoCompress = true; // gzip responses (project spec §55)
  stdout.writeln(
    '[Athur][server] Listening on http://${server.address.host}:${server.port}',
  );

  // Graceful shutdown: close the pool so PostgreSQL connections are released.
  Future<void> shutdown(ProcessSignal signal) async {
    stdout.writeln('[Athur][server] Received $signal — shutting down…');
    await server.close(force: true);
    await database.close();
    turnService?.dispose();
    fcmService?.dispose();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen(shutdown);
  }
}

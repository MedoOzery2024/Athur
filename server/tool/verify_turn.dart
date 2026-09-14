import 'dart:io';

import 'package:athur_server/athur_server.dart';

/// Live verification that the server can obtain REAL ICE servers from Metered.
///
/// This runs the **production** [TurnCredentialService] against the configured
/// account. It is a genuine end-to-end check of the server-side TURN path — not
/// a mock. It prints only non-secret information (URLs, counts); the API key is
/// never echoed.
///
/// Usage (from the server/ directory), with env vars set:
///   dart run tool/verify_turn.dart
///
/// Exit codes: 0 = success, 1 = failure.
Future<void> main() async {
  final domain = Platform.environment['ATHUR_METERED_DOMAIN'];
  final apiKey = Platform.environment['ATHUR_METERED_API_KEY'];

  if (domain == null || domain.isEmpty || apiKey == null || apiKey.isEmpty) {
    stderr.writeln(
      '[FAIL] ATHUR_METERED_DOMAIN and ATHUR_METERED_API_KEY must both be set.',
    );
    exit(1);
  }

  final service = TurnCredentialService(domain: domain, apiKey: apiKey);

  try {
    stdout.writeln('[INFO] Requesting ICE servers from $domain …');
    final config = await service.getIceConfig();

    stdout.writeln('[OK]   provider        : ${config.provider}');
    stdout.writeln('[OK]   TURN configured : ${config.turnConfigured}');
    stdout.writeln('[OK]   STUN entries    : ${config.stunCount}');
    stdout.writeln('[OK]   TURN entries    : ${config.turnCount}');
    stdout.writeln('');

    for (final server in config.iceServers) {
      final kind = server.isTurn ? 'TURN' : 'STUN';
      for (final url in server.urls) {
        // Credentials are deliberately NOT printed in full.
        final hasCreds = server.credential != null ? ' (auth)' : '';
        stdout.writeln('  [$kind]$hasCreds $url');
      }
    }

    stdout.writeln('');

    // --- Assertions that must hold for calls to work across networks --------
    var failed = false;

    if (!config.iceServers.any((s) => s.isStun)) {
      stderr.writeln('[FAIL] No STUN server present.');
      failed = true;
    }
    if (!config.turnConfigured) {
      stderr.writeln(
        '[FAIL] No TURN server present. Calls will fail behind restrictive '
        'NAT / symmetric NAT without a relay.',
      );
      failed = true;
    }
    if (!config.iceServers.any(
      (s) => s.urls.any((u) => u.contains('stun.l.google.com')),
    )) {
      stderr.writeln('[FAIL] Google STUN is missing from the ICE config.');
      failed = true;
    }

    if (failed) {
      stdout.writeln('[RESULT] TURN verification FAILED.');
      exit(1);
    }

    stdout.writeln('[RESULT] TURN verification PASSED.');
    exit(0);
  } on TurnUnavailableException catch (error) {
    stderr.writeln('[FAIL] ${error.message}');
    exit(1);
  } finally {
    service.dispose();
  }
}

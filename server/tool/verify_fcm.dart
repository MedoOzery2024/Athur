import 'dart:io';

import 'package:athur_server/athur_server.dart';

/// Live check that the service-account JSON can mint an FCM OAuth token.
///
/// Sends to a deliberately invalid device token. Success for this tool means
/// Google **authenticated** the service account and rejected the token with
/// `INVALID_ARGUMENT` / `NOT_FOUND` — proving FCM is wired without pushing
/// anyone's phone.
///
/// Usage (from `server/`):
///   dart run tool/verify_fcm.dart
///
/// Never prints the private key.
Future<void> main() async {
  final fileEnv = loadDotEnvFile(findDotEnvFile());
  final env = mergeEnvironment(fileEnv: fileEnv);
  final path = env['ATHUR_FIREBASE_SERVICE_ACCOUNT'];

  if (path == null || path.trim().isEmpty) {
    stderr.writeln(
      '[FAIL] ATHUR_FIREBASE_SERVICE_ACCOUNT is not set. '
      'Point it at the service-account JSON (outside the repo).',
    );
    exit(1);
  }

  final file = File(path.trim());
  if (!file.existsSync()) {
    stderr.writeln(
      '[FAIL] Service-account file not found at the configured path. '
      'Save the JSON there and re-run. The path is not printed so it cannot '
      'leak via logs.',
    );
    exit(1);
  }

  late final FcmService service;
  try {
    service = FcmService.fromServiceAccountFile(path.trim());
  } on FcmException catch (error) {
    stderr.writeln('[FAIL] ${error.message}');
    exit(1);
  }

  stdout.writeln('[INFO] FCM project : ${service.projectId}');
  stdout.writeln('[INFO] Sending a probe to an invalid token …');

  try {
    await service.send(
      const FcmMessage(
        token: 'athur-fcm-probe-invalid-token',
        title: 'Athur probe',
        body: 'Should not be delivered',
        kind: 'system',
      ),
    );
    stderr.writeln(
      '[FAIL] FCM accepted an invalid token. That is unexpected.',
    );
    exit(1);
  } on FcmException catch (error) {
    final status = error.fcmStatus ?? '';
    final ok =
        status == 'INVALID_ARGUMENT' ||
        status == 'NOT_FOUND' ||
        (error.message.toLowerCase().contains('not a valid fcm') ||
            error.message.toLowerCase().contains('requested entity was not found') ||
            error.message.toLowerCase().contains('invalid'));
    if (!ok && error.statusCode == 401) {
      stderr.writeln(
        '[FAIL] Google rejected the service account (HTTP 401). '
        'Check that Cloud Messaging API is enabled and the key is for '
        'this Firebase project.',
      );
      exit(1);
    }
    if (!ok && error.statusCode == 403) {
      stderr.writeln(
        '[FAIL] Permission denied (HTTP 403). Enable Firebase Cloud Messaging '
        'API on the Google Cloud project.',
      );
      exit(1);
    }
    if (!ok) {
      stderr.writeln('[FAIL] ${error.message} (status=$status)');
      exit(1);
    }
    stdout.writeln('[OK]   Google authenticated the service account.');
    stdout.writeln('[OK]   FCM rejected the probe token as expected ($status).');
    stdout.writeln('[RESULT] FCM verification PASSED.');
    exit(0);
  } finally {
    service.dispose();
  }
}

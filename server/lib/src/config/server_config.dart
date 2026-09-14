import 'dart:io';

/// Server configuration, read **only** from environment variables.
///
/// Security rule (project spec §21): secrets are never hardcoded and never
/// committed. This class fails fast at startup if a required secret is missing,
/// so misconfiguration is caught immediately rather than surfacing as a
/// confusing runtime error.
class ServerConfig {
  ServerConfig({
    required this.host,
    required this.port,
    required this.databaseUrl,
    required this.environment,
    required this.jwtSecret,
    this.meteredDomain,
    this.meteredApiKey,
    this.firebaseServiceAccountPath,
    this.allowedOrigins = const <String>[],
  });

  final String host;
  final int port;

  /// Metered TURN app domain, e.g. `athur.metered.live`. Null when TURN is not
  /// configured yet (calls then degrade to STUN-only with a clear warning).
  final String? meteredDomain;

  /// Metered API key. Sensitive: never logged, never sent to the client.
  final String? meteredApiKey;

  /// Absolute path to the Firebase service-account JSON. Null when FCM is off.
  /// The file itself must stay **outside** the git repository.
  final String? firebaseServiceAccountPath;

  /// Browser origins allowed to call the API (CORS). Read from
  /// `ATHUR_ALLOWED_ORIGINS` as a comma-separated list, e.g.
  /// `https://app.athur.example,https://web.athur.example`.
  ///
  /// In development the server also allows any localhost origin so
  /// `flutter run -d chrome` works without configuration. In production only
  /// these exact origins are allowed (never a wildcard).
  final List<String> allowedOrigins;

  /// Whether TURN relay credentials can be minted.
  bool get turnConfigured =>
      (meteredDomain?.isNotEmpty ?? false) &&
      (meteredApiKey?.isNotEmpty ?? false);

  /// Whether a service-account path is configured (file existence is checked
  /// separately when constructing [FcmService]).
  bool get fcmPathConfigured =>
      firebaseServiceAccountPath != null &&
      firebaseServiceAccountPath!.trim().isNotEmpty;

  /// PostgreSQL connection string, e.g.
  /// `postgresql://user:password@localhost:5432/athur`.
  /// Read from `ATHUR_DATABASE_URL`. Never logged.
  final String databaseUrl;

  /// Secret key for signing JWT tokens. Read from `ATHUR_JWT_SECRET`.
  /// Never logged or exposed to clients.
  final String jwtSecret;

  /// `development` | `staging` | `production`.
  final String environment;

  bool get isProduction => environment == 'production';

  /// Loads configuration from [env], or the process environment.
  ///
  /// [env] lets `bin/server.dart` merge a git-ignored `.env` file without
  /// mutating `Platform.environment`. Process/OS values should already have
  /// been merged by the caller so they win over the file.
  ///
  /// Throws [ConfigurationException] when a required value is absent.
  factory ServerConfig.fromEnvironment([Map<String, String>? env]) {
    env ??= Platform.environment;

    final databaseUrl = env['ATHUR_DATABASE_URL'];
    if (databaseUrl == null || databaseUrl.trim().isEmpty) {
      throw const ConfigurationException(
        'ATHUR_DATABASE_URL is not set. Provide it as an environment variable '
        '(see docs/CONFIGURATION.md). It must never be hardcoded.',
      );
    }

    final environment = env['ATHUR_ENV'] ?? 'development';

    final jwtSecret = env['ATHUR_JWT_SECRET'];
    if (jwtSecret == null || jwtSecret.trim().isEmpty) {
      throw const ConfigurationException(
        'ATHUR_JWT_SECRET is not set. Provide a secure random string '
        '(at least 32 characters). It must never be hardcoded.',
      );
    }

    final portRaw = env['ATHUR_PORT'] ?? '8080';
    final port = int.tryParse(portRaw);
    if (port == null || port < 1 || port > 65535) {
      throw ConfigurationException(
        'ATHUR_PORT must be a valid TCP port (1-65535); got "$portRaw".',
      );
    }

    return ServerConfig(
      host: env['ATHUR_HOST'] ?? '0.0.0.0',
      port: port,
      databaseUrl: databaseUrl,
      environment: environment,
      jwtSecret: jwtSecret,
      meteredDomain: env['ATHUR_METERED_DOMAIN'],
      meteredApiKey: env['ATHUR_METERED_API_KEY'],
      firebaseServiceAccountPath: env['ATHUR_FIREBASE_SERVICE_ACCOUNT'],
      allowedOrigins: _parseOrigins(env['ATHUR_ALLOWED_ORIGINS']),
    );
  }

  /// A copy safe to log / print (redacts the database URL credentials).
  Map<String, Object?> toSafeMap() => {
    'host': host,
    'port': port,
    'environment': environment,
    'databaseUrl': _redact(databaseUrl),
    // Never print the key itself — only whether it is present.
    'turnConfigured': turnConfigured,
    'meteredDomain': meteredDomain,
    'fcmPathConfigured': fcmPathConfigured,
  };

  /// Splits a comma-separated origin list, trimming blanks.
  static List<String> _parseOrigins(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <String>[];
    return raw
        .split(',')
        .map((o) => o.trim())
        .where((o) => o.isNotEmpty)
        .toList(growable: false);
  }

  static String _redact(String url) {
    // Show only scheme + host + db name, mask any credentials.
    final uri = Uri.tryParse(url);
    if (uri == null) return '<invalid>';
    return '${uri.scheme}://***:***@${uri.host}:${uri.port}${uri.path}';
  }
}

/// Thrown when configuration is missing or invalid. Fatal at startup.
class ConfigurationException implements Exception {
  const ConfigurationException(this.message);
  final String message;

  @override
  String toString() => 'ConfigurationException: $message';
}

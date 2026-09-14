import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// Central configuration for the backend endpoints the app talks to.
///
/// Why this exists: the correct host **differs per platform**, and hardcoding
/// one value (as the app previously did with `10.0.2.2`) breaks every other
/// platform. This is the single place that decides the backend address.
///
/// | Platform            | Default host                | Why |
/// |---------------------|-----------------------------|-----|
/// | Android emulator    | `10.0.2.2`                  | special alias for the host machine |
/// | iOS simulator / web | `localhost`                 | runs on the same machine |
/// | Physical device     | override via `--dart-define`| must point at a reachable LAN IP |
///
/// Override at build/run time without editing code:
/// ```powershell
/// flutter run -d chrome --dart-define=ATHUR_API_BASE=http://192.168.1.5:8080
/// flutter build apk --dart-define=ATHUR_API_BASE=https://api.athur.example
/// ```
class ApiConfig {
  ApiConfig._();

  /// Explicit override supplied via `--dart-define=ATHUR_API_BASE=...`.
  /// Empty when not provided.
  static const String _override = String.fromEnvironment(
    'ATHUR_API_BASE',
    defaultValue: '',
  );

  /// Port the local Athur backend listens on.
  static const int _localPort = 8080;

  /// The HTTP base URL, e.g. `http://10.0.2.2:8080`.
  ///
  /// Used by [ApiClient] for every REST call.
  static String get httpBaseUrl {
    if (_override.isNotEmpty) return _override;
    return 'http://$_defaultHost:$_localPort';
  }

  /// The WebSocket URL, e.g. `ws://10.0.2.2:8080/ws`.
  ///
  /// Derived from [httpBaseUrl] so a single override covers both transports.
  /// `https` → `wss`, `http` → `ws`.
  static String get webSocketUrl {
    final http = httpBaseUrl;
    final ws = http.startsWith('https')
        ? http.replaceFirst('https', 'wss')
        : http.replaceFirst('http', 'ws');
    return '$ws/ws';
  }

  /// Chooses the default host for the current platform.
  static String get _defaultHost {
    if (kIsWeb) {
      // Web runs in the browser on the same machine as the dev server.
      return 'localhost';
    }
    // On Android, the emulator reaches the host machine via 10.0.2.2. On a
    // physical device this must be overridden with --dart-define. iOS,
    // Windows, macOS and Linux all reach the host as localhost.
    if (Platform.isAndroid) return '10.0.2.2';
    return 'localhost';
  }

  /// True when the app is running on the web target.
  static bool get isWeb => kIsWeb;
}

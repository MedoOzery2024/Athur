import 'dart:convert';
import 'dart:io';

/// A single ICE server entry exactly as WebRTC expects it.
///
/// Mirrors the JSON shape returned by Metered:
/// `{"urls": "...", "username": "...", "credential": "..."}`
/// `urls` may be a single URL or a list in the WebRTC spec; we keep it as a
/// list so both forms are handled without special-casing.
class IceServer {
  const IceServer({required this.urls, this.username, this.credential});

  /// One or more URLs, e.g. `stun:...`, `turn:...`, `turns:...`.
  final List<String> urls;

  /// TURN username (absent for STUN entries).
  final String? username;

  /// TURN credential (absent for STUN entries).
  final String? credential;

  /// True when this entry provides a STUN service.
  bool get isStun =>
      urls.any((u) => u.startsWith('stun:') || u.startsWith('stuns:'));

  /// True when this entry provides a TURN relay service.
  bool get isTurn =>
      urls.any((u) => u.startsWith('turn:') || u.startsWith('turns:'));

  /// Serialises back to the WebRTC-compatible map form.
  Map<String, Object?> toJson() => {
    'urls': urls.length == 1 ? urls.first : urls,
    if (username != null) 'username': username,
    if (credential != null) 'credential': credential,
  };

  /// Parses either the `urls: "..."` (string) or `urls: ["...","..."]` (list)
  /// form returned by Metered.
  factory IceServer.fromJson(Map<String, Object?> json) {
    final rawUrls = json['urls'];
    final urls = switch (rawUrls) {
      final String value => <String>[value],
      final List<Object?> list => list.whereType<String>().toList(
        growable: false,
      ),
      _ => const <String>[],
    };
    if (urls.isEmpty) {
      throw const FormatException('ICE server entry has no usable "urls".');
    }
    return IceServer(
      urls: urls,
      username: json['username'] as String?,
      credential: json['credential'] as String?,
    );
  }
}

/// The full ICE configuration handed to the client for one call.
class IceConfig {
  const IceConfig({
    required this.iceServers,
    required this.provider,
    required this.turnConfigured,
    required this.stunCount,
    required this.turnCount,
  });

  final List<IceServer> iceServers;

  /// Which provider produced this configuration (`metered`).
  final String provider;

  /// Whether TURN is available at all (i.e. relay fallback exists).
  final bool turnConfigured;

  /// How many STUN / TURN entries are present. Surfaced in the diagnostics
  /// panel (spec §7 requires "number of TURN servers / STUN servers").
  final int stunCount;
  final int turnCount;

  Map<String, Object?> toJson() => {
    'iceServers': iceServers.map((s) => s.toJson()).toList(growable: false),
    'provider': provider,
    'turnConfigured': turnConfigured,
    'stunCount': stunCount,
    'turnCount': turnCount,
  };
}

/// Thrown when TURN credentials cannot be obtained.
///
/// The caller decides what to do: for a call, continuing STUN-only degrades
/// connectivity for restrictive NATs, so this is surfaced to the client rather
/// than silently swallowed (project spec §26 — never hide network errors).
class TurnUnavailableException implements Exception {
  const TurnUnavailableException(this.message);
  final String message;

  @override
  String toString() => 'TurnUnavailableException: $message';
}

/// Fetches ICE servers (STUN + TURN) from Metered **server-side only**.
///
/// Why this lives on the server (project spec §9 & §21):
/// - The Metered API key must never ship inside the APK; anyone could extract
///   it and relay traffic on the account.
/// - Centralising the call lets us cache, rate-limit and monitor it.
/// - The client only ever receives the ICE server list, nothing secret.
///
/// Caching: Metered's returned credentials are long-lived, but we still cache
/// to avoid hammering the API on every call setup, and we refresh on demand if
/// the cached set ever fails (the WebRTC layer can request a refresh).
class TurnCredentialService {
  TurnCredentialService({
    required this.domain,
    required this.apiKey,
    HttpClient? httpClient,
    Duration? cacheTtl,
    this.useHttps = true,
  }) : _httpClient = httpClient ?? HttpClient(),
       _cacheTtl = cacheTtl ?? const Duration(hours: 6);

  /// Metered app domain, e.g. `athur.metered.live` (no scheme).
  final String domain;

  /// Metered API key. Held only in memory on the server; never logged.
  final String apiKey;

  /// Whether to use HTTPS. Always true in production (Metered is HTTPS-only).
  /// Configurable so tests can point the service at a local plain-HTTP server
  /// without weakening the production default.
  final bool useHttps;

  final HttpClient _httpClient;
  final Duration _cacheTtl;

  IceConfig? _cache;
  DateTime? _cachedAt;

  /// Returns the ICE configuration, using the cache when it is still fresh.
  ///
  /// Throws [TurnUnavailableException] if Metered cannot be reached or returns
  /// an unexpected payload. The message is safe to log (it never contains the
  /// API key).
  Future<IceConfig> getIceConfig({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _cache != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheTtl) {
      return _cache!;
    }

    final config = await _fetch();
    _cache = config;
    _cachedAt = DateTime.now();
    return config;
  }

  /// Drops the cache so the next request refetches. Called when a call fails
  /// to connect and a re-fetch might help (e.g. rotated credentials).
  void invalidateCache() {
    _cache = null;
    _cachedAt = null;
  }

  Future<IceConfig> _fetch() async {
    final uri = useHttps
        ? Uri.https(domain, '/api/v1/turn/credentials', {'apiKey': apiKey})
        : Uri.http(domain, '/api/v1/turn/credentials', {'apiKey': apiKey});

    try {
      final request = await _httpClient.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );

      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const TurnUnavailableException(
          'Metered rejected the API key (401/403). Check ATHUR_METERED_API_KEY.',
        );
      }
      if (response.statusCode != 200) {
        throw TurnUnavailableException(
          'Metered returned HTTP ${response.statusCode}.',
        );
      }

      final decoded = jsonDecode(body);
      if (decoded is! List) {
        throw const TurnUnavailableException(
          'Metered response was not a JSON array of ICE servers.',
        );
      }

      final servers = decoded
          .whereType<Map<String, Object?>>()
          .map(IceServer.fromJson)
          .toList(growable: false);

      if (servers.isEmpty) {
        throw const TurnUnavailableException(
          'Metered returned an empty ICE server list.',
        );
      }

      // Ensure at least one Google STUN server is present as a first-choice,
      // Google-hosted STUN endpoint (project rule: Google STUN + Metered TURN).
      final withGoogleStun = _ensureGoogleStun(servers);

      return IceConfig(
        iceServers: withGoogleStun,
        provider: 'metered',
        turnConfigured: withGoogleStun.any((s) => s.isTurn),
        stunCount: withGoogleStun.where((s) => s.isStun).length,
        turnCount: withGoogleStun.where((s) => s.isTurn).length,
      );
    } on TurnUnavailableException {
      rethrow;
    } on SocketException catch (error) {
      // Network-level failure. Message contains host/port, never the key.
      throw TurnUnavailableException(
        'Could not reach Metered (${error.message}).',
      );
    } on FormatException catch (error) {
      throw TurnUnavailableException(
        'Metered response could not be parsed: ${error.message}',
      );
    } catch (error) {
      throw TurnUnavailableException('TURN lookup failed: $error');
    }
  }

  /// Prepends Google's public STUN endpoints if the provider did not include
  /// them. Metered supplies its own STUN, but the spec explicitly asks for
  /// Google STUN to be part of the ICE configuration.
  List<IceServer> _ensureGoogleStun(List<IceServer> servers) {
    final hasGoogle = servers.any(
      (s) => s.urls.any((u) => u.contains('stun.l.google.com')),
    );
    if (hasGoogle) return servers;

    return [
      const IceServer(urls: ['stun:stun.l.google.com:19302']),
      const IceServer(urls: ['stun:stun1.l.google.com:19302']),
      ...servers,
    ];
  }

  void dispose() => _httpClient.close(force: true);
}

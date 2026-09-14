import 'package:postgres/postgres.dart';

/// Owns the PostgreSQL connection **pool** for the whole process.
///
/// API note: this targets `postgres` v3.5.x, whose interface is
/// `Pool.withEndpoints([Endpoint(...)], settings: PoolSettings(...))`.
/// (v2's `Endpoint.parse` / URL form on `Connection.open` no longer exists.)
///
/// Design notes (project spec §54 — database performance):
/// - One pool is created at startup and shared; opening a connection per
///   request would be slow and unsafe under load.
/// - Credentials come from the environment (via [ServerConfig]) and are never
///   logged or exposed to the Flutter client.
/// - Only this server talks to PostgreSQL.
class Database {
  Database._(this._pool);

  // `Pool<Endpoint>`: for a fixed endpoint list the connection-lookup key type
  // is `Endpoint` (see postgres v3 `Pool.withEndpoints`).
  final Pool<Endpoint>? _pool;

  /// Creates a fake Database for unit tests that don't need real PostgreSQL.
  ///
  /// The returned instance will throw if any actual query is executed.
  /// Only use in tests that verify routing/middleware without touching the DB.
  factory Database.fake() => Database._(null);

  /// Creates the pool and verifies connectivity. Throws if the URL is
  /// malformed or the database is unreachable, so startup fails loudly instead
  /// of serving broken requests.
  static Future<Database> connect({
    required String url,
    int maxConnections = 8,
  }) async {
    final endpoint = parsePostgresUrl(url);

    final pool = Pool<Endpoint>.withEndpoints(
      [endpoint],
      settings: PoolSettings(
        maxConnectionCount: maxConnections,
        // Recycle connections so stale sockets are not reused indefinitely.
        maxConnectionAge: const Duration(minutes: 30),
        maxSessionUse: const Duration(minutes: 10),
        // Local dev PostgreSQL usually has no SSL; allow URL override via
        // ?sslmode=require or ?sslmode=disable.  Default to disable so
        // development works out of the box.
        sslMode: sslModeFromUrl(url) ?? SslMode.disable,
      ),
    );

    final db = Database._(pool);
    final ready = await db.ping();
    if (!ready) {
      await pool.close();
      throw StateError('PostgreSQL is not reachable at the configured URL.');
    }
    return db;
  }

  /// A real round-trip used by `/health/ready`. Returns false on any failure.
  Future<bool> ping() async {
    final pool = _pool;
    if (pool == null) return false;
    try {
      final result = await pool.execute('SELECT 1 AS one;');
      return result.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Executes a parameterised query.
  ///
  /// Always use parameters — never interpolate user input into SQL, which
  /// would enable SQL injection (project spec §25).
  /// `parameters` accepts a positional `List` or a named `Map` matching the
  /// `@name` placeholders in the query (postgres v3 desugars `@name`).
  Future<Result> execute(String sql, {Object? parameters}) {
    final pool = _pool;
    if (pool == null) {
      throw StateError('Cannot execute queries on a fake Database instance.');
    }
    return pool.execute(sql, parameters: parameters);
  }

  /// Runs statements inside a single transaction.
  ///
  /// Used for multi-step writes that must be atomic (e.g. message insert +
  /// delivery-status rows + chat last-message update). If the callback throws,
  /// everything rolls back — the client is never told a write succeeded before
  /// the transaction actually committed (project spec §57).
  Future<T> transaction<T>(Future<T> Function(TxSession session) action) {
    final pool = _pool;
    if (pool == null) {
      throw StateError('Cannot run transactions on a fake Database instance.');
    }
    return pool.runTx(action);
  }

  Future<void> close() async {
    final pool = _pool;
    if (pool != null) await pool.close();
  }
}

/// Parses a `postgresql://user:pass@host:port/dbname` URL into an [Endpoint].
///
/// Public so it can be unit-tested without a live database. Nothing outside the
/// data layer handles the raw connection string.
Endpoint parsePostgresUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme.isEmpty) {
    throw ArgumentError(
      'ATHUR_DATABASE_URL must be a valid postgresql:// URL.',
    );
  }
  if (uri.scheme != 'postgresql' && uri.scheme != 'postgres') {
    throw ArgumentError(
      'ATHUR_DATABASE_URL scheme must be postgresql:// '
      '(got "${uri.scheme}://").',
    );
  }

  final database = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;
  if (database.isEmpty) {
    throw ArgumentError(
      'ATHUR_DATABASE_URL must include a database name (path).',
    );
  }

  final userInfo = uri.userInfo.split(':');
  return Endpoint(
    host: uri.host.isEmpty ? 'localhost' : uri.host,
    port: uri.hasPort ? uri.port : 5432,
    database: database,
    username: uri.userInfo.isEmpty ? null : Uri.decodeComponent(userInfo.first),
    password: userInfo.length > 1
        ? Uri.decodeComponent(userInfo.skip(1).join(':'))
        : null,
  );
}

/// Resolves the SSL mode from a URL query parameter (`?sslmode=...`).
///
/// Exposed for testing. Returns null when unspecified, letting the driver use
/// its default. Production deployments should set `sslmode=verify-full`.
SslMode? sslModeFromUrl(String url) {
  final uri = Uri.tryParse(url);
  return switch (uri?.queryParameters['sslmode']) {
    'require' => SslMode.require,
    'verify-full' || 'verifyfull' => SslMode.verifyFull,
    'disable' => SslMode.disable,
    _ => null,
  };
}

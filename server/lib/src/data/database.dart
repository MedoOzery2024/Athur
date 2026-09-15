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
  ///
  /// `parameters` accepts either:
  /// - a positional `List` (query uses `$1, $2, …`), or
  /// - a named `Map` (query uses `@name` placeholders).
  ///
  /// IMPORTANT: the underlying `postgres` v3 driver rejects a plain Map with
  /// "Maps are only supported by `Sql.named`". Callers across the codebase pass
  /// `{'id': …}`, so we wrap any Map in [Sql.named] here — one place instead of
  /// dozens of call sites, and impossible to forget in new code.
  Future<Result> execute(String sql, {Object? parameters}) {
    final pool = _pool;
    if (pool == null) {
      throw StateError('Cannot execute queries on a fake Database instance.');
    }
    return pool.execute(_query(sql, parameters), parameters: parameters);
  }

  /// Wraps a statement in [Sql.named] when the caller supplied a named-
  /// parameter Map.
  ///
  /// Why this is needed: the `postgres` v3 driver accepts `parameters: {...}`
  /// (a Map) ONLY when the statement itself is a [Sql.named] value. Passing a
  /// plain String with a Map throws "Maps are only supported by `Sql.named`".
  /// Callers throughout the codebase use `@name` placeholders with Maps, so
  /// the wrapping is applied here — once, centrally — instead of at every call
  /// site. Lists (positional `$1` parameters) are passed through untouched.
  static Object _query(String sql, Object? parameters) {
    if (parameters is Map) return Sql.named(sql);
    return sql;
  }

  /// Runs statements inside a single transaction.
  ///
  /// Used for multi-step writes that must be atomic (e.g. message insert +
  /// delivery-status rows + chat last-message update). If the callback throws,
  /// everything rolls back — the client is never told a write succeeded before
  /// the transaction actually committed (project spec §57).
  ///
  /// The callback receives an [AthurTx], whose `execute` applies the same
  /// [Sql.named] handling as [execute], so callers can use `{\@name: value}`
  /// maps consistently inside and outside transactions.
  Future<T> transaction<T>(Future<T> Function(AthurTx tx) action) {
    final pool = _pool;
    if (pool == null) {
      throw StateError('Cannot run transactions on a fake Database instance.');
    }
    return pool.runTx((session) => action(AthurTx._(session)));
  }

  Future<void> close() async {
    final pool = _pool;
    if (pool != null) await pool.close();
  }
}

/// A transaction handle used by [Database.transaction].
///
/// It only exposes what the application actually needs — a parameterised
/// `execute` — so the complex driver session interface does not leak, and the
/// [Sql.named] wrapping stays consistent.
class AthurTx {
  AthurTx._(this._session);

  final TxSession _session;

  /// Executes a statement inside the transaction.
  ///
  /// Accepts a named-parameter Map (query uses `@name`) or a positional List
  /// (query uses `$1, $2, …`), exactly like [Database.execute].
  Future<Result> execute(String sql, {Object? parameters}) {
    return _session.execute(
      Database._query(sql, parameters),
      parameters: parameters,
    );
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

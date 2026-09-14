import 'dart:io';

/// Reads a dotenv-style file into a map. Never logs values.
///
/// Rules:
/// - Blank lines and `#` comments are ignored.
/// - `KEY=VALUE` (optional quotes around VALUE).
/// - Existing process environment variables are **not** overridden by the
///   caller; this function only parses the file.
Map<String, String> parseDotEnv(String source) {
  final out = <String, String>{};
  for (final raw in source.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq).trim();
    if (key.isEmpty) continue;
    var value = line.substring(eq + 1).trim();
    if (value.length >= 2) {
      final start = value[0];
      final end = value[value.length - 1];
      if ((start == '"' && end == '"') || (start == "'" && end == "'")) {
        value = value.substring(1, value.length - 1);
      }
    }
    out[key] = value;
  }
  return out;
}

/// Locates the repo `.env` without requiring a working directory convention.
///
/// Search order:
/// 1. `ATHUR_ENV_FILE` if set
/// 2. `../.env` relative to the current directory (when run from `server/`)
/// 3. `.env` in the current directory
File? findDotEnvFile({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final explicit = env['ATHUR_ENV_FILE'];
  if (explicit != null && explicit.trim().isNotEmpty) {
    return File(explicit.trim());
  }

  for (final candidate in const ['../.env', '.env']) {
    final file = File(candidate);
    if (file.existsSync()) return file;
  }
  return null;
}

/// Loads dotenv values from disk. Missing files yield an empty map.
Map<String, String> loadDotEnvFile(File? file) {
  if (file == null || !file.existsSync()) return const {};
  return parseDotEnv(file.readAsStringSync());
}

/// Merges file env under process env (process wins).
Map<String, String> mergeEnvironment({
  Map<String, String>? fileEnv,
  Map<String, String>? processEnv,
  Map<String, String>? overrides,
}) {
  return {
    ...?fileEnv,
    ...processEnv ?? Platform.environment,
    ...?overrides,
  };
}

/// Athur backend server library.
///
/// Public surface intended for `bin/server.dart` and tests. Keeping a barrel
/// file means the entry point imports one path instead of many internals.
library;

export 'src/api/server.dart' show AthurServer;
export 'src/api/json.dart' show Json;
export 'src/config/server_config.dart'
    show ServerConfig, ConfigurationException;
export 'src/config/load_env.dart'
    show findDotEnvFile, loadDotEnvFile, mergeEnvironment, parseDotEnv;
export 'src/core/errors/api_error.dart' show ApiError;
export 'src/data/database.dart' show Database, parsePostgresUrl, sslModeFromUrl;
export 'src/integrations/fcm/fcm_service.dart'
    show FcmException, FcmMessage, FcmSendResult, FcmService;
export 'src/integrations/turn/turn_credential_service.dart'
    show IceConfig, IceServer, TurnCredentialService, TurnUnavailableException;
export 'src/services/auth_service.dart' show AuthService, AuthError, TokenPair;

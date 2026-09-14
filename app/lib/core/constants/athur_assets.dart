/// Central place for asset paths so no widget hardcodes a string path.
///
/// Keeping these in one file means moving/renaming an asset is a single edit.
abstract final class AthurAssets {
  AthurAssets._();

  static const String _images = 'assets/images';
  static const String _audio = 'assets/audio';

  /// Official Athur logo (1024x1024, square). Do not replace without approval.
  static const String logo = '$_images/logo.png';

  /// Custom ringtone used for incoming and outgoing calls.
  static const String ringtone = '$_audio/ringtone.mp3';
}

/// Static application metadata.
abstract final class AthurAppInfo {
  AthurAppInfo._();

  static const String appName = 'Athur';

  /// Semantic version — must stay in sync with `pubspec.yaml` `version:`.
  /// The self-hosted update system (later phase) compares this against the
  /// server release manifest.
  static const String version = '1.0.0';

  /// Android versionCode — must be monotonically increasing per release.
  static const int versionCode = 1;
}

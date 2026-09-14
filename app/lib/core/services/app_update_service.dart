import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Checks for app updates from GitHub releases and prompts the user to update.
///
/// Usage:
/// ```dart
/// final updater = AppUpdateService.instance;
/// final hasUpdate = await updater.checkForUpdate();
/// if (hasUpdate) {
///   await updater.showUpdateDialog(context);
/// }
/// ```
class AppUpdateService {
  AppUpdateService._();

  static final AppUpdateService instance = AppUpdateService._();

  /// GitHub repository info (update these values).
  static const _owner = 'medo444'; // TODO: Change to your GitHub username
  static const _repo = 'Athur';

  /// Checks if a new version is available.
  Future<UpdateInfo?> checkForUpdate() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      // Fetch latest release from GitHub API.
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/$_owner/$_repo/releases/latest'),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      );

      if (response.statusCode != 200) {
        debugPrint('[Athur][update] Failed to check: ${response.statusCode}');
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, Object?>;
      final tagName = json['tag_name'] as String? ?? '';
      final latestVersion = tagName.replaceFirst('v', '');

      // Compare versions.
      if (_isNewerVersion(latestVersion, currentVersion)) {
        final apkAsset = (json['assets'] as List?)?.firstWhere(
          (asset) => (asset as Map<String, Object?>)['name']?.toString().endsWith('.apk') == true,
          orElse: () => null,
        ) as Map<String, Object?>?;

        final downloadUrl = apkAsset?['browser_download_url'] as String?;
        final body = json['body'] as String? ?? '';

        return UpdateInfo(
          latestVersion: latestVersion,
          currentVersion: currentVersion,
          downloadUrl: downloadUrl ?? 'https://github.com/$_owner/$_repo/releases/latest',
          changelog: body,
        );
      }

      return null;
    } catch (e) {
      debugPrint('[Athur][update] Error: $e');
      return null;
    }
  }

  /// Opens the download URL in browser or app store.
  Future<void> downloadUpdate(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Compares two version strings (semver).
  bool _isNewerVersion(String latest, String current) {
    final latestParts = latest.split('.').map(int.parse).toList();
    final currentParts = current.split('.').map(int.parse).toList();

    for (var i = 0; i < 3; i++) {
      final l = i < latestParts.length ? latestParts[i] : 0;
      final c = i < currentParts.length ? currentParts[i] : 0;
      if (l > c) return true;
      if (l < c) return false;
    }
    return false;
  }
}

/// Update information.
class UpdateInfo {
  const UpdateInfo({
    required this.latestVersion,
    required this.currentVersion,
    required this.downloadUrl,
    required this.changelog,
  });

  final String latestVersion;
  final String currentVersion;
  final String downloadUrl;
  final String changelog;
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Checks for app updates from GitHub releases and prompts the user to update.
class AppUpdateService {
  AppUpdateService._();

  static final AppUpdateService instance = AppUpdateService._();

  /// GitHub repository info (update these values).
  static const _owner = 'medo444'; // TODO: Change to your GitHub username
  static const _repo = 'Athur';

  http.Client? _downloadClient;
  double _progress = 0;
  bool _isDownloading = false;

  double get progress => _progress;
  bool get isDownloading => _isDownloading;

  /// Checks if a new version is available.
  Future<UpdateInfo?> checkForUpdate() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

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

      if (_isNewerVersion(latestVersion, currentVersion)) {
        final apkAsset = (json['assets'] as List?)?.firstWhere(
          (asset) => (asset as Map<String, Object?>)['name']?.toString().endsWith('.apk') == true,
          orElse: () => null,
        ) as Map<String, Object?>?;

        final downloadUrl = apkAsset?['browser_download_url'] as String?;
        final body = json['body'] as String? ?? '';
        final fileSize = apkAsset?['size'] as int?;

        return UpdateInfo(
          latestVersion: latestVersion,
          currentVersion: currentVersion,
          downloadUrl: downloadUrl ?? 'https://github.com/$_owner/$_repo/releases/latest',
          changelog: body,
          fileSize: fileSize,
        );
      }

      return null;
    } catch (e) {
      debugPrint('[Athur][update] Error: $e');
      return null;
    }
  }

  /// Downloads the APK in-app with progress tracking.
  /// Returns the file path when done, or null on failure/cancel.
  Future<String?> downloadApk(
    String url, {
    void Function(double progress)? onProgress,
  }) async {
    _isDownloading = true;
    _progress = 0;
    _downloadClient = http.Client();

    try {
      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/athur_update.apk';
      final file = File(filePath);
      if (await file.exists()) await file.delete();

      final request = http.Request('GET', Uri.parse(url));
      final response = await _downloadClient!.send(request);

      if (response.statusCode != 200) {
        debugPrint('[Athur][update] Download failed: ${response.statusCode}');
        return null;
      }

      final totalBytes = response.contentLength ?? 0;
      int receivedBytes = 0;
      final sink = file.openWrite();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          _progress = receivedBytes / totalBytes;
          onProgress?.call(_progress);
        }
      }

      await sink.close();
      debugPrint('[Athur][update] Downloaded to: $filePath');
      return filePath;
    } catch (e) {
      debugPrint('[Athur][update] Download error: $e');
      return null;
    } finally {
      _isDownloading = false;
      _downloadClient = null;
    }
  }

  /// Cancels an in-progress download.
  void cancelDownload() {
    _downloadClient?.close();
    _downloadClient = null;
    _isDownloading = false;
    _progress = 0;
  }

  /// Opens the downloaded APK for installation.
  Future<void> installApk(String filePath) async {
    final uri = Uri.file(filePath);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Fallback: opens the download URL in browser.
  Future<void> openInBrowser(String url) async {
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
    this.fileSize,
  });

  final String latestVersion;
  final String currentVersion;
  final String downloadUrl;
  final String changelog;
  final int? fileSize;

  String get fileSizeText {
    if (fileSize == null) return '';
    if (fileSize! < 1024) return '$fileSize B';
    if (fileSize! < 1024 * 1024) return '${(fileSize! / 1024).toStringAsFixed(1)} KB';
    return '${(fileSize! / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

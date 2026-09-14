import 'package:flutter/material.dart';

import '../services/app_update_service.dart';
import '../theme/athur_colors.dart';

/// Shows an update dialog when a new version is available.
/// Supports in-app download with a progress indicator.
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.updateInfo});

  final UpdateInfo updateInfo;

  static Future<void> show(BuildContext context, UpdateInfo updateInfo) async {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => UpdateDialog(updateInfo: updateInfo),
    );
  }

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _isDownloading = false;
  double _progress = 0;
  String? _error;

  @override
  void dispose() {
    if (_isDownloading) {
      AppUpdateService.instance.cancelDownload();
    }
    super.dispose();
  }

  void _startDownload() async {
    setState(() {
      _isDownloading = true;
      _error = null;
    });

    try {
      final filePath = await AppUpdateService.instance.downloadApk(
        widget.updateInfo.downloadUrl,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );

      if (filePath != null && mounted) {
        // Ask user to install.
        setState(() => _isDownloading = false);
        await AppUpdateService.instance.installApk(filePath);
        if (mounted) Navigator.of(context).pop();
      } else if (mounted && _isDownloading) {
        // Download was cancelled or failed.
        setState(() {
          _isDownloading = false;
          _error = 'Download failed. Try opening in browser.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _error = 'Download failed: $e';
        });
      }
    }
  }

  void _openInBrowser() async {
    await AppUpdateService.instance.openInBrowser(widget.updateInfo.downloadUrl);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AthurColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icon
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AthurColors.gold.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.system_update,
                color: AthurColors.gold,
                size: 32,
              ),
            ),
            const SizedBox(height: 16),

            // Title
            const Text(
              'Update Available',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),

            // Version + size info
            Text(
              'Version ${widget.updateInfo.latestVersion}'
              '${widget.updateInfo.fileSizeText.isNotEmpty ? ' (${widget.updateInfo.fileSizeText})' : ''}',
              style: const TextStyle(
                color: AthurColors.gold,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),

            // Changelog
            if (widget.updateInfo.changelog.isNotEmpty) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  widget.updateInfo.changelog,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 13,
                    height: 1.5,
                  ),
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Download progress
            if (_isDownloading) ...[
              LinearProgressIndicator(
                value: _progress,
                backgroundColor: Colors.white.withValues(alpha: 0.1),
                valueColor: const AlwaysStoppedAnimation<Color>(AthurColors.gold),
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
              const SizedBox(height: 8),
              Text(
                '${(_progress * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Error
            if (_error != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AthurColors.danger.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AthurColors.danger, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Buttons
            if (!_isDownloading) ...[
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        'Later',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextButton(
                      onPressed: _openInBrowser,
                      child: const Text(
                        'Browser',
                        style: TextStyle(color: AthurColors.gold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _startDownload,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AthurColors.gold,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Update',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    AppUpdateService.instance.cancelDownload();
                    setState(() {
                      _isDownloading = false;
                      _progress = 0;
                    });
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AthurColors.danger,
                    side: const BorderSide(color: AthurColors.danger),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

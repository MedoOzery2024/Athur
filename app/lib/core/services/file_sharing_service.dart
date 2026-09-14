import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import '../config/api_config.dart';
import 'secure_storage.dart';

/// Handles file, image, and video selection and upload for chat attachments.
///
/// Usage:
/// ```dart
/// final picker = FileSharingService.instance;
/// final result = await picker.uploadImage(source: ImageSource.gallery);
/// final result = await picker.uploadFile();
/// ```
class FileSharingService {
  FileSharingService._();

  static final FileSharingService instance = FileSharingService._();

  final _imagePicker = ImagePicker();
  final _secureStorage = SecureStorage.instance;

  // ────────────────────────── Upload ──────────────────────────

  /// Uploads an image and returns the download URL.
  Future<UploadResult?> uploadImage({required ImageSource source}) async {
    final file = await pickImage(source: source);
    if (file == null) return null;
    return uploadFileToServer(file);
  }

  /// Uploads a video and returns the download URL.
  Future<UploadResult?> uploadVideo({required ImageSource source}) async {
    final file = await pickVideo(source: source);
    if (file == null) return null;
    return uploadFileToServer(file);
  }

  /// Uploads a file and returns the download URL.
  Future<UploadResult?> uploadFile() async {
    final file = await pickFile();
    if (file == null) return null;
    return uploadFileToServer(file);
  }

  /// Uploads a voice recording and returns the download URL.
  Future<UploadResult?> uploadVoiceRecording(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return null;

    final size = await file.length();
    final sharedFile = SharedFile(
      filePath: filePath,
      fileName: p.basename(filePath),
      mimeType: 'audio/mp4',
      fileSize: size,
      type: SharedFileType.audio,
    );

    return uploadFileToServer(sharedFile);
  }

  /// Core upload method that sends file to server.
  Future<UploadResult?> uploadFileToServer(SharedFile file) async {
    try {
      final token = await _secureStorage.getAccessToken();
      if (token == null) {
        debugPrint('[Athur][file] No access token');
        return null;
      }

      final fileBytes = await File(file.filePath).readAsBytes();

      // Create multipart request.
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('${ApiConfig.httpBaseUrl}/api/v1/media/upload'),
      );

      // Add headers.
      request.headers['Authorization'] = 'Bearer $token';

      // Add file.
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        fileBytes,
        filename: file.fileName,
      ));

      // Add metadata.
      request.fields['context'] = 'message';

      // Send request.
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, Object?>;

        return UploadResult(
          id: json['id'] as String,
          url: json['url'] as String,
          mimeType: json['mime_type'] as String,
          fileSize: json['file_size'] as int,
        );
      } else {
        debugPrint('[Athur][file] Upload failed: ${response.statusCode} ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint('[Athur][file] Upload error: $e');
      return null;
    }
  }

  // ────────────────────────── Image Picking ──────────────────────────

  /// Picks an image from gallery or camera.
  Future<SharedFile?> pickImage({required ImageSource source}) async {
    try {
      final pickedFile = await _imagePicker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (pickedFile == null) return null;

      final file = File(pickedFile.path);
      final size = await file.length();

      return SharedFile(
        filePath: pickedFile.path,
        fileName: pickedFile.name,
        mimeType: _getMimeType(pickedFile.path),
        fileSize: size,
        type: SharedFileType.image,
      );
    } catch (e) {
      debugPrint('[Athur][file] Failed to pick image: $e');
      return null;
    }
  }

  /// Picks a video from gallery or camera.
  Future<SharedFile?> pickVideo({required ImageSource source}) async {
    try {
      final pickedFile = await _imagePicker.pickVideo(
        source: source,
        maxDuration: const Duration(minutes: 5),
      );

      if (pickedFile == null) return null;

      final file = File(pickedFile.path);
      final size = await file.length();

      return SharedFile(
        filePath: pickedFile.path,
        fileName: pickedFile.name,
        mimeType: _getMimeType(pickedFile.path),
        fileSize: size,
        type: SharedFileType.video,
      );
    } catch (e) {
      debugPrint('[Athur][file] Failed to pick video: $e');
      return null;
    }
  }

  // ────────────────────────── File Picking ──────────────────────────

  /// Picks a file of any type.
  Future<SharedFile?> pickFile({
    List<String>? allowedExtensions,
    FileType fileType = FileType.any,
  }) async {
    try {
      // file_picker v11+ exposes static methods and returns a PlatformFile
      // directly from pickFile(); the old `FilePicker.platform.pickFiles()`
      // instance API and the FilePickerResult wrapper were removed.
      final platformFile = await FilePicker.pickFile(
        type: fileType,
        allowedExtensions: allowedExtensions,
      );

      if (platformFile == null) return null;
      if (platformFile.path == null) return null;

      final file = File(platformFile.path!);
      final size = await file.length();

      return SharedFile(
        filePath: platformFile.path!,
        fileName: platformFile.name,
        mimeType: _getMimeType(platformFile.path!),
        fileSize: size,
        type: _getFileType(platformFile.extension),
      );
    } catch (e) {
      debugPrint('[Athur][file] Failed to pick file: $e');
      return null;
    }
  }

  // ────────────────────────── Helpers ──────────────────────────

  String _getMimeType(String path) {
    final ext = p.extension(path).toLowerCase();
    return switch (ext) {
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.png' => 'image/png',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.mp4' => 'video/mp4',
      '.mov' => 'video/quicktime',
      '.avi' => 'video/x-msvideo',
      '.mp3' => 'audio/mpeg',
      '.m4a' => 'audio/mp4',
      '.wav' => 'audio/wav',
      '.ogg' => 'audio/ogg',
      '.pdf' => 'application/pdf',
      '.doc' || '.docx' => 'application/msword',
      '.xls' || '.xlsx' => 'application/vnd.ms-excel',
      '.txt' => 'text/plain',
      _ => 'application/octet-stream',
    };
  }

  SharedFileType _getFileType(String? extension) {
    return switch (extension?.toLowerCase()) {
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' || 'bmp' => SharedFileType.image,
      'mp4' || 'mov' || 'avi' || 'mkv' || 'webm' => SharedFileType.video,
      'mp3' || 'm4a' || 'wav' || 'ogg' || 'aac' => SharedFileType.audio,
      'pdf' || 'doc' || 'docx' || 'xls' || 'xlsx' || 'ppt' || 'pptx' => SharedFileType.document,
      _ => SharedFileType.file,
    };
  }
}

/// Upload result from server.
class UploadResult {
  const UploadResult({
    required this.id,
    required this.url,
    required this.mimeType,
    required this.fileSize,
  });

  final String id;
  final String url;
  final String mimeType;
  final int fileSize;
}

/// Shared file metadata.
class SharedFile {
  const SharedFile({
    required this.filePath,
    required this.fileName,
    required this.mimeType,
    required this.fileSize,
    required this.type,
  });

  final String filePath;
  final String fileName;
  final String mimeType;
  final int fileSize;
  final SharedFileType type;

  /// Formatted file size string.
  String get formattedSize {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Whether this file is an image.
  bool get isImage => type == SharedFileType.image;

  /// Whether this file is a video.
  bool get isVideo => type == SharedFileType.video;

  /// Whether this file is audio.
  bool get isAudio => type == SharedFileType.audio;
}

/// Type of shared file.
enum SharedFileType { image, video, audio, document, file }

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../../data/database.dart';
import '../middleware/auth_middleware.dart';

/// Media upload, presigned URL generation, and serving endpoints.
///
/// Routes:
///   POST /api/v1/media/upload          — Upload a file (multipart)
///   POST /api/v1/media/presign         — Get a presigned upload URL
///   GET  /api/v1/media/:id             — Serve/download media
///   GET  /api/v1/media/:id/thumbnail   — Serve thumbnail
///   DELETE /api/v1/media/:id           — Soft-delete media
class MediaRoutes {
  MediaRoutes({required this.db});

  final Database db;
  static const _uuid = Uuid();

  /// Local storage directory for dev (production would use S3/GCS).
  static const _storageDir = 'athur_media';

  Router get router {
    final router = Router();
    router.post('/media/upload', _upload);
    router.post('/media/presign', _presign);
    router.get('/media/<id>', _serve);
    router.get('/media/<id>/thumbnail', _serveThumbnail);
    router.delete('/media/<id>', _delete);
    return router;
  }

  // ────────────────────────── Upload ──────────────────────────

  /// Handles multipart file upload.
  Future<Response> _upload(Request request) async {
    final userId = request.userId;
    if (userId == null) return Response.forbidden('Unauthorized');

    try {
      // Parse multipart form data.
      final contentType = request.headers['content-type'] ?? '';
      if (!contentType.contains('multipart/form-data')) {
        return Response.badRequest(body: 'Expected multipart/form-data');
      }

      // Read the full body as bytes.
      final bodyBytes = await request.read().fold<List<int>>(
        <int>[],
        (previous, element) => previous..addAll(element),
      );
      if (bodyBytes.isEmpty) {
        return Response.badRequest(body: 'Empty request body');
      }

      // Extract boundary from content-type.
      final boundary = _extractBoundary(contentType);
      if (boundary == null) {
        return Response.badRequest(body: 'Missing boundary');
      }

      // Parse multipart data.
      final multipart = MultipartParser(boundary).parse(bodyBytes);
      if (multipart == null || multipart.file == null) {
        return Response.badRequest(body: 'No file in upload');
      }

      final file = multipart.file!;
      final fileName = multipart.fileName ?? 'unknown';
      final mimeType = multipart.mimeType ?? 'application/octet-stream';
      final context = multipart.fields['context'] ?? 'message';

      // Validate file size (max 50MB for dev).
      const maxSize = 50 * 1024 * 1024;
      if (file.length > maxSize) {
        return Response.badRequest(body: 'File too large (max 50MB)');
      }

      // Generate storage key.
      final ext = p.extension(fileName).toLowerCase();
      final storageKey = '${_uuid.v4()}$ext';
      final storagePath = '$_storageDir/$storageKey';

      // Ensure storage directory exists.
      final storageDir = Directory(_storageDir);
      if (!await storageDir.exists()) {
        await storageDir.create(recursive: true);
      }

      // Write file to disk.
      final storedFile = File(storagePath);
      await storedFile.writeAsBytes(file);

      // Calculate SHA256.
      final bytes = await storedFile.readAsBytes();
      final sha256Hash = sha256.convert(bytes).toString();

      // Insert media record.
      final mediaId = _uuid.v4();
      await db.execute(
        '''
        INSERT INTO media (id, owner_id, context, storage_key, mime_type,
                          byte_size, sha256, original_filename, status)
        VALUES (@id, @ownerId, @context, @storageKey, @mimeType,
                @byteSize, @sha256, @filename, 'ready')
        ''',
        parameters: {
          'id': mediaId,
          'ownerId': userId,
          'context': context,
          'storageKey': storageKey,
          'mimeType': mimeType,
          'byteSize': file.length,
          'sha256': sha256Hash,
          'filename': fileName,
        },
      );

      // Generate download URL.
      final host = request.headers['host'] ?? 'localhost:8080';
      final scheme = request.url.scheme.isNotEmpty ? request.url.scheme : 'http';
      final downloadUrl = '$scheme://$host/api/v1/media/$mediaId';

      return Response.ok(
        jsonEncode({
          'id': mediaId,
          'url': downloadUrl,
          'mime_type': mimeType,
          'file_size': file.length,
          'storage_key': storageKey,
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(body: 'Upload failed: $e');
    }
  }

  // ────────────────────────── Presign ──────────────────────────

  /// Returns a presigned URL for direct upload (client-side upload).
  Future<Response> _presign(Request request) async {
    final userId = request.userId;
    if (userId == null) return Response.forbidden('Unauthorized');

    try {
      final body = await request.read().transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, Object?>;

      final fileName = json['file_name'] as String?;
      final mimeType = json['mime_type'] as String?;
      final fileSize = json['file_size'] as int?;
      final context = json['context'] as String? ?? 'message';

      if (fileName == null || mimeType == null || fileSize == null) {
        return Response.badRequest(body: 'Missing file_name, mime_type, or file_size');
      }

      // Validate file size.
      const maxSize = 50 * 1024 * 1024;
      if (fileSize > maxSize) {
        return Response.badRequest(body: 'File too large (max 50MB)');
      }

      // Generate storage key.
      final ext = p.extension(fileName).toLowerCase();
      final storageKey = '${_uuid.v4()}$ext';

      // Create pending media record.
      final mediaId = _uuid.v4();
      await db.execute(
        '''
        INSERT INTO media (id, owner_id, context, storage_key, mime_type,
                          byte_size, original_filename, status)
        VALUES (@id, @ownerId, @context, @storageKey, @mimeType,
                @byteSize, @filename, 'pending')
        ''',
        parameters: {
          'id': mediaId,
          'ownerId': userId,
          'context': context,
          'storageKey': storageKey,
          'mimeType': mimeType,
          'byteSize': fileSize,
          'filename': fileName,
        },
      );

      // For local dev, return the upload URL (same as upload endpoint).
      final host = request.headers['host'] ?? 'localhost:8080';
      final scheme = request.url.scheme.isNotEmpty ? request.url.scheme : 'http';

      return Response.ok(
        jsonEncode({
          'media_id': mediaId,
          'upload_url': '$scheme://$host/api/v1/media/$mediaId/upload',
          'storage_key': storageKey,
          'method': 'PUT',
          'headers': {
            'content-type': mimeType,
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(body: 'Presign failed: $e');
    }
  }

  // ────────────────────────── Serve ──────────────────────────

  /// Serves media file for download/streaming.
  Future<Response> _serve(Request request, String id) async {
    try {
      // Look up media record.
      final result = await db.execute(
        'SELECT storage_key, mime_type, byte_size, original_filename FROM media WHERE id = @id AND status = \'ready\'',
        parameters: {'id': id},
      );

      if (result.isEmpty) {
        return Response.notFound('Media not found');
      }

      final row = result.first.toColumnMap();
      final storageKey = row['storage_key'] as String;
      final mimeType = row['mime_type'] as String;
      final fileSize = row['byte_size'] as int;
      final filename = row['original_filename'] as String?;

      // Read file from disk.
      final file = File('$_storageDir/$storageKey');
      if (!await file.exists()) {
        return Response.notFound('File not found on disk');
      }

      // Stream file for large files.
      final fileStream = file.openRead();

      return Response.ok(
        fileStream,
        headers: {
          'content-type': mimeType,
          'content-length': fileSize.toString(),
          if (filename != null)
            'content-disposition': 'inline; filename="$filename"',
          // Cache for 1 hour.
          'cache-control': 'public, max-age=3600',
        },
      );
    } catch (e) {
      return Response.internalServerError(body: 'Serve failed: $e');
    }
  }

  /// Serves thumbnail (placeholder — would resize in production).
  Future<Response> _serveThumbnail(Request request, String id) async {
    // For now, just serve the original file.
    return _serve(request, id);
  }

  // ────────────────────────── Delete ──────────────────────────

  /// Soft-deletes media (marks as deleted, doesn't remove file).
  Future<Response> _delete(Request request, String id) async {
    final userId = request.userId;
    if (userId == null) return Response.forbidden('Unauthorized');

    try {
      // Verify ownership.
      final result = await db.execute(
        'SELECT owner_id FROM media WHERE id = @id',
        parameters: {'id': id},
      );

      if (result.isEmpty) {
        return Response.notFound('Media not found');
      }

      final ownerId = result.first.toColumnMap()['owner_id'] as String;
      if (ownerId != userId) {
        return Response.forbidden('Not your media');
      }

      // Soft delete.
      await db.execute(
        "UPDATE media SET status = 'deleted', updated_at = NOW() WHERE id = @id",
        parameters: {'id': id},
      );

      return Response.ok(
        jsonEncode({'deleted': true}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(body: 'Delete failed: $e');
    }
  }

  // ────────────────────────── Helpers ──────────────────────────

  String? _extractBoundary(String contentType) {
    final parts = contentType.split(';');
    for (final part in parts) {
      final trimmed = part.trim();
      if (trimmed.startsWith('boundary=')) {
        return trimmed.substring(9).replaceAll('"', '');
      }
    }
    return null;
  }
}

/// Simple multipart parser for file uploads.
class MultipartParser {
  MultipartParser(this.boundary);

  final String boundary;

  MultipartData? parse(List<int> bytes) {
    final boundaryBytes = utf8.encode('--$boundary');
    final endBoundaryBytes = utf8.encode('--$boundary--');

    // Find first boundary.
    final firstBoundary = _findBytes(bytes, boundaryBytes);
    if (firstBoundary == null) return null;

    // Find end boundary.
    final endBoundary = _findBytes(bytes, endBoundaryBytes);
    if (endBoundary == null) return null;

    // Extract headers and body between boundaries.
    final headerStart = firstBoundary + boundaryBytes.length;
    final headerEnd = _findBytes(bytes, utf8.encode('\r\n\r\n'));

    if (headerEnd == null || headerEnd <= headerStart) return null;

    final headerBytes = bytes.sublist(headerStart, headerEnd);
    final bodyStart = headerEnd + 4;
    final bodyEnd = endBoundary - 2; // Before \r\n

    if (bodyStart >= bodyEnd) return null;

    final headers = utf8.decode(headerBytes);
    final body = bytes.sublist(bodyStart, bodyEnd);

    // Parse headers.
    String? fileName;
    String? mimeType;
    final fields = <String, String>{};

    for (final line in headers.split('\r\n')) {
      if (line.toLowerCase().startsWith('content-disposition:')) {
        final disposition = line;
        final nameMatch = RegExp(r'name="([^"]+)"').firstMatch(disposition);
        if (nameMatch != null) {
          fields[nameMatch.group(1)!] = '';
        }
        final filenameMatch = RegExp(r'filename="([^"]+)"').firstMatch(disposition);
        if (filenameMatch != null) {
          fileName = filenameMatch.group(1);
        }
      }
      if (line.toLowerCase().startsWith('content-type:')) {
        mimeType = line.substring(13).trim();
      }
    }

    // Extract field values.
    // Simple implementation: just get the field name from the header.
    final nameMatch = RegExp(r'name="([^"]+)"').firstMatch(headers);
    if (nameMatch != null) {
      final fieldName = nameMatch.group(1)!;
      fields[fieldName] = utf8.decode(body);
    }

    return MultipartData(
      file: body,
      fileName: fileName,
      mimeType: mimeType,
      fields: fields,
    );
  }

  int? _findBytes(List<int> haystack, List<int> needle) {
    if (needle.isEmpty) return 0;
    if (needle.length > haystack.length) return null;

    for (var i = 0; i <= haystack.length - needle.length; i++) {
      var found = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          found = false;
          break;
        }
      }
      if (found) return i;
    }
    return null;
  }
}

/// Parsed multipart data.
class MultipartData {
  const MultipartData({
    this.file,
    this.fileName,
    this.mimeType,
    this.fields = const {},
  });

  final List<int>? file;
  final String? fileName;
  final String? mimeType;
  final Map<String, String> fields;
}

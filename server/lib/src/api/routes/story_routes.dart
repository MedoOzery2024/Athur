import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../../data/database.dart';
import '../middleware/auth_middleware.dart';

/// Stories routes: create, list, view, react, delete.
///
/// Routes:
///   POST   /api/v1/stories          — Create story
///   GET    /api/v1/stories/feed      — Get stories feed (friends' stories)
///   GET    /api/v1/stories/mine      — Get my stories
///   POST   /api/v1/stories/:id/view  — Mark story as viewed
///   POST   /api/v1/stories/:id/react — React to story
///   DELETE /api/v1/stories/:id       — Delete story
class StoryRoutes {
  StoryRoutes({required this.db});

  final Database db;
  static const _uuid = Uuid();

  Router get router {
    final router = Router();
    router.post('/stories', _createStory);
    router.get('/stories/feed', _getFeed);
    router.get('/stories/mine', _getMyStories);
    router.post('/stories/<id>/view', _viewStory);
    router.post('/stories/<id>/react', _reactToStory);
    router.delete('/stories/<id>', _deleteStory);
    return router;
  }

  /// Creates a new story (text, image, or video).
  Future<Response> _createStory(Request request) async {
    try {
      final userId = request.userId;
      if (userId == null) {
        return Response.forbidden(jsonEncode({'error': 'Unauthorized'}),
            headers: {'Content-Type': 'application/json'});
      }

      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final storyType = data['story_type'] as String? ?? 'text';
      if (!['text', 'image', 'video'].contains(storyType)) {
        return Response.badRequest(
            body: jsonEncode({'error': 'Invalid story_type'}),
            headers: {'Content-Type': 'application/json'});
      }

      final storyId = _uuid.v4();
      final bodyText = data['body'] as String?;
      final payload = data['payload'] as Map<String, dynamic>?;
      final visibility = data['visibility'] as String? ?? 'contacts';

      await db.execute(
        '''
        INSERT INTO stories (id, author_id, story_type, body, payload, visibility, expires_at, created_at, updated_at)
        VALUES (@id, @authorId, @storyType, @body, @payload::jsonb, @visibility, NOW() + INTERVAL '24 hours', NOW(), NOW())
        ''',
        parameters: {
          'id': storyId,
          'authorId': userId,
          'storyType': storyType,
          'body': bodyText,
          'bodyText': bodyText,
          'payload': payload != null ? jsonEncode(payload) : null,
          'visibility': visibility,
        },
      );

      return Response.ok(
          jsonEncode({'id': storyId, 'story_type': storyType}),
          headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'});
    }
  }

  /// Gets stories feed (friends' active stories).
  Future<Response> _getFeed(Request request) async {
    try {
      final userId = request.userId;
      if (userId == null) {
        return Response.forbidden(jsonEncode({'error': 'Unauthorized'}),
            headers: {'Content-Type': 'application/json'});
      }

      // Get stories from friends (accepted contacts) that haven't expired.
      final result = await db.execute(
        '''
        SELECT s.*, u.display_name as author_name,
               (SELECT COUNT(*) FROM story_views sv WHERE sv.story_id = s.id) as view_count,
               EXISTS(SELECT 1 FROM story_views sv WHERE sv.story_id = s.id AND sv.viewer_id = @userId) as has_viewed
        FROM stories s
        JOIN users u ON s.author_id = u.id
        WHERE s.author_id IN (
            SELECT contact_user_id FROM contacts WHERE user_id = @userId AND status = 'accepted'
            UNION
            SELECT user_id FROM contacts WHERE contact_user_id = @userId AND status = 'accepted'
        )
        AND s.expires_at > NOW()
        ORDER BY s.created_at DESC
        ''',
        parameters: {'userId': userId},
      );

      final stories = result.map((row) => {
        'id': row.toColumnMap()['id'],
        'author_id': row.toColumnMap()['author_id'],
        'author_name': row.toColumnMap()['author_name'],
        'story_type': row.toColumnMap()['story_type'],
        'body': row.toColumnMap()['body'],
        'payload': row.toColumnMap()['payload'],
        'visibility': row.toColumnMap()['visibility'],
        'view_count': row.toColumnMap()['view_count'],
        'has_viewed': row.toColumnMap()['has_viewed'],
        'expires_at': row.toColumnMap()['expires_at']?.toString(),
        'created_at': row.toColumnMap()['created_at']?.toString(),
      }).toList();

      return Response.ok(jsonEncode({'stories': stories}),
          headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'});
    }
  }

  /// Gets my own stories.
  Future<Response> _getMyStories(Request request) async {
    try {
      final userId = request.userId;
      if (userId == null) {
        return Response.forbidden(jsonEncode({'error': 'Unauthorized'}),
            headers: {'Content-Type': 'application/json'});
      }

      final result = await db.execute(
        '''
        SELECT s.*,
               (SELECT COUNT(*) FROM story_views sv WHERE sv.story_id = s.id) as view_count
        FROM stories s
        WHERE s.author_id = @userId AND s.expires_at > NOW()
        ORDER BY s.created_at DESC
        ''',
        parameters: {'userId': userId},
      );

      final stories = result.map((row) => {
        'id': row.toColumnMap()['id'],
        'story_type': row.toColumnMap()['story_type'],
        'body': row.toColumnMap()['body'],
        'payload': row.toColumnMap()['payload'],
        'visibility': row.toColumnMap()['visibility'],
        'view_count': row.toColumnMap()['view_count'],
        'expires_at': row.toColumnMap()['expires_at']?.toString(),
        'created_at': row.toColumnMap()['created_at']?.toString(),
      }).toList();

      return Response.ok(jsonEncode({'stories': stories}),
          headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'});
    }
  }

  /// Marks a story as viewed.
  Future<Response> _viewStory(Request request, String id) async {
    try {
      final userId = request.userId;
      if (userId == null) {
        return Response.forbidden(jsonEncode({'error': 'Unauthorized'}),
            headers: {'Content-Type': 'application/json'});
      }

      // Check if already viewed.
      final existing = await db.execute(
        'SELECT id FROM story_views WHERE story_id = @storyId AND viewer_id = @userId',
        parameters: {'storyId': id, 'userId': userId},
      );

      if (existing.isEmpty) {
        await db.execute(
          '''
          INSERT INTO story_views (id, story_id, viewer_id, watched_ms, created_at)
          VALUES (@id, @storyId, @userId, 0, NOW())
          ''',
          parameters: {
            'id': _uuid.v4(),
            'storyId': id,
            'userId': userId,
          },
        );

        // Update view count.
        await db.execute(
          '''
          UPDATE stories SET view_count = (SELECT COUNT(*) FROM story_views WHERE story_id = @storyId), updated_at = NOW()
          WHERE id = @storyId
          ''',
          parameters: {'storyId': id},
        );
      }

      return Response.ok(jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'});
    }
  }

  /// Reacts to a story.
  Future<Response> _reactToStory(Request request, String id) async {
    try {
      final userId = request.userId;
      if (userId == null) {
        return Response.forbidden(jsonEncode({'error': 'Unauthorized'}),
            headers: {'Content-Type': 'application/json'});
      }

      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final reaction = data['reaction'] as String?;

      if (reaction == null || reaction.isEmpty) {
        return Response.badRequest(
            body: jsonEncode({'error': 'reaction is required'}),
            headers: {'Content-Type': 'application/json'});
      }

      // Upsert reaction.
      await db.execute(
        '''
        INSERT INTO story_reactions (id, story_id, user_id, reaction, created_at, updated_at)
        VALUES (@id, @storyId, @userId, @reaction, NOW(), NOW())
        ON CONFLICT (story_id, user_id) DO UPDATE SET reaction = @reaction, updated_at = NOW()
        ''',
        parameters: {
          'id': _uuid.v4(),
          'storyId': id,
          'userId': userId,
          'reaction': reaction,
        },
      );

      return Response.ok(jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'});
    }
  }

  /// Deletes a story.
  Future<Response> _deleteStory(Request request, String id) async {
    try {
      final userId = request.userId;
      if (userId == null) {
        return Response.forbidden(jsonEncode({'error': 'Unauthorized'}),
            headers: {'Content-Type': 'application/json'});
      }

      // Only delete own stories.
      await db.execute(
        'DELETE FROM stories WHERE id = @id AND author_id = @userId',
        parameters: {'id': id, 'userId': userId},
      );

      return Response.ok(jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'});
    }
  }
}

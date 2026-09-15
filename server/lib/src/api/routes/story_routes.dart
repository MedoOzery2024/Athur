import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../../data/database.dart';
import '../../services/auth_service.dart';
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
  StoryRoutes({required this.db, required this.authService});

  final Database db;

  /// Used to verify the bearer token. Every stories route requires a valid
  /// session: without this middleware `request.userId` is always null and every
  /// call is rejected as unauthorized — which is why stories appeared broken.
  final AuthService authService;

  static const _uuid = Uuid();

  /// Router whose handlers assume they have already been authenticated.
  ///
  /// Handlers with path parameters (e.g. `_viewStory(Request, String)`) cannot
  /// be wrapped individually because `shelf_router` maps them to a two-arg
  /// callable that is not a `Handler`. Instead the caller applies
  /// [authMiddleware] to the whole router (see AthurServer), which injects the
  /// `userId` into the request context before the handler runs.
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

  /// The stories router wrapped so that every request is authenticated first.
  Handler get authenticatedRouter =>
      const Pipeline().addMiddleware(authMiddleware(authService)).addHandler(router.call);

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

      // Get stories from accepted contacts that have not expired.
      //
      // IMPORTANT: `contacts` rows exist only for ACCEPTED connections and the
      // table has no `status` column (that lives on friend_requests). Filtering
      // on `status = 'accepted'` was a bug that broke the whole stories feed.
      // A contact edge is directional, so we union both directions.
      final result = await db.execute(
        '''
        SELECT s.id, s.author_id, s.story_type, s.body, s.payload,
               s.visibility, s.view_count, s.expires_at, s.created_at,
               p.display_name AS author_name,
               EXISTS(
                 SELECT 1 FROM story_views sv
                 WHERE sv.story_id = s.id AND sv.viewer_id = @userId
               ) AS has_viewed
        FROM stories s
        JOIN users u ON s.author_id = u.id
        LEFT JOIN user_profiles p ON p.user_id = u.id
        WHERE s.author_id <> @userId
          AND s.deleted_at IS NULL
          AND s.expires_at > NOW()
          AND (
            s.visibility = 'public'
            OR s.author_id IN (
              SELECT contact_user_id FROM contacts WHERE user_id = @userId
              UNION
              SELECT user_id FROM contacts WHERE contact_user_id = @userId
            )
          )
        ORDER BY s.created_at DESC
        LIMIT 100
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

      // Check if already viewed. The story_views table has a COMPOSITE primary
      // key (story_id, viewer_id) and a `viewed_at` column — there is no `id`
      // or `created_at` column. Selecting a non-existent column was what made
      // story viewing fail.
      final existing = await db.execute(
        'SELECT 1 FROM story_views WHERE story_id = @storyId AND viewer_id = @userId',
        parameters: {'storyId': id, 'userId': userId},
      );

      if (existing.isEmpty) {
        // Insert the view. `watched_ms` is optional; we record the view time
        // via the column's own default (viewed_at).
        await db.execute(
          '''
          INSERT INTO story_views (story_id, viewer_id, watched_ms)
          VALUES (@storyId, @userId, 0)
          ON CONFLICT (story_id, viewer_id) DO NOTHING
          ''',
          parameters: {
            'storyId': id,
            'userId': userId,
          },
        );

        // Keep the denormalised counter in sync with the real rows.
        await db.execute(
          '''
          UPDATE stories
          SET view_count = (SELECT COUNT(*) FROM story_views WHERE story_id = @storyId),
              updated_at = NOW()
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

      // Upsert reaction. story_reactions has a composite key (story_id, user_id)
      // and only a `created_at` column — there is no `id` or `updated_at`, so
      // the previous statement failed. Re-use created_at as the last-changed
      // timestamp by refreshing it on conflict.
      await db.execute(
        '''
        INSERT INTO story_reactions (story_id, user_id, reaction)
        VALUES (@storyId, @userId, @reaction)
        ON CONFLICT (story_id, user_id)
        DO UPDATE SET reaction = EXCLUDED.reaction, created_at = NOW()
        ''',
        parameters: {
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

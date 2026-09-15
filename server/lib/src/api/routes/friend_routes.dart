import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../../data/database.dart';
import '../../services/auth_service.dart';
import '../middleware/auth_middleware.dart';

/// Friend request routes: send, accept, reject, cancel, list.
///
/// Routes:
///   POST   /api/v1/friends/request          — Send friend request
///   POST   /api/v1/friends/accept/:id       — Accept friend request
///   POST   /api/v1/friends/reject/:id       — Reject friend request
///   POST   /api/v1/friends/cancel/:id       — Cancel sent request
///   DELETE /api/v1/friends/:id              — Remove friend
///   GET    /api/v1/friends                  — List friends
///   GET    /api/v1/friends/requests         — List pending requests
class FriendRoutes {
  FriendRoutes({required this.db, required this.authService});

  final Database db;

  /// Verifies the bearer token. Every friend route calls `request.userId`,
  /// which only [authMiddleware] populates — without it the whole friend system
  /// returned 403 for every request.
  final AuthService authService;

  static const _uuid = Uuid();

  Router get router {
    final router = Router();
    router.post('/friends/request', _sendRequest);
    router.post('/friends/accept/<id>', _acceptRequest);
    router.post('/friends/reject/<id>', _rejectRequest);
    router.post('/friends/cancel/<id>', _cancelRequest);
    router.delete('/friends/<id>', _removeFriend);
    router.get('/friends', _listFriends);
    router.get('/friends/requests', _listRequests);
    return router;
  }

  /// Router with authentication applied to every friend endpoint.
  Handler get authenticatedRouter =>
      const Pipeline().addMiddleware(authMiddleware(authService)).addHandler(router.call);

  // ────────────────────────── Send Request ──────────────────────────

  Future<Response> _sendRequest(Request request) async {
    final userId = request.userId;
    if (userId == null) return Response.forbidden('Unauthorized');

    try {
      final body = await request.read().transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, Object?>;

      final receiverId = json['receiver_id'] as String?;
      final message = json['message'] as String? ?? '';

      if (receiverId == null) {
        return Response.badRequest(body: 'Missing receiver_id');
      }

      if (receiverId == userId) {
        return Response.badRequest(body: 'Cannot send friend request to yourself');
      }

      // Check if receiver exists.
      final userCheck = await db.execute(
        'SELECT id FROM users WHERE id = @id',
        parameters: {'id': receiverId},
      );
      if (userCheck.isEmpty) {
        return Response.notFound('User not found');
      }

      // Check if already friends.
      final friendCheck = await db.execute(
        '''
        SELECT id FROM contacts
        WHERE (user_id = @uid AND contact_id = @cid AND status = 'accepted')
           OR (user_id = @cid AND contact_id = @uid AND status = 'accepted')
        ''',
        parameters: {'uid': userId, 'cid': receiverId},
      );
      if (friendCheck.isNotEmpty) {
        return Response.badRequest(body: 'Already friends');
      }

      // Check if there's already a pending request from receiver.
      final existingRequest = await db.execute(
        '''
        SELECT id FROM friend_requests
        WHERE sender_id = @sender AND receiver_id = @receiver AND status = 'pending'
        ''',
        parameters: {'sender': receiverId, 'receiver': userId},
      );
      if (existingRequest.isNotEmpty) {
        // Auto-accept if they sent us a request.
        await _acceptRequestById(existingRequest.first.toColumnMap()['id'] as String);
        return Response.ok(
          jsonEncode({'accepted': true, 'message': 'Auto-accepted mutual request'}),
          headers: {'content-type': 'application/json'},
        );
      }

      // Check if we already sent a pending request.
      final pendingRequest = await db.execute(
        '''
        SELECT id FROM friend_requests
        WHERE sender_id = @sender AND receiver_id = @receiver AND status = 'pending'
        ''',
        parameters: {'sender': userId, 'receiver': receiverId},
      );

      if (pendingRequest.isNotEmpty) {
        return Response.badRequest(body: 'Friend request already sent');
      }

      // Create friend request.
      final requestId = _uuid.v4();
      await db.execute(
        '''
        INSERT INTO friend_requests (id, sender_id, receiver_id, message, status)
        VALUES (@id, @senderId, @receiverId, @message, 'pending')
        ''',
        parameters: {
          'id': requestId,
          'senderId': userId,
          'receiverId': receiverId,
          'message': message,
        },
      );

      return Response.ok(
        jsonEncode({
          'id': requestId,
          'status': 'pending',
          'message': 'Friend request sent',
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(body: 'Failed to send request: $e');
    }
  }

  // ────────────────────────── Accept Request ──────────────────────────

  Future<Response> _acceptRequest(Request request, String id) async {
    final userId = request.userId;
    if (userId == null) return Response.forbidden('Unauthorized');

    try {
      final accepted = await _acceptRequestById(id, userId);
      if (!accepted) {
        return Response.notFound('Request not found or already handled');
      }

      return Response.ok(
        jsonEncode({'accepted': true}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(body: 'Failed to accept: $e');
    }
  }

  Future<bool> _acceptRequestById(String requestId, [String? userId]) async {
    // Get the request.
    final result = await db.execute(
      'SELECT sender_id, receiver_id, status FROM friend_requests WHERE id = @id',
      parameters: {'id': requestId},
    );

    if (result.isEmpty) return false;

    final row = result.first.toColumnMap();
    final senderId = row['sender_id'] as String;
    final receiverId = row['receiver_id'] as String;
    final status = row['status'] as String;

    if (status != 'pending') return false;
    if (userId != null && receiverId != userId) return false;

    // Update request status.
    await db.execute(
      "UPDATE friend_requests SET status = 'accepted', responded_at = NOW() WHERE id = @id",
      parameters: {'id': requestId},
    );

    // Create bidirectional contact.
    final contactId1 = _uuid.v4();
    final contactId2 = _uuid.v4();

    await db.execute(
      '''
      INSERT INTO contacts (id, user_id, contact_id, status, added_at)
      VALUES (@id1, @uid, @cid, 'accepted', NOW())
      ''',
      parameters: {'id1': contactId1, 'uid': senderId, 'cid': receiverId},
    );

    await db.execute(
      '''
      INSERT INTO contacts (id, user_id, contact_id, status, added_at)
      VALUES (@id2, @cid, @uid, 'accepted', NOW())
      ''',
      parameters: {'id2': contactId2, 'uid': receiverId, 'cid': senderId},
    );

    return true;
  }

  // ────────────────────────── Reject Request ──────────────────────────

  Future<Response> _rejectRequest(Request request, String id) async {
    final userId = request.userId;
    if (userId == null) return Response.forbidden('Unauthorized');

    try {
      final result = await db.execute(
        "UPDATE friend_requests SET status = 'rejected', responded_at = NOW() "
        'WHERE id = @id AND receiver_id = @userId AND status = \'pending\'',
        parameters: {'id': id, 'userId': userId},
      );

      if (result.isEmpty) {
        return Response.notFound('Request not found');
      }

      return Response.ok(
        jsonEncode({'rejected': true}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(body: 'Failed to reject: $e');
    }
  }

  // ────────────────────────── Cancel Request ──────────────────────────

  Future<Response> _cancelRequest(Request request, String id) async {
    final userId = request.userId;
    if (userId == null) return Response.forbidden('Unauthorized');

    try {
      final result = await db.execute(
        "UPDATE friend_requests SET status = 'cancelled' "
        'WHERE id = @id AND sender_id = @userId AND status = \'pending\'',
        parameters: {'id': id, 'userId': userId},
      );

      if (result.isEmpty) {
        return Response.notFound('Request not found');
      }

      return Response.ok(
        jsonEncode({'cancelled': true}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(body: 'Failed to cancel: $e');
    }
  }

  // ────────────────────────── Remove Friend ──────────────────────────

  Future<Response> _removeFriend(Request request, String id) async {
    final userId = request.userId;
    if (userId == null) return Response.forbidden('Unauthorized');

    try {
      // Delete bidirectional contact.
      await db.execute(
        'DELETE FROM contacts WHERE (user_id = @uid AND contact_id = @cid) OR (user_id = @cid AND contact_id = @uid)',
        parameters: {'uid': userId, 'cid': id},
      );

      return Response.ok(
        jsonEncode({'removed': true}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(body: 'Failed to remove: $e');
    }
  }

  // ────────────────────────── List Friends ──────────────────────────

  Future<Response> _listFriends(Request request) async {
    final userId = request.userId;
    if (userId == null) return Response.forbidden('Unauthorized');

    try {
      final result = await db.execute(
        '''
        SELECT c.contact_user_id, u.username, p.display_name, pr.last_online_at
        FROM contacts c
        JOIN users u ON u.id = c.contact_user_id
        LEFT JOIN user_profiles p ON p.user_id = c.contact_user_id
        LEFT JOIN presence pr ON pr.user_id = c.contact_user_id
        WHERE c.user_id = @userId
        ORDER BY p.display_name ASC
        ''',
        parameters: {'userId': userId},
      );

      final friends = result.map((r) {
        final row = r.toColumnMap();
        return {
          'id': row['contact_user_id']?.toString(),
          'username': row['username'],
          'display_name': row['display_name'] ?? row['username'],
          'last_seen': row['last_online_at']?.toString(),
        };
      }).toList();

      return Response.ok(
        jsonEncode({'friends': friends}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(body: 'Failed to list friends: $e');
    }
  }

  // ────────────────────────── List Requests ──────────────────────────

  Future<Response> _listRequests(Request request) async {
    final userId = request.userId;
    if (userId == null) return Response.forbidden('Unauthorized');

    try {
      // Incoming requests.
      final incoming = await db.execute(
        '''
        SELECT fr.id, fr.sender_id, u.username, p.display_name, fr.message, fr.created_at
        FROM friend_requests fr
        JOIN users u ON u.id = fr.sender_id
        LEFT JOIN user_profiles p ON p.user_id = fr.sender_id
        WHERE fr.receiver_id = @userId AND fr.status = 'pending'
        ORDER BY fr.created_at DESC
        ''',
        parameters: {'userId': userId},
      );

      // Outgoing requests.
      final outgoing = await db.execute(
        '''
        SELECT fr.id, fr.receiver_id, u.username, p.display_name, fr.message, fr.created_at
        FROM friend_requests fr
        JOIN users u ON u.id = fr.receiver_id
        LEFT JOIN user_profiles p ON p.user_id = fr.receiver_id
        WHERE fr.sender_id = @userId AND fr.status = 'pending'
        ORDER BY fr.created_at DESC
        ''',
        parameters: {'userId': userId},
      );

      return Response.ok(
        jsonEncode({
          'incoming': incoming.map((r) {
            final row = r.toColumnMap();
            return {
              'id': row['id'],
              'user_id': row['sender_id'],
              'username': row['username'],
              'display_name': row['display_name'],
              'message': row['message'],
              'created_at': row['created_at']?.toString(),
            };
          }).toList(),
          'outgoing': outgoing.map((r) {
            final row = r.toColumnMap();
            return {
              'id': row['id'],
              'user_id': row['receiver_id'],
              'username': row['username'],
              'display_name': row['display_name'],
              'message': row['message'],
              'created_at': row['created_at']?.toString(),
            };
          }).toList(),
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(body: 'Failed to list requests: $e');
    }
  }
}

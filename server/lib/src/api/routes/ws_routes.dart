import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../data/database.dart';
import '../../services/auth_service.dart';

/// WebSocket endpoint for real-time messaging, typing indicators,
/// presence updates, and call signaling.
///
/// Connects at `GET /api/v1/ws` with query parameters `user_id` and `token`.
///
/// Messages are JSON objects with a `type` field:
/// ```json
/// { "type": "message", "chat_id": "...", "content": "..." }
/// { "type": "typing", "chat_id": "..." }
/// { "type": "read_receipt", "chat_id": "...", "message_id": "..." }
/// { "type": "call_signal", "call_id": "...", "signal_type": "...", "data": {...} }
/// { "type": "ping" }
/// ```
class WsRoutes {
  WsRoutes({
    required this.db,
    required this.authService,
  });

  final Database db;
  final AuthService authService;

  /// Connected clients: userId -> WebSocket handler.
  final Map<String, _WsClient> _clients = {};

  Router get router {
    final router = Router();
    router.get('/ws', _handleWebSocket);
    return router;
  }

  /// Upgrades HTTP to WebSocket and manages the client lifecycle.
  Future<Response> _handleWebSocket(Request request) async {
    final userId = request.url.queryParameters['user_id'];
    final token = request.url.queryParameters['token'];

    if (userId == null || token == null) {
      return Response.badRequest(body: 'Missing user_id or token');
    }

    // Verify JWT.
    String verifiedUserId;
    try {
      verifiedUserId = await authService.verifyAccessToken(token);
    } catch (_) {
      return Response.unauthorized('Invalid or expired token');
    }

    // Ensure the authenticated user matches.
    if (verifiedUserId != userId) {
      return Response.forbidden('Token does not match user_id');
    }

    return webSocketHandler((WebSocketChannel webSocket, String? subprotocol) async {
      final client = _WsClient(
        userId: userId,
        webSocket: webSocket,
        routes: this,
      );

      _clients[userId] = client;
      // ignore: avoid_print
      print('[Athur][ws] Client connected: $userId');

      // Send connection acknowledgment.
      client.send({'type': 'connected', 'user_id': userId});

      // Broadcast presence.
      _broadcastPresence(userId, 'online');

      // Handle incoming messages.
      await for (final message in webSocket.stream) {
        try {
          final json = jsonDecode(message as String) as Map<String, Object?>;
          await client.handleMessage(json);
        } catch (e) {
          // ignore: avoid_print
          print('[Athur][ws] Error handling message from $userId: $e');
        }
      }

      // Client disconnected.
      _clients.remove(userId);
      _broadcastPresence(userId, 'offline');
      // ignore: avoid_print
      print('[Athur][ws] Client disconnected: $userId');
    })(request);
  }

  /// Sends a message to a specific user.
  void sendToUser(String userId, Map<String, Object?> message) {
    final client = _clients[userId];
    if (client != null) {
      client.send(message);
    }
  }

  /// Broadcasts presence to all connected clients and saves to database.
  void _broadcastPresence(String userId, String status) async {
    // Save to database.
    try {
      await db.execute(
        '''
        INSERT INTO presence (user_id, status, last_heartbeat_at, last_online_at, active_connection_count)
        VALUES (@userId, @status, NOW(), NOW(), 1)
        ON CONFLICT (user_id) DO UPDATE
        SET status = @status,
            last_heartbeat_at = NOW(),
            last_online_at = CASE WHEN @status = 'online' THEN NOW() ELSE presence.last_online_at END,
            active_connection_count = CASE WHEN @status = 'online' THEN presence.active_connection_count + 1 ELSE GREATEST(presence.active_connection_count - 1, 0) END,
            updated_at = NOW()
        ''',
        parameters: {'userId': userId, 'status': status},
      );
    } catch (e) {
      // ignore: avoid_print
      print('[Athur][ws] Failed to update presence in DB: $e');
    }

    // Broadcast to connected clients.
    final message = {
      'type': 'presence',
      'user_id': userId,
      'status': status,
    };
    for (final client in _clients.values) {
      client.send(message);
    }
  }

  /// Broadcasts typing indicator to chat participants.
  void broadcastTyping(String chatId, String userId, List<String> participantIds) {
    final message = {
      'type': 'typing',
      'chat_id': chatId,
      'user_id': userId,
    };
    for (final participantId in participantIds) {
      if (participantId != userId) {
        sendToUser(participantId, message);
      }
    }
  }

  /// Broadcasts read receipt to chat participants.
  void broadcastReadReceipt(
    String chatId,
    String userId,
    String messageId,
    List<String> participantIds,
  ) {
    final message = {
      'type': 'read_receipt',
      'chat_id': chatId,
      'user_id': userId,
      'message_id': messageId,
    };
    for (final participantId in participantIds) {
      if (participantId != userId) {
        sendToUser(participantId, message);
      }
    }
  }

  /// Sends call signal to target user.
  void sendCallSignal(String targetUserId, Map<String, Object?> signal) {
    sendToUser(targetUserId, {
      'type': 'call_signal',
      ...signal,
    });
  }
}

/// Represents a single WebSocket client connection.
class _WsClient {
  _WsClient({
    required this.userId,
    required this.webSocket,
    required this.routes,
  });

  final String userId;
  final WebSocketChannel webSocket;
  final WsRoutes routes;

  void send(Map<String, Object?> message) {
    try {
      webSocket.sink.add(jsonEncode(message));
    } catch (e) {
      // ignore: avoid_print
      print('[Athur][ws] Failed to send to $userId: $e');
    }
  }

  Future<void> handleMessage(Map<String, Object?> json) async {
    final type = json['type'] as String?;

    switch (type) {
      case 'message':
        await _handleChatMessage(json);
        break;
      case 'typing':
        await _handleTyping(json);
        break;
      case 'read_receipt':
        await _handleReadReceipt(json);
        break;
      case 'call_signal':
        await _handleCallSignal(json);
        break;
      case 'ping':
        // Update heartbeat in database.
        try {
          await routes.db.execute(
            '''
            UPDATE presence SET last_heartbeat_at = NOW(), updated_at = NOW()
            WHERE user_id = @userId
            ''',
            parameters: {'userId': userId},
          );
        } catch (e) {
          // ignore: avoid_print
          print('[Athur][ws] Failed to update heartbeat: $e');
        }
        send({'type': 'pong'});
        break;
      default:
        send({'type': 'error', 'message': 'Unknown message type: $type'});
    }
  }

  Future<void> _handleChatMessage(Map<String, Object?> json) async {
    final chatId = json['chat_id'] as String?;
    final body = json['content'] as String?;
    final messageType = json['message_type'] as String? ?? 'text';
    final clientMessageId = json['client_message_id'] as String?;

    if (chatId == null || body == null) {
      send({'type': 'error', 'message': 'Missing chat_id or content'});
      return;
    }

    try {
      // Persist message to database.
      final result = await routes.db.execute(
        '''
        INSERT INTO messages (chat_id, sender_id, body, message_type, client_message_id)
        VALUES (@chatId, @senderId, @body, @messageType, @clientMessageId)
        RETURNING id, created_at
        ''',
        parameters: {
          'chatId': chatId,
          'senderId': userId,
          'body': body,
          'messageType': messageType,
          'clientMessageId': clientMessageId,
        },
      );

      if (result.isNotEmpty) {
        final row = result.first.toColumnMap();
        final messageId = row['id'] as String;
        final createdAt = row['created_at'] as DateTime;

        // Confirm to sender.
        send({
          'type': 'message_sent',
          'client_message_id': clientMessageId,
          'message_id': messageId,
          'created_at': createdAt.toIso8601String(),
        });

        // Get chat members and broadcast.
        final members = await routes.db.execute(
          '''
          SELECT user_id FROM chat_members WHERE chat_id = @chatId
          ''',
          parameters: {'chatId': chatId},
        );

        final memberIds = members
            .map((r) => r.toColumnMap()['user_id'] as String)
            .toList();

        final broadcastMessage = {
          'type': 'message',
          'message_id': messageId,
          'chat_id': chatId,
          'sender_id': userId,
          'content': body,
          'message_type': messageType,
          'created_at': createdAt.toIso8601String(),
        };

        for (final memberId in memberIds) {
          if (memberId != userId) {
            routes.sendToUser(memberId, broadcastMessage);
          }
        }
      }
    } catch (e) {
      send({'type': 'error', 'message': 'Failed to send message: $e'});
    }
  }

  Future<void> _handleTyping(Map<String, Object?> json) async {
    final chatId = json['chat_id'] as String?;
    if (chatId == null) return;

    try {
      final members = await routes.db.execute(
        '''
        SELECT user_id FROM chat_members WHERE chat_id = @chatId
        ''',
        parameters: {'chatId': chatId},
      );

      final memberIds = members
          .map((r) => r.toColumnMap()['user_id'] as String)
          .toList();

      routes.broadcastTyping(chatId, userId, memberIds);
    } catch (e) {
      // ignore: avoid_print
      print('[Athur][ws] Typing broadcast error: $e');
    }
  }

  Future<void> _handleReadReceipt(Map<String, Object?> json) async {
    final chatId = json['chat_id'] as String?;
    final messageId = json['message_id'] as String?;
    if (chatId == null || messageId == null) return;

    try {
      // Mark message as read in delivery status table.
      await routes.db.execute(
        '''
        INSERT INTO message_delivery_status (message_id, recipient_id, status, read_at)
        VALUES (@messageId, @userId, 'read', NOW())
        ON CONFLICT (message_id, recipient_id) DO UPDATE
        SET status = 'read', read_at = NOW(), updated_at = NOW()
        ''',
        parameters: {'messageId': messageId, 'userId': userId},
      );

      final members = await routes.db.execute(
        '''
        SELECT user_id FROM chat_members WHERE chat_id = @chatId
        ''',
        parameters: {'chatId': chatId},
      );

      final memberIds = members
          .map((r) => r.toColumnMap()['user_id'] as String)
          .toList();

      routes.broadcastReadReceipt(chatId, userId, messageId, memberIds);
    } catch (e) {
      // ignore: avoid_print
      print('[Athur][ws] Read receipt error: $e');
    }
  }

  Future<void> _handleCallSignal(Map<String, Object?> json) async {
    final callId = json['call_id'] as String?;
    final signalType = json['signal_type'] as String?;
    final data = json['data'] as Map<String, Object?>? ?? {};

    if (callId == null || signalType == null) {
      send({'type': 'error', 'message': 'Missing call_id or signal_type'});
      return;
    }

    // Store call in database if it's an offer.
    if (signalType == 'offer') {
      try {
        final targetUserId = data['target_user_id'] as String?;
        if (targetUserId != null) {
          await routes.db.execute(
            '''
            INSERT INTO calls (id, caller_id, callee_id, status, started_at)
            VALUES (@callId, @callerId, @calleeId, 'ringing', NOW())
            ''',
            parameters: {
              'callId': callId,
              'callerId': userId,
              'calleeId': targetUserId,
            },
          );
        }
      } catch (e) {
        // ignore: avoid_print
        print('[Athur][ws] Failed to store call: $e');
      }
    }

    // Update call status on answer/hangup.
    if (signalType == 'answer') {
      try {
        await routes.db.execute(
          "UPDATE calls SET status = 'active', answered_at = NOW() WHERE id = @callId",
          parameters: {'callId': callId},
        );
      } catch (e) {
        // ignore: avoid_print
        print('[Athur][ws] Failed to update call: $e');
      }
    }

    if (signalType == 'hangup') {
      try {
        await routes.db.execute(
          "UPDATE calls SET status = 'ended', ended_at = NOW() WHERE id = @callId",
          parameters: {'callId': callId},
        );
      } catch (e) {
        // ignore: avoid_print
        print('[Athur][ws] Failed to end call: $e');
      }
    }

    // Forward signal to the other party.
    final targetUserId = data['target_user_id'] as String?;
    if (targetUserId != null) {
      routes.sendCallSignal(targetUserId, {
        'call_id': callId,
        'signal_type': signalType,
        'sender_id': userId,
        'data': data,
      });
    }
  }
}

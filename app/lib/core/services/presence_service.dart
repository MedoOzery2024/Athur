import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'websocket_service.dart';

/// Tracks real-time online/offline status and last-seen for users.
class PresenceService {
  PresenceService._();

  static final PresenceService instance = PresenceService._();

  final _presenceController = StreamController<PresenceUpdate>.broadcast();

  /// Stream of presence updates (online/offline/last_seen changes).
  Stream<PresenceUpdate> get presenceUpdates => _presenceController.stream;

  /// Local cache: userId -> isOnline.
  final Map<String, bool> _onlineStatus = {};

  /// Local cache: userId -> lastSeen.
  final Map<String, DateTime> _lastSeen = {};

  StreamSubscription<WsMessage>? _wsSubscription;

  // ────────────────────────── Lifecycle ──────────────────────────

  /// Starts listening to WebSocket presence events.
  void startListening() {
    _wsSubscription?.cancel();
    _wsSubscription = WebSocketService.instance.messages.listen((msg) {
      if (msg.type == 'presence') {
        _handlePresenceEvent(msg);
      }
    });
  }

  /// Stops listening.
  void stopListening() {
    _wsSubscription?.cancel();
    _wsSubscription = null;
  }

  // ────────────────────────── Getters ──────────────────────────

  /// Returns whether the given user is currently online.
  bool isOnline(String userId) => _onlineStatus[userId] ?? false;

  /// Returns the last-seen time for the given user.
  DateTime? getLastSeen(String userId) => _lastSeen[userId];

  // ────────────────────────── Server fetch ──────────────────────────

  /// Fetches online status and last-seen for a list of user IDs from the server.
  Future<void> fetchPresence(List<String> userIds) async {
    if (userIds.isEmpty) return;

    try {
      final api = ApiClient.instance;
      final response = await api.get('/api/v1/friends/presence');

      if (response['presence'] case final List<dynamic> list?) {
        for (final entry in list) {
          final Map<String, dynamic> data = Map<String, dynamic>.from(entry);
          final id = data['user_id'] as String?;
          if (id == null) continue;

          final status = data['status'] as String?;
          _onlineStatus[id] = status == 'online';

          final lastOnline = data['last_online_at'] as String?;
          if (lastOnline != null) {
            _lastSeen[id] = DateTime.tryParse(lastOnline) ?? _lastSeen[id] ?? DateTime.now();
          }
        }
        _presenceController.add(PresenceUpdate.bulk(userIds));
      }
    } catch (e) {
      debugPrint('[Athur][presence] Failed to fetch presence: $e');
    }
  }

  // ────────────────────────── Private ──────────────────────────

  void _handlePresenceEvent(WsMessage msg) {
    final userId = msg.payload['user_id'] as String?;
    final status = msg.payload['status'] as String?;
    if (userId == null || status == null) return;

    final isOnline = status == 'online';
    _onlineStatus[userId] = isOnline;

    if (!isOnline) {
      // When user goes offline, update last_seen to now.
      _lastSeen[userId] = DateTime.now();
    }

    _presenceController.add(PresenceUpdate.single(
      userId: userId,
      isOnline: isOnline,
      lastSeen: _lastSeen[userId],
    ));
  }
}

/// A presence update event.
class PresenceUpdate {
  const PresenceUpdate._({
    required this.userIds,
    required this.isBulk,
    this.userId,
    this.isOnline = false,
    this.lastSeen,
  });

  factory PresenceUpdate.single({
    required String userId,
    required bool isOnline,
    DateTime? lastSeen,
  }) {
    return PresenceUpdate._(
      userIds: [userId],
      isBulk: false,
      userId: userId,
      isOnline: isOnline,
      lastSeen: lastSeen,
    );
  }

  factory PresenceUpdate.bulk(List<String> userIds) {
    return PresenceUpdate._(
      userIds: userIds,
      isBulk: true,
    );
  }

  final List<String> userIds;
  final bool isBulk;
  final String? userId;
  final bool isOnline;
  final DateTime? lastSeen;
}

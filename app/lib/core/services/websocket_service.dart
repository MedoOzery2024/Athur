import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/api_config.dart';

/// Real-time WebSocket connection for messaging, typing indicators,
/// presence updates, and call signaling.
///
/// Usage:
/// ```dart
/// WebSocketService.instance.connect(userId: '...', token: '...');
/// WebSocketService.instance.messages.listen((msg) { ... });
/// WebSocketService.instance.sendMessage(chatId: '...', content: '...');
/// ```
class WebSocketService {
  WebSocketService._();

  static final WebSocketService instance = WebSocketService._();

  WebSocketChannel? _channel;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 10;
  String? _userId;
  String? _token;

  final _messageController = StreamController<WsMessage>.broadcast();
  final _connectionController = StreamController<WsConnectionState>.broadcast();

  /// Incoming messages (chat messages, typing, presence, call signals).
  Stream<WsMessage> get messages => _messageController.stream;

  /// Connection state changes.
  Stream<WsConnectionState> get connectionState => _connectionController.stream;

  bool get isConnected => _channel != null;

  // ────────────────────────── Lifecycle ──────────────────────────

  /// Connects to the WebSocket server.
  Future<void> connect({required String userId, required String token}) async {
    _userId = userId;
    _token = token;

    await _connect();
  }

  /// Disconnects from the server.
  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _reconnectAttempts = 0;

    await _channel?.sink.close();
    _channel = null;
    _connectionController.add(WsConnectionState.disconnected);
  }

  // ────────────────────────── Send ──────────────────────────

  /// Sends a chat message.
  Future<void> sendMessage({
    required String chatId,
    required String content,
    String type = 'text',
    String? clientMessageId,
  }) async {
    _send({
      'type': 'message',
      'chat_id': chatId,
      'content': content,
      'message_type': type,
      // ignore: use_null_aware_elements
      if (clientMessageId case final id?) 'client_message_id': id,
    });
  }

  /// Sends a typing indicator.
  Future<void> sendTyping({required String chatId}) async {
    _send({'type': 'typing', 'chat_id': chatId});
  }

  /// Sends a read receipt.
  Future<void> sendReadReceipt({
    required String chatId,
    required String messageId,
  }) async {
    _send({'type': 'read_receipt', 'chat_id': chatId, 'message_id': messageId});
  }

  /// Sends a call signaling message (offer, answer, ICE candidate).
  Future<void> sendCallSignal({
    required String callId,
    required String signalType,
    required Map<String, Object?> data,
  }) async {
    _send({
      'type': 'call_signal',
      'call_id': callId,
      'signal_type': signalType,
      'data': data,
    });
  }

  // ────────────────────────── Private ──────────────────────────

  Future<void> _connect() async {
    if (_userId == null || _token == null) return;

    try {
      _connectionController.add(WsConnectionState.connecting);

      // Host is chosen per platform by [ApiConfig] so the same code works
      // against a local emulator, a browser, or a remote server.
      final base = ApiConfig.webSocketUrl;
      final separator = base.contains('?') ? '&' : '?';
      final uri = Uri.parse(
        '$base${separator}user_id=$_userId&token=$_token',
      );

      _channel = WebSocketChannel.connect(uri);

      // Listen for messages.
      _channel!.stream.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: _onError,
      );

      _reconnectAttempts = 0;
      _connectionController.add(WsConnectionState.connected);
      _startHeartbeat();

      debugPrint('[Athur][ws] Connected');
    } catch (e) {
      debugPrint('[Athur][ws] Connection failed: $e');
      _connectionController.add(WsConnectionState.disconnected);
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic data) {
    try {
      final json = jsonDecode(data as String) as Map<String, Object?>;
      final message = WsMessage.fromJson(json);
      _messageController.add(message);
    } catch (e) {
      debugPrint('[Athur][ws] Failed to parse message: $e');
    }
  }

  void _onDisconnected() {
    debugPrint('[Athur][ws] Disconnected');
    _heartbeatTimer?.cancel();
    _connectionController.add(WsConnectionState.disconnected);
    _scheduleReconnect();
  }

  void _onError(Object error) {
    debugPrint('[Athur][ws] Error: $error');
  }

  void _send(Map<String, Object?> data) {
    if (_channel == null) {
      debugPrint('[Athur][ws] Cannot send — not connected');
      return;
    }
    _channel!.sink.add(jsonEncode(data));
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _send({'type': 'ping'});
    });
  }

  void _scheduleReconnect() {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint('[Athur][ws] Max reconnect attempts reached');
      return;
    }

    final delay = Duration(seconds: (1 << _reconnectAttempts).clamp(1, 30));
    _reconnectAttempts++;

    debugPrint('[Athur][ws] Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts)');
    _reconnectTimer = Timer(delay, () => _connect());
  }
}

/// WebSocket connection state.
enum WsConnectionState { disconnected, connecting, connected }

/// Parsed WebSocket message.
class WsMessage {
  const WsMessage({
    required this.type,
    required this.payload,
  });

  factory WsMessage.fromJson(Map<String, Object?> json) {
    return WsMessage(
      type: json['type'] as String? ?? 'unknown',
      payload: json,
    );
  }

  final String type;
  final Map<String, Object?> payload;

  String? get chatId => payload['chat_id'] as String?;
  String? get senderId => payload['sender_id'] as String?;
  String? get content => payload['content'] as String?;
  String? get messageId => payload['message_id'] as String?;
}

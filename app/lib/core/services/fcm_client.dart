import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Handles push-notification registration and message handling on the client.
///
/// Lifecycle:
///   1. [init] is called once at startup (after Firebase.initializeApp).
///   2. It requests permission (iOS / Android 13+), obtains the FCM token,
///      and registers foreground / background / terminated handlers.
///   3. The token is exposed via [token] for the caller to send to the backend.
class FcmClient {
  FcmClient._();

  static final FcmClient instance = FcmClient._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  /// The current FCM device token. Null until [init] completes.
  String? _token;
  String? get token => _token;

  /// Stream of token refreshes.
  late final StreamSubscription<String> _tokenSub;

  /// Stream controller so the UI can react to incoming messages.
  final _messageController = StreamController<RemoteMessage>.broadcast();
  Stream<RemoteMessage> get onMessage => _messageController.stream;

  // ───────────────────────────── Public API ─────────────────────────────

  /// Call once after [Firebase.initializeApp].
  Future<void> init() async {
    // 1. Request permission (no-op on Android < 13, always granted on web debug).
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    debugPrint('[Athur][fcm] Permission status: ${settings.authorizationStatus}');

    // 2. Get the initial token.
    _token = await _messaging.getToken();
    debugPrint('[Athur][fcm] Token: $_token');

    // 3. Listen for token rotations.
    _tokenSub = _messaging.onTokenRefresh.listen((newToken) {
      _token = newToken;
      debugPrint('[Athur][fcm] Token refreshed: $newToken');
      // TODO: send refreshed token to backend
    });

    // 4. Foreground messages.
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // 5. Background / terminated messages (opened from notification tap).
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpenedApp);

    // 6. Check if the app was opened from a notification (cold start).
    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      debugPrint('[Athur][fcm] App opened from terminated state via notification');
      _handleMessageOpenedApp(initialMessage);
    }
  }

  /// Clean up resources.
  void dispose() {
    _tokenSub.cancel();
    _messageController.close();
  }

  // ───────────────────────────── Handlers ───────────────────────────────

  void _handleForegroundMessage(RemoteMessage message) {
    debugPrint('[Athur][fcm] Foreground message: ${message.messageId}');
    debugPrint('[Athur][fcm]   title: ${message.notification?.title}');
    debugPrint('[Athur][fcm]   body: ${message.notification?.body}');
    debugPrint('[Athur][fcm]   data: ${message.data}');
    _messageController.add(message);

    // TODO: show in-app notification banner or update UI
  }

  void _handleMessageOpenedApp(RemoteMessage message) {
    debugPrint('[Athur][fcm] Notification tapped: ${message.messageId}');
    debugPrint('[Athur][fcm]   data: ${message.data}');

    // TODO: navigate based on message.data['kind']
    // e.g. 'call' → open call screen, 'message' → open chat, etc.
  }
}

/// Top-level function for background message handling.
/// Must be a top-level function (not a method) per Firebase requirements.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('[Athur][fcm] Background message: ${message.messageId}');
  debugPrint('[Athur][fcm]   data: ${message.data}');
  // No UI work here — just data processing if needed.
}

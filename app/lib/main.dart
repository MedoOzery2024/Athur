import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/config/firebase_options.dart';
import 'core/services/fcm_client.dart';

/// Athur entry point.
///
/// Initializes Firebase (and FCM on mobile), then hands off to [AthurApp]
/// which uses [AuthGate] to decide between auth screens and the main shell.
///
/// FCM is deliberately **not** initialised on web: web push requires a service
/// worker and a Web app registration in Firebase that mobile does not, and the
/// messaging plugin's web API differs. Skipping it on web keeps the web build
/// working without pretending push is available there.
Future<void> main() async {
  // Ensure Flutter's engine bindings are ready before any platform call.
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase (must happen before any Firebase service is used).
  // Fatal on misconfiguration — the app must not silently run half-initialised.
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  if (!kIsWeb) {
    // Register the background message handler (must be a top-level function).
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Initialize the FCM client (request permission, get token, wire handlers).
    await FcmClient.instance.init();
  }

  runApp(const AthurApp());
}

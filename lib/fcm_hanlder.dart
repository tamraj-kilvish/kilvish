import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'dart:developer';
import 'firestore.dart';

// Background message handler - must be top-level function
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  log('Background FCM message received: ${message.messageId}');

  try {
    if (message.data['type'] == 'new_expense') {
      await storeExpenseforFCM(message.data);
    }
  } catch (e) {
    log('Error handling background FCM: $e', error: e);
  }
}

// Handle new expense from FCM and write to local cache

// Setup FCM and request permissions
class FCMService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  Future<void> initialize() async {
    // Request permission
    NotificationSettings settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    log('FCM permission status: ${settings.authorizationStatus}');

    // Get FCM token
    String? token = await _messaging.getToken();
    if (token != null) {
      log('FCM Token: $token');
      await saveFCMToken(token);
    }

    // Handle token refresh
    _messaging.onTokenRefresh.listen(saveFCMToken);

    // Handle foreground messages
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      log('Foreground FCM message: ${message.messageId}');
      // App is open - listener will handle it, so we can ignore
      // Or show in-app notification if needed
    });
  }
}

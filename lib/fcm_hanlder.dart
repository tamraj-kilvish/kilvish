import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:kilvish/firebase_options.dart';
import 'dart:developer';
import 'firestore.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

// Background message handler - must be top-level function
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  log('Background FCM message received: ${message.messageId}');

  try {
    await handleFCMMessage(message.data);
  } catch (e, stackTrace) {
    log('Error handling background FCM: $e', error: e, stackTrace: stackTrace);
  }
}

// Setup FCM and request permissions
class FCMService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  // Static variable to store pending navigation
  static Map<String, String>? _pendingNavigation;

  static Map<String, String>? getPendingNavigation() {
    final nav = _pendingNavigation;
    _pendingNavigation = null; // Clear after reading
    return nav;
  }

  Future<void> initialize() async {
    if (kIsWeb) {
      log('FCM not supported on web, skipping initialization');
      return;
    }

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
      // Data already synced via background handler
    });

    // Handle notification tap when app is in background
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      log('Notification tapped (background): ${message.data}');
      _handleNotificationTap(message.data);
    });

    // Check if app was opened from a notification (terminated state)
    RemoteMessage? initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      log('App opened from notification (terminated): ${initialMessage.data}');
      _handleNotificationTap(initialMessage.data);
    }
  }

  void _handleNotificationTap(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    final tagId = data['tagId'] as String?;

    if (tagId == null) return;

    switch (type) {
      case 'expense_created':
      case 'expense_updated':
        final expenseId = data['expenseId'] as String?;
        if (expenseId != null) {
          log('Storing pending navigation: expense in tag');
          _pendingNavigation = {
            'type': 'expense',
            'tagId': tagId,
            'expenseId': expenseId,
          };
        }
        break;

      case 'expense_deleted':
        // Navigate to tag detail (expense no longer exists)
        log('Storing pending navigation: tag detail (expense deleted)');
        _pendingNavigation = {'type': 'tag', 'tagId': tagId};
        break;

      case 'tag_shared':
        // Navigate to tag detail (newly shared tag)
        log('Storing pending navigation: new tag shared');
        _pendingNavigation = {'type': 'tag', 'tagId': tagId};
        break;

      case 'tag_removed':
        // Navigate to home screen (no longer has access)
        log('Tag access removed: ${data['tagName']}');
        _pendingNavigation = {
          'type': 'home',
          'message': 'Your access to ${data['tagName']} has been removed',
        };
        break;

      default:
        log('Unknown notification type: $type');
    }
  }
}

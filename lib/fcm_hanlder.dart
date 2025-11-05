import 'dart:async';
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:kilvish/firebase_options.dart';
import 'dart:developer';
import 'firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Background message handler - must be top-level function
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  log('Background FCM message received: ${message.messageId}');

  try {
    await updateFirestoreLocalCache(message.data);
  } catch (e, stackTrace) {
    log('Error handling background FCM: $e', error: e, stackTrace: stackTrace);
  }
}

// Setup FCM and request permissions
class FCMService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  // Static variable to store pending navigation
  static Map<String, String>? _pendingNavigation;

  // ✅ ADD THIS: Stream controller for immediate navigation
  static final StreamController<Map<String, String>> _navigationController =
      StreamController<Map<String, String>>.broadcast();

  // ✅ ADD THIS: Stream getter
  static Stream<Map<String, String>> get navigationStream =>
      _navigationController.stream;

  static Map<String, String>? getPendingNavigation() {
    final nav = _pendingNavigation;
    _pendingNavigation = null; // Clear after reading
    return nav;
  }

  Future<void> initialize() async {
    // Initialize local notifications for foreground notifications
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings();
    await _localNotifications.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: (NotificationResponse details) {
        // Handle notification tap from foreground notification
        if (details.payload != null) {
          try {
            final data = jsonDecode(details.payload!) as Map<String, dynamic>;
            _handleNotificationTap(data, isFromForeground: true);
          } catch (e) {
            log('Error parsing notification payload: $e');
          }
        }
      },
    );

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

    // Handle foreground messages - SHOW IN-APP NOTIFICATION
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      log('Foreground FCM message: ${message.messageId}');
      _showForegroundNotification(message);
    });

    // Handle notification tap when app is in background
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      log('Notification tapped (background): ${message.data}');
      _handleNotificationTap(message.data, isFromForeground: false);
    });

    // Check if app was opened from a notification (terminated state)
    RemoteMessage? initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      log('App opened from notification (terminated): ${initialMessage.data}');
      _handleNotificationTap(initialMessage.data, isFromForeground: false);
    }
  }

  /// Show notification when app is in foreground
  Future<void> _showForegroundNotification(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;

    await _localNotifications.show(
      message.hashCode,
      notification.title,
      notification.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'kilvish_expenses',
          'Expense Notifications',
          channelDescription: 'Notifications for expense updates and tags',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: DarwinNotificationDetails(),
      ),
      payload: jsonEncode(message.data), // Pass data for tap handling
    );
  }

  /// Handle notification tap - simplified to always go to Tag Detail
  void _handleNotificationTap(
    Map<String, dynamic> data, {
    required bool isFromForeground,
  }) {
    final type = data['type'] as String?;
    final tagId = data['tagId'] as String?;

    if (tagId == null) return;

    Map<String, String>? navData;

    switch (type) {
      case 'expense_created':
      case 'expense_updated':
      case 'expense_deleted':
        // All expense notifications → Tag Detail
        log('Navigation: tag detail (expense notification)');
        navData = {'type': 'tag', 'tagId': tagId};
        break;

      case 'tag_shared':
        // Tag shared → Tag Detail
        log('Navigation: new tag shared');
        navData = {'type': 'tag', 'tagId': tagId};
        break;

      case 'tag_removed':
        // Tag access removed → Home with message
        log('Tag access removed: ${data['tagName']}');
        navData = {
          'type': 'home',
          'message': 'Your access to ${data['tagName']} has been removed',
        };
        break;

      default:
        log('Unknown notification type: $type');
    }

    if (navData != null) {
      if (isFromForeground) {
        // ✅ For foreground taps, emit to stream for immediate navigation
        _navigationController.add(navData);
      } else {
        // For background/terminated, store for later
        _pendingNavigation = navData;
      }
    }
  }

  // ✅ ADD THIS: Dispose method
  static void dispose() {
    _navigationController.close();
  }
}

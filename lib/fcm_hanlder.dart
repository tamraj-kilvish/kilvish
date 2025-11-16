import 'dart:async';
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:kilvish/firebase_options.dart';
import 'firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Background message handler - must be top-level function
// ✅ Triggers ONLY for background/terminated app states
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  print('Background FCM message received: ${message.messageId}');

  try {
    // Update Firestore cache BEFORE user can tap notification
    await updateFirestoreLocalCache(message.data);
    print('Background: Firestore cache updated');
  } catch (e, stackTrace) {
    print('Error handling background FCM: $e, $stackTrace');
  }
}

// Setup FCM and request permissions
class FCMService {
  static FCMService? _instance;
  static FCMService get instance {
    _instance ??= FCMService._internal();
    return _instance!;
  }

  FCMService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

  // // Stream controller for immediate navigation
  // static final StreamController<Map<String, String>> _navigationController = StreamController<Map<String, String>>.broadcast();

  // // Stream getter
  // static Stream<Map<String, String>> get navigationStream => _navigationController.stream;

  // Non-static stream controller
  StreamController<Map<String, String>>? _navigationController;

  Stream<Map<String, String>> get navigationStream {
    _navigationController ??= StreamController<Map<String, String>>.broadcast();
    return _navigationController!.stream;
  }

  // Static variable to store pending navigation
  static Map<String, String>? _pendingNavigation;

  static Map<String, String>? getPendingNavigation() {
    final nav = _pendingNavigation;
    _pendingNavigation = null; // Clear after reading
    return nav;
  }

  Future<void> initialize() async {
    // Initialize local notifications for foreground notifications
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
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
            print('Error parsing notification payload: $e');
          }
        }
      },
    );

    // Request permission
    NotificationSettings settings = await _messaging.requestPermission(alert: true, badge: true, sound: true);

    print('FCM permission status: ${settings.authorizationStatus}');

    // Get FCM token
    String? token = await _messaging.getToken();
    if (token != null) {
      print('FCM Token: $token');
      await saveFCMToken(token);
    }

    // Handle token refresh
    _messaging.onTokenRefresh.listen(saveFCMToken);

    // ✅ FIXED: Handle foreground messages - UPDATE DATA FIRST, THEN SHOW NOTIFICATION
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      print('Foreground FCM message: ${message.messageId}');

      // CRITICAL: Update Firestore cache BEFORE showing notification
      try {
        await updateFirestoreLocalCache(message.data);
        print('Foreground: Firestore cache updated');
      } catch (e, stackTrace) {
        print('Error updating cache in foreground: $e $stackTrace');
      }

      // NOW show the notification (data is ready)
      print('fcm_handler - showing foreground notification');
      await _showForegroundNotification(message);
    });

    // Handle notification tap when app is in background
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      print('Notification tapped (background): ${message.data}');
      _handleNotificationTap(message.data, isFromForeground: false);
    });

    // Check if app was opened from a notification (terminated state)
    RemoteMessage? initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      print('App opened from notification (terminated): ${initialMessage.data}');
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
  void _handleNotificationTap(Map<String, dynamic> data, {required bool isFromForeground}) {
    final type = data['type'] as String?;
    final tagId = data['tagId'] as String?;

    if (tagId == null) return;

    Map<String, String>? navData;

    switch (type) {
      case 'expense_created':
      case 'expense_updated':
      case 'expense_deleted':
        // All expense notifications → Tag Detail
        print('_handleNotificationTap - Navigation: tag detail (expense notification)');
        navData = {'type': 'tag', 'tagId': tagId};
        break;

      //TODO - for these tag cases, add a previous navigation to tag tab of homescreen
      // so that user returns back to tags tab when they press back.
      case 'tag_shared':
        // Tag shared → Tag Detail
        print('Navigation: new tag shared');
        navData = {'type': 'tag', 'tagId': tagId};
        break;

      case 'tag_removed':
        // Tag access removed → Home with message
        print('Tag access removed: ${data['tagName']}');
        navData = {'type': 'home', 'message': 'Your access to ${data['tagName']} has been removed'};
        break;

      default:
        print('Unknown notification type: $type');
    }

    if (navData != null) {
      if (isFromForeground) {
        // For foreground taps, emit to stream for immediate navigation
        _navigationController!.add(navData);
      } else {
        // For background/terminated, store for later
        _pendingNavigation = navData;
      }
    }
  }

  // Dispose method
  void dispose() {
    _navigationController?.close();
    _navigationController = null;
  }
}

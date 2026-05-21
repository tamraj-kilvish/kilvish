import 'dart:async';
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:kilvish/firebase_options.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cache_manager.dart' as CacheManager;
import 'firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Background message handler - must be top-level function
// ✅ Triggers ONLY for background/terminated app states
final asyncPrefs = SharedPreferencesAsync();

Future<void> _processFCMupdateCacheAndLocalStorage(RemoteMessage message, String type) async {
  await CacheManager.updateHomeScreenExpensesAndCache(
    type: type,
    wipExpenseId: message.data['wipExpenseId'] as String?,
    expenseId: message.data['expenseId'] as String?,
    tagId: message.data['tagId'] as String?,
    actorId: message.data['actorId'] as String?,
    onWIPNeedsAttention: (count) => _showWIPAttentionNotification(count),
  );
}

Future<void> _showWIPAttentionNotification(int count) async {
  final plugin = FlutterLocalNotificationsPlugin();
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosSettings = DarwinInitializationSettings();
  await plugin.initialize(const InitializationSettings(android: androidSettings, iOS: iosSettings));
  await plugin.show(
    200,
    'Receipt${count > 1 ? 's' : ''} need your attention',
    '$count receipt${count > 1 ? 's' : ''} could not be processed automatically',
    const NotificationDetails(
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
    payload: jsonEncode({'type': 'wip_needs_attention'}),
  );
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  final type = message.data['type'] as String?;
  if (type == null) return;

  try {
    await _processFCMupdateCacheAndLocalStorage(message, type);
    await asyncPrefs.setBool('needHomeScreenRefresh', true);
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

  // Non-static stream controller
  StreamController<Map<String, String>>? _navigationController;

  Stream<Map<String, String>> get navigationStream {
    _navigationController ??= StreamController<Map<String, String>>.broadcast();
    return _navigationController!.stream;
  }

  Future<void> initialize() async {
    print("FcmService getting initialized");

    // Initialize local notifications for foreground notifications
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    await _localNotifications.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: (NotificationResponse details) {
        print('onDidReceiveNotificationResponse called with payload: ${details.payload}');

        // Handle notification tap from foreground notification
        if (details.payload != null) {
          try {
            final data = jsonDecode(details.payload!) as Map<String, dynamic>;
            _handleNotificationTap(data);
          } catch (e) {
            print('Error parsing notification payload: $e');
          }
        }
      },
    );

    // Request permission
    NotificationSettings settings = await _messaging.requestPermission(alert: true, badge: true, sound: true);

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      print('[FCM] ⚠️ Permission denied — token will not be issued');
    }

    // Token is saved after login via saveCurrentToken() — not here, as user may not be authenticated yet.

    // Handle token refresh
    _messaging.onTokenRefresh.listen(saveFCMToken, onError: (e) => print('[FCM] ❌ onTokenRefresh error: $e'));

    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      final type = message.data['type'] as String?;
      if (type == null) return;

      try {
        await _processFCMupdateCacheAndLocalStorage(message, type);
      } catch (e, stackTrace) {
        print('Error updating cache in foreground: $e $stackTrace');
      }

      // Show notification
      await _showForegroundNotification(message);
    });

    // Handle notification tap when app is in background
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      print('Notification tapped (background): ${message.data}');
      _handleNotificationTap(message.data);
    });

    // Check if app was opened from a notification (terminated state)
    RemoteMessage? initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      print('App opened from notification (terminated): ${initialMessage.data}');
      _handleNotificationTap(initialMessage.data);
    }
  }

  int _notificationIdForMessage(RemoteMessage message) {
    final type = message.data['type'] as String?;
    final expenseId = message.data['expenseId'] as String?;
    final tagId = message.data['tagId'] as String?;
    switch (type) {
      case 'expense_created':
      case 'expense_updated':
      case 'expense_deleted':
        return expenseId?.hashCode ?? message.hashCode;
      case 'tag_shared':
      case 'tag_updated':
      case 'tag_removed':
        return tagId?.hashCode ?? message.hashCode;
      default:
        return message.hashCode;
    }
  }

  /// Show notification when app is in foreground
  Future<void> _showForegroundNotification(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;

    await _localNotifications.show(
      _notificationIdForMessage(message),
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

  void _handleNotificationTap(Map<String, dynamic> data) {
    print("inside _handleNotificationTap with data: $data");

    final type = data['type'] as String?;

    if (type == 'wip_needs_attention') {
      _navigationController?.add({'type': 'bulk_import'});
      return;
    }

    final tagId = data['tagId'] as String?;
    if (tagId == null) return;

    Map<String, String>? navData;

    switch (type) {
      case 'expense_created':
      case 'expense_updated':
        navData = {'type': 'tag', 'tagId': tagId, if (data['expenseId'] != null) 'expenseId': data['expenseId'] as String};
        break;
      case 'expense_deleted':
        navData = {'type': 'tag', 'tagId': tagId};
        break;
      case 'tag_shared':
      case 'tag_updated':
        navData = {'type': 'tag', 'tagId': tagId};
        break;
      case 'tag_removed':
        navData = {'type': 'home', 'message': 'Your access to ${data['tagName']} has been removed'};
        break;
      default:
        print('Unknown notification type: $type');
    }

    if (navData != null) _navigationController?.add(navData);
  }

  Future<void> saveCurrentToken() async {
    try {
      final token = await _messaging.getToken();
      if (token != null) {
        await saveFCMToken(token);
      } else {
        print('[FCM] ⚠️ getToken() returned null — no token registered');
      }
    } catch (e, stackTrace) {
      print('[FCM] ❌ getToken() threw: $e\n$stackTrace');
    }
  }

  Future<void> cancelNotification(int id) => _localNotifications.cancel(id);

  void dispose() {
    _navigationController?.close();
    _navigationController = null;
  }
}

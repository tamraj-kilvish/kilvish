import 'dart:async';
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:kilvish/cache_manager.dart';
import 'package:kilvish/firebase_options.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Background message handler - must be top-level function
// ✅ Triggers ONLY for background/terminated app states
final asyncPrefs = SharedPreferencesAsync();

Future<void> _processFCMupdateCacheAndLocalStorage(RemoteMessage message, String type, {bool isForeground = false}) async {
  await updateFirestoreLocalCache(message.data);
  print('Firestore cache updated');

  final expenseId = message.data['expenseId'] as String?;
  final wipExpenseId = message.data['wipExpenseId'] as String?;
  final tagId = message.data['tagId'] as String?;

  // Update SharedPreferences cache
  await updateHomeScreenExpensesAndCache(type: type, expenseId: expenseId, wipExpenseId: wipExpenseId, tagId: tagId);
  print("Homescreen cache updated");
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  print('Background FCM message received: ${message.messageId}');

  final type = message.data['type'] as String?;
  if (type == null) return;

  try {
    await _processFCMupdateCacheAndLocalStorage(message, type);

    await asyncPrefs.setBool('needHomeScreenRefresh', true);
    print("asyncPrefs needHomeScreenRefresh is set to true");
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

  // Static variable to store pending navigation
  Map<String, String>? _pendingNavigation;

  Map<String, String>? getPendingNavigation() {
    final nav = _pendingNavigation;
    _pendingNavigation = null; // Clear after reading
    return nav;
  }

  final StreamController<String> _refreshController = StreamController<String>.broadcast();
  bool _needsDataRefresh = false;

  Stream<String> get refreshStream => _refreshController.stream;
  bool get needsDataRefresh => _needsDataRefresh;

  void markDataRefreshed() {
    _needsDataRefresh = false;
  }

  void _notifyRefreshNeeded(RemoteMessage message) {
    if (!_refreshController.isClosed) {
      _refreshController.add(jsonEncode(message.data));
      _needsDataRefresh = true;
    }
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

    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      print('Processing foreground FCM message: ${message.messageId}');

      final type = message.data['type'] as String?;
      if (type == null) return;

      try {
        await _processFCMupdateCacheAndLocalStorage(message, type, isForeground: true);
        // Notify UI to refresh
        _notifyRefreshNeeded(message);
      } catch (e, stackTrace) {
        print('Error updating cache in foreground: $e $stackTrace');
      }

      // Show notification
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

    print("fcm_handler - notification shown to user with title ${notification.title}");
  }

  /// Handle notification tap - simplified to always go to Tag Detail
  void _handleNotificationTap(Map<String, dynamic> data, {required bool isFromForeground}) {
    print("inside _handleNotificationTap with foreground value $isFromForeground");

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

      case 'wip_ready':
        // Navigate to Home screen (expenses tab shows WIPExpenses)
        print('Navigation: WIP expenses ready for review');
        navData = {'type': 'home', 'message': '${data['count']} expense(s) ready for review'};

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
    _refreshController.close();
  }
}

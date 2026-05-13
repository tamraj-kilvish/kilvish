import 'dart:async';
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:kilvish/background_worker.dart';
import 'package:kilvish/firebase_options.dart';
import 'package:kilvish/models_pending_import.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cache_manager.dart' as CacheManager;
import 'firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Background message handler - must be top-level function
// ✅ Triggers ONLY for background/terminated app states
final asyncPrefs = SharedPreferencesAsync();
int _wipAttentionCount = 0;

Future<void> _processFCMupdateCacheAndLocalStorage(RemoteMessage message, String type) async {
  await CacheManager.updateHomeScreenExpensesAndCache(
    type: type,
    wipExpenseId: message.data['wipExpenseId'] as String?,
    expenseId: message.data['expenseId'] as String?,
    tagId: message.data['tagId'] as String?,
    actorId: message.data['actorId'] as String?,
    onWIPNeedsAttention: (count) => _wipAttentionCount = count,
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
        'kilvish_expenses', 'Expense Notifications',
        channelDescription: 'Notifications for expense updates and tags',
        importance: Importance.high, priority: Priority.high,
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
    _wipAttentionCount = 0;
    await _processFCMupdateCacheAndLocalStorage(message, type);
    if (_wipAttentionCount > 0) await _showWIPAttentionNotification(_wipAttentionCount);
    await asyncPrefs.setBool('needHomeScreenRefresh', true);

    if (type == 'wip_status_update') {
      final pending = await PendingImport.loadFromCache();
      if (pending.isNotEmpty) {
        await processNextPendingImport();
      }
    }
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
      final type = message.data['type'] as String?;
      if (type == null) return;

      try {
        _wipAttentionCount = 0;
        await _processFCMupdateCacheAndLocalStorage(message, type);
        _notifyRefreshNeeded(message);
        if (_wipAttentionCount > 0) await _showWIPAttentionNotification(_wipAttentionCount);
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

  /// Handle notification tap - simplified to always go to Tag Detail
  void _handleNotificationTap(Map<String, dynamic> data, {required bool isFromForeground}) {
    print("inside _handleNotificationTap with foreground value $isFromForeground");

    final type = data['type'] as String?;

    if (type == 'wip_needs_attention') {
      final navData = {'type': 'bulk_import'};
      if (isFromForeground) {
        _navigationController!.add(navData);
      } else {
        _pendingNavigation = navData;
      }
      return;
    }

    final tagId = data['tagId'] as String?;

    if (tagId == null) return;

    Map<String, String>? navData;

    switch (type) {
      case 'expense_created':
      case 'expense_updated':
        print('_handleNotificationTap - Navigation: tag detail with expense highlight');
        navData = {'type': 'tag', 'tagId': tagId, if (data['expenseId'] != null) 'expenseId': data['expenseId'] as String};
        break;

      case 'expense_deleted':
        // Expense is gone — navigate to tag without highlighting
        print('_handleNotificationTap - Navigation: tag detail (expense deleted)');
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
    _refreshController.close();
  }
}

import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:kilvish/firestore_tags.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/import_receipt_screen.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/tag_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'signup_screen.dart';
import 'home_screen.dart';
import 'style.dart';
import 'firebase_options.dart';
import 'fcm_handler.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'splash_screen.dart';
import 'package:share_handler/share_handler.dart';
import 'package:app_links/app_links.dart';
import 'package:kilvish/deep_link_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Enable offline persistence
  FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'kilvish').settings = const Settings(persistenceEnabled: true);

  // Setup FCM background handler
  if (!kIsWeb) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  runApp(MyApp());
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  bool _fcmDisposed = false;
  StreamSubscription<Map<String, String>>? _navigationSubscription;
  final asyncPrefs = SharedPreferencesAsync();

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  Future<void> _initDeepLinks() async {
    _appLinks = AppLinks();

    // Handle link that opened app (cold start)
    final initialLink = await _appLinks.getInitialLink();
    if (initialLink != null) {
      _handleDeepLink(initialLink);
    }

    // Handle links while app is running
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
      _handleDeepLink(uri);
    });
  }

  void _handleDeepLink(Uri uri) {
    print('Received deep link: $uri');

    // Get current context from navigator
    final context = navigatorKey.currentContext;
    if (context != null) {
      DeepLinkHandler.handleDeepLink(context, uri);
    } else {
      print('No navigator context available for deep link');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed && !kIsWeb) {
      final pendingNav = FCMService.instance.getPendingNavigation();
      if (pendingNav != null && mounted) {
        _handleFCMNavigation(pendingNav);
      }
    }
  }

  // Future<void> checkNavigation() async {
  //   print("Checking navigation");
  //   final pendingNav = FCMService.instance.getPendingNavigation();
  //   if (pendingNav != null && mounted) {
  //     await _handleFCMNavigation(pendingNav);
  //   }
  // }

  Future<void> _handleFCMNavigation(Map<String, String> navData) async {
    print("inside _handleFCMNavigation with navData $navData");
    try {
      final navType = navData['type'];

      if (navType == 'home') {
        await navigatorKey.currentState?.pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => HomeScreen(messageOnLoad: navData['message'])),
          (route) => false,
        );
      } else if (navType == 'tag') {
        final tagId = navData['tagId'];
        if (tagId == null) return;
        final tag = await getTagData(tagId);

        // Clear navigation stack and go to Home first
        await navigatorKey.currentState?.pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => HomeScreen()),
          (route) => false,
        );

        // Small delay to ensure HomeScreen is mounted
        await Future.delayed(const Duration(milliseconds: 300));

        // Then navigate to tag detail
        await navigatorKey.currentState?.pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => HomeScreen()),
          (route) => false,
        );
        await navigatorKey.currentState?.push(MaterialPageRoute(builder: (context) => TagDetailScreen(tag: tag)));
      }
    } catch (e, stackTrace) {
      print('Error handling FCM navigation: $e $stackTrace');
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (!kIsWeb) {
      _initDeepLinks();

      _navigationSubscription = FCMService.instance.navigationStream.listen((navData) {
        print('main.dart - inside navigationStream.listen');
        _handleFCMNavigation(navData);
      });

      // Handle shared media (receipts)
      ShareHandlerPlatform.instance.sharedMediaStream.listen((SharedMedia media) {
        if (media.attachments!.isNotEmpty) {
          print("Got shared media - processing async");
          final attachment = media.attachments!.first;
          if (attachment != null) {
            WIPExpense.createWIPExpenseFromReceipt(File(attachment.path)).then((newWIPExpense) {
              if (newWIPExpense == null) {
                navigatorKey.currentState?.pushAndRemoveUntil(
                  MaterialPageRoute(builder: (context) => HomeScreen(messageOnLoad: "Receipt already shared with Kilvish")),
                  (route) => false,
                );
              } else {
                // Navigate to ImportReceiptScreen
                navigatorKey.currentState?.pushAndRemoveUntil(
                  MaterialPageRoute(builder: (context) => ImportReceiptScreen(wipExpense: newWIPExpense)),
                  (route) => false,
                );
              }
            });
          }
        }
      });
    }

    FileDownloader().updates.listen((update) {
      if (update is TaskStatusUpdate) {
        print("Status: ${update.task.taskId} -> ${update.status.name}");

        if (update.status == TaskStatus.failed) {
          // Get more details about the failure
          FileDownloader().taskForId(update.task.taskId).then((task) async {
            final result = await FileDownloader().database.recordForId(update.task.taskId);
            print("Failed result: $result");
            print("Exception: ${result?.exception}");
            // print("HTTP response code: ${result?.responseStatusCode}");
            // print("Response body: ${result?.responseBody}");
          });
        }
      } else if (update is TaskProgressUpdate) {
        print("Progress: ${update.task.taskId} -> ${(update.progress * 100).toStringAsFixed(1)}%");
      }
    });

    FileDownloader().start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    if (!kIsWeb && !_fcmDisposed) {
      _navigationSubscription?.cancel();
      FCMService.instance.dispose();
      _fcmDisposed = true;
    }

    FileDownloader().destroy();
    _linkSubscription?.cancel();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kilvish',
      theme: ThemeData(
        primarySwatch: primaryColor,
        fontFamily: 'Roboto',
        textTheme: TextTheme(
          bodyLarge: TextStyle(fontSize: defaultFontSize, color: kTextColor),
          bodyMedium: TextStyle(fontSize: defaultFontSize, color: kTextMedium),
          titleLarge: TextStyle(fontSize: titleFontSize, color: kTextColor, fontWeight: FontWeight.bold),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderSide: BorderSide(color: bordercolor)),
          focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: primaryColor, width: 2.0)),
        ),
      ),
      navigatorKey: navigatorKey,
      home: SplashWrapper(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class SplashWrapper extends StatelessWidget {
  const SplashWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _hasCompletedSignup(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return SplashScreen();
        }

        if (snapshot.data != null) {
          return snapshot.data as Widget;
        }
        return SignupScreen();
      },
    );
  }

  Future<Widget> _hasCompletedSignup() async {
    try {
      KilvishUser? kilvishUser = await getLoggedInUserData();
      if (kilvishUser == null) {
        return SignupScreen();
      }

      final kilvishId = kilvishUser.kilvishId;
      final isCompletedSignup = kilvishId != null && kilvishId.toString().isNotEmpty;
      if (!isCompletedSignup) {
        return SignupScreen();
      }

      updateLastLoginOfUser(kilvishUser.id);

      // Check for initial shared media
      SharedMedia? media = await ShareHandlerPlatform.instance.getInitialSharedMedia();
      if (media != null && media.attachments!.isNotEmpty) {
        print("Got initial shared media - processing async");
        final attachment = media.attachments!.first;
        if (attachment != null) {
          WIPExpense? newWIPExpense = await WIPExpense.createWIPExpenseFromReceipt(File(attachment.path));
          if (newWIPExpense == null) {
            return HomeScreen(messageOnLoad: "Receipt is already uploaded. Skipping");
          }
          return ImportReceiptScreen(wipExpense: newWIPExpense);
        }
      }

      return HomeScreen();
    } catch (e) {
      print('Error checking signup completion: $e');
      return SignupScreen();
    }
  }
}

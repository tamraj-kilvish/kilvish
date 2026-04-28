import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore_tags.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/import_receipt_screen.dart';
import 'package:kilvish/model_expenses.dart';
import 'package:kilvish/model_user.dart';
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
  StreamSubscription? _deepLinkSubscription;

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

      _initDeepLinks();
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

  Future<void> _initDeepLinks() async {
    final appLinks = AppLinks();

    // App opened cold via deep link
    try {
      final uri = await appLinks.getInitialLink();
      if (uri != null) await _handleDeepLink(uri);
    } catch (e) {
      print('Error getting initial deep link: $e');
    }

    // App already running when link is tapped
    _deepLinkSubscription = appLinks.uriLinkStream.listen(
      (uri) => _handleDeepLink(uri),
      onError: (e) => print('Deep link stream error: $e'),
    );
  }

  Future<void> _handleDeepLink(Uri uri) async {
    print('Handling deep link: $uri');
    if (uri.scheme != 'kilvish' || uri.host != 'tag') return;

    final tagId = uri.pathSegments.isNotEmpty ? uri.pathSegments[0] : null;
    if (tagId == null) return;

    try {
      final result = await joinTagViaUrl(tagId);
      final tag = await getTagData(tagId);

      await navigatorKey.currentState?.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => HomeScreen()), (route) => false);
      await Future.delayed(const Duration(milliseconds: 300));
      await navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => TagDetailScreen(tag: tag)));

      final ctx = navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) showSuccess(ctx, result['message']);
    } catch (e) {
      print('Error handling deep link: $e');
      final ctx = navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) showError(ctx, 'Failed to join tag');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    if (!kIsWeb && !_fcmDisposed) {
      _navigationSubscription?.cancel();
      FCMService.instance.dispose();
      _fcmDisposed = true;
    }

    if (!kIsWeb) {
      _deepLinkSubscription?.cancel();
    }

    FileDownloader().destroy();
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

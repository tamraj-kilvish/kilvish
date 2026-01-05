import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:kilvish/firestore.dart';
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
import 'package:workmanager/workmanager.dart';
import 'background_worker.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Enable offline persistence
  FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'kilvish').settings = const Settings(persistenceEnabled: true);

  // Setup FCM background handler
  if (!kIsWeb) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Initialize WorkManager for background tasks
    Workmanager().initialize(callbackDispatcher, isInDebugMode: false).then((value) {
      print("main.dart - initialized workmanager for async file processing");
    });
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    print("main.dart - didChangeAppLifecycleState with state ${state.name} ");
    if (state == AppLifecycleState.resumed && !kIsWeb) {
      checkNavigation().then((value) async {
        bool? needHomeScreenRefresh = await asyncPrefs.getBool('needHomeScreenRefresh');
        if (needHomeScreenRefresh != null && needHomeScreenRefresh == true) {
          print("loading cached data in homescreen");

          homeScreenKey.currentState?.loadDataFromSharedPreference().then((value) async {
            asyncPrefs.setBool('needHomeScreenRefresh', false);
            bool? freshDataLoaded = await asyncPrefs.getBool('freshDataLoaded');
            if (freshDataLoaded != null && freshDataLoaded == false) {
              print("loading freshData from loadData()");
              homeScreenKey.currentState?.loadData();
            }
          });
        }
        // print("refreshing home screen");
        // await homeScreenKey.currentState?.refreshHomeScreen(refreshNow: true);
      });
    }
  }

  Future<void> checkNavigation() async {
    print("Checking navigation");
    final pendingNav = FCMService.instance.getPendingNavigation();
    if (pendingNav != null && mounted) {
      await _handleFCMNavigation(pendingNav);
    }
  }

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
            handleSharedReceipt(File(attachment.path)).then((newWIPExpense) {
              // Navigate to home screen
              navigatorKey.currentState?.pushAndRemoveUntil(
                MaterialPageRoute(builder: (context) => HomeScreen(expenseAsParam: newWIPExpense as BaseExpense?)),
                (route) => false,
              );
            });
          }
        }
      });
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

      // Check for initial shared media
      SharedMedia? media = await ShareHandlerPlatform.instance.getInitialSharedMedia();
      if (media != null && media.attachments!.isNotEmpty) {
        print("Got initial shared media - processing async");
        final attachment = media.attachments!.first;
        if (attachment != null) {
          BaseExpense? newWIPExpense = await handleSharedReceipt(File(attachment.path));
          updateLastLoginOfUser(kilvishUser.id);
          return HomeScreen(expenseAsParam: newWIPExpense);
        }
      }

      updateLastLoginOfUser(kilvishUser.id);
      return HomeScreen();
    } catch (e) {
      print('Error checking signup completion: $e');
      return SignupScreen();
    }
  }
}

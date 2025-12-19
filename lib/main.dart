import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:kilvish/expense_add_edit_screen.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/tag_detail_screen.dart';
import 'signup_screen.dart';
import 'home_screen.dart';
import 'style.dart';
import 'firebase_options.dart';
import 'fcm_hanlder.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'splash_screen.dart';
import 'package:share_handler/share_handler.dart';

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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // ✅ Flag check as backup when returning from navigation
    if (state == AppLifecycleState.resumed && !kIsWeb) {
      // check if there are pending navigations
      print("In didChangeAppLifecycleState of main with state AppLifecycleState.resumed, checking pendingNav");
      final pendingNav = FCMService.instance.getPendingNavigation();
      if (pendingNav != null && mounted) {
        _handleFCMNavigation(pendingNav);
      }
    }

    // if (state == AppLifecycleState.detached) {
    //   if (!kIsWeb && !_fcmDisposed) {
    //     FCMService.instance.dispose();
    //     _fcmDisposed = true;
    //   }
    // }
  }

  void _handleFCMNavigation(Map<String, String> navData) async {
    print("inside _handleFCMNavigation with navData $navData");
    try {
      final navType = navData['type'];

      if (navType == 'home') {
        // Push to home and clear stack
        navigatorKey.currentState?.pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => HomeScreen(messageOnLoad: navData['message'])),
          (route) => false,
        );
      } else if (navType == 'tag') {
        final tagId = navData['tagId'];
        if (tagId == null) return;
        final tag = await getTagData(tagId);

        // Navigate to tag detail
        navigatorKey.currentState?.pushAndRemoveUntil(MaterialPageRoute(builder: (context) => HomeScreen()), (route) => false);

        navigatorKey.currentState?.push(MaterialPageRoute(builder: (context) => TagDetailScreen(tag: tag)));
      }
    } catch (e, stackTrace) {
      print('Error handling FCM navigation: $e $stackTrace');
      //if (mounted) showError(context, 'Could not open notification');
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

      ShareHandlerPlatform.instance.sharedMediaStream.listen((SharedMedia media) {
        if (media.attachments!.isNotEmpty) {
          print("Got some media in ShareHandlerPlatform.instance.sharedMediaStream.listen ");
          //final sharedFile = value.first;
          final attachment = media.attachments!.first;
          if (attachment != null) {
            print("Shared file path: ${attachment.path}");
            //ReceiveSharingIntent.instance.reset();
            navigatorKey.currentState?.pushReplacement(
              MaterialPageRoute(builder: (context) => ExpenseAddEditScreen(sharedReceiptImage: File(attachment.path))),
            );
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
      home: SplashWrapper(), // AuthWrapper(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// New wrapper widget to show splash
class SplashWrapper extends StatelessWidget {
  const SplashWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _hasCompletedSignup(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return SplashScreen(); // Show custom splash with inverted logo
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

      SharedMedia? media = await ShareHandlerPlatform.instance.getInitialSharedMedia();
      if (media != null && media.attachments!.isNotEmpty) {
        print("Got some media in await ShareHandlerPlatform.instance.getInitialSharedMedia()");
        //final sharedFile = value.first;
        final attachment = media.attachments!.first;
        if (attachment != null) {
          print("Shared file path: ${attachment.path}");
          //ReceiveSharingIntent.instance.reset();
          return ExpenseAddEditScreen(sharedReceiptImage: File(attachment.path));
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

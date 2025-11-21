import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:kilvish/expense_add_edit_screen.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';
import 'signup_screen.dart';
import 'home_screen.dart';
import 'style.dart';
import 'firebase_options.dart';
import 'fcm_hanlder.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'splash_screen.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

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

class MyApp extends StatefulWidget {
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  bool _fcmDisposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!kIsWeb && !_fcmDisposed) {
      FCMService.instance.dispose();
      _fcmDisposed = true;
    }

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      if (!kIsWeb && !_fcmDisposed) {
        FCMService.instance.dispose();
        _fcmDisposed = true;
      }
    }
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
      home: SplashWrapper(), // AuthWrapper(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// New wrapper widget to show splash
class SplashWrapper extends StatelessWidget {
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
      if (isCompletedSignup) {
        updateLastLoginOfUser(kilvishUser.id);
      }

      List<SharedMediaFile> value = await ReceiveSharingIntent.instance.getInitialMedia();
      if (value.isNotEmpty) {
        final sharedFile = value.first;
        print("Shared file path: ${sharedFile.path}");
        if (sharedFile.path.isNotEmpty) {
          ReceiveSharingIntent.instance.reset();
          return ExpenseAddEditScreen(sharedReceiptImage: File(sharedFile.path));
        }
      }

      return HomeScreen();
    } catch (e) {
      print('Error checking signup completion: $e');
      return SignupScreen();
    }
  }
}

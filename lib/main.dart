import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';
import 'signup_screen.dart';
import 'home_screen.dart';
import 'style.dart';
import 'firebase_options.dart';
import 'fcm_hanlder.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // ADD THESE LINES:
  // Enable offline persistence
  FirebaseFirestore.instanceFor(
    app: Firebase.app(),
    databaseId: 'kilvish',
  ).settings = const Settings(
    persistenceEnabled: true,
  );

  // Setup FCM background handler
  // TODO move this to home
  if (!kIsWeb) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
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
          titleLarge: TextStyle(
            fontSize: titleFontSize,
            color: kTextColor,
            fontWeight: FontWeight.bold,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderSide: BorderSide(color: bordercolor),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: primaryColor, width: 2.0),
          ),
        ),
      ),
      home: AuthWrapper(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AuthWrapper extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _hasCompletedSignup(),
      builder: (context, isUserSignedIn) {
        if (isUserSignedIn.connectionState == ConnectionState.waiting) {
          return Scaffold(
            body: Center(child: CircularProgressIndicator(color: primaryColor)),
          );
        }

        if (isUserSignedIn.data == true) {
          return HomeScreen();
        }

        // User authenticated but hasn't completed signup (no Kilvish ID)
        return SignupScreen();
      },
    );
  }

  Future<bool> _hasCompletedSignup() async {
    try {
      KilvishUser? kilvishUser = await getLoggedInUserData();
      if (kilvishUser == null) {
        return false;
      }

      final kilvishId = kilvishUser.kilvishId;
      return kilvishId != null && kilvishId.toString().isNotEmpty;
    } catch (e) {
      print('Error checking signup completion: $e');
      return false;
    }
  }
}

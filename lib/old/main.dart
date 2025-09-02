import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'signup_screen_new.dart';
import 'home_screen_new.dart';
import 'style.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const KilvishApp());
}

class KilvishApp extends StatelessWidget {
  const KilvishApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Kilvish',
      theme: ThemeData(
        backgroundColor: kWhitecolor,
        fontFamily: "Roboto",
        appBarTheme: AppBarTheme(
          elevation: 2,
          backgroundColor: primaryColor,
          iconTheme: const IconThemeData(
            color: kWhitecolor,
          ),
        ),
      ),
      home: AuthWrapper(),
    );
  }
}

class AuthWrapper extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            backgroundColor: kWhitecolor,
            body: Center(
              child: CircularProgressIndicator(
                color: primaryColor,
              ),
            ),
          );
        }
        
        if (snapshot.hasData) {
          return HomeScreenNew();
        }
        
        return SignupScreenNew();
      },
    );
  }
}

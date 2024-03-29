import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:kilvish/firebase_options.dart';
import 'package:kilvish/import_expense_screen.dart';
import 'package:kilvish/signup_screen.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'style.dart';
import 'dart:io';
import 'package:kilvish/constants/dimens_constants.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await FirebaseAuth.instance.useAuthEmulator('localhost', 9099);
  FirebaseFunctions.instanceFor().useFunctionsEmulator('localhost', 5001);

  runApp(const Kilvish());
}

class Kilvish extends StatefulWidget {
  const Kilvish({Key? key}) : super(key: key);
  @override
  _MainScreenState createState() => _MainScreenState();
  // This widget is the root of your application.
}

class _MainScreenState extends State<Kilvish> {
  String _pageToShow = "SignupPage";
  var newFiles = <File>[];

  @override
  void initState() {
    super.initState();

    ReceiveSharingIntent.getInitialMedia().then((List<SharedMediaFile> value) {
      if (value.isNotEmpty) {
        for (var element in value) {
          newFiles.add(File(
            Platform.isIOS
                ? element.type == SharedMediaType.FILE
                    ? element.path
                        .toString()
                        .replaceAll(AppConstants.replaceableText, "")
                    : element.path
                : element.path,
          ));
        }
        setState(() {
          _pageToShow = "SharingPage";
        });
      }
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Kilvish App',
        theme: theme(),
        home: _pageToShow == "SignupPage"
            ? const SignUpPage()
            : ImportExpensePage(files: newFiles, text: ""));
  }

  ThemeData theme() {
    return ThemeData(
      backgroundColor: kWhitecolor,
      fontFamily: "Roboto",
      appBarTheme: appBarTheme(),
    );
  }

  AppBarTheme appBarTheme() {
    // ignore: prefer_const_constructors
    return AppBarTheme(
      elevation: 2,
      backgroundColor: primaryColor,
      iconTheme: const IconThemeData(
        color: kWhitecolor,
      ),
    );
  }
}

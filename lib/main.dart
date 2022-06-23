import 'package:flutter/material.dart';
import 'style.dart';
import 'signup_screen.dart';

void main() {
  runApp(const Kilvish());
}

class Kilvish extends StatelessWidget {
  const Kilvish({Key? key}) : super(key: key);

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kilvish App',
      theme: ThemeData(
        primarySwatch: primaryColor,
      ),
      home: const SignUpPage(),
    );
  }
}

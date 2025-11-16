import 'package:flutter/material.dart';
import 'style.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: primaryColor,
      body: Center(child: Image.asset('assets/images/kilvish-inverted.png', width: 200, height: 200)),
    );
  }
}

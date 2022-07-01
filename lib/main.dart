import 'package:flutter/material.dart';
import 'package:kilvish/detail_screen.dart';
import 'package:kilvish/signup_screen.dart';
import 'package:kilvish/tags_screen.dart';
import 'style.dart';

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
      home: const TagsPage(),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:kilvish/signup_screen.dart';
import 'package:kilvish/handle_share.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'style.dart';
import 'dart:io';
import 'package:kilvish/constants/dimens_constants.dart';

void main() {
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
        value.forEach((element) {
          newFiles.add(File(
            Platform.isIOS
                ? element.type == SharedMediaType.FILE
                    ? element.path
                        .toString()
                        .replaceAll(AppConstants.replaceableText, "")
                    : element.path
                : element.path,
          ));
        });
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
      title: 'Kilvish App',
      theme: ThemeData(
        primarySwatch: primaryColor,
      ),
      home: _pageToShow == "SignupPage"
          ? const SignUpPage()
          : HandleShare(files: newFiles, text: ""),
    );
  }
}

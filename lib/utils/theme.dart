import 'package:flutter/material.dart';

import '../style.dart';


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

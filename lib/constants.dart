import 'package:flutter/material.dart';

const MaterialColor primaryColor = Colors.pink;
const TextStyle textStylePrimaryColor = TextStyle(color: primaryColor);

const MaterialColor inactiveColor = Colors.grey;
const TextStyle textStyleInactive = TextStyle(color: inactiveColor);

Widget appBarMenu(Function()? onPressedAction) {
  return IconButton(
    icon: const Icon(Icons.menu),
    onPressed: onPressedAction,
  );
}

Widget appBarSearch(Function()? onPressedAction) {
  return IconButton(
    icon: Icon(
      Icons.search,
      color: Colors.white,
    ),
    onPressed: null,
  );
}

import 'package:flutter/material.dart';

Widget appBarMenu(Function()? onPressedAction) {
  return IconButton(
    icon: const Icon(Icons.menu),
    onPressed: onPressedAction,
  );
}

Widget appBarSearch(Function()? onPressedAction) {
  return IconButton(
    icon: const Icon(
      Icons.search,
      color: Colors.white,
    ),
    onPressed: onPressedAction,
  );
}

Widget appBarRightMenu(Function()? onPressedAction) {
  return IconButton(
    icon: const Icon(
      Icons.more_vert,
      color: Colors.white,
    ),
    onPressed: onPressedAction,
  );
}

import 'package:flutter/material.dart';
import 'package:jiffy/jiffy.dart';
import 'style.dart';

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

Widget appBarEdit(Function()? onPressedAction) {
  return IconButton(
    icon: const Icon(
      Icons.edit,
      color: Colors.white,
    ),
    onPressed: onPressedAction,
  );
}

String relativeTimeFromNow(DateTime d) {
  if (DateTime.now().difference(d) < const Duration(days: 2)) {
    return Jiffy(d).fromNow();
  } else {
    return Jiffy(d).yMMMMd;
  }
}

Widget renderMainBottomButton(String text, Function()? onPressed) {
  return Row(children: [
    Expanded(
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
            backgroundColor: primaryColor,
            minimumSize: const Size.fromHeight(50)),
        child: Text(text,
            style: const TextStyle(color: Colors.white, fontSize: 15)),
      ),
    ),
  ]);
}

Widget renderImageIcon(String url) {
  return Image.asset(
    url,
    width: 30,
    height: 30,
    fit: BoxFit.fitWidth,
  );
}

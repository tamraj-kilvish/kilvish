import 'package:flutter/material.dart';
import 'package:jiffy/jiffy.dart';
import 'style.dart';
import 'models.dart';

Widget appBarMenu(Function()? onPressedAction) {
  return IconButton(
    icon: const Icon(Icons.menu),
    onPressed: onPressedAction,
  );
}

Widget appBarSearchIcon(Function()? onPressedAction) {
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

Widget appBarEditIcon(Function()? onPressedAction) {
  return IconButton(
    icon: const Icon(
      Icons.edit,
      color: Colors.white,
    ),
    onPressed: onPressedAction,
  );
}

Widget appBarSearchInput({required TextEditingController controller}) {
  return TextField(
    controller: controller,
    decoration: InputDecoration(
      prefixIcon: const Icon(Icons.search, color: Colors.white),
      suffixIcon: IconButton(
        icon: const Icon(Icons.clear, color: Colors.white),
        onPressed: () => {controller.clear()},
      ),
      hintText: 'Search...',
    ),
    cursorColor: Colors.white,
    style: const TextStyle(color: Colors.white),
    autofocus: true,
    showCursor: true,
  );
}

String relativeTimeFromNow(DateTime d) {
  if (DateTime.now().difference(d) < const Duration(days: 2)) {
    return Jiffy(d).fromNow();
  } else {
    return Jiffy(d).yMMMMd;
  }
}

Widget renderMainBottomButton(String text, Function()? onPressed,
    [bool status = true]) {
  return Row(children: [
    Expanded(
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
            backgroundColor: status ? primaryColor : inactiveColor,
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

Widget renderTag(
    {required String text, TagStatus status = TagStatus.unselected}) {
  return TextButton(
    style: TextButton.styleFrom(
      backgroundColor:
          status == TagStatus.selected ? primaryColor : inactiveColor,
      shape: const StadiumBorder(),
    ),
    onPressed: null,
    child: RichText(
      text: TextSpan(
        children: [
          TextSpan(
              text: '$text ',
              style: const TextStyle(color: Colors.white, fontSize: 15)),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Icon(
              status == TagStatus.selected
                  ? Icons.clear_rounded
                  : Icons.add_circle_outline_sharp,
              color: Colors.white,
              size: 15,
            ),
          ),
        ],
      ),
    ),
  );
}

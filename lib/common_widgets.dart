import 'package:flutter/material.dart';
import 'package:jiffy/jiffy.dart';
import 'package:kilvish/constants/dimens_constants.dart';
import 'style.dart';
import 'models.dart';

Widget appBarMenu(Function()? onPressedAction) {
  return IconButton(
    icon: const Icon(
      Icons.menu,
      color: kWhitecolor,
    ),
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

Widget renderImageIcon(IconData icon) {
  return Icon(
    icon,
    size: 35,
    color: kWhitecolor,
  );
}

Widget renderPrimaryColorLabel(
    {required String text,
    double topSpacing = DimensionConstants.leftPadding15}) {
  return renderLabel(text: text, color: primaryColor, topSpacing: topSpacing);
}

Widget renderLabel(
    {required String text,
    Color color = inactiveColor,
    double fontSize = defaultFontSize,
    double topSpacing = 0}) {
  return Container(
      margin: EdgeInsets.only(top: topSpacing),
      child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            style: TextStyle(color: color, fontSize: fontSize),
          )));
}

Widget renderSupportLabel(
    {required String text,
    Color color = inactiveColor,
    double fontSize = smallFontSize,
    double topSpacing = 0}) {
  return Container(
      margin: EdgeInsets.only(top: topSpacing),
      child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            style: TextStyle(color: color, fontSize: fontSize),
          )));
}

Widget renderHelperText({required String text}) {
  return Container(
      margin: const EdgeInsets.only(top: 5, bottom: 10),
      child: renderLabel(
          text: text, color: inactiveColor, fontSize: smallFontSize));
}

//-------------------------Custom Text--------------------

Widget customText(String text, Color textColor, double size, fontWeight,
    {int maxLine = 1,
    TextAlign? align,
    TextOverflow? overflow,
    TextDecoration? textDecoration}) {
  return Text(
    text,
    textAlign: align,
    maxLines: maxLine,
    overflow: overflow,
    style: TextStyle(
      decoration: textDecoration,
      color: textColor,
      fontSize: size,
      fontWeight: fontWeight,
    ),
  );
}

// -------------- form header text -----------------------------------
Widget headertext(String text) {
  return customText(text, primaryColor, largeFontSize,
      FontSizeWeightConstants.fontWeightBold);
}

Widget appBarTitleText(String text) {
  return customText(
      text, kWhitecolor, titleFontSize, FontSizeWeightConstants.fontWeightBold);
}

// -------------------- Textfield underline inputdecoration --------------------

InputDecoration customUnderlineInputdecoration(
    {required String hintText,
    required Color bordersideColor,
    Widget? suffixicon}) {
  return InputDecoration(
      hintText: hintText,
      focusedBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: bordersideColor),
      ),
      suffixIcon: suffixicon ?? const SizedBox());
}

// ------------------ contact ui --------------------------

Widget customContactUi({required Function()? onTap}) {
  return InkWell(
      onTap: onTap,
      child: const Icon(
        Icons.contact_page,
        color: primaryColor,
        size: contactIconSize,
      ));
}

Widget renderTagGroup(
    {required Set<Tag> tags,
    required dynamic Function({Tag? tag}) onPressed,
    TagStatus status = TagStatus.unselected}) {
  if (tags.isEmpty) {
    return Container(
        margin: const EdgeInsets.only(top: 10),
        child: const Text('.. Nothing here ..',
            style: TextStyle(color: inactiveColor)));
  }

  return Wrap(
    direction: Axis.horizontal,
    crossAxisAlignment: WrapCrossAlignment.start,
    spacing: 5,
    runSpacing: 10,
    children: tags.map((tag) {
      return renderTag(
          text: tag.name,
          status: status,
          isUpdated: false,
          onPressed: () => onPressed(tag: tag));
      //onPressed: () => executeOnTagButtonPress(tag: tag, status: status));
    }).toList(),
  );
}

Widget renderTag(
    {required String text,
    TagStatus status = TagStatus.unselected,
    bool isUpdated = false,
    Function()? onPressed}) {
  return TextButton(
    style: TextButton.styleFrom(
      backgroundColor: (status == TagStatus.selected && !isUpdated)
          ? primaryColor
          : inactiveColor,
      shape: isUpdated
          ? const StadiumBorder(
              side: BorderSide(color: primaryColor, width: 2),
            )
          : const StadiumBorder(),
    ),
    onPressed: onPressed,
    child: RichText(
      text: TextSpan(
        children: [
          TextSpan(
              text: '$text ',
              style: const TextStyle(color: Colors.white, fontSize: 15)),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Icon(
              status == TagStatus.selected ? Icons.clear_rounded : Icons.add,
              color: Colors.white,
              size: 15,
            ),
          ),
        ],
      ),
    ),
  );
}

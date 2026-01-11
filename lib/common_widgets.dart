import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:jiffy/jiffy.dart';
import 'package:kilvish/constants/dimens_constants.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/expense_add_edit_screen.dart';
import 'package:kilvish/expense_detail_screen.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models_expense.dart';
import 'package:url_launcher/url_launcher.dart';
import 'style.dart';
import 'models.dart';

Widget appBarMenu(Function()? onPressedAction) {
  return IconButton(
    icon: const Icon(Icons.menu, color: kWhitecolor),
    onPressed: onPressedAction,
  );
}

Widget appBarSearchIcon(Function()? onPressedAction) {
  return IconButton(
    icon: const Icon(Icons.search, color: Colors.white),
    onPressed: onPressedAction,
  );
}

Widget appBarRightMenu(Function()? onPressedAction) {
  return IconButton(
    icon: const Icon(Icons.more_vert, color: Colors.white),
    onPressed: onPressedAction,
  );
}

Widget appBarEditIcon(Function()? onPressedAction) {
  return IconButton(
    icon: const Icon(Icons.edit, color: Colors.white),
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
    return Jiffy.parseFromDateTime(d).fromNow();
  } else {
    return Jiffy.parseFromDateTime(d).yMMMMd;
  }
}

Widget renderMainBottomButton(String text, Function()? onPressed, [bool status = true]) {
  return Row(
    children: [
      Expanded(
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            backgroundColor: status ? primaryColor : inactiveColor,
            minimumSize: const Size.fromHeight(50),
          ),
          child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 15)),
        ),
      ),
    ],
  );
}

Widget renderImageIcon(IconData icon) {
  return Icon(icon, size: 35, color: kWhitecolor);
}

Widget renderPrimaryColorLabel({required String text, double topSpacing = DimensionConstants.leftPadding15}) {
  return renderLabel(text: text, color: primaryColor, topSpacing: topSpacing);
}

Widget renderLabel({
  required String text,
  Color color = inactiveColor,
  double fontSize = defaultFontSize,
  double topSpacing = 0,
}) {
  return Container(
    margin: EdgeInsets.only(top: topSpacing),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: fontSize),
      ),
    ),
  );
}

Widget renderSupportLabel({
  required String text,
  Color color = inactiveColor,
  double fontSize = smallFontSize,
  double topSpacing = 0,
}) {
  return Container(
    margin: EdgeInsets.only(top: topSpacing),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: fontSize),
      ),
    ),
  );
}

Widget renderHelperText({required String text}) {
  return Container(
    margin: const EdgeInsets.only(top: 5, bottom: 10),
    child: renderLabel(text: text, color: inactiveColor, fontSize: smallFontSize),
  );
}

//-------------------------Custom Text--------------------

Widget customText(
  String text,
  Color textColor,
  double size,
  fontWeight, {
  int maxLine = 1,
  TextAlign? align,
  TextOverflow? overflow,
  TextDecoration? textDecoration,
}) {
  return Text(
    text,
    textAlign: align,
    maxLines: maxLine,
    overflow: overflow,
    style: TextStyle(decoration: textDecoration, color: textColor, fontSize: size, fontWeight: fontWeight),
  );
}

// -------------- form header text -----------------------------------
Widget headertext(String text) {
  return customText(text, primaryColor, largeFontSize, FontSizeWeightConstants.fontWeightBold);
}

Widget appBarTitleText(String text) {
  return customText(text, kWhitecolor, titleFontSize, FontSizeWeightConstants.fontWeightBold);
}

// -------------------- Textfield underline inputdecoration --------------------

InputDecoration customUnderlineInputdecoration({required String hintText, required Color bordersideColor, Widget? suffixicon}) {
  return InputDecoration(
    hintText: hintText,
    focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: bordersideColor)),
    suffixIcon: suffixicon ?? const SizedBox(),
  );
}

// ------------------ contact ui --------------------------

Widget customContactUi({required Function()? onTap}) {
  return InkWell(
    onTap: onTap,
    child: const Icon(Icons.contact_page, color: primaryColor, size: contactIconSize),
  );
}

Widget renderTagGroup({required Set<Tag> tags, TagStatus status = TagStatus.selected}) {
  if (tags.isEmpty) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tileBackgroundColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: bordercolor),
      ),
      child: Center(
        child: Text(
          'Tap to add tags',
          style: TextStyle(color: inactiveColor, fontSize: smallFontSize),
        ),
      ),
    );
  }

  return Wrap(
    direction: Axis.horizontal,
    crossAxisAlignment: WrapCrossAlignment.start,
    spacing: 5,
    runSpacing: 10,
    children: tags.map((tag) {
      return renderTag(text: tag.name, status: status, isUpdated: false, onPressed: null);
    }).toList(),
  );
}

Widget renderTag({required String text, TagStatus status = TagStatus.unselected, bool isUpdated = false, Function()? onPressed}) {
  return TextButton(
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 0),
      backgroundColor: (status == TagStatus.selected && !isUpdated) ? primaryColor : inactiveColor,
      shape: isUpdated ? const StadiumBorder(side: BorderSide(color: primaryColor, width: 2)) : const StadiumBorder(),
    ),
    onPressed: onPressed,
    child: RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: '${truncateText(text)} ',
            style: const TextStyle(color: Colors.white, fontSize: defaultFontSize),
          ),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Icon(
              status == TagStatus.selected ? Icons.clear_rounded : Icons.add,
              color: Colors.white,
              size: defaultFontSize,
            ),
          ),
        ],
      ),
    ),
  );
}

// -------------------- Unified Expense Tile Widget --------------------

Widget userInitialCircleWithKilvishId(String? kilvishId) {
  const double avatarRadius = 18.0; // Standard radius
  const double leadWidth = avatarRadius * 3; // Fixed width (40.0)

  return SizedBox(
    width: leadWidth,
    height: leadWidth * 1.5,
    child: Column(
      children: [
        CircleAvatar(
          radius: avatarRadius,
          backgroundColor: primaryColor,
          child: Text(
            kilvishId != null ? kilvishId[0].toUpperCase() : "-",
            style: TextStyle(
              color: kWhitecolor,
              fontSize: largeFontSize,
              fontWeight: FontWeight.bold, // Makes the letter pop
            ),
          ),
        ),
        const SizedBox(height: 2), // Small gap
        Text(
          kilvishId != null ? truncateText('@$kilvishId') : "...loading",
          style: TextStyle(fontSize: xsmallFontSize),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    ),
  );
}

Widget renderExpenseTile({required Expense expense, required VoidCallback onTap, bool showTags = true, String? dateFormat}) {
  return Column(
    children: [
      const Divider(height: 1),
      ListTile(
        tileColor: expense.isUnseen ? primaryColor.withOpacity(0.15) : tileBackgroundColor,
        leading: expense.isUnseen
            ? Stack(
                children: [
                  userInitialCircleWithKilvishId(expense.ownerKilvishId),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: errorcolor, shape: BoxShape.circle),
                    ),
                  ),
                ],
              )
            : userInitialCircleWithKilvishId(expense.ownerKilvishId),
        onTap: onTap,
        title: Container(
          margin: const EdgeInsets.only(bottom: 5),
          child: Text(
            'To: ${truncateText(expense.to)}',
            style: TextStyle(
              fontSize: defaultFontSize,
              color: kTextColor,
              fontWeight: expense.isUnseen ? FontWeight.bold : FontWeight.w500,
            ),
          ),
        ),
        subtitle: showTags
            ? renderTagGroup(tags: expense.tags)
            : Text(
                formatRelativeTime(expense.timeOfTransaction),
                style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
              ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '₹${expense.amount.round()}',
              style: TextStyle(fontSize: largeFontSize, color: kTextColor, fontWeight: FontWeight.bold),
            ),
            if (showTags)
              Text(
                '📅 ${formatRelativeTime(expense.timeOfTransaction)}',
                style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
              ),
          ],
        ),
      ),
    ],
  );
}

String formatRelativeTime(dynamic timestamp) {
  if (timestamp == null) return '';

  DateTime date;
  if (timestamp is Timestamp) {
    date = timestamp.toDate();
  } else if (timestamp is DateTime) {
    date = timestamp;
  } else {
    return '';
  }

  Duration difference = DateTime.now().difference(date);

  if (difference.inDays >= 3) {
    return DateFormat('MMM dd, yyyy').format(date); // '${date.day}/${date.month}/${date.year}';
  } else if (difference.inDays > 0) {
    return '${difference.inDays} day(s) ago';
  } else if (difference.inHours > 0) {
    return '${difference.inHours} hour(s) ago';
  } else if (difference.inMinutes > 0) {
    return '${difference.inMinutes} minute(s) ago';
  } else {
    return 'Just now';
  }
}

void showSuccess(BuildContext context, String message) {
  return;
  //ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.green));
}

void showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      padding: const EdgeInsets.only(top: 8.0, left: 20.0),
      persist: false,
      backgroundColor: errorcolor,
      // The main message stays on the left
      content: Text(
        message,
        style: const TextStyle(color: Colors.white, fontSize: smallFontSize),
      ),
      // The button is automatically right-aligned
      action: SnackBarAction(
        label: 'MSG DEVELOPER',
        textColor: Colors.blue[50], // Your preferred readable blue
        onPressed: () async {
          try {
            await launchUrl(Uri.parse('https://wa.me/919538384545'));
          } catch (e) {
            print('Error launching URL: $e');
          }
        },
      ),
    ),
  );
}

void showInfo(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

String normalizePhoneNumber(String phone) {
  // Remove all non-digit characters
  String digits = phone.replaceAll(RegExp(r'\D'), '');

  // Add +91 if it's a 10-digit Indian number without country code
  if (digits.length == 10 && !digits.startsWith('91')) {
    return '+91$digits';
  }

  // Add + if it's missing
  if (!digits.startsWith('+')) {
    return '+$digits';
  }

  return digits;
}

Future<List<Expense>?> openExpenseDetail(bool mounted, BuildContext context, BaseExpense expense, List<Expense> expenses) async {
  // Mark this expense as seen in Firestor

  //if (!mounted) return null;
  final result = await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) =>
          expense is Expense ? ExpenseDetailScreen(expense: expense) : ExpenseAddEditScreen(baseExpense: expense),
    ),
  );

  // Check if expense or WIPExpense is deleted
  if (result != null && result is Map && result['deleted'] == true) {
    expenses.removeWhere((e) => e.id == expense.id);
    showSuccess(context, "Expense successfully deleted");
    return [...expenses];
  }

  if (result != null && result is Expense) {
    // Update local state
    List<Expense> newExpenses = expenses.map((exp) => exp.id == result.id ? result : exp).toList();
    return newExpenses;
  }

  // user hit a back & result is null .. we should mark the Expense seen (only if it is unseen) & should update the list also
  if (expense is Expense && expense.isUnseen) {
    await markExpenseAsSeen(expense.id);
    expense.markAsSeen();
    List<Expense> newExpenses = expenses.map((exp) => exp.id == expense.id ? expense : exp).toList();
    return newExpenses;
  }

  return null;
}

// Helper function (place this outside the widget class)
String truncateText(String text, [int maxCharacters = 13]) {
  if (text.length <= maxCharacters) {
    return text;
  }
  // Ensure the limit is large enough for the ellipsis (e.g., limit >= 3)
  if (maxCharacters < 2) {
    return text.substring(0, maxCharacters);
  }
  return '${text.substring(0, maxCharacters - 2)}..';
}

Widget buildReceiptSection({
  required String initialText,
  String? initialSubText,
  required String processingText,
  required void Function() mainFunction,
  required bool isProcessingImage,
  File? receiptImage,
  String? receiptUrl,
  Uint8List? webImageBytes,
  void Function()? onCloseFunction,
}) {
  return GestureDetector(
    onTap: isProcessingImage ? null : mainFunction, // _showImageSourceOptions,
    child: Container(
      constraints: BoxConstraints(minHeight: 200, maxHeight: receiptImage != null || receiptUrl != null ? 500 : 200),
      decoration: BoxDecoration(
        color: receiptImage != null || receiptUrl != null ? Colors.transparent : tileBackgroundColor,
        border: Border.all(color: bordercolor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: receiptImage != null || receiptUrl != null
          ? Stack(
              children: [
                // Full image display
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: _buildReceiptImage(receiptUrl, receiptImage, webImageBytes),
                  ),
                ),
                // Close button
                if (onCloseFunction != null) ...[
                  Positioned(
                    top: 8,
                    right: 8,
                    child: IconButton(
                      icon: Icon(Icons.close, color: kWhitecolor),
                      style: IconButton.styleFrom(backgroundColor: Colors.black54),
                      onPressed: onCloseFunction /*() {
                        setState(() {
                          receiptImage = null;
                          receiptUrl = null;
                          webImageBytes = null;
                        });
                      },*/,
                    ),
                  ),
                ],
              ],
            )
          : isProcessingImage
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: primaryColor),
                  SizedBox(height: 16),
                  customText(processingText, kTextMedium, defaultFontSize, FontWeight.normal),
                ],
              ),
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                renderImageIcon(Icons.add_photo_alternate_outlined),
                SizedBox(height: 12),
                customText(initialText, kTextMedium, defaultFontSize, FontWeight.normal),
                if (initialSubText != null) ...[
                  SizedBox(height: 4),
                  customText(initialSubText, inactiveColor, smallFontSize, FontWeight.normal),
                ],
              ],
            ),
    ),
  );
}

Widget _buildReceiptImage(String? receiptUrl, File? receiptImage, Uint8List? webImageBytes) {
  if (!kIsWeb && receiptImage != null) {
    // Mobile platform - use file
    return Image.file(
      receiptImage,
      fit: BoxFit.contain, // Show full image
      width: double.infinity,
    );
  } else if (receiptUrl != null && receiptUrl.isNotEmpty) {
    // Show network image (for existing receipts)
    return Image.network(
      receiptUrl,
      fit: BoxFit.contain, // Changed from cover to contain to show full image
      width: double.infinity,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) {
          return child; // The image is ready to show
        }
        // Return an empty box so the Image widget takes up no space/is invisible
        return const Center(child: CircularProgressIndicator());
      },
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) {
          return child;
        }
        return const Center(child: CircularProgressIndicator());
      },
      // Optional: Handle broken URLs or no internet
      errorBuilder: (context, error, stackTrace) {
        return const Center(child: Icon(Icons.error, color: Colors.red));
      },
    );
  } else if (kIsWeb && webImageBytes != null) {
    // Web platform - use memory bytes
    return Image.memory(
      webImageBytes,
      fit: BoxFit.contain, // Show full image
      width: double.infinity,
    );
  } else {
    return Container(color: Colors.grey[300]);
  }
}

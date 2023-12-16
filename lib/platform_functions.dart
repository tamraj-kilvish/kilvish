import 'package:fluttercontactpicker/fluttercontactpicker.dart';

Future<PhoneContact?> fetchContactFromPhonebook() async {
  bool permission = await FlutterContactPicker.requestPermission();
  if (permission) {
    if (await FlutterContactPicker.hasPermission()) {
      PhoneContact phoneContact = await FlutterContactPicker.pickPhoneContact();
      return phoneContact;
    }
  }
  return null;
}

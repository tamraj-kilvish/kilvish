import 'package:contacts_service/contacts_service.dart';
import 'package:flutter/material.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/style.dart';
import 'package:permission_handler/permission_handler.dart';



class ContactScreen extends StatefulWidget {
  const ContactScreen({Key? key}) : super(key: key);

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {

  List<Contact> contacts = [];
  bool isLoading = true;

  @override
  void initState() {
    // TODO: implement initState
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) async {
      await getContactPermission();
    });
  }

  Future<void> getContactPermission() async {
    if (await Permission.contacts.request().isGranted) {
      // Permission is granted, fetch contacts
      fetchContacts();
    } else {
      await Permission.contacts.request();
      // Permission is denied
      print('Contact permission is denied');
    }
  }

  Future fetchContacts() async {
     contacts = await ContactsService.getContacts();
     setState(() {
       isLoading = false;
     });

  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: appBarTitleText('Contact List'),
      ),
      body:
      isLoading?const Center(child: CircularProgressIndicator()):ListView.builder(
        itemCount: contacts.length,
        itemBuilder: (BuildContext context, int index) {
          print("con-${contacts[index].phones}");
          return
            contacts[index].displayName == null?const SizedBox():
            ListTile(
            leading: CircleAvatar(
              child: Text(contacts[index].displayName![0]??''),
            ),
            title: Text(contacts[index].displayName??''),
            subtitle: Text(
              contacts[index].phones?.isNotEmpty == true
                  ? contacts[index].phones![0].value ?? ''
                  : 'No phone number',
            ),

          );
        },
      ),
    );
  }
}

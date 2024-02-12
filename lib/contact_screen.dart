import 'package:contacts_service/contacts_service.dart';
import 'package:flutter/material.dart';
import 'package:kilvish/models.dart';
import 'package:permission_handler/permission_handler.dart';

enum ContactSelection { singleSelect, multiSelect }

const int TOTAL_CONTACTS_TO_SHOW = 5;

class ContactScreen extends StatefulWidget {
  final ContactSelection contactSelection;

  const ContactScreen(
      {Key? key, this.contactSelection = ContactSelection.singleSelect})
      : super(key: key);

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  final List<ContactModel> _selectedContactsList = [];
  final List<ContactModel> _kilvishContactsList = [
    ContactModel(
        kilvishId: "Kelvish ID 1",
        name: 'Kilvish User 1',
        phoneNumber: "65656-52452"),
  ];

  final Set<ContactModel> _kilvishContactsPostFiltering = <ContactModel>{};
  final Map<ContactModel, bool> _selectedContact = <ContactModel, bool>{};

  bool _isLoading = true;

  final TextEditingController _searchController = TextEditingController();
  final String _hintText = "Enter Name, Contact";
  final ValueNotifier<bool> _permissionDenied = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    getContactPermission(); // _isLoading is true & _permissionDenied is false
    // checking _permissionDenied value inside searchFromContact & returning if it is true
    _permissionDenied.addListener(searchFromContactList);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Ask Contact permission
  Future<void> getContactPermission() async {
    if (!await Permission.contacts.request().isGranted) {
      final status = await Permission.contacts.request();
      if (!status.isGranted) {
        setState(() {
          _permissionDenied.value = true;
          _isLoading = false;
        });
      }
    }
  }

  Widget contactPermissionDeniedBox() {
    if (!_permissionDenied.value) {
      return const SizedBox
          .shrink(); //return empty is permission is already there
    }
    return SizedBox(
      height: 72,
      child: Card(
        child: Container(
          margin: const EdgeInsets.all(10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                  child: Text(
                      "Contact permission isn't provided so contacts are not fetched followed by a button to provide permission.")),
              const SizedBox(width: 8),
              InkWell(
                  onTap: () {
                    getContactPermission();
                  },
                  child: const Text("Grant"))
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        bottomNavigationBar: contactPermissionDeniedBox(),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () {
            Navigator.pop(context, _selectedContactsList);
          },
          label: const Text('Done'),
          icon: const Icon(Icons.check, color: Colors.green),
          backgroundColor: Colors.pink,
        ),
        appBar: appBarForSearch(),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : ListView.builder(
                itemCount: _kilvishContactsPostFiltering.length,
                shrinkWrap: true,
                itemBuilder: (BuildContext context, int index) {
                  ContactModel kilvishContact =
                      _kilvishContactsPostFiltering.elementAt(index);
                  return InkWell(
                    onTap: () {
                      if (widget.contactSelection ==
                          ContactSelection.singleSelect) {
                        Navigator.pop(context, kilvishContact);
                      } else {
                        if (_selectedContact[kilvishContact] == null) {
                          // this is selecting the contact
                          _selectedContactsList.add(kilvishContact);
                          _selectedContact[kilvishContact] = true;
                        } else {
                          _selectedContactsList.remove(kilvishContact);
                          _selectedContact.remove(kilvishContact);
                        }
                        setState(() {});
                      }
                    },
                    child: Column(
                      children: [
                        (index > 0 &&
                                kilvishContact.kilvishId == null &&
                                _kilvishContactsPostFiltering
                                        .elementAt(index - 1)
                                        .kilvishId !=
                                    null)
                            ? const Divider(height: 1, color: Colors.grey)
                            : const SizedBox(),
                        ListTile(
                          leading: Stack(
                            children: [
                              CircleAvatar(
                                child: Text(kilvishContact.name[0]),
                              ),
                              if (_selectedContact[kilvishContact] == true)
                                const CircleAvatar(
                                  child: Center(
                                      child: Icon(Icons.check,
                                          color: Colors.green)),
                                )
                            ],
                          ),
                          title: Text(kilvishContact.name),
                          subtitle: Text(
                            kilvishContact.phoneNumber.isNotEmpty
                                ? kilvishContact.phoneNumber
                                : 'No phone number',
                          ),
                          trailing: Text((kilvishContact.kilvishId ?? "")),
                        ),
                      ],
                    ),
                  );
                },
              ));
  }

  /// AppBar for Search bhajan
  AppBar appBarForSearch() {
    return AppBar(
      centerTitle: true,
      automaticallyImplyLeading: false,
      leading: Container(
          margin: const EdgeInsets.only(left: 8),
          child: IconButton(
            icon: Icon(Icons.arrow_back_ios,
                color: Theme.of(context).textSelectionTheme.selectionColor),
            onPressed: () {
              Navigator.pop(context);
            },
          )),
      title: titleSearchWidget(),
    );
  }

  Set<ContactModel> getFilteredContacts(List<ContactModel> list) {
    return list
        .map((ContactModel kilvishContact) {
          if (kilvishContact.isMatch(
              text: _searchController.text.toLowerCase())) {
            return kilvishContact;
          }
          return null;
        })
        .nonNulls
        .toSet();
  }

  /// Search Contact from Kilvish Contact & Phone Contact List
  Future<void> searchFromContactList() async {
    setState(() {
      _isLoading = true;
    });

    Set<ContactModel> selectedContacts =
        getFilteredContacts(_selectedContactsList);
    selectedContacts.forEach((element) {
      _selectedContact[element] = true;
    });

    _kilvishContactsPostFiltering.addAll(selectedContacts);

    _kilvishContactsPostFiltering
        .addAll(getFilteredContacts(_kilvishContactsList));

    if (_permissionDenied.value) {
      setState(() {
        _isLoading = false;
      });
      return; // we can not call getContacts()
    }

    List<Contact> contactSearchResult = (await ContactsService.getContacts(
            query: _searchController.text.toLowerCase()))
        .take(TOTAL_CONTACTS_TO_SHOW)
        .toList();

    _kilvishContactsPostFiltering.addAll(contactSearchResult
        .map((contact) => ContactModel.fromContact(contact: contact))
        .toSet());

    setState(() {
      _isLoading = false;
    });
  }

  /// Showing title widget for app bar Search title
  Widget titleSearchWidget() {
    return TextField(
      controller: _searchController,
      onChanged: (value) {
        searchFromContactList();
      },
      decoration: InputDecoration(
          prefixIcon: Icon(Icons.search,
              color: Theme.of(context).textSelectionTheme.selectionColor),
          hintText: _hintText,
          hintStyle: TextStyle(
              color: Theme.of(context).textSelectionTheme.selectionColor)),
    );
  }
}

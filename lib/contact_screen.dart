import 'package:contacts_service/contacts_service.dart';
import 'package:flutter/material.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/provider/search_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:collection/collection.dart';

enum ContactSelection { singleSelect, multiSelect }

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
  bool _isLoading = true;

  final SearchNotifier _searchNotifier = SearchNotifier();
  final TextEditingController _searchController = TextEditingController();
  final String _hintText = "Enter Name, Contact";
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) async {
      await getContactPermission();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Ask Contact permission
  Future<void> getContactPermission() async {
    if (await Permission.contacts.request().isGranted) {
      setState(() {
        _permissionDenied = false;
      });
      // Permission is granted, fetch contacts
      searchFromContactList();
    } else {
      final status = await Permission.contacts.request();
      if (status.isGranted) {
        setState(() {
          _permissionDenied = false;
        });
        // Permission is granted, fetch contacts
        searchFromContactList();
      } else {
        setState(() {
          _permissionDenied = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: _permissionDenied
          ? SizedBox(
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
            )
          : const SizedBox(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.pop(context, _selectedContactsList);
        },
        label: const Text('Done'),
        icon: const Icon(Icons.check, color: Colors.green),
        backgroundColor: Colors.pink,
      ),
      appBar: PreferredSize(
        preferredSize: const Size(double.infinity, kToolbarHeight),
        child: appBarForSearch(),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ValueListenableBuilder<List<ContactModel>>(
              valueListenable: _searchNotifier.contactNotifier,
              builder: (context, filterList, child) {
                return ListView.builder(
                  itemCount: filterList.length,
                  shrinkWrap: true,
                  itemBuilder: (BuildContext context, int index) {
                    return InkWell(
                      onTap: () {
                        if (widget.contactSelection ==
                            ContactSelection.singleSelect) {
                          Navigator.pop(context, filterList[index]);
                        } else {
                          final localContact = _selectedContactsList
                              .firstWhereOrNull((element) =>
                                  element.name == filterList[index].name);
                          if (localContact == null) {
                            _selectedContactsList.add(filterList[index]);
                          } else {
                            _selectedContactsList.remove(localContact);
                          }
                          setState(() {});
                        }
                      },
                      child: Column(
                        children: [
                          (index > 0 &&
                                  filterList[index].kilvishId == null &&
                                  filterList[index - 1].kilvishId != null)
                              ? const Divider(height: 1, color: Colors.grey)
                              : const SizedBox(),
                          ListTile(
                            leading: Stack(
                              children: [
                                CircleAvatar(
                                  child: Text(filterList[index].name.isNotEmpty
                                      ? filterList[index].name[0]
                                      : ""),
                                ),
                                if (_selectedContactsList.firstWhereOrNull(
                                        (element) =>
                                            element.name ==
                                            filterList[index].name) !=
                                    null)
                                  const CircleAvatar(
                                    child: Center(
                                        child: Icon(Icons.check,
                                            color: Colors.green)),
                                  )
                              ],
                            ),
                            title: Text(filterList[index].name),
                            subtitle: Text(
                              filterList[index].phoneNumber.isNotEmpty
                                  ? filterList[index].phoneNumber
                                  : 'No phone number',
                            ),
                            trailing: Text((filterList[index].kilvishId ?? "")),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
    );
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

  /// Search Contact from Kilvish Contact & Phone Contact List
  Future<void> searchFromContactList() async {
    setState(() {
      _isLoading = true;
    });
    final kilvishSearchResult = _kilvishContactsList.where((element) {
      return element.name
              .toLowerCase()
              .contains(_searchController.text.toLowerCase()) ||
          element.phoneNumber
              .toLowerCase()
              .contains(_searchController.text.toLowerCase()) ||
          (element.kilvishId != null &&
              element.kilvishId!
                  .toLowerCase()
                  .contains(_searchController.text.toLowerCase()));
    }).toList();

    List<Contact> contactSearchResult =
        await ContactsService.getContacts(query: _searchController.text);
    if (contactSearchResult.length > 5) {
      contactSearchResult = contactSearchResult.take(5).toList();
    }
    contactSearchResult.forEach((contactsElement) {
      final localContact = kilvishSearchResult.firstWhereOrNull(
          (element) => element.name == contactsElement.displayName);
      if (localContact == null) {
        kilvishSearchResult.add(ContactModel(
            name: (contactsElement.displayName ?? ""),
            phoneNumber: (contactsElement.phones != null &&
                    contactsElement.phones!.isNotEmpty)
                ? (contactsElement.phones![0].value ?? "")
                : ""));
      }
    });
    _searchNotifier.updateSearchValue(kilvishSearchResult);
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

import 'package:fast_contacts/fast_contacts.dart';
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
  List<ContactModel> _selectedContactsList = [];
  List<ContactModel> _contactsList = [
    ContactModel(
        kilvishId: "Kelvish ID 1",
        name: 'Kilvish User 1',
        phoneNumber: "65656-52452"),
  ];
  bool _isLoading = true;

  final SearchNotifier _searchNotifier = SearchNotifier();
  final ValueNotifier<bool> _valueNotifier = ValueNotifier<bool>(true);
  final TextEditingController _searchController = TextEditingController();
  String _filterOn = "name";
  final String _hintText = "Enter name";
  final String _appbarTitle = "Contact List";

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

  Future<void> getContactPermission() async {
    if (await Permission.contacts.request().isGranted) {
      // Permission is granted, fetch contacts
      fetchContacts();
    } else {
      final status = await Permission.contacts.request();
      if (status.isGranted) {
        // Permission is granted, fetch contacts
        fetchContacts();
      }
    }
  }

  Future fetchContacts() async {
    List<Contact> contacts = await FastContacts.getAllContacts(batchSize: 5);
    if (contacts.length > 5) {
      contacts = contacts.take(5).toList();
    }
    setState(() {
      _isLoading = false;
      contacts.forEach((contactsElement) {
        final localContact = _contactsList.firstWhereOrNull(
            (element) => element.name == contactsElement.displayName);
        if (localContact == null) {
          _contactsList.add(ContactModel(
              name: contactsElement.displayName,
              phoneNumber: contactsElement.phones.isNotEmpty
                  ? contactsElement.phones[0].number
                  : ""));
        }
      });
      _searchNotifier.updateSearchValue(_contactsList);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
        child: ValueListenableBuilder(
          valueListenable: _valueNotifier,
          builder: (context, value, child) {
            return _valueNotifier.value
                ? appBarForShowOnlyTitle()
                : appBarForSearch();
          },
        ),
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
                          final localContact =
                              _selectedContactsList.firstWhereOrNull((element) =>
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
                                  filterList[index].kilvishId != null)
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

  /// App bar for show only title and icon
  AppBar appBarForShowOnlyTitle() {
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
      title: titleWidget(),
      actions: [
        IconButton(
            icon: Icon(Icons.search_rounded,
                color: Theme.of(context).textSelectionTheme.selectionColor),
            onPressed: () {
              _valueNotifier.value = !_valueNotifier.value;
            })
      ],
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
                _valueNotifier.value = !_valueNotifier.value;
              },
            )),
        title: titleSearchWidget(),
        actions: <Widget>[
          IconButton(
            icon: Icon(Icons.close,
                color: Theme.of(context).textSelectionTheme.selectionColor),
            onPressed: () {
              _valueNotifier.value = !_valueNotifier.value;
            },
          ),
        ]);
  }

  void searchFromContactList() {
    if (_searchController.text.isNotEmpty) {
      if (_filterOn == "name") {
        final list = _contactsList.where((element) {
          return element.name
              .toLowerCase()
              .contains(_searchController.text.toLowerCase());
        }).toList();
        _searchNotifier.updateSearchValue(list);
      } else if (_filterOn == "phoneNumber") {
        final list = _contactsList.where((element) {
          if (element.phoneNumber.isNotEmpty) {
            return element.phoneNumber
                .toLowerCase()
                .contains(_searchController.text.toLowerCase());
          } else {
            return false;
          }
        }).toList();
        _searchNotifier.updateSearchValue(list);
      } else if (_filterOn == "kilvishId") {
        final list = _contactsList.where((element) {
          if (element.kilvishId != null) {
            return element.kilvishId!
                .toLowerCase()
                .contains(_searchController.text.toLowerCase());
          } else {
            return false;
          }
        }).toList();
        _searchNotifier.updateSearchValue(list);
      }
    } else {
      _searchNotifier.updateSearchValue(_contactsList);
    }
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
          suffixIcon: PopupMenuButton<String>(
            icon: const Icon(Icons.filter_list),
            onSelected: (String result) {
              _filterOn = result;
              searchFromContactList();
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(
                value: 'name',
                child: Text('Name'),
              ),
              const PopupMenuItem<String>(
                value: 'phoneNumber',
                child: Text('Phone Number'),
              ),
              const PopupMenuItem<String>(
                value: 'kilvishId',
                child: Text('Kilvish Id'),
              ),
            ],
          ),
          hintStyle: TextStyle(
              color: Theme.of(context).textSelectionTheme.selectionColor)),
    );
  }

  /// Showing title widget for app bar
  Widget titleWidget() {
    return Material(
        type: MaterialType.transparency,
        child: Text(
          _appbarTitle,
          style: const TextStyle(
              fontSize: 18, fontWeight: FontWeight.w500, color: Colors.white),
        ));
  }
}

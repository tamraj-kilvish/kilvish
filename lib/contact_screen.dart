import 'package:fast_contacts/fast_contacts.dart';
import 'package:flutter/material.dart';
import 'package:kilvish/models/ContactModel.dart';
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
  List<ContactModel> selectedContactsList = [];
  List<ContactModel> contactsList = [
    ContactModel(
        kilvishId: "Kelvish ID 1",
        contact: const Contact(
            id: 'Kilvish User 1',
            emails: [],
            structuredName: StructuredName(
                displayName: "kilvish user",
                familyName: "no",
                givenName: "no",
                middleName: "",
                namePrefix: "",
                nameSuffix: ""),
            organization: null,
            phones: [Phone(label: "my", number: "65656-52452")])),
  ];
  bool isLoading = true;

  SearchNotifier searchNotifier = SearchNotifier();
  String filterOn = "name";
  final ValueNotifier<bool> _searchNotifier = ValueNotifier<bool>(true);
  final TextEditingController searchController = TextEditingController();
  final String hintText = "Enter name";
  final String appbarTitle = "Contact List";

  @override
  void initState() {
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
      final status = await Permission.contacts.request();
      if(status.isGranted){
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
      isLoading = false;
      contacts.forEach((contactsElement) {
        final localContact = contactsList.firstWhereOrNull((element) =>
            element.contact.displayName == contactsElement.displayName);
        if (localContact == null) {
          contactsList.add(ContactModel(contact: contactsElement));
        }
      });
      searchNotifier.updateSearchValue(contactsList);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.pop(context,selectedContactsList);
        },
        label: const Text('Done'),
        icon: const Icon(Icons.check,color: Colors.green),
        backgroundColor: Colors.pink,
      ) ,
      appBar: PreferredSize(
        preferredSize: const Size(double.infinity, kToolbarHeight),
        child: ValueListenableBuilder(
          valueListenable: _searchNotifier,
          builder: (context, value, child) {
            return _searchNotifier.value
                ? appBarForShowOnlyTitle()
                : appBarForSearch();
          },
        ),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : ValueListenableBuilder<List<ContactModel>>(
              valueListenable: searchNotifier.contactNotifier,
              builder: (context, filterList, child) {
                return ListView.builder(
                  itemCount: filterList.length,
                  shrinkWrap: true,
                  itemBuilder: (BuildContext context, int index) {
                    return filterList[index].contact.displayName == null
                        ? const SizedBox()
                        : InkWell(
                            onTap: () {
                              if (widget.contactSelection ==
                                  ContactSelection.singleSelect) {
                                Navigator.pop(context, filterList[index]);
                              } else {
                                final localContact = selectedContactsList
                                    .firstWhereOrNull((element) =>
                                        element.contact.displayName ==
                                        filterList[index].contact.displayName);
                                if (localContact == null) {
                                  selectedContactsList.add(filterList[index]);
                                } else {
                                  selectedContactsList.remove(localContact);
                                }
                                setState(() {});
                              }
                            },
                            child: Column(
                              children: [
                                (index > 0 &&
                                        filterList[index].kilvishId == null &&
                                        filterList[index].kilvishId != null)
                                    ? const Divider(
                                        height: 1, color: Colors.grey)
                                    : const SizedBox(),
                                ListTile(
                                  leading: Stack(
                                    children: [
                                      CircleAvatar(
                                        child: Text(filterList[index]
                                            .contact
                                            .displayName[0]),
                                      ),
                                      if (selectedContactsList.firstWhereOrNull(
                                              (element) =>
                                                  element.contact.displayName ==
                                                  filterList[index]
                                                      .contact
                                                      .displayName) !=
                                          null)
                                        const CircleAvatar(
                                          child: Center(
                                              child: Icon(Icons.check,
                                                  color: Colors.green)),
                                        )
                                    ],
                                  ),
                                  title: Text(
                                      filterList[index].contact.displayName),
                                  subtitle: Text(
                                    filterList[index].contact.phones.isNotEmpty
                                        ? filterList[index]
                                            .contact
                                            .phones[0]
                                            .number
                                        : 'No phone number',
                                  ),
                                  trailing:
                                      Text((filterList[index].kilvishId ?? "")),
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
              _searchNotifier.value = !_searchNotifier.value;
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
                _searchNotifier.value = !_searchNotifier.value;
              },
            )),
        title: titleSearchWidget(),
        actions: <Widget>[
          IconButton(
            icon: Icon(Icons.close,
                color: Theme.of(context).textSelectionTheme.selectionColor),
            onPressed: () {
              _searchNotifier.value = !_searchNotifier.value;
            },
          ),
        ]);
  }

  void searchFromContactList() {
    if (searchController.text.isNotEmpty) {
      if (filterOn == "name") {
        final list = contactsList.where((element) {
          return element.contact.displayName
              .toLowerCase()
              .contains(searchController.text.toLowerCase());
        }).toList();
        searchNotifier.updateSearchValue(list);
      } else if (filterOn == "phoneNumber") {
        final list = contactsList.where((element) {
          if (element.contact.phones.isNotEmpty) {
            return element.contact.phones[0].number
                .toLowerCase()
                .contains(searchController.text.toLowerCase());
          } else {
            return false;
          }
        }).toList();
        searchNotifier.updateSearchValue(list);
      } else if (filterOn == "kilvishId") {
        final list = contactsList.where((element) {
          if (element.kilvishId != null) {
            return element.kilvishId!
                .toLowerCase()
                .contains(searchController.text.toLowerCase());
          } else {
            return false;
          }
        }).toList();
        searchNotifier.updateSearchValue(list);
      }
    } else {
      searchNotifier.updateSearchValue(contactsList);
    }
  }

  /// Showing title widget for app bar Search title
  Widget titleSearchWidget() {
    return TextField(
      controller: searchController,
      onChanged: (value) {
        searchFromContactList();
      },
      decoration: InputDecoration(
          prefixIcon: Icon(Icons.search,
              color: Theme.of(context).textSelectionTheme.selectionColor),
          hintText: hintText,
          suffixIcon: PopupMenuButton<String>(
            icon: const Icon(Icons.filter_list),
            onSelected: (String result) {
              filterOn = result;
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
          appbarTitle,
          style: const TextStyle(
              fontSize: 18, fontWeight: FontWeight.w500, color: Colors.white),
        ));
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/style.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'dart:developer';

enum ContactSelection { singleSelect, multiSelect }

class ContactScreen extends StatefulWidget {
  final ContactSelection contactSelection;

  const ContactScreen({
    Key? key,
    this.contactSelection = ContactSelection.singleSelect,
  }) : super(key: key);

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  List<ContactModel> _contacts = [];
  List<ContactModel> _filteredContacts = [];
  Set<ContactModel> _selectedContacts = {};
  bool _isLoading = true;
  bool _permissionDenied = false;
  final TextEditingController _searchController = TextEditingController();

  final FirebaseFirestore _firestore = FirebaseFirestore.instanceFor(
    app: Firebase.app(),
    databaseId: 'kilvish',
  );

  @override
  void initState() {
    super.initState();
    _loadContacts();
    _searchController.addListener(_filterContacts);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    try {
      // Request permission
      if (!await FlutterContacts.requestPermission()) {
        setState(() {
          _permissionDenied = true;
          _isLoading = false;
        });
        return;
      }

      // Get all contacts with phone numbers
      final contacts = await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: false,
      );

      // Convert to ContactModel and fetch Kilvish IDs
      List<ContactModel> contactModels = [];
      for (var contact in contacts) {
        if (contact.phones.isNotEmpty) {
          final phoneNumber = contact.phones.first.number;
          final normalizedPhone = _normalizePhoneNumber(phoneNumber);

          // Check if user exists in Kilvish
          String? kilvishId = await _getKilvishIdByPhone(normalizedPhone);

          contactModels.add(
            ContactModel(
              name: contact.displayName,
              phoneNumber: normalizedPhone,
              kilvishId: kilvishId,
            ),
          );
        }
      }

      // Sort: Kilvish users first, then alphabetically
      contactModels.sort((a, b) {
        if (a.kilvishId != null && b.kilvishId == null) return -1;
        if (a.kilvishId == null && b.kilvishId != null) return 1;
        return a.name.compareTo(b.name);
      });

      setState(() {
        _contacts = contactModels;
        _filteredContacts = contactModels;
        _isLoading = false;
      });
    } catch (e) {
      log('Error loading contacts: $e', error: e);
      setState(() => _isLoading = false);
    }
  }

  String _normalizePhoneNumber(String phone) {
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

    return digits.startsWith('+') ? digits : '+$digits';
  }

  Future<String?> _getKilvishIdByPhone(String phoneNumber) async {
    try {
      final querySnapshot = await _firestore
          .collection('Users')
          .where('phone', isEqualTo: phoneNumber)
          .limit(1)
          .get();

      if (querySnapshot.docs.isNotEmpty) {
        final userData = querySnapshot.docs.first.data();
        return userData['kilvishId'] as String?;
      }
    } catch (e) {
      log('Error fetching Kilvish ID for $phoneNumber: $e');
    }
    return null;
  }

  void _filterContacts() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredContacts = _contacts;
      } else {
        _filteredContacts = _contacts.where((contact) {
          return contact.name.toLowerCase().contains(query) ||
              contact.phoneNumber.contains(query) ||
              (contact.kilvishId?.toLowerCase().contains(query) ?? false);
        }).toList();
      }
    });
  }

  void _toggleContact(ContactModel contact) {
    setState(() {
      if (widget.contactSelection == ContactSelection.singleSelect) {
        _selectedContacts.clear();
        _selectedContacts.add(contact);
      } else {
        if (_selectedContacts.contains(contact)) {
          _selectedContacts.remove(contact);
        } else {
          _selectedContacts.add(contact);
        }
      }
    });
  }

  void _done() {
    if (_selectedContacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please select at least one contact'),
          backgroundColor: errorcolor,
        ),
      );
      return;
    }

    if (widget.contactSelection == ContactSelection.singleSelect) {
      Navigator.pop(context, _selectedContacts.first);
    } else {
      Navigator.pop(context, _selectedContacts.toList());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kWhitecolor,
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: appBarTitleText('Select Contact'),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: kWhitecolor),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: primaryColor))
          : _permissionDenied
          ? _buildPermissionDenied()
          : Column(
              children: [
                // Search bar
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search contacts...',
                      prefixIcon: Icon(Icons.search, color: primaryColor),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: bordercolor),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: primaryColor, width: 2),
                      ),
                    ),
                  ),
                ),

                // Selected contacts count
                if (_selectedContacts.isNotEmpty)
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: primaryColor.withOpacity(0.1),
                    child: Row(
                      children: [
                        Text(
                          '${_selectedContacts.length} selected',
                          style: TextStyle(
                            color: primaryColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),

                // Contacts list
                Expanded(
                  child: _filteredContacts.isEmpty
                      ? Center(
                          child: Text(
                            'No contacts found',
                            style: TextStyle(
                              color: inactiveColor,
                              fontSize: defaultFontSize,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _filteredContacts.length,
                          itemBuilder: (context, index) {
                            final contact = _filteredContacts[index];
                            final isSelected = _selectedContacts.contains(
                              contact,
                            );
                            final hasKilvishId = contact.kilvishId != null;

                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: hasKilvishId
                                    ? primaryColor
                                    : inactiveColor,
                                child: Text(
                                  contact.name.isNotEmpty
                                      ? contact.name[0].toUpperCase()
                                      : '?',
                                  style: TextStyle(
                                    color: kWhitecolor,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              title: Text(
                                contact.name,
                                style: TextStyle(
                                  fontSize: defaultFontSize,
                                  color: kTextColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    contact.phoneNumber,
                                    style: TextStyle(
                                      fontSize: smallFontSize,
                                      color: kTextMedium,
                                    ),
                                  ),
                                  if (hasKilvishId)
                                    Text(
                                      '@${contact.kilvishId}',
                                      style: TextStyle(
                                        fontSize: smallFontSize,
                                        color: primaryColor,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                ],
                              ),
                              trailing: isSelected
                                  ? Icon(
                                      Icons.check_circle,
                                      color: primaryColor,
                                    )
                                  : Icon(
                                      Icons.circle_outlined,
                                      color: inactiveColor,
                                    ),
                              onTap: () => _toggleContact(contact),
                            );
                          },
                        ),
                ),
              ],
            ),
      bottomNavigationBar: _selectedContacts.isNotEmpty
          ? BottomAppBar(child: renderMainBottomButton('Done', _done))
          : null,
    );
  }

  Widget _buildPermissionDenied() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.contacts_outlined, size: 64, color: inactiveColor),
            SizedBox(height: 16),
            Text(
              'Contact Permission Required',
              style: TextStyle(
                fontSize: largeFontSize,
                color: kTextColor,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Please grant permission to access contacts to share tags with your friends.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: defaultFontSize, color: kTextMedium),
            ),
            SizedBox(height: 24),
            ElevatedButton(
              onPressed: () async {
                setState(() => _isLoading = true);
                await _loadContacts();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryColor,
                padding: EdgeInsets.symmetric(horizontal: 32, vertical: 12),
              ),
              child: Text(
                'Grant Permission',
                style: TextStyle(color: kWhitecolor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

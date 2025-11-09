import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/style.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore.dart';
import 'dart:developer';

class ContactScreen extends StatefulWidget {
  final ContactSelection contactSelection;
  Set<SelectableContact>? sharedWithContacts;

  ContactScreen({
    super.key,
    this.contactSelection = ContactSelection.singleSelect,
    this.sharedWithContacts,
  });

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  List<UserFriend> _userFriends = [];
  List<LocalContact> _localContacts = [];
  List<SelectableContact> _filteredContacts = [];
  PublicUserInfo? _publicInfoResult;

  Set<SelectableContact> _selectedContacts = {};
  bool _isLoading = true;
  bool _permissionDenied = false;
  bool _isSearchingPublicInfo = false;

  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.sharedWithContacts!.isNotEmpty) {
      _selectedContacts.addAll(widget.sharedWithContacts!);
    }
    _loadAllContacts();
    _searchController.addListener(_filterContacts);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAllContacts() async {
    setState(() => _isLoading = true);

    try {
      // Load user friends from Firestore
      List<UserFriend>? userFriends = await getAllUserFriendsFromFirestore();
      if (userFriends != null) {
        _userFriends = userFriends;
      }

      // Load local phone contacts
      await _loadLocalContacts();

      // Initial filter ToDo - not sure if this required
      _filterContacts();

      setState(() => _isLoading = false);
    } catch (e, stackTrace) {
      print('Error loading contacts: $e $stackTrace');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadLocalContacts() async {
    try {
      // Request permission
      if (!await FlutterContacts.requestPermission()) {
        setState(() => _permissionDenied = true);
        return;
      }

      // Get all contacts with phone numbers
      final contacts = await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: false,
      );

      List<LocalContact> localContacts = [];
      for (var contact in contacts) {
        if (contact.phones.isNotEmpty) {
          final phoneNumber = contact.phones.first.number;
          final normalizedPhone = _normalizePhoneNumber(phoneNumber);

          localContacts.add(
            LocalContact(
              name: contact.displayName,
              phoneNumber: normalizedPhone,
            ),
          );
        }
      }

      // Sort alphabetically
      localContacts.sort((a, b) => a.name.compareTo(b.name));

      _localContacts = localContacts;
      print('Loaded ${_localContacts.length} local contacts');
    } catch (e, stackTrace) {
      print('Error loading local contacts: $e, $stackTrace');
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
    if (!phone.startsWith('+')) {
      return '+$digits';
    }

    return phone;
  }

  void _filterContacts() async {
    final query = _searchController.text.trim();

    if (query.isEmpty) {
      // Show all contacts: friends first, then local
      setState(() {
        _filteredContacts = [
          ..._userFriends.map((f) => SelectableContact.fromUserFriend(f)),
          ..._localContacts.map((c) => SelectableContact.fromLocalContact(c)),
        ];
        _publicInfoResult = null;
      });
      return;
    }

    final isNumeric = RegExp(r'^\d+$').hasMatch(query);

    if (isNumeric) {
      // Filter only local contacts by phone number
      final filtered = _localContacts
          .where((c) => c.phoneNumber.contains(query))
          .map((c) => SelectableContact.fromLocalContact(c))
          .toList();

      setState(() {
        _filteredContacts = filtered;
        _publicInfoResult = null;
      });
    } else {
      // Filter by name (local) and kilvishId (friends)
      final queryLower = query.toLowerCase();

      final filteredFriends = _userFriends
          .where(
            (f) =>
                (f.kilvishId?.toLowerCase().contains(queryLower) ?? false) ||
                (f.name?.toLowerCase().contains(queryLower) ?? false),
          )
          .map((f) => SelectableContact.fromUserFriend(f))
          .toList();

      final filteredLocal = _localContacts
          .where((c) => c.name.toLowerCase().contains(queryLower))
          .map((c) => SelectableContact.fromLocalContact(c))
          .toList();

      // Combine: friends first, then local
      final combined = [...filteredFriends, ...filteredLocal];

      setState(() {
        _filteredContacts = combined;
      });

      // If no results and query is alphabetic, search publicInfo
      if (combined.isEmpty && !isNumeric) {
        await _searchPublicInfo(query);
      } else {
        setState(() => _publicInfoResult = null);
      }
    }
  }

  Future<void> _searchPublicInfo(String kilvishId) async {
    setState(() => _isSearchingPublicInfo = true);

    try {
      PublicUserInfo? publicUserInfo = await getPublicInfoUserFromKilvishId(
        kilvishId,
      );

      setState(() {
        _publicInfoResult = publicUserInfo;
        _isSearchingPublicInfo = false;
      });
    } catch (e, stackTrace) {
      print('Error searching publicInfo: $e $stackTrace');
      setState(() => _isSearchingPublicInfo = false);
    }
  }

  void _toggleContact(SelectableContact contact) {
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

  Future<void> _done() async {
    if (_selectedContacts.isEmpty && mounted) {
      showError(context, 'Please select at least one contact');
      return;
    }

    setState(() => _isLoading = true);

    try {
      if (mounted) {
        Navigator.pop(context, _selectedContacts);
      }
    } catch (e, stackTrace) {
      print('Error processing selected contacts: $e $stackTrace');
      if (mounted) showError(context, 'Failed to process contacts');
      setState(() => _isLoading = false);
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
                      hintText: 'Search by name, phone, or Kilvish ID...',
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
                Expanded(child: _buildContactsList()),
              ],
            ),
      bottomNavigationBar: _selectedContacts.isNotEmpty
          ? BottomAppBar(child: renderMainBottomButton('Done', _done))
          : null,
    );
  }

  Widget _buildContactsList() {
    if (_isSearchingPublicInfo) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: primaryColor),
            SizedBox(height: 16),
            Text(
              'Searching for Kilvish user...',
              style: TextStyle(color: kTextMedium),
            ),
          ],
        ),
      );
    }

    if (_filteredContacts.isEmpty && _publicInfoResult == null) {
      return Center(
        child: Text(
          'No contacts found',
          style: TextStyle(color: inactiveColor, fontSize: defaultFontSize),
        ),
      );
    }

    return ListView.builder(
      itemCount: _filteredContacts.length + (_publicInfoResult != null ? 1 : 0),
      itemBuilder: (context, index) {
        // Show publicInfo result first if available
        if (_publicInfoResult != null && index == 0) {
          final contact = SelectableContact.fromPublicInfo(_publicInfoResult!);
          return _buildContactTile(contact);
        }

        final contactIndex = _publicInfoResult != null ? index - 1 : index;
        final contact = _filteredContacts[contactIndex];
        return _buildContactTile(contact);
      },
    );
  }

  Widget _buildContactTile(SelectableContact contact) {
    final isSelected = _selectedContacts.contains(contact);
    final hasKilvishId = contact.hasKilvishId;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: hasKilvishId ? primaryColor : inactiveColor,
        child: Text(
          contact.displayName.isNotEmpty
              ? contact.displayName[0].toUpperCase()
              : '?',
          style: TextStyle(color: kWhitecolor, fontWeight: FontWeight.bold),
        ),
      ),
      title: Text(
        contact.displayName,
        style: TextStyle(
          fontSize: defaultFontSize,
          color: kTextColor,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (contact.subtitle != null)
            Text(
              contact.subtitle!,
              style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
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
          ? Icon(Icons.check_circle, color: primaryColor)
          : Icon(Icons.circle_outlined, color: inactiveColor),
      onTap: () => _toggleContact(contact),
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
                await _loadAllContacts();
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

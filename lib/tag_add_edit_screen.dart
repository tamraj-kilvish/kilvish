import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/contact_screen.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/style.dart';
import 'package:kilvish/firestore.dart';
import 'dart:developer';

class TagAddEditScreen extends StatefulWidget {
  final Tag? tag;

  const TagAddEditScreen({Key? key, this.tag}) : super(key: key);

  @override
  State<TagAddEditScreen> createState() => _TagAddEditScreenState();
}

class _TagAddEditScreenState extends State<TagAddEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _tagNameController = TextEditingController();

  Set<ContactModel> _sharedWithContacts = {};
  bool _isLoading = false;

  final FirebaseFirestore _firestore = FirebaseFirestore.instanceFor(
    app: Firebase.app(),
    databaseId: 'kilvish',
  );

  @override
  void initState() {
    super.initState();
    if (widget.tag != null) {
      _tagNameController.text = widget.tag!.name;
      _loadSharedUsers();
    }
  }

  @override
  void dispose() {
    _tagNameController.dispose();
    super.dispose();
  }

  Future<void> _loadSharedUsers() async {
    if (widget.tag == null) return;

    setState(() => _isLoading = true);

    try {
      Set<ContactModel> contacts = {};

      for (String userId in widget.tag!.sharedWith) {
        final userDoc = await _firestore.collection('Users').doc(userId).get();
        if (userDoc.exists) {
          final userData = userDoc.data();
          if (userData != null) {
            contacts.add(
              ContactModel(
                name: userData['kilvishId'] ?? 'Unknown',
                phoneNumber: userData['phone'] ?? '',
                kilvishId: userData['kilvishId'],
              ),
            );
          }
        }
      }

      setState(() {
        _sharedWithContacts = contacts;
        _isLoading = false;
      });
    } catch (e) {
      log('Error loading shared users: $e', error: e);
      setState(() => _isLoading = false);
    }
  }

  Future<void> _selectContacts() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ContactScreen(contactSelection: ContactSelection.multiSelect),
      ),
    );

    if (result != null && result is List<ContactModel>) {
      setState(() {
        // Add new contacts to the set
        _sharedWithContacts.addAll(result);
      });
    }
  }

  void _removeContact(ContactModel contact) {
    setState(() {
      _sharedWithContacts.remove(contact);
    });
  }

  Future<void> _saveTag() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final userId = await getUserIdFromClaim();
      if (userId == null) {
        throw Exception('User not authenticated');
      }

      // Get user IDs from contacts
      List<String> sharedWithUserIds = [];
      for (var contact in _sharedWithContacts) {
        String? foundUserId;

        if (contact.kilvishId != null) {
          // Find user by kilvishId
          final userQuery = await _firestore
              .collection('Users')
              .where('kilvishId', isEqualTo: contact.kilvishId)
              .limit(1)
              .get();

          if (userQuery.docs.isNotEmpty) {
            foundUserId = userQuery.docs.first.id;
          }
        }

        // If not found by kilvishId, try by phone
        if (foundUserId == null && contact.phoneNumber.isNotEmpty) {
          final userQuery = await _firestore
              .collection('Users')
              .where('phone', isEqualTo: contact.phoneNumber)
              .limit(1)
              .get();

          if (userQuery.docs.isNotEmpty) {
            foundUserId = userQuery.docs.first.id;
          } else {
            // User doesn't exist - create placeholder user document
            try {
              final newUserRef = _firestore.collection('Users').doc();
              await newUserRef.set({
                'phone': contact.phoneNumber,
                'createdAt': FieldValue.serverTimestamp(),
                'accessibleTagIds': [],
                'unseenExpenseIds': [],
              });
              foundUserId = newUserRef.id;
              log(
                'Created new user document for ${contact.phoneNumber}: $foundUserId',
              );
            } catch (e) {
              log('Error creating user document: $e');
            }
          }
        }

        if (foundUserId != null) {
          sharedWithUserIds.add(foundUserId);
        }
      }

      final tagData = {
        'name': _tagNameController.text.trim(),
        'sharedWith': sharedWithUserIds,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (widget.tag != null) {
        // Update existing tag
        await _firestore.collection('Tags').doc(widget.tag!.id).update(tagData);
        _showSuccess('Tag updated successfully');
      } else {
        // Create new tag
        tagData['ownerId'] = userId;
        tagData['createdAt'] = FieldValue.serverTimestamp();
        tagData['totalAmountTillDate'] = 0;
        tagData['monthWiseTotal'] = {};

        await _firestore.collection('Tags').add(tagData);
        _showSuccess('Tag created successfully');
      }

      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      log('Error saving tag: $e', error: e);
      _showError('Failed to save tag');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.tag != null;

    return Scaffold(
      backgroundColor: kWhitecolor,
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: appBarTitleText(isEditing ? 'Edit Tag' : 'Add Tag'),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: kWhitecolor),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: primaryColor))
          : Form(
              key: _formKey,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Tag Name
                    renderPrimaryColorLabel(text: 'Tag Name'),
                    SizedBox(height: 8),
                    TextFormField(
                      controller: _tagNameController,
                      decoration: customUnderlineInputdecoration(
                        hintText: 'e.g., Household, Office, Travel',
                        bordersideColor: primaryColor,
                      ),
                      validator: (value) {
                        if (value?.isEmpty ?? true) {
                          return 'Please enter tag name';
                        }
                        return null;
                      },
                    ),
                    SizedBox(height: 24),

                    // Shared With Section
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        renderPrimaryColorLabel(text: 'Shared With'),
                        customContactUi(onTap: _selectContacts),
                      ],
                    ),
                    SizedBox(height: 8),
                    renderHelperText(
                      text: 'Select contacts to share this tag with',
                    ),
                    SizedBox(height: 12),

                    // Shared contacts display
                    _buildSharedContactsSection(),
                  ],
                ),
              ),
            ),
      bottomNavigationBar: BottomAppBar(
        child: renderMainBottomButton(
          isEditing ? 'Update Tag' : 'Create Tag',
          _isLoading ? null : _saveTag,
          !_isLoading,
        ),
      ),
    );
  }

  Widget _buildSharedContactsSection() {
    if (_sharedWithContacts.isEmpty) {
      return Container(
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: tileBackgroundColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            'No contacts selected',
            style: TextStyle(color: inactiveColor, fontSize: smallFontSize),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _sharedWithContacts.map((contact) {
        return Chip(
          backgroundColor: primaryColor.withOpacity(0.1),
          label: Text(
            contact.kilvishId ?? contact.name,
            style: TextStyle(color: primaryColor, fontSize: smallFontSize),
          ),
          deleteIcon: Icon(Icons.close, size: 18, color: primaryColor),
          onDeleted: () => _removeContact(contact),
        );
      }).toList(),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: errorcolor),
    );
  }
}

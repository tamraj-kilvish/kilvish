import 'package:flutter/material.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/contact_screen.dart';
import 'package:kilvish/firestore/tags.dart';
import 'package:kilvish/firestore/user.dart';
import 'package:kilvish/models/tags.dart';
import 'package:kilvish/models/user.dart';
import 'package:kilvish/style.dart';

class TagAddEditScreen extends StatefulWidget {
  Tag? tag;

  TagAddEditScreen({super.key, this.tag});

  @override
  State<TagAddEditScreen> createState() => _TagAddEditScreenState();
}

class _TagAddEditScreenState extends State<TagAddEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _tagNameController = TextEditingController();

  Set<SelectableContact> _sharedWithContacts = {};
  Set<SelectableContact> _sharedWithContactsInDB = {};

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    if (widget.tag != null) {
      print("Dumping tag name ${widget.tag!.name}");
      _tagNameController.text = widget.tag!.name;
      _loadUsersTagIsSharedWith();
    }
  }

  @override
  void dispose() {
    _tagNameController.dispose();
    super.dispose();
  }

  Future<void> _loadUsersTagIsSharedWith() async {
    if (widget.tag == null) return;

    setState(() => _isLoading = true);

    try {
      List<UserFriend>? userFriends = await getAllUserFriendsFromFirestore();
      if (userFriends == null || userFriends.isEmpty) {
        print("No user friends found");
        setState(() {
          _isLoading = false;
        });
        return;
      }

      for (UserFriend userFriend in userFriends) {
        if (widget.tag!.sharedWithFriends.contains(userFriend.id)) {
          _sharedWithContactsInDB.add(SelectableContact.fromUserFriend(userFriend));
        }
      }
      print("Dumping _sharedWithContactsInDB: ");
      _sharedWithContactsInDB.forEach((SelectableContact contact) => print(contact));

      setState(() {
        _sharedWithContacts.addAll(_sharedWithContactsInDB);
        _isLoading = false;
      });
    } catch (e, stackTrace) {
      print('Error loading shared users: $e $stackTrace');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _selectContacts() async {
    // if (widget.tag == null && mounted) {
    //   //Ideally user should not come to here at all
    //   showInfo(context, 'Please save the expense first before adding tags');
    //   return;
    // }
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ContactScreen(contactSelection: ContactSelection.multiSelect, sharedWithContacts: _sharedWithContacts),
      ),
    );

    if (result != null && result is Set<SelectableContact>) {
      setState(() {
        _sharedWithContacts = result;
      });
    }
  }

  void _removeContact(SelectableContact contact) {
    setState(() {
      _sharedWithContacts.remove(contact);
    });
  }

  Future<void> _saveTag() async {
    if (!_formKey.currentState!.validate()) return;

    final userId = await getUserIdFromClaim();
    if (userId == null) {
      throw Exception('User not authenticated');
    }

    setState(() => _isLoading = true);

    try {
      Tag? tag = widget.tag;

      final Map<String, Object> tagData = {'name': _tagNameController.text.trim()};

      // if (_sharedWithContacts.isEmpty) {
      //   tag = await createOrUpdateTag(tagData, tag?.id);
      //   if (mounted) {
      //     showSuccess(context, widget.tag == null ? 'Tag created successfully' : 'Tag updated successfully');
      //     Navigator.pop(context, tag);
      //     return;
      //   }
      // }

      List<UserFriend> tagSharedWithList = [];

      for (var contact in _sharedWithContacts) {
        switch (contact.type) {
          case ContactType.userFriend:
            tagSharedWithList.add(contact.userFriend!);
            break;

          case ContactType.localContact:
            final localContact = contact.localContact!;

            // Check if friend with same phone already exists
            UserFriend? friend =
                await getUserFriendWithGivenPhoneNumber(localContact.phoneNumber) ?? await addUserFriendFromContact(localContact);

            tagSharedWithList.add(friend!);
            break;

          case ContactType.publicInfo:
            UserFriend? friend = await addFriendFromPublicInfoIfNotExist(contact.publicInfo!);
            tagSharedWithList.add(friend!);
            break;
        }
      }
      tagData['sharedWithFriends'] = tagSharedWithList.map((userFriend) => userFriend.id).toList();

      tag = await createOrUpdateTag(tagData, tag?.id);

      if (mounted) {
        showSuccess(context, widget.tag != null ? 'Tag updated successfully' : 'Tag created successfully');
        Navigator.pop(context, tag);
      }
    } catch (e, stackTrace) {
      print('Error saving tag: $e $stackTrace');
      if (mounted) showError(context, 'Failed to save changes');
    } finally {
      setState(() => _isLoading = false);
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
                    renderHelperText(text: 'Select contacts to share this tag with'),
                    SizedBox(height: 12),

                    // Shared contacts display
                    _buildSharedContactsSection(),
                  ],
                ),
              ),
            ),
      bottomNavigationBar: BottomAppBar(
        child: renderMainBottomButton(isEditing ? 'Update Tag' : 'Create Tag', _isLoading ? null : _saveTag, !_isLoading),
      ),
    );
  }

  Widget _buildSharedContactsSection() {
    if (_sharedWithContacts.isEmpty) {
      return Container(
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(color: tileBackgroundColor, borderRadius: BorderRadius.circular(8)),
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
            contact.displayName,
            style: TextStyle(color: primaryColor, fontSize: smallFontSize),
          ),
          deleteIcon: Icon(Icons.close, size: 18, color: primaryColor),
          onDeleted: () => _removeContact(contact),
        );
      }).toList(),
    );
  }
}

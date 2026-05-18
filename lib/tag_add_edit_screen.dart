import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:kilvish/app_constants.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/contact_screen.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/style.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:share_plus/share_plus.dart';

// Unified display model for all tag participants.
// [userId] is null for contacts added via picker but not yet saved to Firestore.
// [contact] is set for pending-add participants so they can be removed from _sharedWithContacts.
class _TagParticipant {
  final String? userId;
  final String displayName;
  final String? phoneNumber;
  final SelectableContact? contact; // non-null when pending add (not yet in sharedWith)

  _TagParticipant({this.userId, required this.displayName, this.phoneNumber, this.contact});
}

class TagAddEditScreen extends StatefulWidget {
  Tag? tag;

  TagAddEditScreen({super.key, this.tag});

  @override
  State<TagAddEditScreen> createState() => _TagAddEditScreenState();
}

class _TagAddEditScreenState extends State<TagAddEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _tagNameController = TextEditingController();

  // Used for save flow (builds sharedWithFriends). Owner only.
  Set<SelectableContact> _sharedWithContacts = {};
  Set<SelectableContact> _sharedWithContactsInDB = {};

  // Unified display list — everyone in sharedWith + pending adds.
  List<_TagParticipant> _participants = [];

  bool _isLoading = false;
  bool _isParticipantsLoading = true;
  bool _dontShowOutstanding = false;
  bool _isOwner = false;
  String? _savedTagId;
  String? _currentUserId;

  @override
  void initState() {
    super.initState();
    if (widget.tag != null) {
      _tagNameController.text = widget.tag!.name;
      _dontShowOutstanding = widget.tag!.dontShowOutstanding;
      _savedTagId = widget.tag!.id;
    }
    _loadParticipants();
  }

  @override
  void dispose() {
    _tagNameController.dispose();
    super.dispose();
  }

  Future<void> _loadParticipants() async {
    _currentUserId = await getUserIdFromClaim();

    if (widget.tag == null) {
      // Creating a new tag — no participants yet, owner by definition.
      if (mounted) setState(() { _isOwner = true; _isParticipantsLoading = false; });
      return;
    }

    _isOwner = widget.tag!.ownerId == _currentUserId;

    // Owner: also populate _sharedWithContacts for the save flow.
    if (_isOwner) _loadUsersTagIsSharedWith();

    try {
      final participants = <_TagParticipant>[];
      for (final userId in widget.tag!.sharedWith) {
        if (userId == widget.tag!.ownerId) continue;
        final friend = await getFriendByUserId(widget.tag!.ownerId, userId);
        if (friend != null) {
          participants.add(_TagParticipant(
            userId: userId,
            displayName: friend.name ?? friend.kilvishId ?? userId,
            phoneNumber: friend.phoneNumber,
          ));
        } else {
          final kilvishId = await getUserKilvishId(userId) ?? userId;
          participants.add(_TagParticipant(userId: userId, displayName: kilvishId));
        }
      }
      if (mounted) setState(() { _participants = participants; _isParticipantsLoading = false; });
    } catch (e) {
      print('Error loading participants: $e');
      if (mounted) setState(() => _isParticipantsLoading = false);
    }
  }

  // Populates _sharedWithContacts from sharedWithFriends for the owner save flow.
  Future<void> _loadUsersTagIsSharedWith() async {
    if (widget.tag == null) return;
    try {
      final userFriends = await getAllUserFriendsFromFirestore();
      if (userFriends == null || userFriends.isEmpty) return;
      for (final userFriend in userFriends) {
        if (widget.tag!.sharedWithFriends.contains(userFriend.id)) {
          _sharedWithContactsInDB.add(SelectableContact.fromUserFriend(userFriend));
        }
      }
      if (mounted) setState(() => _sharedWithContacts.addAll(_sharedWithContactsInDB));
    } catch (e) {
      print('Error loading sharedWithContacts: $e');
    }
  }

  Future<void> _selectContacts() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ContactScreen(contactSelection: ContactSelection.multiSelect, sharedWithContacts: _sharedWithContacts),
      ),
    );

    if (result == null || result is! Set<SelectableContact>) return;

    final added = result.difference(_sharedWithContacts);
    final removed = _sharedWithContacts.difference(result);

    setState(() {
      _sharedWithContacts = result;

      // Add new contacts to the participant display list.
      for (final contact in added) {
        String? userId;
        String displayName = contact.displayName;
        String? phoneNumber;

        if (contact.type == ContactType.userFriend) {
          userId = contact.userFriend!.kilvishUserId;
          phoneNumber = contact.userFriend!.phoneNumber;
        } else if (contact.type == ContactType.localContact) {
          phoneNumber = contact.localContact!.phoneNumber;
        } else if (contact.type == ContactType.publicInfo) {
          userId = contact.publicInfo!.userId;
        }

        // Avoid duplicating a participant already loaded from sharedWith.
        if (userId != null && _participants.any((p) => p.userId == userId)) continue;

        _participants.add(_TagParticipant(
          userId: userId,
          displayName: displayName,
          phoneNumber: phoneNumber,
          contact: contact,
        ));
      }

      // Remove contacts deselected in the picker from the display list.
      for (final contact in removed) {
        _participants.removeWhere((p) => p.contact == contact);
      }
    });
  }

  Future<void> _removeParticipant(_TagParticipant p) async {
    if (p.userId != null) {
      // Already in Firestore — remove server-side.
      try {
        await removeTagMemberCallable(widget.tag!.id, p.userId!);
      } catch (e) {
        if (mounted) showError(context, 'Failed to remove participant');
        return;
      }
    }
    setState(() {
      _participants.remove(p);
      // Keep _sharedWithContacts in sync so save doesn't re-add them.
      if (p.contact != null) _sharedWithContacts.remove(p.contact);
      if (p.userId != null) {
        _sharedWithContacts.removeWhere(
          (c) => c.type == ContactType.userFriend && c.userFriend?.kilvishUserId == p.userId,
        );
      }
    });
  }

  Future<void> _leaveTag() async {
    try {
      await removeTagMemberCallable(widget.tag!.id, _currentUserId!);
      await CacheManager.removeTag(widget.tag!.id);
      if (mounted) context.go('/home');
    } catch (e) {
      if (mounted) showError(context, 'Failed to leave tag');
    }
  }

  Future<void> _shareTagLink(String tagId) async {
    final link = '$kWebBaseUrl/tags/$tagId';
    if (kIsWeb) {
      await Clipboard.setData(ClipboardData(text: link));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invite link copied to clipboard')),
        );
      }
      return;
    }
    await Share.share(link, subject: 'Join my Kilvish tag');
  }

  Future<void> _saveTag() async {
    if (!_formKey.currentState!.validate()) return;

    final userId = await getUserIdFromClaim();
    if (userId == null) throw Exception('User not authenticated');

    setState(() => _isLoading = true);

    try {
      Tag? tag = widget.tag;
      final Map<String, Object> tagData = {'name': _tagNameController.text.trim()};

      List<UserFriend> tagSharedWithList = [];
      for (var contact in _sharedWithContacts) {
        switch (contact.type) {
          case ContactType.userFriend:
            tagSharedWithList.add(contact.userFriend!);
            break;
          case ContactType.localContact:
            final localContact = contact.localContact!;
            UserFriend? friend =
                await getUserFriendWithGivenPhoneNumber(localContact.phoneNumber) ??
                await addUserFriendFromContact(localContact);
            tagSharedWithList.add(friend!);
            break;
          case ContactType.publicInfo:
            UserFriend? friend = await addFriendFromPublicInfoIfNotExist(contact.publicInfo!);
            tagSharedWithList.add(friend!);
            break;
        }
      }
      tagData['sharedWithFriends'] = tagSharedWithList.map((f) => f.id).toList();
      tagData['dontShowOutstanding'] = _dontShowOutstanding;

      tag = await createOrUpdateTag(tagData, tag?.id);
      await CacheManager.addOrUpdateTag(tag!);

      if (mounted) {
        setState(() => _savedTagId = tag!.id);
        showSuccess(context, widget.tag != null ? 'Tag updated successfully' : 'Tag created successfully');
        Navigator.pop(context, {"operation": widget.tag != null ? "update" : "create", "tag": tag});
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
        title: appBarTitleText(_isOwner ? (isEditing ? 'Edit Tag' : 'Add Tag') : 'Tag Details'),
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
                    if (_isOwner)
                      TextFormField(
                        controller: _tagNameController,
                        decoration: customUnderlineInputdecoration(
                          hintText: 'e.g., Household, Office, Travel',
                          bordersideColor: primaryColor,
                        ),
                        validator: (value) {
                          if (value?.isEmpty ?? true) return 'Please enter tag name';
                          return null;
                        },
                      )
                    else
                      Text(
                        _tagNameController.text,
                        style: TextStyle(fontSize: defaultFontSize, color: kTextDark),
                      ),
                    SizedBox(height: 24),

                    // Participants section
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        renderPrimaryColorLabel(text: 'Participants'),
                        if (_isOwner) customContactUi(onTap: _selectContacts),
                      ],
                    ),
                    SizedBox(height: 8),
                    if (_isOwner)
                      renderHelperText(text: 'Select contacts to share this tag with'),
                    SizedBox(height: 12),
                    _buildParticipantsSection(),
                    SizedBox(height: 24),

                    // Invite link (owner only, once tag is saved)
                    if (_isOwner && _savedTagId != null) ...[
                      SizedBox(height: 24),
                      renderPrimaryColorLabel(text: 'Invite Link'),
                      SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '$kWebBaseUrl/tags/$_savedTagId',
                              style: TextStyle(color: kTextMedium, fontSize: smallFontSize),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () => _shareTagLink(_savedTagId!),
                            icon: Icon(Icons.share, color: primaryColor),
                            label: Text('Share', style: TextStyle(color: primaryColor)),
                          ),
                        ],
                      ),
                      SizedBox(height: 12),
                    ],

                    // Hide Outstanding
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      activeColor: primaryColor,
                      title: Text('Hide Outstanding', style: TextStyle(fontSize: defaultFontSize)),
                      subtitle: Text(
                        'Don\'t show outstanding/recovery data for this tag',
                        style: TextStyle(fontSize: smallFontSize, color: inactiveColor),
                      ),
                      value: _dontShowOutstanding,
                      onChanged: _isOwner ? (v) => setState(() => _dontShowOutstanding = v ?? false) : null,
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  ],
                ),
              ),
            ),
      bottomNavigationBar: BottomAppBar(
        child: _isOwner
            ? renderMainBottomButton(isEditing ? 'Update Tag' : 'Create Tag', _isLoading ? null : _saveTag)
            : renderMainBottomButton('Leave Tag', _isLoading ? null : _leaveTag),
      ),
    );
  }

  Widget _buildParticipantsSection() {
    if (_isParticipantsLoading) {
      return Center(child: CircularProgressIndicator(color: primaryColor));
    }
    if (_participants.isEmpty) {
      return Container(
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(color: tileBackgroundColor, borderRadius: BorderRadius.circular(8)),
        child: Center(
          child: Text(
            'No other participants',
            style: TextStyle(color: inactiveColor, fontSize: smallFontSize),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _participants.map((p) {
        final label = p.phoneNumber != null ? '${p.displayName}\n${p.phoneNumber}' : p.displayName;
        return Chip(
          backgroundColor: primaryColor.withOpacity(0.1),
          label: Text(label, style: TextStyle(color: primaryColor, fontSize: smallFontSize)),
          deleteIcon: _isOwner ? Icon(Icons.close, size: 18, color: primaryColor) : null,
          onDeleted: _isOwner ? () => _removeParticipant(p) : null,
        );
      }).toList(),
    );
  }
}

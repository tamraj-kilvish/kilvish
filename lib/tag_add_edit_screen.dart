import 'package:cloud_firestore/cloud_firestore.dart';
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

// Screen-level participant wrapper — holds a TagParticipant (persisted) plus an optional
// contact for contacts added via picker that are not yet saved to Firestore.
class _TagParticipant {
  final String? userId; // null only for unregistered local contacts pending add
  final String displayName;
  final String? phoneNumber;
  final SelectableContact? contact; // set for all participants enriched via Friends or pending adds

  _TagParticipant({this.userId, required this.displayName, this.phoneNumber, this.contact});

  // Build from a persisted TagParticipant (already in tag.sharedWith)
  factory _TagParticipant.fromModel(TagParticipant p) =>
      _TagParticipant(userId: p.userId, displayName: p.displayName, phoneNumber: p.phoneNumber, contact: p.contact);
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

  // Unified display list — everyone in sharedWith (from tag.participants) + pending picker adds.
  List<_TagParticipant> _participants = [];

  // UserIds of persisted participants (originally in tag.sharedWith) removed via X button.
  // Applied via FieldValue.arrayRemove on save for share-link joiners not in sharedWithFriends.
  Set<String> _removedUserIds = {};

  bool _isLoading = false;
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
      // Sync init — participants already loaded into Tag model, no spinner needed
      _participants = widget.tag!.participants.map<_TagParticipant>((p) => _TagParticipant.fromModel(p)).toList();
    }
    _initOwnerState();
  }

  @override
  void dispose() {
    _tagNameController.dispose();
    super.dispose();
  }

  Future<void> _initOwnerState() async {
    _currentUserId = await getUserIdFromClaim();
    final isOwner = widget.tag == null || widget.tag!.ownerId == _currentUserId;
    if (mounted) setState(() => _isOwner = isOwner);
  }

  // Current contacts derived from _participants — used as pre-selection in ContactScreen.
  Set<SelectableContact> get _currentParticipantContacts =>
      _participants.where((p) => p.contact != null).map((p) => p.contact!).toSet();

  Future<void> _selectContacts() async {
    final preSelected = _currentParticipantContacts;
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ContactScreen(contactSelection: ContactSelection.multiSelect, sharedWithContacts: preSelected),
      ),
    );

    if (result == null || result is! Set<SelectableContact>) return;

    final added = result.difference(preSelected);
    final removed = preSelected.difference(result);

    setState(() {
      // Add newly selected contacts to participant list
      for (final contact in added) {
        String? userId;
        String? phoneNumber;

        if (contact.type == ContactType.userFriend) {
          userId = contact.userFriend!.kilvishUserId;
          phoneNumber = contact.userFriend!.phoneNumber;
        } else if (contact.type == ContactType.localContact) {
          phoneNumber = contact.localContact!.phoneNumber;
        } else if (contact.type == ContactType.publicInfo) {
          userId = contact.publicInfo!.userId;
        }

        // Avoid duplicating a participant already in the list
        if (userId != null && _participants.any((p) => p.userId == userId)) continue;

        _participants.add(
          _TagParticipant(userId: userId, displayName: contact.displayName, phoneNumber: phoneNumber, contact: contact),
        );
      }

      // Remove deselected contacts — pure UI, tracked via _removedUserIds if persisted
      for (final contact in removed) {
        final idx = _participants.indexWhere((p) => p.contact == contact);
        if (idx == -1) continue;
        final p = _participants[idx];
        // If this participant was already in sharedWith, track for arrayRemove on save
        if (p.userId != null && (widget.tag?.sharedWith.contains(p.userId) ?? false)) {
          _removedUserIds.add(p.userId!);
        }
        _participants.removeAt(idx);
      }
    });
  }

  // Pure UI removal — no immediate server call.
  // Tracks userId in _removedUserIds if the participant was already persisted in sharedWith.
  void _removeParticipant(_TagParticipant p) {
    setState(() {
      _participants.remove(p);
      if (p.userId != null && (widget.tag?.sharedWith.contains(p.userId) ?? false)) {
        _removedUserIds.add(p.userId!);
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invite link copied to clipboard')));
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

      // Build sharedWithFriends — complete replacement covering all participants with contacts.
      // For localContact / publicInfo: register as UserFriend first, then collect their doc ID.
      final List<String> sharedWithFriendIds = [];
      for (final p in _participants) {
        final contact = p.contact;
        if (contact == null) continue; // share-link joiner — not a friend, handled via sharedWith
        switch (contact.type) {
          case ContactType.userFriend:
            sharedWithFriendIds.add(contact.userFriend!.id);
          case ContactType.localContact:
            UserFriend? friend =
                await getUserFriendWithGivenPhoneNumber(contact.localContact!.phoneNumber) ??
                await addUserFriendFromContact(contact.localContact!);
            if (friend != null) sharedWithFriendIds.add(friend.id);
          case ContactType.publicInfo:
            UserFriend? friend = await addFriendFromPublicInfoIfNotExist(contact.publicInfo!);
            if (friend != null) sharedWithFriendIds.add(friend.id);
        }
      }

      tagData['sharedWithFriends'] = sharedWithFriendIds;
      tagData['dontShowOutstanding'] = _dontShowOutstanding;

      // arrayRemove any explicitly removed participants from sharedWith.
      // Covers share-link joiners (not in sharedWithFriends) removed via X button.
      // Friends removed via X are also absent from sharedWithFriends above, so the server's
      // _handleTagSharingChanges will remove them from sharedWith too — arrayRemove is idempotent.
      if (_removedUserIds.isNotEmpty) {
        tagData['sharedWith'] = FieldValue.arrayRemove(_removedUserIds.toList());
      }

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
                        style: TextStyle(fontSize: defaultFontSize, color: kTextColor),
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
                    if (_isOwner) renderHelperText(text: 'Select contacts to share this tag with'),
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
          label: Text(
            label,
            style: TextStyle(color: primaryColor, fontSize: smallFontSize),
          ),
          deleteIcon: _isOwner ? Icon(Icons.close, size: 18, color: primaryColor) : null,
          onDeleted: _isOwner ? () => _removeParticipant(p) : null,
        );
      }).toList(),
    );
  }
}

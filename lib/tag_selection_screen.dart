import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:kilvish/style.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/tag_add_edit_screen.dart';
import 'dart:developer';

class TagSelectionScreen extends StatefulWidget {
  final Set<Tag> initialSelectedTags;
  final String expenseId;

  const TagSelectionScreen({
    Key? key,
    required this.initialSelectedTags,
    required this.expenseId,
  }) : super(key: key);

  @override
  State<TagSelectionScreen> createState() => _TagSelectionScreenState();
}

class _TagSelectionScreenState extends State<TagSelectionScreen> {
  Set<Tag> _attachedTags = {};
  Set<Tag> _attachedTagsOriginal = {};
  Set<Tag> _allTags = {};
  Set<Tag> _unselectedTags = {};

  Set<Tag> _attachedTagsFiltered = {};
  Set<Tag> _unselectedTagsFiltered = {};

  // Map of modified tags to show user what has changed
  Map<Tag, TagStatus> _modifiedTags = {};

  final TextEditingController _searchController = TextEditingController();
  bool _isLoading = true;

  final FirebaseFirestore _firestore = FirebaseFirestore.instanceFor(
    app: Firebase.app(),
    databaseId: 'kilvish',
  );

  @override
  void initState() {
    super.initState();
    _attachedTags = Set.from(widget.initialSelectedTags);
    _attachedTagsOriginal = Set.from(widget.initialSelectedTags);

    _loadAllTags();

    _searchController.addListener(_filterTags);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAllTags() async {
    setState(() => _isLoading = true);

    try {
      final user = await getLoggedInUserData();
      if (user == null) {
        setState(() => _isLoading = false);
        return;
      }

      Set<Tag> tags = {};
      for (String tagId in user.accessibleTagIds) {
        final tag = await getTagData(tagId);
        tags.add(tag);
      }

      setState(() {
        _allTags = tags;
        _calculateRenderingTagValues();
        _isLoading = false;
      });
    } catch (e) {
      log('Error loading tags: $e', error: e);
      setState(() => _isLoading = false);
    }
  }

  void _calculateRenderingTagValues() {
    _attachedTagsFiltered = Set.from(_attachedTags);

    _unselectedTags = _allTags.difference(_attachedTags);

    // Show modified tags first, then unselected tags (limited to 10)
    _unselectedTagsFiltered = _modifiedTags.entries
        .where((entry) => entry.value == TagStatus.unselected)
        .map((entry) => entry.key)
        .toSet()
        .union(_unselectedTags)
        .take(10)
        .toSet();
  }

  void _filterTags() {
    String searchText = _searchController.text.trim().toLowerCase();

    setState(() {
      if (searchText.isEmpty) {
        _calculateRenderingTagValues();
        return;
      }

      _attachedTagsFiltered = _attachedTags
          .where((tag) => tag.name.toLowerCase().contains(searchText))
          .toSet();

      // Ensure modified tags are always visible
      _unselectedTagsFiltered = _modifiedTags.entries
          .where((entry) => entry.value == TagStatus.unselected)
          .map((entry) => entry.key)
          .toSet()
          .union(_unselectedTags)
          .where((tag) => tag.name.toLowerCase().contains(searchText))
          .take(10)
          .toSet();
    });
  }

  void _toggleTag(Tag tag, TagStatus currentStatus) {
    setState(() {
      _modifiedTags.remove(tag);

      if (currentStatus == TagStatus.selected) {
        // Remove from attached
        _attachedTags.remove(tag);
        if (_attachedTagsOriginal.contains(tag)) {
          _modifiedTags[tag] = TagStatus.unselected;
        }
      } else {
        // Add to attached
        _attachedTags.add(tag);
        if (!_attachedTagsOriginal.contains(tag)) {
          _modifiedTags[tag] = TagStatus.selected;
        }
      }

      _calculateRenderingTagValues();
    });
  }

  Future<void> _done() async {
    if (_modifiedTags.isEmpty) {
      Navigator.pop(context);
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Update expense in each modified tag
      for (var entry in _modifiedTags.entries) {
        final tag = entry.key;
        final status = entry.value;

        if (status == TagStatus.selected) {
          // Add expense to tag
          await _addExpenseToTag(tag.id);
        } else {
          // Remove expense from tag
          await _removeExpenseFromTag(tag.id);
        }
      }

      if (mounted) {
        _showSuccess('Tags updated successfully');
        Navigator.pop(context, _attachedTags);
      }
    } catch (e) {
      log('Error updating tags: $e', error: e);
      _showError('Failed to update tags');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addExpenseToTag(String tagId) async {
    try {
      final userId = await getUserIdFromClaim();
      if (userId == null) return;

      // Get the expense data from Users/{userId}/Expenses
      final expenseDoc = await _firestore
          .collection('Users')
          .doc(userId)
          .collection('Expenses')
          .doc(widget.expenseId)
          .get();

      if (!expenseDoc.exists) return;

      final expenseData = expenseDoc.data();
      if (expenseData == null) return;

      // Add expense to tag's Expenses subcollection
      await _firestore
          .collection('Tags')
          .doc(tagId)
          .collection('Expenses')
          .doc(widget.expenseId)
          .set(expenseData);

      log('Expense ${widget.expenseId} added to tag $tagId');
    } catch (e) {
      log('Error adding expense to tag: $e', error: e);
      rethrow;
    }
  }

  Future<void> _removeExpenseFromTag(String tagId) async {
    try {
      await _firestore
          .collection('Tags')
          .doc(tagId)
          .collection('Expenses')
          .doc(widget.expenseId)
          .delete();

      log('Expense ${widget.expenseId} removed from tag $tagId');
    } catch (e) {
      log('Error removing expense from tag: $e', error: e);
      rethrow;
    }
  }

  Future<void> _createNewTag() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => TagAddEditScreen()),
    );

    if (result == true) {
      // Reload tags
      await _loadAllTags();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kWhitecolor,
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: appBarSearchInput(controller: _searchController),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: kWhitecolor),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: primaryColor))
          : Container(
              margin: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Attached Tags Section
                  renderPrimaryColorLabel(text: 'Attached Tags'),
                  SizedBox(height: 8),
                  _renderTagGroup(
                    tags: _attachedTagsFiltered,
                    status: TagStatus.selected,
                  ),

                  SizedBox(height: 16),
                  Divider(height: 1),
                  SizedBox(height: 16),

                  // All Tags Section
                  renderPrimaryColorLabel(text: 'All Tags'),
                  SizedBox(height: 4),
                  renderHelperText(text: 'Only 10 tags are shown'),
                  SizedBox(height: 8),
                  _renderTagGroup(
                    tags: _unselectedTagsFiltered,
                    status: TagStatus.unselected,
                  ),
                ],
              ),
            ),
      bottomNavigationBar: BottomAppBar(
        child: renderMainBottomButton(
          'Done',
          _isLoading ? null : _done,
          !_isLoading,
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: primaryColor,
        onPressed: _createNewTag,
        child: Icon(Icons.add, color: kWhitecolor),
      ),
    );
  }

  Widget _renderTagGroup({
    required Set<Tag> tags,
    TagStatus status = TagStatus.unselected,
  }) {
    if (tags.isEmpty) {
      return Container(
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: tileBackgroundColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            status == TagStatus.selected
                ? '.. Nothing here ..'
                : 'No tags found',
            style: TextStyle(color: inactiveColor, fontSize: smallFontSize),
          ),
        ),
      );
    }

    return Wrap(
      direction: Axis.horizontal,
      crossAxisAlignment: WrapCrossAlignment.start,
      spacing: 5,
      runSpacing: 10,
      children: tags.map((tag) {
        return renderTag(
          text: tag.name,
          status: status,
          isUpdated: _modifiedTags.containsKey(tag),
          onPressed: () => _toggleTag(tag, status),
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

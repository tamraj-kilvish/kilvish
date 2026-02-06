import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/cache_manager.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/style.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/firestore.dart';
import 'dart:developer';

class TagSelectionScreen extends StatefulWidget {
  final BaseExpense expense;
  final Map<Tag, TagStatus> initialAttachments;
  final Map<Tag, SettlementEntry> initialSettlementData;

  const TagSelectionScreen({
    super.key,
    required this.expense,
    required this.initialAttachments,
    required this.initialSettlementData,
  });

  @override
  State<TagSelectionScreen> createState() => _TagSelectionScreenState();
}

class _TagSelectionScreenState extends State<TagSelectionScreen> {
  Map<Tag, TagStatus> _attachedTagsOriginal = {};
  Map<Tag, TagStatus> _currentTagStatus = {};
  Map<Tag, dynamic> _modifiedTags = {};
  Map<Tag, SettlementEntry> _settlementData = {};

  Tag? _expandedTag;

  Set<Tag> _allTags = {};

  Set<Tag> _allTagsFiltered = {};
  Set<Tag> _attachedTagsFiltered = {};

  final TextEditingController _searchController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _attachedTagsOriginal = Map.from(widget.initialAttachments);
    _currentTagStatus = Map.from(widget.initialAttachments);
    _settlementData = Map.from(widget.initialSettlementData);

    _loadAllTags().then((value) {
      setState(() {
        _allTagsFiltered = _allTags;
        _attachedTagsFiltered = _currentTagStatus.keys.toSet();
      });
      _searchController.addListener(_applyTagFiltering);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAllTags() async {
    try {
      _allTags = (await getUserTags()).toSet();
    } catch (e, stackTrace) {
      print('Error loading tags: $e, $stackTrace');
      setState(() => _isLoading = false);
    }
  }

  void _applyTagFiltering() {
    String searchText = _searchController.text.trim().toLowerCase();
    if (searchText.isEmpty) {
      _allTagsFiltered = _allTags;
      _attachedTagsFiltered = _currentTagStatus.keys.toSet();
      return;
    }

    _allTagsFiltered = _allTags.where((tag) => tag.name.toLowerCase().contains(searchText)).toSet();
    _attachedTagsFiltered = _currentTagStatus.keys.where((tag) => tag.name.toLowerCase().contains(searchText)).toSet();
  }

  void _updateModifiedTags(Tag tag) {
    if (_currentTagStatus[tag] == null && _attachedTagsOriginal[tag] != null) {
      _modifiedTags[tag] = TagStatus.unselected;
      return;
    }

    if (_currentTagStatus[tag] != null && _attachedTagsOriginal[tag] == null) {
      _modifiedTags[tag] = _currentTagStatus[tag];
      return;
    }

    //both are non null .. check if they are different
    if (_currentTagStatus[tag] != _attachedTagsOriginal[tag]) {
      _modifiedTags[tag] = _currentTagStatus[tag];
      return;
    }

    //none of the conditions matched .. both _currentTagStatus & _attachedTagsOriginal must be same
    _modifiedTags.remove(tag);
  }

  void _selectTag(Tag tag) {
    if (_currentTagStatus[tag] != null) return; //tag is already selected

    _currentTagStatus[tag] = TagStatus.expense; //default state .. user can change
    _expandedTag = tag;

    _updateModifiedTags(tag);
    _applyTagFiltering();

    setState(() {});
  }

  void _unselectTag(Tag tag) {
    if (_currentTagStatus[tag] == null) return; //tag is already selected

    _currentTagStatus.remove(tag);
    _settlementData.remove(tag);

    _updateModifiedTags(tag);
    _applyTagFiltering();

    setState(() {});
  }

  void _toggleSettlementMode(Tag tag, bool isSettlement) async {
    if (isSettlement) {
      // Switch to settlement mode
      final userId = await getUserIdFromClaim();
      if (userId == null) return;

      final tagUsers = [tag.ownerId, ...tag.sharedWith].where((id) => id != userId).toList();
      if (tagUsers.isEmpty) {
        if (mounted) showError(context, 'No other users in this tag for settlement');
        return;
      }

      final settlementDate = widget.expense.timeOfTransaction ?? DateTime.now();
      final settlement = SettlementEntry(
        to: tagUsers.first,
        month: settlementDate.month,
        year: settlementDate.year,
        tagId: tag.id,
      );

      setState(() {
        _currentTagStatus[tag] = TagStatus.settlement;
        _settlementData[tag] = settlement;
        _updateModifiedTags(tag);
      });
    } else {
      // Switch back to expense mode
      setState(() {
        _currentTagStatus[tag] = TagStatus.expense;
        _settlementData.remove(tag);
        _updateModifiedTags(tag);
      });
    }
  }

  void _updateSettlementPeriod(Tag tag, int monthDelta) {
    final current = _settlementData[tag];
    if (current == null) return;

    DateTime date = DateTime(current.year, current.month);
    date = DateTime(date.year, date.month + monthDelta);

    setState(() {
      _settlementData[tag] = SettlementEntry(to: current.to, month: date.month, year: date.year, tagId: current.tagId);
      _modifiedTags[tag] = TagStatus.settlement; //this is to ensure that this gets saved in DB
    });
  }

  void _updateSettlementRecipient(Tag tag, String recipientId) {
    final current = _settlementData[tag];
    if (current == null) return;

    setState(() {
      _settlementData[tag] = SettlementEntry(to: recipientId, month: current.month, year: current.year, tagId: current.tagId);
      _modifiedTags[tag] = TagStatus.settlement;
    });
  }

  Future<void> _done() async {
    if (_modifiedTags.isEmpty) {
      print("TagSelectionScreen: modifiedTags is empty .. returning empty");
      Navigator.pop(context);
      return;
    }

    setState(() => _isLoading = true);

    try {
      if (widget.expense is Expense) {
        for (var entry in _modifiedTags.entries) {
          final tag = entry.key;
          final newStatus = entry.value;
          final oldStatus = _attachedTagsOriginal[tag];

          if (oldStatus != newStatus) {
            switch (oldStatus) {
              case TagStatus.expense:
                await removeExpenseFromTag(tag.id, widget.expense.id);
                break;
              case TagStatus.settlement:
                await removeExpenseFromTag(tag.id, widget.expense.id, isSettlement: true);
                break;
              default:
                print("Old status for ${tag.name} was either null or unselected");
            }

            switch (newStatus) {
              case TagStatus.expense:
                await addExpenseOrSettlementToTag(widget.expense.id, tagId: tag.id);
                break;
              case TagStatus.settlement:
                final settlementEntry = _settlementData[tag];
                if (settlementEntry != null) {
                  await addExpenseOrSettlementToTag(widget.expense.id, settlementData: settlementEntry);
                }
                break;
              default:
                print("New status for ${tag.name} is unselected");
            }
          }

          if (oldStatus == newStatus && newStatus == TagStatus.settlement) {
            // update the settlement data
            await addExpenseOrSettlementToTag(widget.expense.id, settlementData: _settlementData[tag]);
          }
        }
      }

      final regularTags = _currentTagStatus.entries.where((e) => e.value == TagStatus.expense).map((e) => e.key).toSet();
      final settlements = _currentTagStatus.entries
          .where((e) => e.value == TagStatus.settlement)
          .map((e) => _settlementData[e.key]!)
          .toList();

      if (mounted) {
        showSuccess(context, 'Attachments updated successfully');
        Navigator.pop(context, {'tags': regularTags, 'settlements': settlements});
      }
    } catch (e, stackTrace) {
      print('Error updating attachments: $e, $stackTrace');
      if (mounted) showError(context, e.toString());
      setState(() => _isLoading = false);
    }
  }

  Future<void> onBackButtonPress() async {
    if (_modifiedTags.isEmpty) {
      Navigator.pop(context);
      return;
    }

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Discard Changes ?', style: TextStyle(color: kTextColor)),
          content: Text(
            'There are changes done but not saved, which will be lost. Proceed with discarding them & navigating back ?',
            style: TextStyle(color: kTextMedium),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context); // close AlertDialog
                Navigator.pop(context); // Navigate Back
              },
              child: Text('Yes, Discard Them', style: TextStyle(color: kTextMedium)),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context); // close AlertDialog
                await _done(); // Save Changes
              },
              child: Text('Save Changes', style: TextStyle(color: errorcolor)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    print(
      "TagSelectionScreen: currentTagStatus size ${_currentTagStatus.length}, settlementData size ${_settlementData.length}, modifiedTag size ${_modifiedTags.length}",
    );

    return Scaffold(
      backgroundColor: kWhitecolor,
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: appBarSearchInput(controller: _searchController),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: kWhitecolor),
          onPressed: () async {
            await onBackButtonPress();
          },
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: primaryColor))
          : SingleChildScrollView(
              child: Container(
                margin: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // All Tags Section (moved to top)
                    renderPrimaryColorLabel(text: 'All Tags'),
                    SizedBox(height: 8),
                    _renderAllTagsSection(),

                    SizedBox(height: 24),
                    Divider(height: 1),
                    SizedBox(height: 24),

                    // Attached Tags Section (with accordions)
                    renderPrimaryColorLabel(text: 'Attached Tags'),
                    SizedBox(height: 8),
                    _renderAttachedTagsSection(),
                  ],
                ),
              ),
            ),
      bottomNavigationBar: BottomAppBar(child: renderMainBottomButton('Done', _isLoading ? null : _done, !_isLoading)),
    );
  }

  Widget _renderAllTagsSection() {
    if (_allTagsFiltered.isEmpty) {
      return Container(
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(color: tileBackgroundColor, borderRadius: BorderRadius.circular(8)),
        child: Center(
          child: Text(
            'No tags found',
            style: TextStyle(color: inactiveColor, fontSize: smallFontSize),
          ),
        ),
      );
    }

    return Wrap(
      direction: Axis.horizontal,
      spacing: 5,
      runSpacing: 10,
      children: _allTagsFiltered.map((tag) {
        TagStatus status = _currentTagStatus[tag] ?? TagStatus.unselected;
        TagStatus originalStatus = _attachedTagsOriginal[tag] ?? TagStatus.unselected;

        return renderTag(text: tag.name, status: status, previousStatus: originalStatus, onPressed: () => _selectTag(tag));
      }).toList(),
    );
  }

  Widget _renderAttachedTagsSection() {
    if (_attachedTagsFiltered.isEmpty) {
      return Container(
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(color: tileBackgroundColor, borderRadius: BorderRadius.circular(8)),
        child: Center(
          child: Text(
            '.. Nothing here ..',
            style: TextStyle(color: inactiveColor, fontSize: smallFontSize),
          ),
        ),
      );
    }

    return Column(children: _attachedTagsFiltered.map((tag) => _buildTagAccordion(tag)).toList());
  }

  Widget _buildTagAccordion(Tag tag) {
    final isExpanded = _expandedTag == tag;
    final isSettlement = _currentTagStatus[tag] == TagStatus.settlement;

    return Card(
      margin: EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          ListTile(
            title: Text(tag.name, style: TextStyle(fontWeight: FontWeight.w600)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(isExpanded ? Icons.expand_less : Icons.expand_more),
                  onPressed: () {
                    setState(() {
                      _expandedTag = isExpanded ? null : tag;
                    });
                  },
                ),
                IconButton(
                  icon: Icon(Icons.delete, color: errorcolor),
                  onPressed: () => _unselectTag(tag),
                ),
              ],
            ),
          ),
          if (isExpanded) ...[
            Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Settlement checkbox
                  if (tag.sharedWith.isNotEmpty) ...[
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Record as a Settlement instead'),
                      subtitle: Text(
                        'Settlement is to settle balance offset & paying someone in the group to whom you owe money',
                        style: TextStyle(fontSize: xsmallFontSize, color: kTextMedium),
                      ),
                      value: isSettlement,
                      onChanged: (value) => _toggleSettlementMode(tag, value ?? false),
                    ),
                    SizedBox(height: 8),
                  ],

                  // Settlement fields
                  if (isSettlement && _settlementData.containsKey(tag)) ...[_buildSettlementFields(tag)],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSettlementFields(Tag tag) {
    final settlement = _settlementData[tag]!;
    final date = DateTime(settlement.year, settlement.month);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Month/Year selector
        Text(
          'Settlement Period',
          style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
        ),
        SizedBox(height: 8),
        Container(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: bordercolor),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: Icon(Icons.remove_circle_outline, color: primaryColor),
                onPressed: () => _updateSettlementPeriod(tag, -1),
              ),
              Text(
                DateFormat.yMMMM().format(date),
                style: TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.w500),
              ),
              IconButton(
                icon: Icon(Icons.add_circle_outline, color: primaryColor),
                onPressed: () => _updateSettlementPeriod(tag, 1),
              ),
            ],
          ),
        ),
        SizedBox(height: 16),

        // Recipient selector
        FutureBuilder<Map<String, String>>(
          future: _loadTagUsers(tag),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return CircularProgressIndicator(color: primaryColor);
            }

            final userKilvishIds = snapshot.data!;
            if (userKilvishIds.isEmpty) {
              return Text('No other users available', style: TextStyle(color: errorcolor));
            }

            return DropdownButtonFormField<String>(
              value: settlement.to,
              decoration: InputDecoration(labelText: 'Settled With', border: OutlineInputBorder()),
              items: userKilvishIds.entries.map((entry) {
                return DropdownMenuItem(value: entry.key, child: Text('@${entry.value}'));
              }).toList(),
              onChanged: (value) {
                if (value != null) _updateSettlementRecipient(tag, value);
              },
            );
          },
        ),
      ],
    );
  }

  Future<Map<String, String>> _loadTagUsers(Tag tag) async {
    final userId = await getUserIdFromClaim();
    if (userId == null) return {};

    final tagUsers = [tag.ownerId, ...tag.sharedWith].where((id) => id != userId).toList();
    Map<String, String> userKilvishIds = {};

    for (String uid in tagUsers) {
      final kilvishId = await getUserKilvishId(uid);
      if (kilvishId != null) userKilvishIds[uid] = kilvishId;
    }

    return userKilvishIds;
  }
}

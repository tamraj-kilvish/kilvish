import 'package:flutter/material.dart';
import 'package:kilvish/cache_manager.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/style.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/firestore.dart';

class _TagOutstandingState {
  bool trackOutstanding = false;
  final TextEditingController ownExpenseController = TextEditingController();
  Map<String, bool> recipientChecked = {};
  Map<String, TextEditingController> recipientAmountControllers = {};

  void dispose() {
    ownExpenseController.dispose();
    for (final c in recipientAmountControllers.values) c.dispose();
  }
}

class TagSelectionScreen extends StatefulWidget {
  final Set<Tag> initialSelectedTags;
  final BaseExpense expense;
  final bool isExpenseOwner;

  const TagSelectionScreen({
    super.key,
    required this.initialSelectedTags,
    required this.expense,
    this.isExpenseOwner = true,
  });

  @override
  State<TagSelectionScreen> createState() => _TagSelectionScreenState();
}

class _TagSelectionScreenState extends State<TagSelectionScreen> {
  Set<Tag> _attachedTags = {};
  Set<Tag> _attachedTagsOriginal = {};
  Set<Tag> _allTags = {};
  Map<Tag, TagStatus> _modifiedTags = {};

  final Map<String, _TagOutstandingState> _outstandingState = {};
  final Map<String, String> _userIdToKilvishId = {};
  final Map<String, List<String>> _tagUserIds = {};

  String _searchQuery = '';
  bool _isLoading = false;
  String? _currentUserId;

  @override
  void initState() {
    super.initState();
    _attachedTags = Set.from(widget.initialSelectedTags);
    _attachedTagsOriginal = Set.from(widget.initialSelectedTags);

    getUserIdFromClaim().then((id) {
      if (mounted) setState(() => _currentUserId = id);
    });

    _loadAllTags().then((_) {
      if (mounted) setState(() {});
      _initOutstandingStates();
      _loadBreakdownsFromCache();
    });
  }

  @override
  void dispose() {
    for (final state in _outstandingState.values) state.dispose();
    super.dispose();
  }

  Future<void> _loadAllTags() async {
    final cached = await loadTags();
    if (cached != null) {
      _allTags = cached.toSet();
      return;
    }
    try {
      final user = await getLoggedInUserData();
      if (user == null) return;
      for (final tagId in user.accessibleTagIds) {
        final tag = await getTagData(tagId, fromCache: true);
        _allTags.add(tag);
      }
    } catch (e) {
      print('Error loading tags: $e');
    }
  }

  void _initOutstandingStates() {
    for (final tag in _attachedTags) {
      _ensureOutstandingState(tag);
    }
  }

  Future<void> _loadBreakdownsFromCache() async {
    for (final tag in _attachedTagsOriginal) {
      final expenses = await loadTagExpenses(tag.id);
      if (expenses == null) continue;
      Expense? found;
      try { found = expenses.firstWhere((e) => e.id == widget.expense.id); } catch (_) {}
      if (found == null || found.recipients.isEmpty) continue;

      final state = _outstandingState[tag.id];
      if (state == null) continue;

      state.trackOutstanding = true;
      final ownAmount = (found.amount) - (found.totalOutstandingAmount ?? 0);
      state.ownExpenseController.text = ownAmount.toStringAsFixed(0);
      for (final r in found.recipients) {
        state.recipientChecked[r.userId] = true;
        state.recipientAmountControllers[r.userId]?.text = r.amount.toStringAsFixed(0);
      }
    }
    if (mounted) setState(() {});
  }

  void _ensureOutstandingState(Tag tag) {
    if (_outstandingState.containsKey(tag.id)) return;

    final state = _TagOutstandingState();
    _outstandingState[tag.id] = state;

    final userIds = <String>{tag.ownerId, ...tag.sharedWith}.toList();
    _tagUserIds[tag.id] = userIds;

    for (final userId in userIds) {
      state.recipientChecked[userId] = false;
      state.recipientAmountControllers[userId] = TextEditingController();
    }

    for (final userId in userIds) {
      if (!_userIdToKilvishId.containsKey(userId)) {
        getUserKilvishId(userId).then((id) {
          if (id != null && mounted) setState(() => _userIdToKilvishId[userId] = id);
        });
      }
    }
  }

  void _toggleTag(Tag tag, TagStatus currentStatus) {
    setState(() {
      _modifiedTags.remove(tag);
      if (currentStatus == TagStatus.selected) {
        _attachedTags.remove(tag);
        if (_attachedTagsOriginal.contains(tag)) _modifiedTags[tag] = TagStatus.unselected;
      } else {
        _attachedTags.add(tag);
        _ensureOutstandingState(tag);
        if (!_attachedTagsOriginal.contains(tag)) _modifiedTags[tag] = TagStatus.selected;
      }
    });
  }

  num _computeTotalOutstanding(String tagId) {
    final state = _outstandingState[tagId];
    if (state == null || !state.trackOutstanding) return 0;
    num total = 0;
    for (final entry in state.recipientChecked.entries) {
      if (entry.value) {
        total += num.tryParse(state.recipientAmountControllers[entry.key]?.text ?? '') ?? 0;
      }
    }
    return total;
  }

  Future<void> _done() async {
    setState(() => _isLoading = true);
    try {
      if (!widget.isExpenseOwner) {
        final uid = _currentUserId;
        if (uid != null && widget.expense is Expense) {
          for (final tag in _attachedTagsOriginal) {
            final state = _outstandingState[tag.id];
            if (state == null) continue;
            final checked = state.recipientChecked[uid] ?? false;
            if (checked) {
              final amount = num.tryParse(state.recipientAmountControllers[uid]?.text ?? '') ?? 0;
              await addOrUpdateRecipient(tag.id, widget.expense.id, uid, amount);
            } else {
              await removeRecipient(tag.id, widget.expense.id, uid);
            }
          }
        }
        if (mounted) Navigator.pop(context, _attachedTags);
        return;
      }

      for (final entry in _modifiedTags.entries) {
        final tag = entry.key;
        if (entry.value == TagStatus.selected) {
          if (widget.expense is Expense) {
            final outstanding = _computeTotalOutstanding(tag.id);
            await addExpenseToTag(tag.id, widget.expense.id, totalOutstandingAmount: outstanding);
            await _writeRecipients(tag.id, widget.expense.id);
            await _writeTagExpenseBreakdown(tag.id, widget.expense.id, outstanding);
          }
        } else {
          if (widget.expense is Expense) await removeExpenseFromTag(tag.id, widget.expense.id);
        }
      }

      // Update outstanding for already-attached tags that weren't added/removed
      for (final tag in _attachedTagsOriginal.intersection(_attachedTags)) {
        if (!_modifiedTags.containsKey(tag)) {
          final state = _outstandingState[tag.id];
          if (state != null && state.trackOutstanding && widget.expense is Expense) {
            final outstanding = _computeTotalOutstanding(tag.id);
            await updateExpenseOutstandingInTag(tag.id, widget.expense.id, outstanding);
            await _writeRecipients(tag.id, widget.expense.id);
            await _writeTagExpenseBreakdown(tag.id, widget.expense.id, outstanding);
          }
        }
      }

      if (mounted) Navigator.pop(context, _attachedTags);
    } catch (e) {
      print('Error updating tags: $e');
      if (mounted) showError(context, 'Failed to update tags');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _writeTagExpenseBreakdown(String tagId, String expenseId, num outstanding) async {
    final state = _outstandingState[tagId];
    if (state == null || !state.trackOutstanding) return;

    final recipients = state.recipientChecked.entries
        .where((e) => e.value)
        .map((e) => RecipientBreakdown(
              userId: e.key,
              amount: num.tryParse(state.recipientAmountControllers[e.key]?.text ?? '') ?? 0,
            ))
        .toList();

    await updateExpenseOutstandingInTag(tagId, expenseId, outstanding);

    final expenses = await loadTagExpenses(tagId) ?? [];
    final idx = expenses.indexWhere((e) => e.id == expenseId);
    if (idx >= 0) {
      expenses[idx].recipients = recipients;
      expenses[idx].totalOutstandingAmount = outstanding;
      await saveTagExpenses(tagId, expenses);
    }
  }

  Future<void> _writeRecipients(String tagId, String expenseId) async {
    final state = _outstandingState[tagId];
    if (state == null || !state.trackOutstanding) return;
    for (final entry in state.recipientChecked.entries) {
      if (entry.value) {
        final amount = num.tryParse(state.recipientAmountControllers[entry.key]?.text ?? '') ?? 0;
        await addOrUpdateRecipient(tagId, expenseId, entry.key, amount);
      } else {
        await removeRecipient(tagId, expenseId, entry.key);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final unselectedTags = _allTags.difference(_attachedTags);
    final filteredUnselected = _searchQuery.isEmpty
        ? unselectedTags.take(10).toSet()
        : unselectedTags.where((t) => t.name.toLowerCase().contains(_searchQuery)).take(10).toSet();

    return Scaffold(
      backgroundColor: kWhitecolor,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: Text(
          'Tags',
          style: TextStyle(color: kWhitecolor, fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: kWhitecolor),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: primaryColor))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_attachedTags.isNotEmpty) ...[
                    renderPrimaryColorLabel(text: 'Attached Tags'),
                    const SizedBox(height: 8),
                    ..._attachedTags.map(_buildTagAccordion),
                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 16),
                  ],
                  if (widget.isExpenseOwner) ...[
                    renderPrimaryColorLabel(text: 'All Tags'),
                    const SizedBox(height: 8),
                    TextField(
                      decoration: InputDecoration(
                        hintText: 'Search tags...',
                        prefixIcon: const Icon(Icons.search, color: inactiveColor),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        isDense: true,
                      ),
                      onChanged: (v) => setState(() => _searchQuery = v.toLowerCase().trim()),
                    ),
                    const SizedBox(height: 8),
                    if (filteredUnselected.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: tileBackgroundColor, borderRadius: BorderRadius.circular(8)),
                        child: Center(
                          child: Text(
                            'No tags found',
                            style: TextStyle(color: inactiveColor, fontSize: smallFontSize),
                          ),
                        ),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: filteredUnselected
                            .map(
                              (tag) => renderTag(
                                text: tag.name,
                                status: TagStatus.unselected,
                                isUpdated: _modifiedTags.containsKey(tag),
                                onPressed: () => _toggleTag(tag, TagStatus.unselected),
                              ),
                            )
                            .toList(),
                      ),
                  ],
                ],
              ),
            ),
      bottomNavigationBar: BottomAppBar(child: renderMainBottomButton('Done', _isLoading ? null : _done, !_isLoading)),
    );
  }

  Widget _buildTagAccordion(Tag tag) {
    final state = _outstandingState[tag.id];
    final userIds = _tagUserIds[tag.id] ?? [];
    final expenseAmount = widget.expense.amount ?? 0;

    return Card(
      color: tileBackgroundColor,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Row(
          children: [
            Expanded(
              child: Text(
                tag.name,
                style: const TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.w600),
              ),
            ),
            if (widget.isExpenseOwner)
              GestureDetector(
                onTap: () => _toggleTag(tag, TagStatus.selected),
                child: Icon(Icons.close, size: 18, color: errorcolor),
              ),
          ],
        ),
        children: [
          if (state != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Checkbox(
                        value: state.trackOutstanding,
                        activeColor: primaryColor,
                        onChanged: widget.isExpenseOwner
                            ? (v) => setState(() => state.trackOutstanding = v ?? false)
                            : null,
                      ),
                      const Text('Others involved ?', style: TextStyle(fontSize: defaultFontSize)),
                    ],
                  ),
                  if (state.trackOutstanding) ...[
                    const SizedBox(height: 8),
                    if (widget.isExpenseOwner)
                      TextField(
                        controller: state.ownExpenseController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Own Expense (₹)',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    const SizedBox(height: 8),
                    _buildOutstandingRow(expenseAmount, state),
                    const SizedBox(height: 12),
                    Text(
                      'Expense For / Settlement To:',
                      style: TextStyle(fontSize: smallFontSize, color: kTextMedium, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 4),
                    ...userIds.map((uid) => _buildRecipientRow(state, uid)),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildOutstandingRow(num expenseAmount, _TagOutstandingState state) {
    final ownExpense = num.tryParse(state.ownExpenseController.text) ?? 0;
    final outstanding = expenseAmount - ownExpense;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'To Recover / Settle',
            style: TextStyle(color: Colors.orange.shade800, fontSize: smallFontSize),
          ),
          Text(
            '₹${outstanding.toStringAsFixed(0)}',
            style: TextStyle(color: Colors.orange.shade800, fontWeight: FontWeight.bold, fontSize: defaultFontSize),
          ),
        ],
      ),
    );
  }

  Widget _buildRecipientRow(_TagOutstandingState state, String userId) {
    final label = _userIdToKilvishId[userId] != null ? '@${_userIdToKilvishId[userId]}' : userId;
    final checked = state.recipientChecked[userId] ?? false;
    final controller = state.recipientAmountControllers[userId];
    final isEditable = widget.isExpenseOwner || userId == _currentUserId;

    return Row(
      children: [
        Checkbox(
          value: checked,
          activeColor: primaryColor,
          onChanged: isEditable ? (v) => setState(() => state.recipientChecked[userId] = v ?? false) : null,
        ),
        Expanded(
          child: Text(label, style: const TextStyle(fontSize: smallFontSize)),
        ),
        if (checked && controller != null)
          SizedBox(
            width: 90,
            child: TextField(
              controller: controller,
              enabled: isEditable,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                prefixText: '₹',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                isDense: true,
              ),
            ),
          ),
      ],
    );
  }
}

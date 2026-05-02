import 'package:flutter/material.dart';
import 'package:kilvish/cache_manager.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/style.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/tag_expense_config_screen.dart';

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
  final Map<Tag, TagStatus> _modifiedTags = {};

  // Per-tag config keyed by tagId
  final Map<String, TagExpenseConfig> _configs = {};
  // All member user IDs per tag, used when writing recipients
  final Map<String, List<String>> _tagMemberIds = {};
  // kilvishId lookup cache for card display
  final Map<String, String> _userIdToKilvishId = {};

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
      _initTagMemberIds();
      _loadConfigsFromCache();
    });
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

  void _initTagMemberIds() {
    for (final tag in _attachedTags) {
      _ensureTagMemberIds(tag);
    }
  }

  void _ensureTagMemberIds(Tag tag) {
    if (_tagMemberIds.containsKey(tag.id)) return;
    final ids = <String>{tag.ownerId, ...tag.sharedWith}.toList();
    _tagMemberIds[tag.id] = ids;
    for (final userId in ids) {
      if (!_userIdToKilvishId.containsKey(userId)) {
        getUserKilvishId(userId).then((id) {
          if (id != null && mounted) setState(() => _userIdToKilvishId[userId] = id);
        });
      }
    }
  }

  Future<void> _loadConfigsFromCache() async {
    for (final tag in _attachedTagsOriginal) {
      final expenses = await loadTagExpenses(tag.id);
      if (expenses == null) continue;
      Expense? found;
      try { found = expenses.firstWhere((e) => e.id == widget.expense.id); } catch (_) {}
      if (found == null) continue;

      final recipients = <String, num>{};
      for (final r in found.recipients) {
        recipients[r.userId] = r.amount;
      }
      final outstanding = found.totalOutstandingAmount ?? 0;
      final ownerShare = (found.amount) - outstanding;

      _configs[tag.id] = TagExpenseConfig(
        isSettlement: found.isSettlement,
        settlementMonth: found.settlementMonth,
        settlementCounterpartyId: found.isSettlement && found.recipients.isNotEmpty
            ? found.recipients.first.userId
            : null,
        recipientAmounts: recipients,
        ownerShare: ownerShare > 0 ? ownerShare : 0,
      );
    }
    if (mounted) setState(() {});
  }

  void _toggleTag(Tag tag, TagStatus currentStatus) {
    setState(() {
      _modifiedTags.remove(tag);
      if (currentStatus == TagStatus.selected) {
        _attachedTags.remove(tag);
        _configs.remove(tag.id);
        if (_attachedTagsOriginal.contains(tag)) _modifiedTags[tag] = TagStatus.unselected;
      } else {
        _attachedTags.add(tag);
        _ensureTagMemberIds(tag);
        if (!_attachedTagsOriginal.contains(tag)) _modifiedTags[tag] = TagStatus.selected;
      }
    });
  }

  Future<void> _openTagConfig(Tag tag) async {
    if (widget.expense is! Expense) return;
    final result = await Navigator.push<TagExpenseConfig>(
      context,
      MaterialPageRoute(
        builder: (ctx) => TagExpenseConfigScreen(
          tag: tag,
          expense: widget.expense as Expense,
          isExpenseOwner: widget.isExpenseOwner,
          initialConfig: _configs[tag.id],
          currentUserId: _currentUserId,
        ),
      ),
    );
    if (result == null) return;
    if (result.removed) {
      _toggleTag(tag, TagStatus.selected);
    } else {
      setState(() => _configs[tag.id] = result);
    }
  }

  Future<void> _done() async {
    setState(() => _isLoading = true);
    try {
      if (!widget.isExpenseOwner) {
        // Non-owner: only update own recipient row for originally-attached tags
        final uid = _currentUserId;
        if (uid != null && widget.expense is Expense) {
          for (final tag in _attachedTagsOriginal) {
            final config = _configs[tag.id];
            if (config == null || config.isSettlement) continue;
            final amount = config.recipientAmounts[uid] ?? 0;
            if (amount > 0) {
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
            final config = _configs[tag.id] ?? const TagExpenseConfig();
            final outstanding = config.isSettlement ? 0 : config.computeOutstanding(widget.expense.amount ?? 0);
            await addExpenseToTag(
              tag.id,
              widget.expense.id,
              totalOutstandingAmount: outstanding,
              isSettlement: config.isSettlement,
              settlementMonth: config.settlementMonth,
            );
            await _writeRecipients(tag.id, widget.expense.id, config);
            await _updateExpenseCache(tag.id, widget.expense.id, config, outstanding);
          }
        } else {
          if (widget.expense is Expense) await removeExpenseFromTag(tag.id, widget.expense.id);
        }
      }

      // Update already-attached tags that have config changes
      for (final tag in _attachedTagsOriginal.intersection(_attachedTags)) {
        if (!_modifiedTags.containsKey(tag) && widget.expense is Expense) {
          final config = _configs[tag.id];
          if (config != null) {
            final outstanding = config.isSettlement ? 0 : config.computeOutstanding(widget.expense.amount ?? 0);
            await updateTagExpenseData(
              tag.id,
              widget.expense.id,
              totalOutstandingAmount: outstanding,
              isSettlement: config.isSettlement,
              settlementMonth: config.settlementMonth,
            );
            await _writeRecipients(tag.id, widget.expense.id, config);
            await _updateExpenseCache(tag.id, widget.expense.id, config, outstanding);
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

  Future<void> _writeRecipients(String tagId, String expenseId, TagExpenseConfig config) async {
    final allMemberIds = _tagMemberIds[tagId] ?? [];
    final expenseOwnerId = (widget.expense as Expense).ownerId ?? '';

    if (config.isSettlement) {
      final counterparty = config.settlementCounterpartyId;
      if (counterparty != null) {
        await addOrUpdateRecipient(tagId, expenseId, counterparty, widget.expense.amount ?? 0);
      }
      for (final userId in allMemberIds) {
        if (userId != counterparty) await removeRecipient(tagId, expenseId, userId);
      }
    } else {
      for (final userId in allMemberIds) {
        if (userId == expenseOwnerId) continue;
        final amount = config.recipientAmounts[userId] ?? 0;
        if (amount > 0) {
          await addOrUpdateRecipient(tagId, expenseId, userId, amount);
        } else {
          await removeRecipient(tagId, expenseId, userId);
        }
      }
    }
  }

  Future<void> _updateExpenseCache(String tagId, String expenseId, TagExpenseConfig config, num outstanding) async {
    final expenses = await loadTagExpenses(tagId) ?? [];
    final idx = expenses.indexWhere((e) => e.id == expenseId);
    if (idx < 0) return;
    expenses[idx].totalOutstandingAmount = outstanding;
    expenses[idx].isSettlement = config.isSettlement;
    expenses[idx].settlementMonth = config.settlementMonth;
    if (config.isSettlement) {
      expenses[idx].recipients = config.settlementCounterpartyId != null
          ? [RecipientBreakdown(userId: config.settlementCounterpartyId!, amount: widget.expense.amount ?? 0)]
          : [];
    } else {
      expenses[idx].recipients = config.recipientAmounts.entries
          .where((e) => e.value > 0)
          .map((e) => RecipientBreakdown(userId: e.key, amount: e.value))
          .toList();
    }
    await saveTagExpenses(tagId, expenses);
  }

  String _labelFor(String userId) {
    final k = _userIdToKilvishId[userId];
    return k != null ? '@$k' : userId;
  }

  String _formatMonth(String monthKey) {
    final parts = monthKey.split('-');
    if (parts.length != 2) return monthKey;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    if (year == null || month == null) return monthKey;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[month - 1]} $year';
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
                    ..._attachedTags.map(_buildTagCard),
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

  bool _hasAdvancedData(String tagId) {
    final config = _configs[tagId];
    if (config == null) return false;
    if (config.isSettlement) return true;
    if (config.ownerShare > 0) return true;
    if (config.recipientAmounts.values.any((v) => v > 0)) return true;
    return false;
  }

  Widget _buildTagCard(Tag tag) {
    final config = _configs[tag.id];
    final expenseAmount = widget.expense.amount ?? 0;

    if (_hasAdvancedData(tag.id)) {
      if (config!.isSettlement) return _buildSettlementCard(tag, config, expenseAmount);
      return _buildExpenseCard(tag, config, expenseAmount);
    }
    return _buildSimpleCard(tag);
  }

  Widget _buildSimpleCard(Tag tag) {
    return Card(
      color: tileBackgroundColor,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openTagConfig(tag),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Text(tag.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: defaultFontSize)),
              ),
              Text(
                'Advanced Options',
                style: TextStyle(color: primaryColor, fontSize: smallFontSize, fontWeight: FontWeight.w500),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 16, color: primaryColor),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpenseCard(Tag tag, TagExpenseConfig config, num expenseAmount) {
    final outstanding = config.computeOutstanding(expenseAmount);
    final recipients = config.recipientAmounts.entries.where((e) => e.value > 0).toList();

    return Card(
      color: tileBackgroundColor,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openTagConfig(tag),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(tag.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: defaultFontSize)),
                  ),
                  Text(
                    'Outstanding: ₹${outstanding.toStringAsFixed(0)}',
                    style: TextStyle(color: Colors.orange.shade800, fontSize: smallFontSize),
                  ),
                ],
              ),
              if (recipients.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  recipients.map((e) => '${_labelFor(e.key)}: ₹${e.value.toStringAsFixed(0)}').join('  '),
                  style: TextStyle(color: kTextMedium, fontSize: smallFontSize),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSettlementCard(Tag tag, TagExpenseConfig config, num expenseAmount) {
    return Card(
      color: Colors.teal.shade50,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.teal.shade200),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openTagConfig(tag),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(tag.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: defaultFontSize)),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.teal.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Settlement',
                      style: TextStyle(color: Colors.teal.shade800, fontSize: smallFontSize, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  if (config.settlementMonth != null) ...[
                    Icon(Icons.calendar_month, size: 12, color: kTextMedium),
                    const SizedBox(width: 4),
                    Text(_formatMonth(config.settlementMonth!), style: TextStyle(color: kTextMedium, fontSize: smallFontSize)),
                    const SizedBox(width: 12),
                  ],
                  if (config.settlementCounterpartyId != null) ...[
                    Text(
                      'With: ${_labelFor(config.settlementCounterpartyId!)} · ₹${expenseAmount.toStringAsFixed(0)}',
                      style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

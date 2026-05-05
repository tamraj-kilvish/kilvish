import 'package:flutter/material.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/style.dart';
import 'package:kilvish/tag_expense_config_screen.dart';
import 'package:kilvish/tag_selection_screen.dart';

class TagLinksSection extends StatefulWidget {
  final BaseExpense expense;
  final bool isExpenseOwner;
  final String? currentUserId;
  final Function(BaseExpense) onExpenseUpdated;

  const TagLinksSection({
    super.key,
    required this.expense,
    required this.isExpenseOwner,
    this.currentUserId,
    required this.onExpenseUpdated,
  });

  @override
  State<TagLinksSection> createState() => _TagLinksSectionState();
}

class _TagLinksSectionState extends State<TagLinksSection> {
  Map<String, Tag> _tagsById = {};
  final Map<String, String> _userIdToKilvishId = {};

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void didUpdateWidget(TagLinksSection old) {
    super.didUpdateWidget(old);
    if (old.expense != widget.expense) {
      _loadData();
    }
  }

  Future<void> _loadData() async {
    final allTags = await CacheManager.loadTags();
    final tagMap = {for (final t in allTags) t.id: t};
    if (mounted) {
      setState(() => _tagsById = {
        for (final link in widget.expense.tagLinks)
          if (tagMap.containsKey(link.tagId)) link.tagId: tagMap[link.tagId]!,
      });
    }
    final ownerId = widget.expense.ownerId ?? '';
    for (final config in widget.expense.tagLinks) {
      _resolveKilvishIds(config.nonOwnerAmounts(ownerId).keys.toList());
      if (config.settlementCounterpartyId != null) {
        _resolveKilvishIds([config.settlementCounterpartyId!]);
      }
    }
  }

  void _resolveKilvishIds(List<String> userIds) {
    for (final userId in userIds) {
      if (!_userIdToKilvishId.containsKey(userId)) {
        getUserKilvishId(userId).then((id) {
          if (id != null && mounted) setState(() => _userIdToKilvishId[userId] = id);
        });
      }
    }
  }

  Future<void> _openTagSelection() async {
    final selectedTag = await Navigator.push<Tag>(
      context,
      MaterialPageRoute(
        builder: (ctx) => TagSelectionScreen(expense: widget.expense),
      ),
    );
    if (selectedTag == null) return;

    final updatedLinks = [...widget.expense.tagLinks, TagExpenseConfig(tagId: selectedTag.id)];
    await widget.expense.saveTagData(updatedLinks);
    widget.onExpenseUpdated(widget.expense);
    if (mounted) _loadData();
  }

  Future<void> _openTagConfig(Tag tag) async {
    final config = widget.expense.tagLinks.firstWhere(
      (t) => t.tagId == tag.id,
      orElse: () => TagExpenseConfig(tagId: tag.id),
    );

    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (ctx) => TagExpenseConfigScreen(
          tag: tag,
          expense: widget.expense,
          isExpenseOwner: widget.isExpenseOwner,
          initialConfig: config,
          currentUserId: widget.currentUserId,
          onSaved: (updated) {
            widget.onExpenseUpdated(updated);
            if (mounted) _loadData();
          },
        ),
      ),
    );
  }

  bool _hasAdvancedData(TagExpenseConfig config) => config.recipients.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final tagLinks = widget.expense.tagLinks;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            renderPrimaryColorLabel(text: 'Tags'),
            if (widget.isExpenseOwner)
              TextButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Tag'),
                onPressed: _openTagSelection,
                style: TextButton.styleFrom(
                  foregroundColor: primaryColor,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(fontSize: smallFontSize),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (tagLinks.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: tileBackgroundColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: bordercolor),
            ),
            child: Text(
              'No tags added',
              style: TextStyle(color: inactiveColor, fontSize: smallFontSize),
              textAlign: TextAlign.center,
            ),
          )
        else
          ...tagLinks.map((config) {
            final tag = _tagsById[config.tagId];
            if (tag == null) return const SizedBox.shrink();
            return _buildCard(tag, config);
          }),
      ],
    );
  }

  Widget _buildCard(Tag tag, TagExpenseConfig config) {
    final expenseAmount = widget.expense.amount ?? 0;
    if (!_hasAdvancedData(config)) return _buildSimpleCard(tag);
    if (config.isSettlement) return _buildSettlementCard(tag, config, expenseAmount);
    return _buildExpenseCard(tag, config, expenseAmount);
  }

  Widget _buildSimpleCard(Tag tag) {
    return Card(
      color: tileBackgroundColor,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openTagConfig(tag),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              AbsorbPointer(child: renderTag(text: tag.name, status: TagStatus.selected, onPressed: () {})),
              const Spacer(),
              Text('Advanced Options', style: TextStyle(color: primaryColor, fontSize: smallFontSize, fontWeight: FontWeight.w500)),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 16, color: primaryColor),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpenseCard(Tag tag, TagExpenseConfig config, num expenseAmount) {
    final ownerId = widget.expense.ownerId ?? '';
    final outstanding = config.outstandingFor(ownerId, expenseAmount);
    final ownerLabel = '@${widget.expense.ownerKilvishId}';

    final resolvedRecipients = config.nonOwnerAmounts(ownerId).entries
        .where((e) => e.value > 0 && _userIdToKilvishId.containsKey(e.key))
        .toList();

    String subtitle = '$ownerLabel is owed ₹${outstanding.toStringAsFixed(0)}';
    if (resolvedRecipients.isNotEmpty) {
      final shown = resolvedRecipients.take(2).map((e) {
        return '@${_userIdToKilvishId[e.key]} (₹${e.value.toStringAsFixed(0)})';
      }).join(' & ');
      final suffix = resolvedRecipients.length > 2 ? ' & more' : '';
      subtitle += ' from $shown$suffix';
    }

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
              AbsorbPointer(child: renderTag(text: tag.name, status: TagStatus.selected, onPressed: () {})),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(color: kTextMedium, fontSize: smallFontSize),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSettlementCard(Tag tag, TagExpenseConfig config, num expenseAmount) {
    final ownerLabel = '@${widget.expense.ownerKilvishId}';
    final cpId = config.settlementCounterpartyId;
    final cpLabel = cpId != null && _userIdToKilvishId.containsKey(cpId)
        ? '@${_userIdToKilvishId[cpId]}'
        : '...';

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
                  AbsorbPointer(child: renderTag(text: tag.name, status: TagStatus.selected, onPressed: () {})),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: Colors.teal.shade100, borderRadius: BorderRadius.circular(12)),
                    child: Text(
                      'Settlement',
                      style: TextStyle(color: Colors.teal.shade800, fontSize: smallFontSize, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '$ownerLabel settled with $cpLabel',
                style: TextStyle(color: kTextMedium, fontSize: smallFontSize),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

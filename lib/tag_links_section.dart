import 'package:flutter/material.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/style.dart';
import 'package:kilvish/tag_expense_config_screen.dart';
import 'package:kilvish/tag_selection_screen.dart';

class TagLinksSection extends StatefulWidget {
  final BaseExpense expense;
  final bool isExpenseOwner;
  final String? currentUserId;
  final Function(List<TagExpenseConfig>) onExpenseUpdated;

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
  Future<void> _openTagSelection() async {
    await Navigator.push<Tag>(context, MaterialPageRoute(builder: (ctx) => TagSelectionScreen(expense: widget.expense)));
    widget.onExpenseUpdated([...widget.expense.tagLinks]);
  }

  Future<void> _openTagExpenseConfig(Tag tag) async {
    final config = widget.expense.tagLinks.firstWhere(
      (t) => t.tagId == tag.id,
      orElse: () => TagExpenseConfig(tagId: tag.id, expenseAmount: widget.expense.amount),
    );

    await Navigator.push<Expense?>(
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
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            renderPrimaryColorLabel(text: 'Tags', topSpacing: 0),
            const Spacer(),
            if (widget.isExpenseOwner)
              ElevatedButton.icon(
                onPressed: _openTagSelection,
                icon: const Icon(Icons.add, size: 14, color: kWhitecolor),
                label: const Text(
                  'Add Tag',
                  style: TextStyle(color: kWhitecolor, fontSize: smallFontSize),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryColor,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Tap on a tag card to see more details',
          style: TextStyle(color: inactiveColor, fontSize: smallFontSize),
        ),
        const SizedBox(height: 8),
        ...tagLinks.map((config) {
          final tag = CacheManager.getTagFromCache(config.tagId);
          if (tag == null) return const SizedBox.shrink();
          return _buildCard(tag, config);
        }),
      ],
    );
  }

  Widget _buildCard(Tag tag, TagExpenseConfig config) {
    if (!_hasAdvancedData(config)) return _buildSimpleCard(tag, config);
    if (config.isSettlement) return _buildSettlementCard(tag, config);
    return _buildExpenseCard(tag, config);
  }

  Widget _buildSimpleCard(Tag tag, TagExpenseConfig config) {
    return Card(
      color: tileBackgroundColor,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openTagExpenseConfig(tag),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              AbsorbPointer(
                child: renderTag(text: tag.name, status: TagStatus.selected, onPressed: () {}),
              ),
              const Spacer(),
              if (config.expenseAmount != null)
                Text(
                  '₹${config.expenseAmount!.round()}',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: defaultFontSize),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpenseCard(Tag tag, TagExpenseConfig config) {
    return Card(
      color: tileBackgroundColor,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openTagExpenseConfig(tag),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AbsorbPointer(
                child: renderTag(text: tag.name, status: TagStatus.selected, onPressed: () {}),
              ),
              const SizedBox(height: 4),
              Text(
                config.getSummary(widget.expense.ownerKilvishId),
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

  Widget _buildSettlementCard(Tag tag, TagExpenseConfig config) {
    return Card(
      color: Colors.teal.shade50,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.teal.shade200),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openTagExpenseConfig(tag),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AbsorbPointer(
                    child: renderTag(text: tag.name, status: TagStatus.selected, onPressed: () {}),
                  ),
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
                config.getSummary(widget.expense.ownerKilvishId),
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

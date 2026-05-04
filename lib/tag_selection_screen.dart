import 'package:flutter/material.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/style.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/tag_expense_config_screen.dart';

class TagSelectionScreen extends StatefulWidget {
  final BaseExpense expense;
  final bool isExpenseOwner;
  final Function(BaseExpense)? onExpenseUpdated;

  const TagSelectionScreen({
    super.key,
    required this.expense,
    this.isExpenseOwner = true,
    this.onExpenseUpdated,
  });

  @override
  State<TagSelectionScreen> createState() => _TagSelectionScreenState();
}

class _TagSelectionScreenState extends State<TagSelectionScreen> {
  Set<Tag> _attachedTags = {};
  Set<Tag> _allTags = {};
  String _searchQuery = '';
  String? _currentUserId;

  @override
  void initState() {
    super.initState();
    _attachedTags = Set.from(widget.expense.tags);
    getUserIdFromClaim().then((id) {
      if (mounted) setState(() => _currentUserId = id);
    });
    _loadAllTags().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadAllTags() async {
    _allTags = (await CacheManager.loadTags()).toSet();
  }

  void _openTagConfig(Tag tag) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (ctx) => TagExpenseConfigScreen(
          tag: tag,
          expense: widget.expense,
          isExpenseOwner: widget.isExpenseOwner,
          initialConfig: widget.expense.tagLinks.firstWhere(
            (t) => t.tagId == tag.id,
            orElse: () => TagExpenseConfig(tagId: tag.id),
          ),
          currentUserId: _currentUserId,
          onSaved: widget.onExpenseUpdated,
        ),
      ),
    );
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
          'Select Tag',
          style: TextStyle(color: kWhitecolor, fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: kWhitecolor),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            renderSupportLabel(text: 'Tap a tag to configure it'),
            const SizedBox(height: 16),
            if (_attachedTags.isNotEmpty) ...[
              renderPrimaryColorLabel(text: 'Selected Tags'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _attachedTags
                    .map(
                      (tag) => renderTag(
                        text: tag.name,
                        status: TagStatus.selected,
                        isUpdated: false,
                        onPressed: () => _openTagConfig(tag),
                      ),
                    )
                    .toList(),
              ),
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
                          isUpdated: false,
                          onPressed: () => _openTagConfig(tag),
                        ),
                      )
                      .toList(),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

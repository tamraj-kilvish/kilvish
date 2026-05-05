import 'package:flutter/material.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/style.dart';
import 'package:kilvish/common_widgets.dart';

class TagSelectionScreen extends StatefulWidget {
  final BaseExpense expense;

  const TagSelectionScreen({super.key, required this.expense});

  @override
  State<TagSelectionScreen> createState() => _TagSelectionScreenState();
}

class _TagSelectionScreenState extends State<TagSelectionScreen> {
  Set<Tag> _allTags = {};
  String _searchQuery = '';

  Set<String> get _attachedTagIds => widget.expense.tagIds.toSet();

  @override
  void initState() {
    super.initState();
    _loadAllTags();
  }

  Future<void> _loadAllTags() async {
    final tags = (await CacheManager.loadTags()).toSet();
    if (mounted) setState(() => _allTags = tags);
  }

  @override
  Widget build(BuildContext context) {
    final unattached = _allTags.where((t) => !_attachedTagIds.contains(t.id));
    final filtered = _searchQuery.isEmpty
        ? unattached.take(10).toSet()
        : unattached.where((t) => t.name.toLowerCase().contains(_searchQuery)).take(10).toSet();

    return Scaffold(
      backgroundColor: kWhitecolor,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: Text('Select Tag', style: TextStyle(color: kWhitecolor, fontWeight: FontWeight.bold)),
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
            renderSupportLabel(text: 'Tap a tag to add it'),
            const SizedBox(height: 16),
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
            if (filtered.isEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: tileBackgroundColor, borderRadius: BorderRadius.circular(8)),
                child: Center(
                  child: Text('No tags found', style: TextStyle(color: inactiveColor, fontSize: smallFontSize)),
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: filtered
                    .map((tag) => renderTag(
                          text: tag.name,
                          status: TagStatus.unselected,
                          isUpdated: false,
                          onPressed: () => Navigator.pop(context, tag),
                        ))
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }
}

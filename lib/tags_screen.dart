import 'package:flutter/material.dart';
import 'style.dart';
import 'common_widgets.dart';
import 'models.dart';

class TagsPage extends StatefulWidget {
  TagsPage({Key? key}) : super(key: key);
  @override
  createState() => _TagsPageState();
}

class _TagsPageState extends State<TagsPage> {
  //TODO Expense expense;
  late Set<Tag> _attachedTags;
  late Set<Tag> _allTags;
  late Set<Tag> _unselectedTags;

// had to initialize them with empty else it kept cribbing about these variables not initialized
// not sure I understood why was the cause as initState() is suppose to be called before build()
  late Set<Tag> _attachedTagsFiltered = Set();
  late Set<Tag> _unselectedTagsFiltered = Set();

  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    //TODO fetch tags of the expense
    //TODO fetch all the tags locally stored
    _allTags = Set.from({
      const Tag(name: 'tag 1'),
      const Tag(name: 'tag 2'),
      const Tag(name: 'tag 3'),
      const Tag(name: 'tag 4'),
      const Tag(name: 'tag 5'),
    });

    _attachedTags = Set.from({
      const Tag(name: 'tag 6'),
      const Tag(name: 'tag 7'),
    });

    resetTagsToInitialState();

    _searchController.addListener(() {
      String searchText = _searchController.text.trim().toLowerCase();

      setState(() {
        if (searchText.isEmpty) {
          resetTagsToInitialState();
          return;
        }
        _attachedTagsFiltered = Set();
        _attachedTags.forEach((tag) {
          if (tag.name.contains(searchText)) _attachedTagsFiltered.add(tag);
        });

        _unselectedTagsFiltered = Set();
        _unselectedTags.forEach((tag) {
          if (tag.name.contains(searchText)) _unselectedTagsFiltered.add(tag);
        });
      });
    });
  }

  void resetTagsToInitialState() {
    _attachedTagsFiltered = Set.from(_attachedTags);

    _unselectedTags = _allTags.difference(_attachedTags);
    //there could be a lot of unselected tags, taking only first 10
    _unselectedTagsFiltered = _unselectedTags.take(10).toSet();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: appBarSearchInput(controller: _searchController),
        actions: null,
      ),
      body: Container(
        margin: const EdgeInsets.all(5.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          renderTagGroup(
              tags: _attachedTagsFiltered, status: TagStatus.selected),
          const Divider(height: 10),
          renderTagGroup(tags: _unselectedTagsFiltered),
        ]),
      ),
      bottomNavigationBar: renderMainBottomButton('Done', null),
    );
  }

  Widget renderTagGroup(
      {required Set<Tag> tags, TagStatus status = TagStatus.unselected}) {
    if (tags.isEmpty) {
      return const Text('No tags found ..',
          style: TextStyle(color: inactiveColor));
    }
    return Wrap(
      direction: Axis.horizontal,
      crossAxisAlignment: WrapCrossAlignment.start,
      spacing: 5,
      runSpacing: 10,
      children:
          tags.map((tag) => renderTag(text: tag.name, status: status)).toList(),
    );
  }
}

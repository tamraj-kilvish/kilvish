import 'package:flutter/material.dart';
import 'style.dart';
import 'common_widgets.dart';
import 'models.dart';

class TagsPage extends StatefulWidget {
  TagsPage({Key? key}) : super(key: key);

  //TODO Expense expense;
  late Set<Tag> _attachedTags;
  late Set<Tag> _allTags;
  late Set<Tag> _unselectedTags;

// had to initialize them with empty else it kept cribbing about these variables not initialized
// not sure I understood why was the cause as initState() is suppose to be called before build()
  late Set<Tag> _attachedTagsFiltered = Set();
  late Set<Tag> _unselectedTagsFiltered = Set();

  @override
  createState() => _TagsPageState();
}

class _TagsPageState extends State<TagsPage> {
  @override
  void initState() {
    super.initState();
    //TODO fetch tags of the expense
    //TODO fetch all the tags locally stored
    widget._allTags = Set.from({
      const Tag(name: 'tag 1'),
      const Tag(name: 'tag 2'),
      const Tag(name: 'tag 3'),
      const Tag(name: 'tag 4'),
      const Tag(name: 'tag 5'),
    });

    widget._attachedTags = Set.from({
      const Tag(name: 'tag 6'),
      const Tag(name: 'tag 7'),
    });
    widget._attachedTagsFiltered = Set.from(widget._attachedTags);

    widget._unselectedTags = widget._allTags.difference(widget._attachedTags);
    widget._unselectedTagsFiltered = Set.from(widget._unselectedTags);
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
        title: appBarSearchInput(),
        actions: null,
      ),
      body: Container(
        margin: const EdgeInsets.all(5.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          renderTagGroup(
              tags: widget._attachedTagsFiltered, status: TagStatus.selected),
          const Divider(height: 10),
          renderTagGroup(tags: widget._unselectedTagsFiltered),
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

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

  late Set<Tag> _attachedTagsFiltered;
  late Set<Tag> _unselectedTagsFiltered;

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
      const Tag(name: 'tag 6'),
      const Tag(name: 'tag 7'),
    });

    _attachedTags = Set.from({
      const Tag(name: 'tag 6'),
      const Tag(name: 'tag 7'),
    });

    _renderTagsWithoutFiltering();

    _searchController.addListener(() {
      String searchText = _searchController.text.trim().toLowerCase();

      setState(() {
        if (searchText.isEmpty) {
          _renderTagsWithoutFiltering();
          return;
        }
        _attachedTagsFiltered = Set();
        _attachedTags.map((tag) {
          if (tag.name.contains(searchText)) _attachedTagsFiltered.add(tag);
        });

        _unselectedTagsFiltered = Set();
        _unselectedTags.map((tag) {
          if (tag.name.contains(searchText)) _unselectedTagsFiltered.add(tag);
        });
        _unselectedTagsFiltered = _unselectedTagsFiltered.take(10).toSet();
      });
    });
  }

  void _renderTagsWithoutFiltering() {
    _attachedTagsFiltered = Set.from(_attachedTags);

    _unselectedTags = _allTags.difference(_attachedTags);
    //there could be a lot of unselected tags, taking only first 10
    _unselectedTagsFiltered = _unselectedTags.take(10).toSet();
  }

  @override
  void dispose() {
    _searchController.dispose();
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
          Container(
            margin: const EdgeInsets.all(5.0),
            child: renderPrimaryColorLabel(text: 'Attached Tags'),
          ),
          _renderTagGroup(
              tags: _attachedTagsFiltered, status: TagStatus.selected),
          Container(
            margin: const EdgeInsets.only(top: 5.0),
            child: const Divider(height: 10),
          ),
          Container(
            margin: const EdgeInsets.all(5.0),
            child: Column(children: [
              renderPrimaryColorLabel(text: 'All Tags'),
              renderHelperText(text: 'only 10 tags are shown')
            ]),
          ),
          _renderTagGroup(tags: _unselectedTagsFiltered),
        ]),
      ),
      bottomNavigationBar: renderMainBottomButton('Done', null),
    );
  }

  Widget _renderTagGroup(
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
      children: tags.map((tag) {
        return renderTag(
            text: tag.name,
            status: status,
            onPressed: status == TagStatus.selected
                ? () {
                    setState(() {
                      _attachedTags.remove(tag);
                      _renderTagsWithoutFiltering();
                    });
                  }
                : () {
                    setState(() {
                      _attachedTags.add(tag);
                      _renderTagsWithoutFiltering();
                    });
                  });
      }).toList(),
    );
  }
}

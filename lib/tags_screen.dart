import 'package:collection/collection.dart';

import 'package:flutter/material.dart';
import 'style.dart';
import 'common_widgets.dart';
import 'models.dart';

class TagsPage extends StatefulWidget {
  const TagsPage({Key? key}) : super(key: key);
  @override
  createState() => _TagsPageState();
}

class _TagsPageState extends State<TagsPage> {
  //TODO Expense expense;
  late Set<Tag> _attachedTags;
  late Set<Tag> _attachedTagsOriginal;
  late Set<Tag> _allTags;
  late Set<Tag> _unselectedTags;

  late Set<Tag> _attachedTagsFiltered;
  late Set<Tag> _unselectedTagsFiltered;

  // map of modified tags to show user what has changed
  // also these tags need to be saved post operation completion
  final Map<Tag, TagStatus> _modifiedTags = {};

  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();

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

    //TODO fetch tags of the expense
    _attachedTags = Set.from({
      const Tag(name: 'tag 6'),
      const Tag(name: 'tag 7'),
    });

    //For quick lookup to decide which are newly added tags
    _attachedTagsOriginal = Set.from(_attachedTags);

    _renderTagsFromCurrentState();

    _searchController.addListener(() {
      String searchText = _searchController.text.trim().toLowerCase();

      setState(() {
        if (searchText.isEmpty) {
          _renderTagsFromCurrentState();
          return;
        }
        _attachedTagsFiltered = _attachedTags
            .map((tag) {
              if (tag.name.contains(searchText)) return tag;
            })
            .whereNotNull()
            .toSet();

        //ensuring modifiedTags are always on the front & visible to the user
        _unselectedTagsFiltered = _modifiedTags.entries
            .map((entry) =>
                (entry.value == TagStatus.unselected) ? entry.key : null)
            .whereNotNull()
            .toSet()
            .union(_unselectedTags)
            .map((tag) => tag.name.contains(searchText) ? tag : null)
            .whereNotNull()
            .take(10)
            .toSet();
      });
    });
  }

  void _renderTagsFromCurrentState() {
    _attachedTagsFiltered = Set.from(_attachedTags);

    _unselectedTags = _allTags.difference(_attachedTags);
    //there could be a lot of unselected tags, taking only first 10
    _unselectedTagsFiltered = _modifiedTags.entries
        .map(
            (entry) => (entry.value == TagStatus.unselected) ? entry.key : null)
        .whereNotNull()
        .toSet()
        .union(_unselectedTags)
        .take(10)
        .toSet();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        //leading: const BackButton(),
        title: appBarSearchInput(controller: _searchController),
      ),
      body: Container(
        margin: const EdgeInsets.all(5.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            margin: const EdgeInsets.all(5.0),
            child: renderPrimaryColorLabel(text: 'Attached Tags'),
          ),
          _renderTagGroup(
              tags: _attachedTagsFiltered,
              status: TagStatus.selected,
              context: context),
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
          _renderTagGroup(tags: _unselectedTagsFiltered, context: context),
        ]),
      ),
      bottomNavigationBar: BottomAppBar(
          child: renderMainBottomButton('Done', () {
        Navigator.pop(context, _attachedTags);
      })),
    );
  }

  Widget _renderTagGroup(
      {required Set<Tag> tags,
      TagStatus status = TagStatus.unselected,
      required BuildContext context}) {
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
            isUpdated: _modifiedTags.containsKey(tag) ? true : false,
            onPressed: () =>
                onTagPressed(tag: tag, status: status, context: context));
      }).toList(),
    );
  }

  Future<void> onTagPressed(
      {required Tag tag,
      TagStatus status = TagStatus.unselected,
      required BuildContext context}) async {
    String? userAction = await showDialog<String>(
        context: context,
        builder: (BuildContext context) {
          return SimpleDialog(
            children: <Widget>[
              SimpleDialogOption(
                onPressed: () {
                  Navigator.pop(context, "Add/Remove");
                },
                child: status == TagStatus.selected
                    ? Text('Remove ${tag.name}')
                    : Text('Add ${tag.name}'),
              ),
              SimpleDialogOption(
                onPressed: () {
                  Navigator.pop(context, "View/Edit");
                },
                child: Text('View/Edit ${tag.name}'),
              ),
            ],
          );
        });

    switch (userAction) {
      case "Add/Remove":
        selectDeselectTag(tag: tag, status: status);
        break;
      case "View/Edit":
        // TODO - send to add/edit tag screen .. as of now, just sending to tags page again
        Navigator.push(
            context, MaterialPageRoute(builder: (context) => const TagsPage()));
        break;
    }
  }

  void selectDeselectTag({required Tag tag, required TagStatus status}) {
    setState(() {
      _modifiedTags.remove(tag);

      if (status == TagStatus.selected) {
        _attachedTags.remove(tag);
        if (_attachedTagsOriginal.contains(tag)) {
          _modifiedTags[tag] = TagStatus.unselected;
        }
      } else {
        _attachedTags.add(tag);
        if (!_attachedTagsOriginal.contains(tag)) {
          _modifiedTags[tag] = TagStatus.selected;
        }
      }

      _renderTagsFromCurrentState();
    });
  }
}

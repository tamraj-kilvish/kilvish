import 'package:collection/collection.dart';

import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:kilvish/old/tag_edit_screen.dart';
import '../style.dart';
import '../common_widgets.dart';
import '../models.dart';

class TagSelectionPage extends StatefulWidget {
  const TagSelectionPage({Key? key}) : super(key: key);
  @override
  createState() => _TagSelectionPageState();
}

class _TagSelectionPageState extends State<TagSelectionPage> {
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

    _calculateRenderingTagValues();

    _searchController.addListener(() {
      String searchText = _searchController.text.trim().toLowerCase();

      setState(() {
        if (searchText.isEmpty) {
          _calculateRenderingTagValues();
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
            .map(
              (entry) =>
                  (entry.value == TagStatus.unselected) ? entry.key : null,
            )
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

  void _calculateRenderingTagValues() {
    _attachedTagsFiltered = Set.from(_attachedTags);

    _unselectedTags = _allTags.difference(_attachedTags);
    //there could be a lot of unselected tags, taking only first 10
    _unselectedTagsFiltered = _modifiedTags.entries
        .map(
          (entry) => (entry.value == TagStatus.unselected) ? entry.key : null,
        )
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.all(5.0),
              child: renderPrimaryColorLabel(text: 'Attached Tags'),
            ),
            _renderTagGroup(
              tags: _attachedTagsFiltered,
              status: TagStatus.selected,
            ),
            Container(
              margin: const EdgeInsets.only(top: 5.0),
              child: const Divider(height: 10),
            ),
            Container(
              margin: const EdgeInsets.all(5.0),
              child: Column(
                children: [
                  renderPrimaryColorLabel(text: 'All Tags'),
                  renderHelperText(text: 'only 10 tags are shown'),
                ],
              ),
            ),
            _renderTagGroup(tags: _unselectedTagsFiltered),
          ],
        ),
      ),
      bottomNavigationBar: BottomAppBar(
        child: renderMainBottomButton('Done', () {
          Navigator.pop(context, _attachedTags);
        }),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: primaryColor,
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const TagEditPage()),
          ).then((newTagName) {
            setState(() {
              if (newTagName != null) {
                _allTags.add(Tag(name: newTagName));
                _calculateRenderingTagValues();
              }
            });
          });
        },
        child: const Icon(Icons.add, color: kWhitecolor),
      ),
    );
  }

  Widget _renderTagGroup({
    required Set<Tag> tags,
    TagStatus status = TagStatus.unselected,
  }) {
    if (tags.isEmpty) {
      return const Text(
        'No tags found ..',
        style: TextStyle(color: inactiveColor),
      );
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
          onPressed: () => executeOnTagButtonPress(tag: tag, status: status),
        );
      }).toList(),
    );
  }

  void executeOnTagButtonPress({required Tag tag, required TagStatus status}) {
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

      _calculateRenderingTagValues();
    });
  }
}

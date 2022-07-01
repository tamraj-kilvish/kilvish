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

    widget._unselectedTags = widget._allTags.difference(widget._attachedTags);
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
        title: renderSearchTagInput(),
        actions: null,
      ),
      body: Container(
        margin: const EdgeInsets.all(5.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(
            direction: Axis.horizontal,
            crossAxisAlignment: WrapCrossAlignment.start,
            spacing: 5,
            runSpacing: 10,
            children: widget._attachedTags
                .map((tag) =>
                    renderTag(text: tag.name, status: TagStatus.selected))
                .toList(),
          ),
          const Divider(height: 10),
          Wrap(
            direction: Axis.horizontal,
            crossAxisAlignment: WrapCrossAlignment.start,
            spacing: 5,
            runSpacing: 10,
            children: widget._unselectedTags
                .map((tag) =>
                    renderTag(text: tag.name, status: TagStatus.unselected))
                .toList(),
          ),
        ]),
      ),
      bottomNavigationBar: renderMainBottomButton('Add Tag', null, false),
    );
  }

  Widget renderSearchTagInput() {
    return const TextField(
      decoration: InputDecoration(
        prefixIcon: Icon(Icons.search, color: Colors.white),
        suffixIcon: IconButton(
          icon: Icon(Icons.clear, color: Colors.white),
          onPressed: null,
        ),
        hintText: 'Search...',
      ),
      cursorColor: Colors.white,
      style: TextStyle(color: Colors.white),
      autofocus: true,
      showCursor: true,
    );
  }

  Widget renderTag(
      {required String text, TagStatus status = TagStatus.unselected}) {
    return TextButton(
      style: TextButton.styleFrom(
        backgroundColor:
            status == TagStatus.selected ? primaryColor : inactiveColor,
        shape: const StadiumBorder(),
      ),
      onPressed: null,
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
                text: '$text ',
                style: const TextStyle(color: Colors.white, fontSize: 15)),
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Icon(
                status == TagStatus.selected
                    ? Icons.clear_rounded
                    : Icons.add_circle_outline_sharp,
                color: Colors.white,
                size: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

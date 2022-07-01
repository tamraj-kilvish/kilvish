import 'package:flutter/material.dart';
import 'style.dart';
import 'common_widgets.dart';

class TagsPage extends StatefulWidget {
  const TagsPage({Key? key}) : super(key: key);

  @override
  createState() => _TagsPageState();
}

class _TagsPageState extends State<TagsPage> {
  @override
  void initState() {
    super.initState();
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
            children: [renderTag(), renderTag()],
          ),
          const Divider(height: 10),
          Wrap(
            direction: Axis.horizontal,
            crossAxisAlignment: WrapCrossAlignment.start,
            spacing: 5,
            runSpacing: 10,
            children: [renderTag(), renderTag()],
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

  Widget renderTag() {
    return TextButton(
      style: TextButton.styleFrom(
        backgroundColor: primaryColor,
        shape: const StadiumBorder(),
      ),
      onPressed: null,
      child: RichText(
        text: const TextSpan(
          children: [
            TextSpan(
                text: 'tag text ',
                style: TextStyle(color: Colors.white, fontSize: 15)),
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Icon(
                Icons.clear_rounded,
                color: Colors.white,
                size: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

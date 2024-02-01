import 'package:flutter/material.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/constants/dimens_constants.dart';
import 'package:kilvish/contact_screen.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/style.dart';

class TagEditPage extends StatefulWidget {
  const TagEditPage({Key? key}) : super(key: key);

  @override
  createState() => _TagEditPageState();
}

class _TagEditPageState extends State<TagEditPage> {
  final Set<Tag> _peopleList =
      Set.from({const Tag(name: 'Ashish'), const Tag(name: 'Ruchi')});
  TextEditingController _tagNameController = TextEditingController();

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
          title: Row(children: [
            renderImageIcon(Icons.turned_in),
            const Text("Add/Edit Tag")
          ]),
        ),
        body: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: DimensionConstants.leftPadding15,
                vertical: DimensionConstants.topPadding10),
            child: SingleChildScrollView(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  renderPrimaryColorLabel(
                    text: "Tag Name",
                  ),
                  SizedBox(
                    height: DimensionConstants.containerHeight40,
                    child: TextFormField(
                        onChanged: (String val) {
                          _tagNameController.text = val;
                        },
                        controller: _tagNameController,
                        maxLines: 1,
                        cursorColor: primaryColor,
                        decoration: customUnderlineInputdecoration(
                            hintText:
                                'Group or category name for collating expense',
                            bordersideColor: primaryColor)),
                  ),
                  renderPrimaryColorLabel(
                      text: "People with whom tag is shared"),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      renderTagGroup(
                          tags: _peopleList,
                          status: TagStatus.selected,
                          onPressed: ({Tag? tag}) {
                            setState(() {
                              _peopleList.remove(tag);
                            });
                          }),
                      const Spacer(),
                      customContactUi(onTap: () {
                        Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (context) => ContactScreen()));
                        // _contactFetchFn
                      }),
                    ],
                  )
                ]))),
        bottomNavigationBar: BottomAppBar(
            child: renderMainBottomButton('Done', () {
          Navigator.pop(context, _tagNameController.text);
        })));
  }
}

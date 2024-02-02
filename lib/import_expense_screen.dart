import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:kilvish/constants/dimens_constants.dart';
import 'package:flutter/scheduler.dart';
import 'package:kilvish/contact_screen.dart';
import 'package:kilvish/home_screen.dart';
import 'package:kilvish/style.dart';
import 'package:kilvish/tag_selection_screen.dart';
import '../common_widgets.dart';
import 'dart:io';
import 'models.dart';

class MediaPreviewItem {
  int? id;
  File? resource;
  bool isSelected;
  TextEditingController? controller;

  MediaPreviewItem(
      {this.id, this.resource, this.controller, this.isSelected = false});
}

class ImportExpensePage extends StatefulWidget {
  final String title = 'Killvish';
  final List<File>? files;
  final String? text;

  const ImportExpensePage({super.key, this.files, this.text = ""});

  @override
  State<ImportExpensePage> createState() => _ImportExpensePageState();
}

class _ImportExpensePageState extends State<ImportExpensePage> {
  final PageController _pageController =
      PageController(initialPage: 0, viewportFraction: 0.95, keepPage: false);
  final List<MediaPreviewItem> _galleryItems = [];
  int _initialIndex = 0;
  XFile? _imageFile;
  TextEditingController amountcon = TextEditingController();
  TextEditingController namecon = TextEditingController();
  String pickedname = "";
  Set<Tag> tagList =
      Set.from({const Tag(name: 'Ashish'), const Tag(name: 'Ruchi')});

  Future<void> _pickImage() async {
    final pickedFile =
        await ImagePicker().pickImage(source: ImageSource.gallery);

    setState(() {
      _imageFile = pickedFile;
    });
  }

  Widget crossButtonTopRightForImage() {
    return Positioned(
        right: 10,
        top: 10,
        child: InkWell(
          onTap: () {
            setState(() {
              _imageFile = null;
            });
          },
          child: Container(
              decoration: const BoxDecoration(
                  color: primaryColor, shape: BoxShape.circle),
              child: const Padding(
                padding: EdgeInsets.all(5.0),
                child: Icon(
                  Icons.clear,
                  color: kWhitecolor,
                ),
              )),
        ));
  }

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPostFrameCallback((timeStamp) {
      if (widget.files != null) {
        if (widget.files!.isNotEmpty) {
          setState(() {
            _imageFile = XFile(widget.files!.first.path);
            // var i = 0;
            // widget.files?.forEach((element) {
            //   _galleryItems.add(MediaPreviewItem(
            //       id: i,
            //       resource: element,
            //       controller: TextEditingController(),
            //       isSelected: i == 0 ? true : false));
            //   i++;
            // });
          });
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: appBarTitleText('Import Expense'),
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: DimensionConstants.leftPadding15,
            vertical: DimensionConstants.topPadding10),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              /*
                Amount
              */
              renderPrimaryColorLabel(
                text: "Amount",
              ),
              SizedBox(
                height: DimensionConstants.containerHeight40,
                child: TextFormField(
                    onChanged: (val) {
                      amountcon.text = val;
                    },
                    controller: amountcon,
                    maxLines: 1,
                    cursorColor: primaryColor,
                    decoration: customUnderlineInputdecoration(
                        hintText: 'Enter Amount',
                        bordersideColor: primaryColor)),
              ),
              /*
                To
              */
              renderPrimaryColorLabel(text: "To"),
              pickedname.isNotEmpty
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        renderTag(
                            text: pickedname,
                            status: TagStatus.selected,
                            onPressed: () {
                              setState(() {
                                pickedname = "";
                                namecon.clear();
                              });
                            }),
                        const Spacer(),
                        customContactUi(onTap: () {
                          Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (context) => ContactScreen()));
                        }
                            // onTap: _contactFetchFn
                            ),
                      ],
                    )
                  : TextFormField(
                      controller: namecon,
                      maxLines: 1,
                      cursorColor: primaryColor,
                      decoration: customUnderlineInputdecoration(
                        hintText: 'Enter Name or select from contact',
                        bordersideColor: primaryColor,
                        suffixicon: customContactUi(onTap: () {
                          Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (context) => const ContactScreen(
                                      contactSelection: ContactSelection
                                          .multiSelect))).then((value) {
                            if (value != null) {
                              if (value is ContactModel) {
                                namecon.text = value.name;
                              } else if (value is List<ContactModel>) {
                                List<String> temp=[];
                                value.forEach((element) {
                                  temp.add(element.name);
                                });
                                namecon.text = temp.join(",");
                              }
                            }
                          });
                        }),
                      )),
              /*
               render Receipt/Screenshot
              */
              renderPrimaryColorLabel(text: "Receipt/ Screenshot"),
              const SizedBox(height: DimensionConstants.sizedBoxHeight5),
              _imageFile != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(15),
                      child: Stack(children: [
                        Image.file(
                          File(_imageFile!.path),
                          width: MediaQuery.of(context).size.width,
                          height: 400,
                          fit: BoxFit
                              .fitHeight, //this will ensure the image is not distorted
                        ),
                        crossButtonTopRightForImage()
                      ]),
                    )
                  : InkWell(
                      onTap: _pickImage,
                      child: Container(
                        width: MediaQuery.of(context).size.width,
                        height: DimensionConstants.containerHeight200,
                        decoration: BoxDecoration(
                          color: borderCustom,
                          borderRadius: BorderRadius.circular(
                              DimensionConstants.circular15),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.image,
                              size: DimensionConstants.containerHeight60,
                              color: inactiveColor,
                            ),
                            const SizedBox(
                              height: 5,
                            ),
                            customText("Tap to Select Image", kTextMedium,
                                smallFontSize, FontWeight.w400)
                          ],
                        ),
                      ),
                    ),
              /*
                Tag
              */
              renderPrimaryColorLabel(text: "Tags"),
              tagList.isNotEmpty
                  ? renderTagGroup(
                      tags: tagList,
                      status: TagStatus.selected,
                      onPressed: ({Tag? tag}) {
                        Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (context) =>
                                    const TagSelectionPage())).then((value) {
                          setState(() {
                            if (value != null) {
                              tagList = value.toSet();
                            }
                          });
                        });
                      })
                  : TextFormField(
                      onTap: () {
                        Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (context) =>
                                    const TagSelectionPage())).then((value) {
                          setState(() {
                            if (value != null) {
                              tagList = value.toSet();
                            }
                          });
                        });
                      },
                      readOnly: true,
                      maxLines: 1,
                      cursorColor: primaryColor,
                      decoration: customUnderlineInputdecoration(
                          hintText: 'Click to select tags',
                          bordersideColor: primaryColor)),

              //_fullMediaPreview(context),
            ],
          ),
        ),
      ),
      bottomNavigationBar: BottomAppBar(
        child: renderMainBottomButton('Add', () {
          if (Navigator.canPop(context)) {
            Navigator.pop(context);
          } else {
            // take to home page
            Navigator.push(context,
                MaterialPageRoute(builder: (context) => const HomePage()));
          }
        }),
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}

import 'package:flutter/material.dart';
import 'package:fluttercontactpicker/fluttercontactpicker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:kilvish/constants/dimens_constants.dart';
import 'package:flutter/scheduler.dart';
import 'package:kilvish/style.dart';
import 'package:kilvish/tags_screen.dart';
import '../common_widgets.dart';
import 'dart:io';

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
  PhoneContact? _phoneContact;
  XFile? _imageFile;
  TextEditingController amountcon = TextEditingController();
  TextEditingController namecon = TextEditingController();
  String pickedname = "";
  List tagList = [];

  Future<void> _pickImage() async {
    final pickedFile = await ImagePicker().pickImage(source: ImageSource.gallery);

    setState(() {
      _imageFile = pickedFile;
    });
  }


  contactFetchFn() async {
    bool permission = await FlutterContactPicker.requestPermission();
    if (permission) {
      if (await FlutterContactPicker.hasPermission()) {
        _phoneContact = await FlutterContactPicker.pickPhoneContact();
        if (_phoneContact != null) {
          if (_phoneContact!.fullName!.isNotEmpty) {
            setState(() {
              pickedname = _phoneContact!.fullName.toString();
              namecon.text = _phoneContact!.fullName.toString();
            });
          }

          if (_phoneContact!.phoneNumber!.number!.isNotEmpty) {}
        }
      }
    }
  }

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPostFrameCallback((timeStamp) {
      setState(() {
        var i = 0;
        widget.files?.forEach((element) {
          _galleryItems.add(MediaPreviewItem(
              id: i,
              resource: element,
              controller: TextEditingController(),
              isSelected: i == 0 ? true : false));
          i++;
        });
      });
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
              const SizedBox(height: DimensionConstants.sizedBoxHeight5),
              headertext("Amount"),
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
              const SizedBox(height: DimensionConstants.leftPadding15),
              headertext("To"),
              pickedname.isNotEmpty
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(
                          height: DimensionConstants.sizedBoxHeight5,
                        ),
                        Row(
                          children: [
                            customSelecteData(text: pickedname, ontap:  () {
                              setState(() {
                                pickedname = "";
                                namecon.clear();
                              });
                            },),
                            const Spacer(),
                            customContactUi(onTap: contactFetchFn),
                          ],
                        ),
                        const SizedBox(
                          height: DimensionConstants.sizedBoxHeight5,
                        ),
                        Container(
                          width: MediaQuery.of(context).size.width,
                          height: 1,
                          color: bordercolor,
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
                          suffixicon: customContactUi(onTap: contactFetchFn),)),
              const SizedBox(height: DimensionConstants.leftPadding15),
              headertext("Receipt/ Screenshot"),
              const SizedBox(height: DimensionConstants.sizedBoxHeight5),
              _imageFile != null?ClipRRect(
                borderRadius: BorderRadius.circular(15),

                child: Stack(
                  children: [
                    Image.file(File(_imageFile!.path),
                    width: MediaQuery.of(context).size.width,
                    height: DimensionConstants.containerHeight200,fit: BoxFit.fill,),

                    Positioned(
                        right: 10,
                        top: 10,
                        child: InkWell(
                          onTap: (){
                            setState(() {
                              _imageFile = null;
                            });
                          },
                          child: Container(
                              decoration: const BoxDecoration(
                                color: primaryColor,
                                shape: BoxShape.circle
                              ),
                              child: const Padding(
                                padding: EdgeInsets.all(5.0),
                                child: Icon(Icons.clear,color: kWhitecolor,),
                              )),
                        ))
                ]),
              ):
              InkWell(
                onTap: _pickImage,
                child: Container(
                  width: MediaQuery.of(context).size.width,
                  height: DimensionConstants.containerHeight200,
                  decoration: BoxDecoration(
                    color: borderCustom,
                    borderRadius:
                        BorderRadius.circular(DimensionConstants.circular15),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.image,
                        size: DimensionConstants.containerHeight60,
                        color: inactiveColor,
                      ),
                      const SizedBox(height: 5,),
                      customText("Tap to Select Image", kTextMedium, smallFontSize, FontWeight.w400)
                    ],
                  ),
                ),
              ),
              const SizedBox(height: DimensionConstants.leftPadding15),
              headertext("Tags"),
              tagList.isNotEmpty
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(
                          height: DimensionConstants.sizedBoxHeight5,
                        ),
                        GridView.builder(
                          padding: EdgeInsets.zero,
                          scrollDirection: Axis.vertical,
                          shrinkWrap: true,
                          physics:
                          const NeverScrollableScrollPhysics(),
                          itemCount: tagList.length,
                          gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 10,
                              mainAxisExtent: 50),
                          itemBuilder: (context, index) {
                            var item = tagList[index];
                            return  customSelecteData(text: item.name, ontap: (){
                              setState(() {
                                tagList.removeAt(index);
                              });
                            });
                          },
                        ),

                        const SizedBox(
                          height: DimensionConstants.sizedBoxHeight5,
                        ),
                        Container(
                          width: MediaQuery.of(context).size.width,
                          height: 1,
                          color: bordercolor,
                        ),
                      ],
                    )
                  : SizedBox(
                      height: DimensionConstants.containerHeight40,
                      child: TextFormField(
                          onTap: (){
                            Navigator.push(context, MaterialPageRoute(builder: (context) => const TagsPage())).then((value) {
                              setState(() {
                                if(value != null){
                                tagList = value.toList();
                                }
                              });
                            });
                          },
                          readOnly: true,
                          maxLines: 1,
                          cursorColor: primaryColor,
                          decoration: customUnderlineInputdecoration(
                              hintText: 'Select',
                              bordersideColor:primaryColor)
                      ),
              ),

              //_fullMediaPreview(context),
            ],
          ),
        ),
      ),
      bottomNavigationBar: BottomAppBar(
        child: renderMainBottomButton('Add', () {}),
      ),
    );
  }

  Widget customSelecteData ({required String text,required Function() ontap}){
    return  Container(
      decoration: BoxDecoration(
          color: Colors.pink[50],
          border: Border.all(color: primaryColor),
          borderRadius: BorderRadius.circular(
              DimensionConstants.circular20)),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            customText(text, primaryColor, 14,
                FontWeight.w500),
            InkWell(
                onTap:ontap,
                child: const Icon(
                  Icons.close,
                  color: primaryColor,
                ))
          ],
        ),
      ),
    );
  }

  Widget _fullMediaPreview(BuildContext context) => Expanded(
          child: PageView(
        controller: _pageController,
        physics: const ClampingScrollPhysics(),
        scrollDirection: Axis.horizontal,
        onPageChanged: (value) {
          _mediaPreviewChanged(value);
        },
        children: _galleryItems
            .map((e) => AppConstants.imageExtensions
                    .contains(e.resource?.path.split('.').last.toLowerCase())
                ? Image.file(File(e.resource!.path))
                : Image.asset(
                    FileConstants.icFile,
                  ))
            .toList(),
      ));

  void _mediaPreviewChanged(int value) {
    _initialIndex = value;
    setState(() {
      var i = 0;
      for (var element in _galleryItems) {
        if (i == value) {
          _galleryItems[i].isSelected = true;
        } else {
          _galleryItems[i].isSelected = false;
        }
        i++;
      }
    });
  }

  @override
  void dispose() {
    super.dispose();
  }
}

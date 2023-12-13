import 'package:flutter/material.dart';
import 'package:kilvish/constants/dimens_constants.dart';
import 'package:flutter/scheduler.dart';
import 'package:kilvish/import_screen_section/personselector_screen.dart';
import 'package:kilvish/style.dart';
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
  TextEditingController amountcon = TextEditingController();
  bool isPersonSelected = false;
  bool isTagSelected = false;
  String pickedname = "";
  String pickednumber = "";


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
          title: customText('Import Expense', kWhitecolor, FontSizeWeightConstants.fontSize20, FontSizeWeightConstants.fontWeight500),
        ),
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: DimensionConstants.leftPadding15,vertical: DimensionConstants.topPadding10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: DimensionConstants.sizedBoxHeight5),
              headertext("Amount"),
              SizedBox(
                height: DimensionConstants.containerHeight40,
                child: TextFormField(
                    onChanged: (val){
                      amountcon.text = val;
                    },
                    controller: amountcon,
                    maxLines: 1,
                    cursorColor: primaryColor,
                    decoration: customUnderlineInputdecoration(
                        hintText: 'Enter Amount',
                        bordersideColor:primaryColor)
                ),
              ),
              const SizedBox(height: DimensionConstants.leftPadding15),
              headertext("To"),
              isPersonSelected?Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: DimensionConstants.sizedBoxHeight5,),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.pink[50],
                      border: Border.all(color: primaryColor),
                      borderRadius: BorderRadius.circular(DimensionConstants.circular20)
                    ),

                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: customText(pickedname, primaryColor, 14, FontWeight.w500),
                    ),
                  ),
                  const SizedBox(height: DimensionConstants.sizedBoxHeight5,),
                  Container(
                    width: MediaQuery.of(context).size.width,
                    height: 1,
                    color: bordercolor,

                  ),
                ],
              ):
              SizedBox(
                height: DimensionConstants.containerHeight40,
                child: TextFormField(
                  onTap: (){
                    Navigator.push(context, MaterialPageRoute(builder: (context)=> PersonSelectorScreen())).then((value) {
                      print("val -${value}");
                      pickedname = value['name'];
                      pickednumber = value['number'];
                      if(pickedname != ""){
                        isPersonSelected = true;
                      }
                      setState(() {

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
              const SizedBox(height: DimensionConstants.leftPadding15),
              headertext("Receipt/ Screenshot"),
              const SizedBox(height: DimensionConstants.sizedBoxHeight5),
              Container(
                width: MediaQuery.of(context).size.width,
                height: DimensionConstants.containerHeight200,
                decoration: BoxDecoration(
                  color: borderCustom,
                  borderRadius: BorderRadius.circular(DimensionConstants.circular15),
                ),
                child: const Icon(Icons.image,size:  DimensionConstants.containerHeight60,color: kGrey,),
              ),
              const SizedBox(height: DimensionConstants.leftPadding15),
              headertext("Tags"),
              isTagSelected?Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: DimensionConstants.sizedBoxHeight5,),
                  Container(
                    decoration: BoxDecoration(
                        color: Colors.pink[50],
                        border: Border.all(color: primaryColor),
                        borderRadius: BorderRadius.circular(DimensionConstants.circular20)
                    ),

                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: customText(pickedname, primaryColor, 14, FontWeight.w500),
                    ),
                  ),
                  const SizedBox(height: DimensionConstants.sizedBoxHeight5,),
                  Container(
                    width: MediaQuery.of(context).size.width,
                    height: 1,
                    color: bordercolor,

                  ),
                ],
              ):
              SizedBox(
                height: DimensionConstants.containerHeight40,
                child: TextFormField(
                    onTap: (){
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
      bottomNavigationBar: BottomAppBar(
        child: renderMainBottomButton('Add', (){

        }),
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

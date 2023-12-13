import 'package:flutter/material.dart';
import 'package:kilvish/constants/dimens_constants.dart';
import 'package:flutter/scheduler.dart';
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

class HandleShare extends StatefulWidget {
  final String title = 'Killvish';
  final List<File>? files;
  final String? text;

  const HandleShare({super.key, this.files, this.text = ""});

  @override
  State<HandleShare> createState() => _HandleShareScreenState();
}

class _HandleShareScreenState extends State<HandleShare> {
  final PageController _pageController =
      PageController(initialPage: 0, viewportFraction: 0.95, keepPage: false);
  final List<MediaPreviewItem> _galleryItems = [];
  int _initialIndex = 0;
  TextEditingController amountcon = TextEditingController();



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
          // leading: appBarMenu(null),
          title: customText('Import Expense', kWhitecolor, FontSizeWeightConstants.fontSize20, FontSizeWeightConstants.fontWeight500),
          // actions: <Widget>[
          //   appBarSearchIcon(null),
          //   appBarRightMenu(null),
          // ],
        ),
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: DimensionConstants.leftPadding15,vertical: DimensionConstants.topPadding10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: DimensionConstants.sizedBoxHeight5),
              headertext("Amount"),
              SizedBox(
                height: 40,
                child: TextFormField(
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
              SizedBox(
                height: 40,
                child: TextFormField(
                  readOnly: true,
                    maxLines: 1,
                    cursorColor: primaryColor,
                    decoration: customUnderlineInputdecoration(
                        hintText: 'Select',
                        bordersideColor:primaryColor)
                ),
              )

              //_fullMediaPreview(context),
            ],
          ),
        ));
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

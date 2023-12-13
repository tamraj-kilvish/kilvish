import 'package:flutter/material.dart';
import 'package:fluttercontactpicker/fluttercontactpicker.dart';

import '../common_widgets.dart';
import '../constants/dimens_constants.dart';
import '../style.dart';

class PersonSelectorScreen extends StatefulWidget {
  const PersonSelectorScreen({Key? key}) : super(key: key);

  @override
  State<PersonSelectorScreen> createState() => _PersonSelectorScreenState();
}

class _PersonSelectorScreenState extends State<PersonSelectorScreen> {
  
  PhoneContact? _phoneContact;
  String pickedname = "";
  String pickednumber = "";
  TextEditingController namecon = TextEditingController();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: customText('Select Person', kWhitecolor, FontSizeWeightConstants.fontSize20, FontSizeWeightConstants.fontWeight500),
        actions: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: InkWell(
                onTap: (){
                  Navigator.pop(context,{'name':pickedname,'number':pickednumber});
                },
                child: customText("Done", kWhitecolor, FontSizeWeightConstants.fontSize16,FontSizeWeightConstants.fontWeight500)),
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: DimensionConstants.leftPadding15,vertical: DimensionConstants.topPadding10),
        child: Column(
          children: [
            TextFormField(
                controller: namecon,
                maxLines: 1,
                cursorColor: primaryColor,
                decoration: customUnderlineInputdecoration(
                    hintText: 'Enter Name or select from contact',
                    bordersideColor:primaryColor,suffixicon: InkWell(
                    onTap: ()async{
                      bool permission = await FlutterContactPicker.requestPermission();
                      if(permission){
                        if(await FlutterContactPicker.hasPermission()){
                          _phoneContact = await FlutterContactPicker.pickPhoneContact();
                          if(_phoneContact != null){
                            if(_phoneContact!.fullName!.isNotEmpty){
                              pickedname = _phoneContact!.fullName.toString();
                              namecon.text = _phoneContact!.fullName.toString();
                              setState(() {
                                
                              });
                              
                            }

                            if(_phoneContact!.phoneNumber!.number!.isNotEmpty){
                              pickednumber = _phoneContact!.phoneNumber!.number.toString();
                              setState(() {

                              });

                            }
                          }
                        }
                      }else{
                        
                      }
                    },
                    child: const Icon(Icons.contact_page,color: primaryColor,size: 35,)))
            ),
          ],
        ),
      ),
    );
  }
}

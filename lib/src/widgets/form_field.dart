import 'package:flutter/material.dart';
import '../../home.dart';

const MaterialColor primaryColor = Colors.pink;
const TextStyle textStylePrimaryColor = TextStyle(color: primaryColor);

class CustomFormField extends StatelessWidget {
  final String stepNumber;
  final String fieldLabel;
  final String buttonLabel;
  final bool onPressed;
  final Function? fieldValidation;
  final String hint;
  final VoidCallback? buttonClickHandler;
  const CustomFormField(
    String s, {
    this.stepNumber = '',
    required this.fieldLabel,
    this.onPressed = false,
    this.buttonLabel = '',
    required this.hint,
    this.buttonClickHandler,
    this.fieldValidation,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      const Divider(height: 50),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.fitWidth,
            child: Container(
              margin: const EdgeInsets.only(right: 50),
              child: Text(stepNumber,
                  style: const TextStyle(fontSize: 50.0, color: Colors.grey)),
            ),
          ),
          Expanded(
            child: Column(
              children: [
                TextFormField(
                  decoration:
                      InputDecoration(hintText: hint, labelText: fieldLabel),
                  validator: (value) => fieldValidation!(value),
                ),
                Container(
                  margin: const EdgeInsets.only(top: 10),
                  child: TextButton(
                    style: TextButton.styleFrom(
                        backgroundColor: primaryColor,
                        minimumSize: const Size.fromHeight(50)),
                    onPressed: onPressed
                        ? () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (context) {
                                return HomePage(title: 'Home Screen');
                              }),
                            );
                          }
                        : null,
                    child: Text(buttonLabel,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 15)),
                  ),
                )
              ],
            ),
          ),
        ],
      ),
    ]);
  }
}

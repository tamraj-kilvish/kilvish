import 'package:flutter/material.dart';
import 'constants.dart';

class SignUpPage extends StatefulWidget {
  const SignUpPage({Key? key}) : super(key: key);

  @override
  SignUpPageState createState() => SignUpPageState();
}

class SignUpPageState extends State<SignUpPage> {
  int stepNumber = 1;

  void allowFormSubmission() {
    print("here");
    setState(() {
      stepNumber += 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      body: Container(
        padding: const EdgeInsets.all(50),
        child: ListView(
          children: <Widget>[
            Center(
              child: Column(
                children: [
                  Image.asset(
                    'images/kilvish.png',
                    width: 100,
                    height: 100,
                    fit: BoxFit.fitWidth,
                  ),
                  FittedBox(
                    fit: BoxFit.fitWidth,
                    child: Container(
                      margin: const EdgeInsets.only(top: 10),
                      child: const Text("Kilvish in 3 steps",
                          style:
                              TextStyle(fontSize: 50.0, color: inactiveColor)),
                    ),
                  ),
                  FittedBox(
                    fit: BoxFit.fitWidth,
                    child: Container(
                      margin: const EdgeInsets.only(top: 30),
                      child: const Text(
                          "A better way to track & recover expenses",
                          style:
                              TextStyle(fontSize: 20.0, color: inactiveColor)),
                    ),
                  ),
                ],
              ),
            ),
            SignupForm(
              stepNumber: "1",
              fieldLabel: "Phone Number",
              buttonLabel: "Get OTP",
              hint: "7019316063",
              isActive: stepNumber == 1,
              // the functions are passed from here as stepNumber variable is defined in this class
              buttonClickHandler: allowFormSubmission,
            ),
            SignupForm(
              stepNumber: "2",
              fieldLabel: "Enter OTP",
              buttonLabel: "Verify OTP",
              hint: "1234",
              isActive: stepNumber == 2,
              buttonClickHandler: allowFormSubmission,
            ),
            SignupForm(
              stepNumber: "3",
              fieldLabel: "Setup Kilvish Id",
              buttonLabel: "Get Started",
              hint: "crime-master-gogo",
              isActive: stepNumber == 3,
              buttonClickHandler: allowFormSubmission,
            ),
          ],
        ),
      ),
    );
  }
}

//This function need to be kept global else the compiler cribbed about not accessible in SignupForm constructor
String? genericFieldValidator(value) {
  print("in generic validator");
  if (value == null || value.isEmpty) {
    return 'Please enter some text';
  }
  return null;
}

class SignupForm extends StatefulWidget {
  final String stepNumber;
  final String fieldLabel;
  final String buttonLabel;
  final String hint;
  final bool isActive;
  final String? Function(String?) fieldValidator;
  final void Function() buttonClickHandler;

  const SignupForm({
    required this.stepNumber,
    required this.fieldLabel,
    required this.buttonLabel,
    required this.hint,
    required this.isActive,
    required this.buttonClickHandler,
    String? Function(String?)? fieldvalidator,
    super.key,
  }) : fieldValidator = fieldvalidator ?? genericFieldValidator;

  @override
  SignupFormState createState() => SignupFormState();
}

class SignupFormState extends State<SignupForm> {
  final _formKey = GlobalKey<
      FormState>(); //this field has made the class stateful. Now we have stateful class within stateful which is bad but I could not get it to work otherwise

  void denyFormSubmission() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('This form is locked')),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Build a Form widget using the _formKey created above.
    return Form(
      key: _formKey,
      child: Column(children: [
        const Divider(height: 50),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.fitWidth,
              child: Container(
                margin: const EdgeInsets.only(right: 50),
                child: Text(widget.stepNumber,
                    style: TextStyle(
                        fontSize: 50.0,
                        color:
                            (widget.isActive) ? Colors.black : inactiveColor)),
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(widget.fieldLabel,
                        style: (widget.isActive)
                            ? textStylePrimaryColor
                            : textStyleInactive),
                  ),
                  TextFormField(
                      decoration: InputDecoration(
                        hintText: widget.isActive ? widget.hint : "",
                      ),
                      validator: widget.fieldValidator),
                  Container(
                    margin: const EdgeInsets.only(top: 10),
                    child: TextButton(
                      style: TextButton.styleFrom(
                          backgroundColor:
                              (widget.isActive) ? primaryColor : inactiveColor,
                          minimumSize: const Size.fromHeight(50)),
                      onPressed: () {
                        if (!widget.isActive) {
                          return denyFormSubmission();
                        }
                        if (_formKey.currentState!.validate()) {
                          widget.buttonClickHandler();
                        }
                      },
                      child: Text(widget.buttonLabel,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 15)),
                    ),
                  )
                ],
              ),
            ),
          ],
        ),
      ]),
    );
  }
}

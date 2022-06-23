import 'package:flutter/material.dart';
import 'style.dart';
import 'home_screen.dart';

class SignUpPage extends StatefulWidget {
  const SignUpPage({Key? key}) : super(key: key);

  @override
  SignUpPageState createState() => SignUpPageState();
}

class SignUpPageState extends State<SignUpPage> {
  int _stepNumber = 1;
  late FocusNode textFocus;

  @override
  void initState() {
    super.initState();
    textFocus = FocusNode();
  }

  @override
  void dispose() {
    // Clean up the focus node when the Form is disposed.
    textFocus.dispose();
    super.dispose();
  }

  void allowFormSubmission(int stepNumber) {
    print("here");
    setState(() {
      _stepNumber = stepNumber + 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        padding:
            const EdgeInsets.only(top: 50, left: 50, right: 50, bottom: 50),
        children: <Widget>[
          Center(
            child: Column(
              children: [
                //Top Image
                Image.asset(
                  'images/kilvish.png',
                  width: 100,
                  height: 100,
                  fit: BoxFit.fitWidth,
                ),
                //TagLine
                FittedBox(
                  fit: BoxFit.fitWidth,
                  child: Container(
                    margin: const EdgeInsets.only(top: 10),
                    child: const Text("Kilvish in 3 steps",
                        style: TextStyle(fontSize: 50.0, color: inactiveColor)),
                  ),
                ),
                //Sub tagline
                FittedBox(
                  fit: BoxFit.fitWidth,
                  child: Container(
                    margin: const EdgeInsets.only(top: 30),
                    child: const Text(
                        "A better way to track & recover expenses",
                        style: TextStyle(fontSize: 20.0, color: inactiveColor)),
                  ),
                ),
              ],
            ),
          ),
          SignupForm(
            stepNumber: "1",
            fieldLabel:
                (_stepNumber == 1) ? "Phone Number" : "Update Phone Number",
            buttonLabel:
                (_stepNumber == 1) ? "Get OTP" : "Get OTP for new number",
            hint: "7019316063",
            isActive: _stepNumber == 1,
            isOperationAllowedButNotActive: _stepNumber > 1,
            // the functions are passed from here as stepNumber variable is defined in this class
            buttonClickHandler: () => allowFormSubmission(1),
            textFocus: textFocus,
          ),
          SignupForm(
            stepNumber: "2",
            fieldLabel: "Enter OTP",
            buttonLabel: "Verify OTP",
            hint: "1234",
            isActive: _stepNumber == 2,
            isOperationAllowedButNotActive: _stepNumber > 2,
            buttonClickHandler: () => allowFormSubmission(2),
            textFocus: textFocus,
          ),
          SignupForm(
            stepNumber: "3",
            fieldLabel: "Setup Kilvish Id",
            buttonLabel: "Get Started",
            hint: "crime-master-gogo",
            isActive: _stepNumber == 3,
            isOperationAllowedButNotActive: _stepNumber > 3,
            buttonClickHandler: () => {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) {
                  return const HomePage(title: 'Home Screen');
                }),
              )
            },
            textFocus: textFocus,
          ),
        ],
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
  final bool isOperationAllowedButNotActive;
  final String? Function(String?) fieldValidator;
  final void Function() buttonClickHandler;
  final FocusNode textFocus;

  const SignupForm({
    required this.stepNumber,
    required this.fieldLabel,
    required this.buttonLabel,
    required this.hint,
    required this.isActive,
    required this.isOperationAllowedButNotActive,
    required this.buttonClickHandler,
    String? Function(String?)? fieldvalidator,
    required this.textFocus,
    super.key,
  }) : fieldValidator = fieldvalidator ?? genericFieldValidator;

  @override
  SignupFormState createState() => SignupFormState();
}

class SignupFormState extends State<SignupForm> {
  final _formKey = GlobalKey<FormState>();

  @override
  Widget build(BuildContext context) {
    Form form = Form(
      key: _formKey,
      child: Column(children: [
        const Divider(height: 50),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            renderStepNumber(),
            // to let the form fill rest of the space after the step number
            Expanded(
              child: Column(
                children: [
                  renderInputLabel(),
                  renderTextField(),
                  Container(
                    margin: const EdgeInsets.only(top: 10),
                    child: renderFormSubmitButton(),
                  )
                ],
              ),
            ),
          ],
        ),
      ]),
    );
    //this will give focus to the active input field
    widget.textFocus.requestFocus();
    return form;
  }

  // need 'context' variable in this function hence keeping it here
  void denyFormSubmission() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('This form is locked')),
    );
  }

  Widget renderStepNumber() {
    return FittedBox(
      fit: BoxFit.fitWidth,
      child: Container(
        margin: const EdgeInsets.only(right: 50),
        child: Text(widget.stepNumber,
            style: TextStyle(
                fontSize: 50.0,
                color: (widget.isActive) ? Colors.black : inactiveColor)),
      ),
    );
  }

  Widget renderInputLabel() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(widget.fieldLabel,
          style: (widget.isActive) ? textStylePrimaryColor : textStyleInactive),
    );
  }

  Widget renderTextField() {
    return TextFormField(
        decoration: InputDecoration(
          hintText: widget.isActive ? widget.hint : "",
        ),
        validator: widget.fieldValidator,
        focusNode: widget.isActive ? widget.textFocus : null);
  }

  Widget renderFormSubmitButton() {
    StadiumBorder? greyBorderIfNeeded = (widget.isOperationAllowedButNotActive)
        ? const StadiumBorder(
            side: BorderSide(color: primaryColor, width: 2),
          )
        : const StadiumBorder();
    Color backgroundColor = (widget.isActive) ? primaryColor : inactiveColor;

    return TextButton(
      style: TextButton.styleFrom(
          backgroundColor: backgroundColor,
          minimumSize: const Size.fromHeight(50),
          shape: greyBorderIfNeeded),
      onPressed: () {
        if (!widget.isActive && !widget.isOperationAllowedButNotActive) {
          return denyFormSubmission();
        }
        if (_formKey.currentState!.validate()) {
          widget.buttonClickHandler();
        }
      },
      child: Text(widget.buttonLabel,
          style: const TextStyle(color: Colors.white, fontSize: 15)),
    );
  }
}

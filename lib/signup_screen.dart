import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:kilvish/constants/dimens_constants.dart';
import 'package:kilvish/home_screen.dart';

import 'common_widgets.dart';
import 'style.dart';

class SignUpPage extends StatefulWidget {
  const SignUpPage({Key? key}) : super(key: key);

  @override
  SignUpPageState createState() => SignUpPageState();
}

class SignUpPageState extends State<SignUpPage> {
  int _stepNumber = 1;
  final FocusNode _kilvishTextFocus = FocusNode();
  final FocusNode _phoneTextFocus = FocusNode();
  final FocusNode _emailTextFocus = FocusNode();
  final FocusNode _otpEmailTextFocus = FocusNode();
  final FocusNode _otpPhoneTextFocus = FocusNode();
  final TextEditingController _kilvishTextEditingController =
      TextEditingController();
  final TextEditingController _phoneTextEditingController =
      TextEditingController();
  final TextEditingController _emailTextEditingController =
      TextEditingController();
  final TextEditingController _otpPhoneTextEditingController =
      TextEditingController();
  final TextEditingController _otpEmailTextEditingController =
      TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool sendOtpSuccess = false;
  bool isOtpButtonEnabled = true;

  @override
  void initState() {
    super.initState();
    _kilvishTextFocus.addListener(() {
      if (_kilvishTextFocus.hasFocus) {
        /// For active variable change states for highlight color when focus
        _stepNumber = 1;
        setState(() {});
      }
    });
    _phoneTextFocus.addListener(() {
      if (_phoneTextFocus.hasFocus) {
        /// For active variable change states for highlight color when focus
        _stepNumber = 2;
        setState(() {});
      }
    });
    _emailTextFocus.addListener(() {
      if (_emailTextFocus.hasFocus) {
        /// For active variable change states for highlight color when focus
        _stepNumber = 3;
        setState(() {});
      }
    });
    _otpEmailTextFocus.addListener(() {
      if (_otpEmailTextFocus.hasFocus && sendOtpSuccess) {
        /// For active variable change states for highlight color when focus
        _stepNumber = 4;
        setState(() {});
      }
    });
    _otpPhoneTextFocus.addListener(() {
      if (_otpPhoneTextFocus.hasFocus && sendOtpSuccess) {
        /// For active variable change states for highlight color when focus
        _stepNumber = 5;
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    // Clean up the focus node when the Form is disposed.
    _kilvishTextFocus.dispose();
    _phoneTextFocus.dispose();
    _emailTextFocus.dispose();
    _otpEmailTextFocus.dispose();
    _otpPhoneTextFocus.dispose();
    _kilvishTextEditingController.dispose();
    _phoneTextEditingController.dispose();
    _emailTextEditingController.dispose();
    _otpPhoneTextEditingController.dispose();
    _otpEmailTextEditingController.dispose();
    super.dispose();
  }

  void removeFocusFromAllInputFields() {
    _kilvishTextFocus.unfocus();
    _phoneTextFocus.unfocus();
    _emailTextFocus.unfocus();
    _otpEmailTextFocus.unfocus();
    _otpPhoneTextFocus.unfocus();
  }

  void allowFormSubmission(int stepNumber) {
    setState(() {
      _stepNumber = stepNumber + 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: ListView(
            padding:
                const EdgeInsets.only(top: 50, left: 50, right: 50, bottom: 50),
            children: <Widget>[
              Center(
                child: Column(
                  children: [
                    //Top Image
                    Image.asset(
                      FileConstants.kilvish,
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
                            style: TextStyle(
                                fontSize: 50.0, color: inactiveColor)),
                      ),
                    ),
                    //Sub tagline
                    FittedBox(
                      fit: BoxFit.fitWidth,
                      child: Container(
                        margin: const EdgeInsets.only(top: 30),
                        child: const Text(
                            "A better way to track & recover expenses",
                            style: TextStyle(
                                fontSize: 20.0, color: inactiveColor)),
                      ),
                    ),
                  ],
                ),
              ),
              SignupForm(
                stepNumber: "1",
                fieldLabel: "Kilvish Id",
                hint: "First time user ? Create a new kilvish id",
                isActive: _stepNumber == 1 && (!sendOtpSuccess),
                isOperationAllowedButNotActive: _stepNumber > 1,
                buttonClickHandler: () => allowFormSubmission(1),
                textFocus: _kilvishTextFocus,
                controller: _kilvishTextEditingController,
              ),
              SignupForm(
                stepNumber: "2",
                fieldLabel: "Phone Number",
                hint: "7019316063",
                isActive: _stepNumber == 2 && (!sendOtpSuccess),
                isOperationAllowedButNotActive: _stepNumber > 2,
                // the functions are passed from here as stepNumber variable is defined in this class
                buttonClickHandler: () => allowFormSubmission(2),
                textFocus: _phoneTextFocus,
                controller: _phoneTextEditingController,
              ),
              SignupForm(
                stepNumber: "3",
                fieldLabel: "Email Id",
                buttonLabel: sendOtpSuccess
                    ? (isOtpButtonEnabled ? "Re-requet OTP" : "Please wait ..")
                    : "Get OTP",
                hint: "admin@mail.com",
                isActive: _stepNumber == 3 && (!sendOtpSuccess),
                isOperationAllowedButNotActive: _stepNumber > 3,
                buttonClickHandler: () {
                  removeFocusFromAllInputFields();
                  verifyUser();
                  setState(() {
                    _stepNumber = 4;
                    isOtpButtonEnabled = false;
                  });
                  Timer(const Duration(seconds: 10), () {
                    setState(() {
                      isOtpButtonEnabled = true;
                    });
                  });
                },
                buttonEnabled: isOtpButtonEnabled,
                buttonVisible: true,
                textFocus: _emailTextFocus,
                controller: _emailTextEditingController,
              ),
              const SizedBox(height: 32),
              if (sendOtpSuccess)
                Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                        child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        renderInputLabel("Phone OTP", _stepNumber == 4),
                        renderTextField(_otpPhoneTextEditingController, "xxxx",
                            _otpPhoneTextFocus)
                      ],
                    )),
                    const SizedBox(width: 16),
                    Expanded(
                        child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        renderInputLabel("Email OTP", _stepNumber == 5),
                        renderTextField(_otpEmailTextEditingController, "xxxx",
                            _otpEmailTextFocus)
                      ],
                    )),
                  ],
                ),
              if (sendOtpSuccess) renderFormSubmitButton()
            ],
          ),
        ),
      ),
    );
  }

  Widget renderInputLabel(String label, bool isActive) {
    return isActive
        ? renderPrimaryColorLabel(text: label, topSpacing: 0)
        : renderLabel(text: label);
  }

  /// Render Text filed
  Widget renderTextField(
      TextEditingController controller, String hint, FocusNode focusNode) {
    return TextFormField(
        focusNode: focusNode,
        controller: controller,
        decoration: InputDecoration(hintText: hint),
        validator: genericFieldValidator);
  }

  Widget renderFormSubmitButton() {
    StadiumBorder? greyBorderIfNeeded = const StadiumBorder(
      side: BorderSide(color: primaryColor, width: 2),
    );
    Color backgroundColor = primaryColor;

    return TextButton(
      style: TextButton.styleFrom(
          backgroundColor: backgroundColor,
          minimumSize: const Size.fromHeight(50),
          shape: greyBorderIfNeeded),
      onPressed: () {
        removeFocusFromAllInputFields();
        verifyOtp();
      },
      child: const Text("Verify OTP",
          style: TextStyle(color: Colors.white, fontSize: 15)),
    );
  }

  Future<void> verifyUser() async {
    if (_formKey.currentState != null && _formKey.currentState!.validate()) {
      HttpsCallable request =
          FirebaseFunctions.instance.httpsCallable('verifyUser');
      try {
        final result = await request.call(<String, dynamic>{
          "kilvishId": _kilvishTextEditingController.text,
          "email": _emailTextEditingController.text,
          "phone": _phoneTextEditingController.text,
        });
        if (result.data['success']) {
          sendOtpSuccess = true;
          _otpPhoneTextFocus.requestFocus();
          setState(() {});
        } else {
          Fluttertoast.showToast(
              msg: result.data['message'],
              toastLength: Toast.LENGTH_SHORT,
              gravity: ToastGravity.CENTER,
              backgroundColor: Colors.red,
              textColor: Colors.white,
              fontSize: 16.0);
        }
      } on FirebaseFunctionsException catch (error) {
        print("Exception $error");
      }
    }
  }

  Future<void> verifyOtp() async {
    if (_otpPhoneTextEditingController.text.isNotEmpty &&
        _otpEmailTextEditingController.text.isNotEmpty) {
      try {
        HttpsCallable request =
            FirebaseFunctions.instance.httpsCallable('verifyOtp');
        final result = await request.call(<String, dynamic>{
          "kilvishId": _kilvishTextEditingController.text,
          "phoneOtp": _otpPhoneTextEditingController.text,
          "emailOtp": _otpEmailTextEditingController.text,
        });
        if (result.data['success']) {
          try {
            final token = result.data['token'];
            final userCredential =
                await FirebaseAuth.instance.signInWithCustomToken(token);

            /// Navigate to dashboard
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) {
                return const HomePage();
              }),
            );
          } on FirebaseAuthException catch (e) {
            switch (e.code) {
              case "invalid-custom-token":
                print(
                    "The supplied token is not a Firebase custom auth token.");
                break;
              case "custom-token-mismatch":
                print(
                    "The supplied token is for a different Firebase project.");
                break;
              default:
                print("Unknown error.");
            }
          }
        } else {
          Fluttertoast.showToast(
              msg: result.data['message'],
              toastLength: Toast.LENGTH_SHORT,
              gravity: ToastGravity.CENTER,
              backgroundColor: Colors.red,
              textColor: Colors.white,
              fontSize: 16.0);
        }
      } on FirebaseFunctionsException catch (error) {
        print("Exception $error");
      }
    }
  }
}

//This function need to be kept global else the compiler cribbed about not accessible in SignupForm constructor
String? genericFieldValidator(String? value) {
  print("in generic validator");
  if (value == null || value.isEmpty) {
    return 'Please enter some text';
  }
  return null;
}

class SignupForm extends StatefulWidget {
  final String stepNumber;
  final String fieldLabel;
  final String? buttonLabel;
  final String hint;
  final bool isActive;
  final bool isOperationAllowedButNotActive;
  final String? Function(String?) fieldValidator;
  final void Function() buttonClickHandler;
  final FocusNode textFocus;
  final TextEditingController controller;
  final TextInputAction textInputAction;
  final bool buttonVisible;
  final bool buttonEnabled;

  const SignupForm({
    required this.stepNumber,
    required this.fieldLabel,
    this.buttonLabel,
    required this.hint,
    required this.isActive,
    required this.isOperationAllowedButNotActive,
    required this.buttonClickHandler,
    String? Function(String?)? fieldvalidator,
    required this.textFocus,
    required this.controller,
    this.textInputAction = TextInputAction.next,
    this.buttonVisible = false,
    this.buttonEnabled = false,
    super.key,
  }) : fieldValidator = fieldvalidator ?? genericFieldValidator;

  @override
  SignupFormState createState() => SignupFormState();
}

class SignupFormState extends State<SignupForm> {
  @override
  Widget build(BuildContext context) {
    Widget uiWidget = Column(children: [
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
                Visibility(
                  visible: widget.buttonVisible,
                  child: Container(
                    margin: const EdgeInsets.only(top: 10),
                    child: renderFormSubmitButton(),
                  ),
                )
              ],
            ),
          ),
        ],
      ),
    ]);

    if (widget.isActive) {
      //this will give focus to the active input field
      widget.textFocus.requestFocus();
    } else {
      //this will give un focus to the in active input field
      widget.textFocus.unfocus();
    }

    return uiWidget;
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
    return widget.isActive
        ? renderPrimaryColorLabel(text: widget.fieldLabel, topSpacing: 0)
        : renderLabel(text: widget.fieldLabel);
  }

  Widget renderTextField() {
    return TextFormField(
        controller: widget.controller,
        decoration: InputDecoration(
          hintText: widget.isActive ? widget.hint : "",
        ),
        validator: widget.fieldValidator,
        textInputAction: widget.textInputAction,
        focusNode: widget.textFocus);
  }

  Widget renderFormSubmitButton() {
    StadiumBorder? greyBorderIfNeeded = (widget.buttonEnabled)
        ? const StadiumBorder(
            side: BorderSide(color: primaryColor, width: 2),
          )
        : const StadiumBorder();
    Color backgroundColor =
        (widget.buttonEnabled) ? primaryColor : inactiveColor;

    return TextButton(
      style: TextButton.styleFrom(
          backgroundColor: backgroundColor,
          minimumSize: const Size.fromHeight(50),
          shape: greyBorderIfNeeded),
      onPressed: widget.buttonEnabled ? widget.buttonClickHandler : null,
      child: Text(widget.buttonLabel ?? "Click Me",
          style: const TextStyle(color: Colors.white, fontSize: 15)),
    );
  }
}

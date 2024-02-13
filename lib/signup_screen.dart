import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:kilvish/constants/dimens_constants.dart';
import 'style.dart';
import 'home_screen.dart';
import 'common_widgets.dart';

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
  final FocusNode _otpTextFocus = FocusNode();
  final TextEditingController _kilvishTextEditingController = TextEditingController();
  final TextEditingController _phoneTextEditingController = TextEditingController();
  final TextEditingController _emailTextEditingController = TextEditingController();
  final TextEditingController _otpTextEditingController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  ValueNotifier<bool> sendOtpSuccess = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _kilvishTextFocus.addListener(() {
      if (_kilvishTextFocus.hasFocus) {
        /// For active variable change states for highlight color when focus
        _stepNumber = 1;
        setState(() {

        });
      }
    });
    _phoneTextFocus.addListener(() {
      if (_phoneTextFocus.hasFocus) {
        /// For active variable change states for highlight color when focus
        _stepNumber = 2;
        setState(() {

        });
      }
    });
    _emailTextFocus.addListener(() {
      if (_emailTextFocus.hasFocus) {
        /// For active variable change states for highlight color when focus
        _stepNumber = 3;
        setState(() {

        });
      }
    });
    _otpTextFocus.addListener(() {
      if (_otpTextFocus.hasFocus && sendOtpSuccess.value) {
        /// For active variable change states for highlight color when focus
        _stepNumber = 4;
        setState(() {

        });
      }
    });
  }

  @override
  void dispose() {
    // Clean up the focus node when the Form is disposed.
    _kilvishTextFocus.dispose();
    _phoneTextFocus.dispose();
    _emailTextFocus.dispose();
    _otpTextFocus.dispose();
    _kilvishTextEditingController.dispose();
    _phoneTextEditingController.dispose();
    _emailTextEditingController.dispose();
    _otpTextEditingController.dispose();
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
                            style: TextStyle(fontSize: 50.0,
                                color: inactiveColor)),
                      ),
                    ),
                    //Sub tagline
                    FittedBox(
                      fit: BoxFit.fitWidth,
                      child: Container(
                        margin: const EdgeInsets.only(top: 30),
                        child: const Text(
                            "A better way to track & recover expenses",
                            style: TextStyle(fontSize: 20.0,
                                color: inactiveColor)),
                      ),
                    ),
                  ],
                ),
              ),
              // {
              //   Navigator.push(
              //     context,
              //     MaterialPageRoute(builder: (context) {
              //       return const HomePage();
              //     }),
              //   )
              // }
              SignupForm(
                stepNumber: "1",
                fieldLabel: "Setup Kilvish Id",
                buttonLabel: "Get Started",
                hint: "crime-master-gogo",
                isActive: _stepNumber == 1 && (!sendOtpSuccess.value),
                isOperationAllowedButNotActive: _stepNumber > 1,
                buttonClickHandler: () => allowFormSubmission(1),
                textFocus: _kilvishTextFocus,
                controller: _kilvishTextEditingController,
              ),
              SignupForm(
                stepNumber: "2",
                fieldLabel:
                (_stepNumber == 2) ? "Phone Number" : "Update Phone Number",
                buttonLabel:
                (_stepNumber == 2) ? "Get OTP" : "Get OTP for new number",
                hint: "7019316063",
                isActive: _stepNumber == 2 && (!sendOtpSuccess.value),
                isOperationAllowedButNotActive: _stepNumber > 2,
                // the functions are passed from here as stepNumber variable is defined in this class
                buttonClickHandler: () => allowFormSubmission(2),
                textFocus: _phoneTextFocus,
                controller: _phoneTextEditingController,
              ),
              SignupForm(
                stepNumber: "3",
                fieldLabel: "Enter Email Id",
                buttonLabel: "Send OTP",
                hint: "admin@mail.com",
                isActive: _stepNumber == 3 && (!sendOtpSuccess.value),
                isOperationAllowedButNotActive: _stepNumber > 3,
                buttonClickHandler: () {
                  verifyUser();
                },
                buttonVisible: true,
                textFocus: _emailTextFocus,
                controller: _emailTextEditingController,
              ),
              ValueListenableBuilder<bool>(
                valueListenable: sendOtpSuccess,
                builder: (context, value, child) {
                  return Visibility(
                    visible: value,
                    child: SignupForm(
                      stepNumber: "4",
                      fieldLabel: "Enter OTP",
                      buttonLabel: "Verify OTP",
                      hint: "1234",
                      isActive: _stepNumber == 4,
                      isOperationAllowedButNotActive: _stepNumber > 4,
                      buttonVisible: true,
                      buttonClickHandler: () {
                        verifyOtp();
                      },
                      textFocus: _otpTextFocus,
                      textInputAction: TextInputAction.done,
                      controller: _otpTextEditingController,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> verifyUser() async {
    if(_formKey.currentState !=null && _formKey.currentState!.validate()){
      HttpsCallable request = FirebaseFunctions.instance.httpsCallable('login');
      try {
        final result = await request.call(<String, dynamic>{
          "kilvishId": _kilvishTextEditingController.text,
          "email": _kilvishTextEditingController.text,
          "phone": _phoneTextEditingController.text,
        });
        print("response is here ${result.data}");
        if (result.data['success']) {
          sendOtpSuccess.value = true;
          _otpTextFocus.requestFocus();
        } else {
          Fluttertoast.showToast(
              msg: result.data['message'],
              toastLength: Toast.LENGTH_SHORT,
              gravity: ToastGravity.CENTER,
              backgroundColor: Colors.red,
              textColor: Colors.white,
              fontSize: 16.0
          );
        }
      } on FirebaseFunctionsException catch (error) {
        print("Exception $error");
      }
    }
  }

  Future<void> verifyOtp() async {
    if(_otpTextEditingController.text.isNotEmpty){
      HttpsCallable request = FirebaseFunctions.instance.httpsCallable('verifyOtp');
      try {
        final result = await request.call(<String, dynamic>{
          "kilvishId": "kilvishId",
          "phoneOtp": "1234",
          "emailOtp": "5678",
        });
        print("response is here ${result.data}");
        if (result.data['success']) {
          sendOtpSuccess.value = true;
          _otpTextFocus.requestFocus();
        } else {
          Fluttertoast.showToast(
              msg: result.data['message'],
              toastLength: Toast.LENGTH_SHORT,
              gravity: ToastGravity.CENTER,
              backgroundColor: Colors.red,
              textColor: Colors.white,
              fontSize: 16.0
          );
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
  final String buttonLabel;
  final String hint;
  final bool isActive;
  final bool isOperationAllowedButNotActive;
  final String? Function(String?) fieldValidator;
  final void Function() buttonClickHandler;
  final FocusNode textFocus;
  final TextEditingController controller;
  final TextInputAction textInputAction;
  final bool buttonVisible;

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
    required this.controller,
    this.textInputAction = TextInputAction.next,
    this.buttonVisible = false,
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
        readOnly: !widget.isActive,
        controller: widget.controller,
        decoration: InputDecoration(
          hintText: widget.isActive ? widget.hint : "",
        ),
        validator: widget.fieldValidator,
        textInputAction: widget.textInputAction,
        focusNode: widget.textFocus);
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
      onPressed: widget.isActive
          ? () {
              if (!widget.isActive && !widget.isOperationAllowedButNotActive) {
                return denyFormSubmission();
              }
              widget.buttonClickHandler();
            }
          : null,
      child: Text(widget.buttonLabel,
          style: const TextStyle(color: Colors.white, fontSize: 15)),
    );
  }
}

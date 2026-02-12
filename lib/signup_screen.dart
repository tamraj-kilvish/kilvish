import 'dart:async';
import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/models.dart';
import 'style.dart';
import 'home_screen.dart';
import 'package:kilvish/deep_link_handler.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({Key? key}) : super(key: key);

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  // Step tracking
  int _currentStep = 1;

  // Focus nodes
  final FocusNode _phoneFocus = FocusNode();
  final FocusNode _otpFocus = FocusNode();
  final FocusNode _kilvishIdFocus = FocusNode();

  // Controllers
  late TextEditingController _phoneController;
  final TextEditingController _otpController = TextEditingController();
  late TextEditingController _kilvishIdController;

  // Form key
  final _formKey = GlobalKey<FormState>();

  // Firebase instances
  final FirebaseAuth _auth = FirebaseAuth.instance;

  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(region: "asia-south1");

  // State variables
  String _verificationId = '';
  bool _isOtpSent = false;
  bool _isLoading = false;
  bool _canResendOtp = true;
  bool _hasKilvishId = false;
  KilvishUser? _kilvishUser = null;

  @override
  void initState() {
    super.initState();

    _phoneController = TextEditingController();
    _kilvishIdController = TextEditingController();

    // Focus listeners to update current step
    _phoneFocus.addListener(() {
      if (_phoneFocus.hasFocus && !_isOtpSent) {
        setState(() => _currentStep = 1);
      }
    });

    _otpFocus.addListener(() {
      if (_otpFocus.hasFocus && _isOtpSent) {
        setState(() => _currentStep = 2);
      }
    });

    _kilvishIdFocus.addListener(() {
      if (_kilvishIdFocus.hasFocus) {
        setState(() => _currentStep = 3);
      }
    });
  }

  @override
  void dispose() {
    _phoneFocus.dispose();
    _otpFocus.dispose();
    _kilvishIdFocus.dispose();
    _phoneController.dispose();
    _otpController.dispose();
    _kilvishIdController.dispose();
    super.dispose();
  }

  void _removeFocusFromAllFields() {
    _phoneFocus.unfocus();
    _otpFocus.unfocus();
    _kilvishIdFocus.unfocus();
  }

  String generateButtonLabelForPhoneForm() {
    if (_isLoading && _currentStep == 1) {
      return "Wait...";
    }

    if (!_isOtpSent) {
      return "Send OTP";
    }

    if (_canResendOtp) {
      return "Resend OTP";
    } else {
      return "OTP Sent .. button will activate after 30 seconds";
    }
  }

  String generateButtonLabelForVerifyOTPForm() {
    if (_currentStep != 2) return "Verify OTP";

    if (_isLoading) {
      return "Wait...";
    }
    // if (_isOtpSent) {

    // }

    return "Verify OTP";
  }

  @override
  Widget build(BuildContext context) {
    Widget scaffold = Scaffold(
      backgroundColor: kWhitecolor,
      body: SafeArea(
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: ListView(
            children: [
              // Header
              _buildHeader(),
              const Divider(height: 1),

              //const SizedBox(height: 40),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    SignupFormStep(
                      currentStep: _currentStep,
                      stepNumber: "1",
                      fieldLabel: "Phone Number",
                      supportLabel: "OTP will be sent to this number",
                      hint: "+91 9876543210",
                      isActive: _currentStep >= 1,
                      isCompleted: _currentStep > 1,
                      controller: _phoneController,
                      focusNode: _phoneFocus,
                      validator: _validatePhone,
                      buttonVisible: true,
                      buttonLabel: generateButtonLabelForPhoneForm(),
                      buttonEnabled: !_isLoading && _canResendOtp,
                      onButtonPressed: _sendOtpWrapper,
                    ),

                    // Step 2: OTP
                    //if (_isOtpSent)
                    SignupFormStep(
                      currentStep: _currentStep,
                      stepNumber: "2",
                      fieldLabel: "Enter OTP",
                      supportLabel: "Check your phone for the verification code",
                      hint: "123456",
                      isActive: _currentStep == 2,
                      isCompleted: _currentStep > 2,
                      controller: _otpController,
                      focusNode: _otpFocus,
                      validator: _validateOtp,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      buttonVisible: true,
                      buttonLabel: generateButtonLabelForVerifyOTPForm(),
                      buttonEnabled: _currentStep == 2 && !_isLoading,
                      onButtonPressed: _verifyOtpAndLoginUser,
                    ),

                    // Step 3: Kilvish ID (only for new users, after authentication)
                    //if (_isNewUser)
                    SignupFormStep(
                      currentStep: _currentStep,
                      stepNumber: "3",
                      fieldLabel: "Kilvish ID",
                      supportLabel: _hasKilvishId
                          ? "You can choose a different kilvish Id if you like to. Leave it the same & press login if you do not want to update it."
                          : "Choose a unique username which will help others identify you without disclosing your phone number",
                      hint: "crime-master-gogo .. only letters, numbers & '-' allowed",
                      isActive: _currentStep == 3,
                      isCompleted: false,
                      controller: _kilvishIdController,
                      focusNode: _kilvishIdFocus,
                      validator: _validateKilvishId,
                      buttonVisible: true,
                      buttonLabel: _isLoading && _currentStep == 3
                          ? "Wait..."
                          : _hasKilvishId
                          ? "Login"
                          : "Just let me in !!",
                      buttonEnabled: _currentStep == 3 && !_isLoading,
                      onButtonPressed: _updateUserKilvishIdAndSendToHomeScreen,
                    ),
                  ],
                ),
              ),

              // Step 1: Phone Number
            ],
          ),
        ),
      ),
    );

    return scaffold;
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity, // Full width
      color: primaryColor, // Optional: background color to distinguish header
      padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 20),
      alignment: Alignment.center,
      child: Column(
        children: [
          //Top Image
          Image.asset("assets/images/kilvish-inverted.png", width: 100, height: 100, fit: BoxFit.fitWidth),
          //TagLine
          const SizedBox(height: 10),
          const Text("Kilvish in 3 steps", style: TextStyle(fontSize: 40.0, color: Colors.white)),
          //Sub tagline
          const SizedBox(height: 5),
          const Text("A better way to track & recover expenses", style: TextStyle(fontSize: 20.0, color: Colors.white)),
        ],
      ),
    );
  }

  // Validators
  String? _validatePhone(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter phone number';
    }
    if (!value.startsWith('+')) {
      return 'Phone must start with country code (e.g., +91)';
    }
    return null;
  }

  String? _validateOtp(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter OTP';
    }
    if (value.length != 6) {
      return 'OTP must be 6 digits';
    }
    return null;
  }

  String? _validateKilvishId(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter Kilvish ID';
    }
    if (value.length < 3) {
      return 'Kilvish ID must be at least 3 characters';
    }
    if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(value)) {
      return 'Only letters, numbers and hyphens allowed';
    }

    //TODO - check if kilvish ID already exist

    return null;
  }

  // Phone OTP flow
  void _sendOtp() async {
    if (_formKey.currentState != null && !_formKey.currentState!.validate()) {
      print("Validation failed!"); // ADD THIS
      return;
    }

    _removeFocusFromAllFields();
    setState(() => _isLoading = true);
    try {
      // Ensure we have a valid BuildContext (the widget is mounted)
      if (!mounted) {
        setState(() => _isLoading = false);
        return;
      }

      // Add a small delay to ensure the view hierarchy is ready
      await Future.delayed(const Duration(milliseconds: 500));
      await _auth.verifyPhoneNumber(
        phoneNumber: normalizePhoneNumber(_phoneController.text),
        verificationCompleted: (PhoneAuthCredential credential) async {
          await _signInWithCredential(credential);
        },
        verificationFailed: (FirebaseAuthException e) {
          if (mounted) {
            setState(() => _isLoading = false);
            showError(context, e.message ?? 'Verification failed');
          }
        },
        codeSent: (String verificationId, int? resendToken) {
          setState(() {
            _verificationId = verificationId;
            _isOtpSent = true;
            _currentStep = 2;
            _isLoading = false;
          });

          WidgetsBinding.instance.addPostFrameCallback((_) {
            _otpFocus.requestFocus();
          });
          if (mounted) showSuccess(context, 'OTP sent successfully!');
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          _verificationId = verificationId;
        },
      );
    } catch (e) {
      log('Send OTP error: $e', error: e);
      setState(() => _isLoading = false);
      if (mounted) showError(context, 'Failed to send OTP');
    }
  }

  void _sendOtpWrapper() {
    setState(() {
      _isOtpSent = false;
      _otpController.clear();
      _currentStep = 1;
      _canResendOtp = false;
    });

    _sendOtp();

    // Enable resend after 30 seconds
    Timer(const Duration(seconds: 30), () {
      if (mounted) {
        setState(() => _canResendOtp = true);
      }
    });
  }

  void _verifyOtpAndLoginUser() async {
    if (!_formKey.currentState!.validate()) return;

    _removeFocusFromAllFields();
    setState(() => _isLoading = true);

    try {
      PhoneAuthCredential credential = PhoneAuthProvider.credential(
        verificationId: _verificationId,
        smsCode: _otpController.text,
      );

      await _signInWithCredential(credential);
    } catch (e) {
      log('OTP Verification error: $e', error: e);
      setState(() => _isLoading = false);
      if (mounted) showError(context, 'Invalid OTP. Please try again.');
    }
  }

  Future<void> _signInWithCredential(PhoneAuthCredential credential) async {
    try {
      UserCredential userCredential = await _auth.signInWithCredential(credential);
      User? user = userCredential.user;

      if (user == null) {
        throw Exception('User is null after sign in');
      }

      log('User signed in: ${user.uid}');

      // Call Cloud Function to check if user exists
      try {
        HttpsCallable callable = _functions.httpsCallable('getUserByPhone');
        final result = await callable.call({'phoneNumber': normalizePhoneNumber(_phoneController.text)});

        //print('getUserByPhone result: ${result.data}');

        if (result.data != null && result.data['user'] != null) {
          // Map<String, dynamic>? typedMap = Map<String, dynamic>.from(
          //   result.data['user'],
          // );
          // final KilvishUser userData = KilvishUser.fromFirestoreObject(
          //   typedMap,
          // );

          // force refresh custom token else first time users may see an error
          await _auth.currentUser?.getIdToken(true);

          _kilvishUser = await getLoggedInUserData();

          setState(() {
            if (_kilvishUser?.kilvishId != null) {
              _hasKilvishId = true;
              _kilvishIdController.text = _kilvishUser?.kilvishId ?? "";
            }
            _currentStep = 3;
            _isLoading = false;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _kilvishIdFocus.requestFocus();
          });
        }
      } catch (e, stackTrace) {
        print('Firebase Function error: $e $stackTrace');
        setState(() => _isLoading = false);
        if (mounted) {
          showError(context, 'Failed to verify user. Please try again.');
        }
      }
    } catch (e) {
      log('Authentication error: $e', error: e);
      setState(() => _isLoading = false);
      if (mounted) {
        showError(context, 'Authentication failed. Please try again.');
      }
    }
  }

  void _updateUserKilvishIdAndSendToHomeScreen() async {
    if (!_formKey.currentState!.validate()) return;

    if (_kilvishUser == null) {
      showError(context, 'User data not found. This should not have happened. Please start from getting new OTP');
      return;
    }

    _removeFocusFromAllFields();
    setState(() => _isLoading = true);

    try {
      bool isKilvishIdUpdated = await updateUserKilvishId(_kilvishUser!.id, _kilvishIdController.text.trim());
      if (!isKilvishIdUpdated && mounted) {
        showError(context, "kilvishId is taken, please select a different id");
        return;
      }

      if (mounted) {
        _navigateToHome();
      }
    } catch (e, stackTrace) {
      print('User profile creation error: $e, $stackTrace');
      setState(() => _isLoading = false);
      if (mounted) {
        showError(context, 'User profile creation error: $e');
      }
    }
  }

  void _navigateToHome() {
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (context) => HomeScreen()));

    // Check for pending deep link after navigation completes
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) {
        await DeepLinkHandler.checkAndHandlePendingDeepLink(context);
      }
    });
  }
}

// Reusable signup form step widget
class SignupFormStep extends StatelessWidget {
  final int currentStep;
  final String stepNumber;
  final String fieldLabel;
  final String supportLabel;
  final String hint;
  final bool isActive;
  final bool isCompleted;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String? Function(String?)? validator;
  final TextInputType keyboardType;
  final int? maxLength;
  final bool buttonVisible;
  final String? buttonLabel;
  final bool buttonEnabled;
  final VoidCallback? onButtonPressed;

  const SignupFormStep({
    Key? key,
    required this.currentStep,
    required this.stepNumber,
    required this.fieldLabel,
    required this.supportLabel,
    required this.hint,
    required this.isActive,
    required this.isCompleted,
    required this.controller,
    required this.focusNode,
    this.validator,
    this.keyboardType = TextInputType.text,
    this.maxLength,
    this.buttonVisible = false,
    this.buttonLabel,
    this.buttonEnabled = true,
    this.onButtonPressed,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,

      children: [
        // Row(
        //   crossAxisAlignment: CrossAxisAlignment.start,
        //   children: [
        // Step number
        _buildStepNumber(),
        //     const SizedBox(width: 32),
        //     _buildLabel(),
        //   ],
        // ),
        const SizedBox(height: 4),
        _buildSupportLabel(),
        const SizedBox(height: 8),
        _buildTextField(),
        const SizedBox(height: 12),
        _buildButton(),
        const Divider(height: 50),
      ],

      // Row(
      //   crossAxisAlignment: CrossAxisAlignment.start,
      //   children: [
      //     // Step number
      //     _buildStepNumber(),

      //     const SizedBox(width: 32),

      //     // Form content
      //     Expanded(
      //       child: Column(
      //         crossAxisAlignment: CrossAxisAlignment.start,
      //         children: [
      //           _buildLabel(),
      //           const SizedBox(height: 4),
      //           _buildSupportLabel(),
      //           const SizedBox(height: 8),
      //           _buildTextField(),
      //           if (buttonVisible) ...[
      //             const SizedBox(height: 12),
      //             _buildButton(),
      //           ],
      //         ],
      //       ),
      //     ),
      //   ],
      // ),
      //],
    );
  }

  Widget _buildStepNumber() {
    return FittedBox(
      fit: BoxFit.fitHeight,
      alignment: AlignmentGeometry.center,
      child: Container(
        child: Text(
          "$stepNumber. $fieldLabel",
          style: TextStyle(fontSize: 25.0, color: (currentStep.toString() == stepNumber) ? primaryColor : inactiveColor),
        ),
      ),
    );
  }

  Widget _buildSupportLabel() {
    return Text(supportLabel, style: TextStyle(fontSize: 12, color: inactiveColor));
  }

  Widget _buildTextField() {
    Widget textFormField = TextFormField(
      controller: controller,
      focusNode: focusNode,
      enabled: isActive,
      keyboardType: keyboardType,
      maxLength: maxLength,
      decoration: InputDecoration(
        hintText: isActive ? hint : "",
        hintStyle: TextStyle(color: inactiveColor),
        counterText: maxLength != null ? "" : null,
        border: OutlineInputBorder(borderSide: BorderSide(color: bordercolor)),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: primaryColor, width: 2.0)),
        filled: !isActive,
        fillColor: isActive ? null : Colors.grey[100],
      ),
      validator: isActive ? validator : null,
    );
    return textFormField;
  }

  Widget _buildButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: buttonEnabled ? primaryColor : inactiveColor, width: 2),
          backgroundColor: buttonEnabled ? primaryColor : inactiveColor,
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        onPressed: buttonEnabled ? onButtonPressed : null,
        child: Text(
          buttonLabel ?? "Continue",
          style: TextStyle(color: /*buttonEnabled ? */ Colors.white /*: primaryColor*/, fontSize: 14),
        ),
      ),
    );
  }
}

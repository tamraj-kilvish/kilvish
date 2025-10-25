import 'dart:async';
import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:kilvish/constants/dimens_constants.dart';
import 'style.dart';
import 'home_screen.dart';

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

  void removeFocusFromAllInputFields() {
    _phoneFocus.unfocus();
    _otpFocus.unfocus();
    _kilvishIdFocus.unfocus();
  }

  // Controllers
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();
  final TextEditingController _kilvishIdController = TextEditingController();

  // Form key
  final _formKey = GlobalKey<FormState>();

  // Firebase instances
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instanceFor(
    app: Firebase.app(),
    databaseId: 'kilvish',
  );
  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(
    region: "asia-south1",
  );

  // State variables
  String _verificationId = '';
  bool _isOtpSent = false;
  bool _isLoading = false;
  bool _isNewUser = false;
  bool _canResendOtp = true;

  @override
  void initState() {
    super.initState();

    // Focus listeners to update current step
    _phoneFocus.addListener(() {
      if (_phoneFocus.hasFocus && !_isOtpSent) {
        setState(() => _currentStep = 1);
      }
    });

    _otpFocus.addListener(() {
      if (_otpFocus.hasFocus && _isOtpSent && !_isNewUser) {
        setState(() => _currentStep = 2);
      }
    });

    _kilvishIdFocus.addListener(() {
      if (_kilvishIdFocus.hasFocus && _isNewUser) {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kWhitecolor,
      body: SafeArea(
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: ListView(
            padding: const EdgeInsets.only(
              top: 50,
              left: 50,
              right: 50,
              bottom: 50,
            ),
            children: [
              // Header
              _buildHeader(),

              //const SizedBox(height: 40),

              // Step 1: Phone Number
              SignupFormStep(
                stepNumber: "1",
                fieldLabel: "Phone Number",
                supportLabel: "OTP will be sent to this number",
                hint: "+91 9876543210",
                isActive: _currentStep == 1 && !_isOtpSent,
                isCompleted: _currentStep > 1,
                controller: _phoneController,
                focusNode: _phoneFocus,
                validator: _validatePhone,
                buttonVisible: true,
                buttonLabel: _isOtpSent && _canResendOtp
                    ? "Resend OTP"
                    : "Send OTP",
                buttonEnabled: !_isLoading,
                onButtonPressed: _sendOtp,
              ),

              // Step 2: OTP
              //if (_isOtpSent)
              SignupFormStep(
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
                buttonLabel: "Verify OTP",
                buttonEnabled: _currentStep == 2 && !_isLoading,
                onButtonPressed: _resendOtp,
              ),

              // Step 3: Kilvish ID (only for new users, after authentication)
              //if (_isNewUser)
              SignupFormStep(
                stepNumber: "3",
                fieldLabel: "Kilvish ID",
                supportLabel:
                    "Choose a unique username which will help others identify you without disclosing your phone number",
                hint: "crime-master-gogo",
                isActive: _currentStep == 3,
                isCompleted: false,
                controller: _kilvishIdController,
                focusNode: _kilvishIdFocus,
                validator: _validateKilvishId,
                buttonVisible: true,
                buttonLabel: "Just let me in !!",
                buttonEnabled: _currentStep == 3,
              ),

              const SizedBox(height: 32),

              // Main action button
              if (_isOtpSent && !_isNewUser)
                _buildMainButton("Verify OTP", _verifyOtp),

              if (_isNewUser)
                _buildMainButton("Complete Setup", _completeUserSetup),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Center(
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
              child: const Text(
                "Kilvish in 3 steps",
                style: TextStyle(fontSize: 50.0, color: inactiveColor),
              ),
            ),
          ),
          //Sub tagline
          FittedBox(
            fit: BoxFit.fitWidth,
            child: Container(
              //margin: const EdgeInsets.only(top: 5),
              child: const Text(
                "A better way to track & recover expenses",
                style: TextStyle(fontSize: 20.0, color: inactiveColor),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainButton(String label, VoidCallback onPressed) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: primaryColor,
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: _isLoading ? null : onPressed,
      child: _isLoading
          ? const CircularProgressIndicator(color: Colors.white)
          : Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
    );
  }

  // Validators
  String? _validatePhone(String? value) {
    String? retVal;
    if (value == null || value.isEmpty) {
      retVal = 'Please enter phone number';
    }
    if (value != null && !value.startsWith('+')) {
      retVal = 'Phone must start with country code (e.g., +91)';
    }
    return retVal;
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
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(value)) {
      return 'Only letters, numbers, hyphens and underscores allowed';
    }
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
      await _auth.verifyPhoneNumber(
        phoneNumber: _phoneController.text,
        verificationCompleted: (PhoneAuthCredential credential) async {
          await _signInWithCredential(credential);
        },
        verificationFailed: (FirebaseAuthException e) {
          setState(() => _isLoading = false);
          _showError(e.message ?? 'Verification failed');
        },
        codeSent: (String verificationId, int? resendToken) {
          setState(() {
            _verificationId = verificationId;
            _isOtpSent = true;
            _currentStep = 2;
            _isLoading = false;
          });
          _otpFocus.requestFocus();
          _showSuccess('OTP sent successfully!');
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          _verificationId = verificationId;
        },
      );
    } catch (e) {
      log('Send OTP error: $e', error: e);
      setState(() => _isLoading = false);
      _showError('Failed to send OTP');
    }
  }

  void _resendOtp() {
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

  void _verifyOtp() async {
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
      _showError('Invalid OTP. Please try again.');
    }
  }

  Future<void> _signInWithCredential(PhoneAuthCredential credential) async {
    try {
      UserCredential userCredential = await _auth.signInWithCredential(
        credential,
      );
      User? user = userCredential.user;

      if (user == null) {
        throw Exception('User is null after sign in');
      }

      log('User signed in: ${user.uid}');

      // Call Cloud Function to check if user exists
      try {
        HttpsCallable callable = _functions.httpsCallable('getUserByPhone');
        final result = await callable.call({
          'phoneNumber': _phoneController.text,
        });

        log('getUserByPhone result: ${result.data}');

        if (result.data != null && result.data['user'] != null) {
          final isNewUser = result.data['isNewUser'] ?? false;
          final userData = result.data['user'];

          if (isNewUser) {
            // New user - show Kilvish ID field
            setState(() {
              _isNewUser = true;
              _currentStep = 3;
              _isLoading = false;
            });
            _kilvishIdFocus.requestFocus();
          } else {
            // Existing user - check if they have kilvishId
            final hasKilvishId =
                userData['kilvishId'] != null &&
                userData['kilvishId'].toString().isNotEmpty;

            if (!hasKilvishId) {
              // User exists but needs to set up kilvishId
              setState(() {
                _isNewUser = true;
                _currentStep = 3;
                _isLoading = false;
              });
              _kilvishIdFocus.requestFocus();
            } else {
              // Existing user with complete profile - refresh token and navigate
              await Future.delayed(const Duration(seconds: 1));
              await user.getIdToken(true);

              if (mounted) {
                _navigateToHome();
              }
            }
          }
        }
      } catch (e, stackTrace) {
        log('Firebase Function error: $e', error: e, stackTrace: stackTrace);
        setState(() => _isLoading = false);
        _showError('Failed to verify user. Please try again.');
      }
    } catch (e) {
      log('Authentication error: $e', error: e);
      setState(() => _isLoading = false);
      _showError('Authentication failed. Please try again.');
    }
  }

  void _completeUserSetup() async {
    if (!_formKey.currentState!.validate()) return;

    _removeFocusFromAllFields();
    setState(() => _isLoading = true);

    try {
      User? user = _auth.currentUser;
      if (user == null) {
        throw Exception('No authenticated user');
      }

      // Get userId from custom claims
      final idTokenResult = await user.getIdTokenResult();
      final userId = idTokenResult.claims?['userId'] as String?;

      if (userId == null) {
        throw Exception('User ID not found in custom claims');
      }

      log('Updating user document: $userId');

      // Update user document with kilvishId
      await _firestore.collection('Users').doc(userId).update({
        'kilvishId': _kilvishIdController.text,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      log('User profile updated successfully');

      // Wait for token refresh
      await Future.delayed(const Duration(seconds: 1));
      await user.getIdToken(true);

      if (mounted) {
        _navigateToHome();
      }
    } catch (e) {
      log('User profile creation error: $e', error: e);
      setState(() => _isLoading = false);
      _showError('Failed to create profile. Please try again.');
    }
  }

  void _navigateToHome() {
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (context) => HomeScreen()));
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green),
    );
  }
}

// Reusable signup form step widget
class SignupFormStep extends StatelessWidget {
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
      children: [
        const Divider(height: 50),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Step number
            _buildStepNumber(),

            const SizedBox(width: 32),

            // Form content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildLabel(),
                  const SizedBox(height: 4),
                  _buildSupportLabel(),
                  const SizedBox(height: 8),
                  _buildTextField(),
                  if (buttonVisible) ...[
                    const SizedBox(height: 12),
                    _buildButton(),
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStepNumber() {
    return FittedBox(
      fit: BoxFit.fitHeight,
      alignment: AlignmentGeometry.center,
      child: Container(
        child: Text(
          "$stepNumber.",
          style: TextStyle(
            fontSize: 50.0,
            color: (isActive) ? primaryColor : inactiveColor,
          ),
        ),
      ),
    );
  }

  Widget _buildLabel() {
    return Text(
      fieldLabel,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: isActive ? primaryColor : kTextColor,
      ),
    );
  }

  Widget _buildSupportLabel() {
    return Text(
      supportLabel,
      style: TextStyle(fontSize: 12, color: inactiveColor),
    );
  }

  Widget _buildTextField() {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      enabled: isActive,
      keyboardType: keyboardType,
      maxLength: maxLength,
      decoration: InputDecoration(
        hintText: isActive ? hint : "",
        counterText: maxLength != null ? "" : null,
        border: OutlineInputBorder(borderSide: BorderSide(color: bordercolor)),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: primaryColor, width: 2.0),
        ),
        filled: !isActive,
        fillColor: isActive ? null : Colors.grey[100],
      ),
      validator: isActive ? validator : null,
    );
  }

  Widget _buildButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          side: BorderSide(
            color: buttonEnabled ? primaryColor : inactiveColor,
            width: 2,
          ),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        onPressed: buttonEnabled ? onButtonPressed : null,
        child: Text(
          buttonLabel ?? "Continue",
          style: TextStyle(
            color: buttonEnabled ? primaryColor : inactiveColor,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

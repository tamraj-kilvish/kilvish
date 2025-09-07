import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'dart:developer';
import 'style.dart';
import 'common_widgets.dart';
import 'home_screen.dart';

class SignupScreen extends StatefulWidget {
  @override
  _SignupScreenState createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();
  final _usernameController = TextEditingController();
  
  String _verificationId = '';
  bool _isOtpSent = false;
  bool _isLoading = false;
  bool _showUsernameField = false;
  
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'kilvish');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kWhitecolor,
      appBar: AppBar(
        backgroundColor: kWhitecolor,
        elevation: 0,
        title: Text(
          'Welcome to Kilvish',
          style: TextStyle(
            color: primaryColor,
            fontSize: titleFontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: 40),
            
            // Phone Number Field
            if (!_showUsernameField) ...[
              Text(
                'Enter your phone number',
                style: TextStyle(
                  fontSize: largeFontSize,
                  color: kTextColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
              SizedBox(height: 10),
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                enabled: !_isOtpSent,
                decoration: InputDecoration(
                  hintText: '+91 9876543210',
                  prefixIcon: Icon(Icons.phone, color: primaryColor),
                  border: OutlineInputBorder(
                    borderSide: BorderSide(color: bordercolor),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: primaryColor, width: 2.0),
                  ),
                ),
              ),
              SizedBox(height: 20),
            ],
            
            // OTP Field
            if (_isOtpSent && !_showUsernameField) ...[
              Text(
                'Enter OTP sent to ${_phoneController.text}',
                style: TextStyle(
                  fontSize: largeFontSize,
                  color: kTextColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
              SizedBox(height: 10),
              TextField(
                controller: _otpController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(
                  hintText: '123456',
                  prefixIcon: Icon(Icons.security, color: primaryColor),
                  border: OutlineInputBorder(
                    borderSide: BorderSide(color: bordercolor),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: primaryColor, width: 2.0),
                  ),
                  counterText: '',
                ),
              ),
              SizedBox(height: 20),
            ],
            
            // Username Field
            if (_showUsernameField) ...[
              Text(
                'Choose a username',
                style: TextStyle(
                  fontSize: largeFontSize,
                  color: kTextColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
              SizedBox(height: 10),
              TextField(
                controller: _usernameController,
                decoration: InputDecoration(
                  hintText: 'Enter username',
                  prefixIcon: Icon(Icons.person, color: primaryColor),
                  border: OutlineInputBorder(
                    borderSide: BorderSide(color: bordercolor),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: primaryColor, width: 2.0),
                  ),
                ),
              ),
              SizedBox(height: 20),
            ],
            
            // Action Button
            ElevatedButton(
              onPressed: _isLoading ? null : _handleButtonPress,
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryColor,
                padding: EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: _isLoading
                  ? CircularProgressIndicator(color: kWhitecolor)
                  : Text(
                      _getButtonText(),
                      style: TextStyle(
                        fontSize: largeFontSize,
                        color: kWhitecolor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
            
            SizedBox(height: 20),
            
            // Resend OTP
            if (_isOtpSent && !_showUsernameField)
              TextButton(
                onPressed: _resendOtp,
                child: Text(
                  'Resend OTP',
                  style: TextStyle(
                    color: primaryColor,
                    fontSize: defaultFontSize,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _getButtonText() {
    if (_showUsernameField) return 'Complete Setup';
    if (_isOtpSent) return 'Verify OTP';
    return 'Send OTP';
  }

  void _handleButtonPress() {
    if (_showUsernameField) {
      _completeUserSetup();
    } else if (_isOtpSent) {
      _verifyOtp();
    } else {
      _sendOtp();
    }
  }

  void _sendOtp() async {
    if (_phoneController.text.isEmpty) {
      _showError('Please enter phone number');
      return;
    }

    setState(() => _isLoading = true);

    await _auth.verifyPhoneNumber(
      phoneNumber: _phoneController.text,
      verificationCompleted: (PhoneAuthCredential credential) async {
        _signInWithCredential(credential);
      },
      verificationFailed: (FirebaseAuthException e) {
        setState(() => _isLoading = false);
        _showError(e.message ?? 'Verification failed');
      },
      codeSent: (String verificationId, int? resendToken) {
        setState(() {
          _verificationId = verificationId;
          _isOtpSent = true;
          _isLoading = false;
        });
      },
      codeAutoRetrievalTimeout: (String verificationId) {
        _verificationId = verificationId;
      },
    );
  }

  void _verifyOtp() async {
    if (_otpController.text.isEmpty) {
      _showError('Please enter OTP');
      return;
    }

    setState(() => _isLoading = true);

    try {
      PhoneAuthCredential credential = PhoneAuthProvider.credential(
        verificationId: _verificationId,
        smsCode: _otpController.text,
      );
      
      _signInWithCredential(credential);
    } catch (e) {
      log('OTP Verification error: $e', error: e);
      setState(() => _isLoading = false);
      _showError('Invalid OTP: ${e.toString()}');
    }
  }

  void _signInWithCredential(PhoneAuthCredential credential) async {
    try {
      UserCredential userCredential = await _auth.signInWithCredential(credential);
      User? user = userCredential.user;
      
      if (user != null) {
        // Use Firebase Function to check if user exists by phone number
        try {
          HttpsCallable callable = FirebaseFunctions.instance.httpsCallable('getUserByPhone');
          final result = await callable.call({
            'phoneNumber': _phoneController.text,
          });
          
          if (result.data != null && result.data['user'] != null) {
            // Existing user - update their UID and go to home
            _navigateToHome();
          } else {
            // New user - show username field
            setState(() {
              _isLoading = false;
              _showUsernameField = true;
            });
          }
        } catch (e, stackTrace) {
          log('Firebase Function error: $e', error: e, stackTrace: stackTrace);
          // Fallback to direct Firestore check if function fails
          DocumentSnapshot userDoc = await _firestore
              .collection('User')
              .doc(user.uid)
              .get();
              
          if (!userDoc.exists) {
            setState(() {
              _isLoading = false;
              _showUsernameField = true;
            });
          } else {
            _navigateToHome();
          }
        }
      }
    } catch (e) {
      log('Authentication error: $e', error: e);
      //setState(() => _isLoading = false);
      _showError('Authentication failed: ${e.toString()}');
    }
  }

  void _completeUserSetup() async {
    if (_usernameController.text.isEmpty) {
      _showError('Please enter username');
      return;
    }

    setState(() => _isLoading = true);

    try {
      User? user = _auth.currentUser;
      if (user != null) {
        await _firestore.collection('User').doc(user.uid).set({
          'phone': _phoneController.text,
          'username': _usernameController.text,
          'createdAt': FieldValue.serverTimestamp(),
        });
        
        _navigateToHome();
      }
    } catch (e) {
      log('User profile creation error: $e', error:e,  name: 'SignupScreen');
      setState(() => _isLoading = false);
      _showError('Failed to create user profile: ${e.toString()}');
    }
  }

  void _resendOtp() {
    setState(() {
      _isOtpSent = false;
      _otpController.clear();
    });
    _sendOtp();
  }

  void _navigateToHome() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => HomeScreen()),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: errorcolor,
      ),
    );
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _otpController.dispose();
    _usernameController.dispose();
    super.dispose();
  }
}

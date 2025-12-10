import 'package:flutter/material.dart';
// Assuming CannyFeedbackPage is located in lib/pages/
import 'package:kilvish/canny_feedback_screen.dart';
import 'package:kilvish/style.dart';

class CannyFeedbackRibbon extends StatelessWidget {
  const CannyFeedbackRibbon({super.key});

  // The angle to rotate the ribbon (-45 degrees in radians)
  static const double _ribbonAngle = 0.785398;
  static const Color _ribbonColor = Color(0xFFE91E63); // Deep Pink for visibility

  @override
  Widget build(BuildContext context) {
    return Positioned(
      // Position the ribbon in the bottom-left corner
      bottom: 70,
      left: -40,
      child: Transform.rotate(
        angle: _ribbonAngle, // Rotate -45 degrees
        alignment: Alignment.bottomLeft,
        child: Material(
          color: Colors.transparent, // Use Material for InkWell effects
          child: InkWell(
            onTap: () {
              // Navigate to the feedback page
              Navigator.of(context).push(MaterialPageRoute(builder: (context) => const CannyFeedbackPage()));
            },
            child: Container(
              width: 150, // Width of the ribbon
              padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 20.0),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: primaryColor),
                //boxShadow: const [BoxShadow(color: primaryColor, blurRadius: 6, offset: Offset(4, 4))],
              ),
              child: const Text(
                'Feedback',
                textAlign: TextAlign.center,
                style: TextStyle(color: primaryColor, fontWeight: FontWeight.bold, fontSize: smallFontSize, letterSpacing: 0.7),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

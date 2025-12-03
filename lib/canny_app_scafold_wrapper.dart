import 'package:flutter/material.dart';
import 'package:kilvish/canny_feedback_ribbon.dart';

class AppScaffoldWrapper extends StatelessWidget {
  final Widget body;

  // Standard Scaffold properties
  final PreferredSizeWidget? appBar;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;

  const AppScaffoldWrapper({
    super.key,
    required this.body, // This is the content of your screen
    this.appBar,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
  });

  @override
  Widget build(BuildContext context) {
    // We use a Scaffold to preserve basic structure (appBar, etc.)
    return Scaffold(
      appBar: appBar,
      body: Stack(
        // The Stack is the key to layering content
        children: [
          // 1. The main content of the screen (e.g., your homepage, settings page)
          body,

          // 2. The Feedback Ribbon, positioned absolutely over the content
          const CannyFeedbackRibbon(),
        ],
      ),
      bottomNavigationBar: bottomNavigationBar,
      floatingActionButton: floatingActionButton,
      floatingActionButtonLocation: floatingActionButtonLocation,
    );
  }
}

import 'package:flutter/material.dart';
import 'package:kilvish/style.dart';
import 'package:webview_flutter/webview_flutter.dart';
// Note: Depending on your Flutter version, you might need to import
// 'package:webview_flutter_android/webview_flutter_android.dart'
// and 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart'
// for full platform compatibility, but the base package usually handles it.

// Replace this placeholder with your actual Canny Board Token.
const String cannyBoardToken = '28dce58a-bdbe-ea2d-1875-7099543df9e0';

class CannyFeedbackPage extends StatefulWidget {
  const CannyFeedbackPage({super.key});

  @override
  State<CannyFeedbackPage> createState() => _CannyFeedbackPageState();
}

class _CannyFeedbackPageState extends State<CannyFeedbackPage> {
  // 1. Construct the Controller
  late final WebViewController controller;

  // 2. Build the Canny URL for the mobile widget.
  // We omit ssoToken since you are not tracking/identifying users yet.
  final String cannyUrl = 'https://embed-40835889.sleekplan.app';

  @override
  void initState() {
    super.initState();

    // 3. Initialize the controller
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      //..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            // Can be used to show a loading indicator
            debugPrint('WebView is loading (progress: $progress%)');
          },
          onPageStarted: (String url) {
            debugPrint('Page started loading: $url');
          },
          onPageFinished: (String url) {
            debugPrint('Page finished loading: $url');
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('''
              Page loading error:
              Error Code: ${error.errorCode}
              Description: ${error.description}
              For: ${error.url}
            ''');
          },
          onNavigationRequest: (NavigationRequest request) {
            // Allows the WebView to load the Canny URL
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(cannyUrl));

    // Optional: If you want to use a specific platform controller for customization
    // if (controller.platform is AndroidWebViewController) {
    //   AndroidWebViewController.enableDebugging(true);
    // }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Features/Bugs'), backgroundColor: primaryColor, foregroundColor: Colors.white),
      body: SafeArea(
        // 4. Use the WebViewWidget in the body
        child: WebViewWidget(controller: controller),
      ),
    );
  }
}

// Example of how to call this page from your main app:
/*
  onTap: () {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const CannyFeedbackPage(),
      ),
    );
  },
*/

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:kilvish/style.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

const String _feedbackUrl = 'https://embed-40835889.sleekplan.app';

class CannyFeedbackPage extends StatefulWidget {
  const CannyFeedbackPage({super.key});

  @override
  State<CannyFeedbackPage> createState() => _CannyFeedbackPageState();
}

class _CannyFeedbackPageState extends State<CannyFeedbackPage> {
  late final WebViewController? _controller;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _controller = null;
      // Auto-open in a new browser tab and pop back.
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await launchUrl(Uri.parse(_feedbackUrl), mode: LaunchMode.externalApplication);
        if (mounted) Navigator.of(context).pop();
      });
    } else {
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(NavigationDelegate(
          onNavigationRequest: (_) => NavigationDecision.navigate,
        ))
        ..loadRequest(Uri.parse(_feedbackUrl));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Features/Bugs'), backgroundColor: primaryColor, foregroundColor: Colors.white),
      body: kIsWeb
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(child: WebViewWidget(controller: _controller!)),
    );
  }
}

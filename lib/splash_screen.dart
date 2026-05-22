import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:kilvish/app_router.dart';
import 'package:kilvish/import_receipt_screen.dart';
import 'package:kilvish/main.dart';
import 'package:share_handler/share_handler.dart';
import 'style.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      // Web has no share handler — go straight to home
      WidgetsBinding.instance.addPostFrameCallback((_) => context.go('/home'));
      return;
    }
    _startup();
  }

  Future<void> _startup() async {
    final media = await ShareHandlerPlatform.instance.getInitialSharedMedia();
    if (!mounted) return;

    if (media?.attachments?.isNotEmpty == true) {
      final attachment = media!.attachments!.first;
      if (attachment != null) {
        navigatorKey.currentState?.pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => ImportReceiptScreen(receiptFile: File(attachment.path))),
          (route) => false,
        );
        return;
      }
    }

    // No incoming share — check for pending work
    final navigated = await navigateToBulkImportIfRequired();
    if (!mounted || navigated) return;

    // No pending work — go to home
    context.go('/home');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: primaryColor,
      body: Center(child: Image.asset('assets/images/kilvish-inverted.png', width: 200, height: 200)),
    );
  }
}

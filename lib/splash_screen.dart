import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/models_pending_import.dart';
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
      // Web has no share handler — go straight to home.
      // addPostFrameCallback ensures the widget tree is fully built before navigating.
      WidgetsBinding.instance.addPostFrameCallback((_) => _goHome());
      return;
    }
    _startup();
  }

  Future<void> _startup() async {
    // Check for a receipt shared into the app at cold launch (iOS/Android share sheet).
    final media = await ShareHandlerPlatform.instance.getInitialSharedMedia();
    if (!mounted) return;

    if (media?.attachments?.isNotEmpty == true) {
      final attachment = media!.attachments!.first;
      if (attachment != null) {
        // context.go() keeps GoRouter's internal state in sync — critical for
        // logout redirect to work correctly after startup.
        context.go('/import-receipt', extra: File(attachment.path));
        return;
      }
    }

    // No incoming share — check for pending imports or WIP expenses.
    final pending = await PendingImport.loadFromCache();
    final wips = await CacheManager.loadWIPExpenses() ?? [];
    if (!mounted) return;

    if (pending.isNotEmpty || wips.isNotEmpty) {
      context.go('/bulk-import');
      return;
    }

    _goHome();
  }

  void _goHome() {
    if (mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: primaryColor,
      body: Center(child: Image.asset('assets/images/kilvish-inverted.png', width: 200, height: 200)),
    );
  }
}

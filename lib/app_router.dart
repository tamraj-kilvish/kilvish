import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:kilvish/bulk_import_screen.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/home_screen.dart';
import 'package:kilvish/import_receipt_screen.dart';
import 'package:kilvish/models_pending_import.dart';
import 'package:kilvish/signup_screen.dart';
import 'package:kilvish/tag_detail_screen.dart';
import 'package:share_handler/share_handler.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();

bool _initialMediaChecked = false;
String? _initialMediaPath;
bool _shouldCheckPendingImports = true;

class _AuthNotifier extends ChangeNotifier {
  late final StreamSubscription<User?> _sub;

  _AuthNotifier() {
    _sub = FirebaseAuth.instance.authStateChanges().listen((_) => notifyListeners());
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

class _AppLifecycleNotifier extends ChangeNotifier with WidgetsBindingObserver {
  _AppLifecycleNotifier() {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _shouldCheckPendingImports = true;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final appRouter = GoRouter(
  navigatorKey: navigatorKey,
  observers: [routeObserver],
  refreshListenable: Listenable.merge([_AuthNotifier(), _AppLifecycleNotifier()]),
  initialLocation: '/home',
  redirect: (context, state) async {
    final loggedIn = FirebaseAuth.instance.currentUser != null;
    final onSignup = state.matchedLocation == '/';
    if (!loggedIn && !onSignup) {
      final from = Uri.encodeComponent(state.uri.toString());
      return '/?from=$from';
    }

    if (!loggedIn) return null;

    if (!kIsWeb && !_initialMediaChecked) {
      _initialMediaChecked = true;
      final media = await ShareHandlerPlatform.instance.getInitialSharedMedia();
      if (media?.attachments?.isNotEmpty == true) {
        final path = media!.attachments!.first?.path;
        if (path != null) {
          _initialMediaPath = path;
          return '/import';
        }
      }
    }

    if (!kIsWeb && _shouldCheckPendingImports && state.matchedLocation != '/bulk-import') {
      _shouldCheckPendingImports = false;
      final pending = await PendingImport.loadFromCache();
      final wips = await CacheManager.loadWIPExpenses() ?? [];
      if (pending.isNotEmpty || wips.isNotEmpty) {
        return '/bulk-import';
      }
    }

    return null;
  },
  routes: [
    GoRoute(path: '/', builder: (_, __) => const SignupScreen()),
    GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
    GoRoute(
      path: '/import',
      builder: (_, __) => ImportReceiptScreen(receiptFile: File(_initialMediaPath!)),
    ),
    GoRoute(path: '/bulk-import', builder: (_, __) => const BulkImportScreen()),
    GoRoute(
      path: '/tags/:tagId',
      builder: (_, state) => TagDetailScreen(tagId: state.pathParameters['tagId']),
    ),
  ],
);

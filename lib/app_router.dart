import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:kilvish/home_screen.dart';
import 'package:kilvish/import_receipt_screen.dart';
import 'package:kilvish/signup_screen.dart';
import 'package:kilvish/tag_detail_screen.dart';
import 'package:share_handler/share_handler.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();

bool _initialMediaChecked = false;
String? _initialMediaPath;

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

final appRouter = GoRouter(
  navigatorKey: navigatorKey,
  observers: [routeObserver],
  refreshListenable: _AuthNotifier(),
  initialLocation: '/home',
  redirect: (context, state) async {
    final loggedIn = FirebaseAuth.instance.currentUser != null;
    final onSignup = state.matchedLocation == '/';
    if (!loggedIn && !onSignup) {
      final from = Uri.encodeComponent(state.uri.toString());
      return '/?from=$from';
    }

    if (loggedIn && !kIsWeb && !_initialMediaChecked) {
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

    return null;
  },
  routes: [
    GoRoute(path: '/', builder: (_, __) => const SignupScreen()),
    GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
    GoRoute(
      path: '/import',
      builder: (_, __) => ImportReceiptScreen(receiptFile: File(_initialMediaPath!)),
    ),
    GoRoute(
      path: '/tags/:tagId',
      builder: (_, state) => TagDetailScreen(tagId: state.pathParameters['tagId']),
    ),
  ],
);

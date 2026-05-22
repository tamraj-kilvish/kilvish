import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:kilvish/home_screen.dart';
import 'package:kilvish/signup_screen.dart';
import 'package:kilvish/splash_screen.dart';
import 'package:kilvish/tag_detail_screen.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();

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
  initialLocation: '/splash',
  redirect: (context, state) {
    final loggedIn = FirebaseAuth.instance.currentUser != null;
    final onPublicRoute = state.matchedLocation == '/' || state.matchedLocation == '/splash';
    if (!loggedIn && !onPublicRoute) {
      final from = Uri.encodeComponent(state.uri.toString());
      return '/?from=$from';
    }
    return null;
  },
  routes: [
    GoRoute(path: '/', builder: (_, __) => const SignupScreen()),
    GoRoute(path: '/splash', builder: (_, _s) => const SplashScreen()),
    GoRoute(path: '/home', builder: (_, _s) => const HomeScreen()),
    GoRoute(
      path: '/tags/:tagId',
      builder: (_, state) => TagDetailScreen(tagId: state.pathParameters['tagId']),
    ),
  ],
);

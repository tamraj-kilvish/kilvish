import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:kilvish/pending_import_service.dart';
import 'package:kilvish/share_service.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:kilvish/bulk_import_screen.dart';
import 'package:kilvish/contact_screen.dart';
import 'package:kilvish/expense_add_edit_screen.dart';
import 'package:kilvish/pre_expense_add_edit_screen.dart';
import 'package:kilvish/expense_detail_screen.dart';
import 'package:kilvish/home_screen.dart';
import 'package:kilvish/import_receipt_screen.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/models_pending_import.dart';
import 'package:kilvish/pending_import_detail_screen.dart';
import 'package:kilvish/signup_screen.dart';
import 'package:kilvish/splash_screen.dart';
import 'package:kilvish/tag_add_edit_screen.dart';
import 'package:kilvish/tag_detail_screen.dart';
import 'package:kilvish/tag_expense_config_screen.dart';
import 'package:kilvish/canny_feedback_screen.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/tag_selection_screen.dart';

// ── Globals ──────────────────────────────────────────────────────────────────

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Attached to the GoRouter navigator so RouteAware screens (e.g. HomeScreen)
/// receive didPopNext() when a pushed route is popped.
final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();

// ── Auth notifier ─────────────────────────────────────────────────────────────

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

// ── Router ────────────────────────────────────────────────────────────────────

/// GoRouter's sole job: auth guard + URL resolution.
/// context.push() is used for all runtime navigation — GoRouter handles
/// browser history entries and URL updates automatically.
final appRouter = GoRouter(
  navigatorKey: navigatorKey,
  observers: [routeObserver],
  refreshListenable: Listenable.merge([_AuthNotifier(), ShareService(), PendingImportService()]),
  initialLocation: '/splash',
  onException: (BuildContext context, GoRouterState state, GoRouter router) {
    // Firebase Auth reCAPTCHA callbacks arrive as custom-scheme deep links
    // (com.googleusercontent.apps.*://firebaseauth/link?...).
    // The Firebase SDK handles these internally — GoRouter should ignore them.
    if (state.uri.host == 'firebaseauth') return;
    showError(context, 'Page not found. Redirecting you home.');
    router.go('/');
  },
  redirect: (context, state) {
    final loggedIn = FirebaseAuth.instance.currentUser != null;
    final path = state.matchedLocation;
    final onPublicRoute = path == '/signup' || path == '/splash';

    print('[Router] redirect: path=$path loggedIn=$loggedIn pendingMedia=${ShareService().pendingMedia != null} hasPendingItems=${PendingImportService().hasPendingItems}');

    if (!loggedIn && !onPublicRoute) {
      final from = Uri.encodeComponent(state.uri.toString());
      return '/signup?from=$from';
    }

    if (loggedIn && !kIsWeb) {
      // Share received — highest priority, takes user to import screen.
      if (ShareService().pendingMedia != null && path != '/import-receipt') {
        print('[Router] redirect -> /import-receipt (share pending)');
        return '/import-receipt';
      }
      // Pending imports — only interrupt cold launch (splash) or home landing.
      // Do not intercept in-app navigation (e.g. pushing expense edit from bulk-import).
      if (PendingImportService().hasPendingItems &&
          (path == '/splash' || path == '/')) {
        print('[Router] redirect -> /bulk-import (pending items)');
        return '/bulk-import';
      }
    }

    // Navigate away from splash once auth + service state is known.
    if (loggedIn && path == '/splash') return kIsWeb ? '/tags' : '/';

    // On web, redirect bare root to /tags so the address bar never shows '/'.
    if (kIsWeb && path == '/') return '/tags';

    return null;
  },
  routes: [
    // ── Public ───────────────────────────────────────────────────────────────
    GoRoute(path: '/signup', builder: (_, s) => const SignupScreen()),
    GoRoute(path: '/splash', builder: (_, s) => const SplashScreen()),
    GoRoute(path: '/feedback', builder: (_, s) => const CannyFeedbackPage()),

    // ── Home (root) ───────────────────────────────────────────────────────────
    // extra: optional String? messageOnLoad (used by FCM navigation)
    GoRoute(path: '/', builder: (_, s) => HomeScreen(messageOnLoad: s.extra as String?)),

    // ── Utility screens ───────────────────────────────────────────────────────
    GoRoute(path: '/bulk-import', builder: (_, s) => BulkImportScreen(newImport: s.extra as PendingImport?)),
    GoRoute(
      path: '/import-receipt',
      builder: (_, state) {
        final media = ShareService().pendingMedia;
        final attachment = media?.attachments?.isNotEmpty == true ? media!.attachments!.first : null;
        if (attachment == null) {
          return const Scaffold(body: Center(child: Text('No receipt file provided')));
        }
        return ImportReceiptScreen(receiptFile: File(attachment.path));
      },
    ),

    // ── Contact picker ────────────────────────────────────────────────────────
    // extra: {'contactSelection': ContactSelection, 'sharedWithContacts': Set<SelectableContact>}
    GoRoute(
      path: '/contacts',
      builder: (_, state) {
        final d = state.extra as Map<String, dynamic>;
        return ContactScreen(
          contactSelection: d['contactSelection'] as ContactSelection,
          sharedWithContacts: d['sharedWithContacts'] as Set<SelectableContact>,
        );
      },
    ),

    // ── Pending import detail ─────────────────────────────────────────────────
    // extra: PendingImport
    GoRoute(
      path: '/pending-import',
      builder: (_, state) =>
          PendingImportDetailScreen(pendingImport: state.extra as PendingImport),
    ),

    // ── Tags ─────────────────────────────────────────────────────────────────
    // /tags (exact) → HomeScreen with Tags tab active (web deep-link / refresh)
    GoRoute(path: '/tags', builder: (_, s) => const HomeScreen(initialTabIndex: 0)),
    GoRoute(path: '/tags/new', builder: (_, s) => TagAddEditScreen()),
    GoRoute(
      path: '/tags/:tagId',
      builder: (_, state) => TagDetailScreen(
        tag: state.extra as Tag?,             // non-null for in-app navigation
        tagId: state.pathParameters['tagId'], // used on cold URL load
      ),
    ),
    GoRoute(
      path: '/tags/:tagId/edit',
      builder: (_, state) => TagAddEditScreen(tag: state.extra as Tag?),
    ),

    // ── Expenses ──────────────────────────────────────────────────────────────
    // /expenses (exact) → HomeScreen with My Expenses tab active (web deep-link / refresh)
    GoRoute(path: '/expenses', builder: (_, s) => const HomeScreen(initialTabIndex: 1)),
    // In-memory FAB flow — must be before /expenses/:expenseId so 'new' isn't parsed as an id
    GoRoute(
      path: '/expenses/new',
      builder: (_, state) => ExpenseAddEditScreen(baseExpense: state.extra as WIPExpense),
    ),
    GoRoute(
      path: '/pre-expense-create',
      builder: (_, state) => PreExpenseAddEditScreen(wipExpense: state.extra as WIPExpense),
    ),
    GoRoute(
      path: '/expenses/:expenseId',
      builder: (_, state) => ExpenseDetailScreen(
        expense: state.extra as Expense?,
        expenseId: state.pathParameters['expenseId'],
      ),
    ),
    GoRoute(
      path: '/expenses/:expenseId/edit',
      builder: (_, state) =>
          ExpenseAddEditScreen(baseExpense: state.extra as BaseExpense),
    ),
    GoRoute(
      path: '/expenses/:expenseId/tag-selection',
      builder: (_, state) =>
          TagSelectionScreen(expense: state.extra as BaseExpense),
    ),
    GoRoute(
      path: '/expenses/:expenseId/tag-link',
      builder: (_, state) {
        final d = state.extra as Map<String, dynamic>;
        return TagExpenseConfigScreen(
          tag: d['tag'] as Tag,
          expense: d['expense'] as BaseExpense,
          isExpenseOwner: d['isExpenseOwner'] as bool,
          initialConfig: d['initialConfig'] as TagExpenseConfig?,
          currentUserId: d['currentUserId'] as String?,
        );
      },
    ),

    // ── Tags > Expenses ───────────────────────────────────────────────────────
    GoRoute(
      path: '/tags/:tagId/expenses/:expenseId',
      builder: (_, state) => ExpenseDetailScreen(
        expense: state.extra as Expense?,
        expenseId: state.pathParameters['expenseId'],
        tagId: state.pathParameters['tagId'],
      ),
    ),
    GoRoute(
      path: '/tags/:tagId/expenses/:expenseId/edit',
      builder: (_, state) =>
          ExpenseAddEditScreen(baseExpense: state.extra as BaseExpense),
    ),
  ],
);

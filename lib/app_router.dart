import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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
  refreshListenable: _AuthNotifier(),
  initialLocation: '/splash',
  redirect: (context, state) {
    final loggedIn = FirebaseAuth.instance.currentUser != null;
    final onPublicRoute =
        state.matchedLocation == '/signup' || state.matchedLocation == '/splash';
    if (!loggedIn && !onPublicRoute) {
      final from = Uri.encodeComponent(state.uri.toString());
      return '/signup?from=$from';
    }
    // On web, redirect bare root to /tags so the address bar never shows '/'.
    // FCM navigation uses appRouter.go('/') only on mobile, so this is safe.
    if (kIsWeb && state.matchedLocation == '/') return '/tags';
    return null;
  },
  routes: [
    // ── Public ───────────────────────────────────────────────────────────────
    GoRoute(path: '/signup', builder: (_, s) => const SignupScreen()),
    GoRoute(path: '/splash', builder: (_, s) => const SplashScreen()),

    // ── Home (root) ───────────────────────────────────────────────────────────
    // extra: optional String? messageOnLoad (used by FCM navigation)
    GoRoute(path: '/', builder: (_, s) => HomeScreen(messageOnLoad: s.extra as String?)),

    // ── Utility screens ───────────────────────────────────────────────────────
    GoRoute(path: '/bulk-import', builder: (_, s) => BulkImportScreen(newImport: s.extra as PendingImport?)),
    GoRoute(
      path: '/import-receipt',
      builder: (_, state) {
        final file = state.extra as File?;
        if (file == null) {
          return const Scaffold(body: Center(child: Text('No receipt file provided')));
        }
        return ImportReceiptScreen(receiptFile: file);
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

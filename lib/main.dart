import 'dart:async';
import 'dart:io';

import 'package:flutter_web_plugins/url_strategy.dart';

import 'package:background_downloader/background_downloader.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:go_router/go_router.dart';
import 'package:kilvish/app_router.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/models_pending_import.dart';
import 'style.dart';
import 'firebase_options.dart';
import 'fcm_handler.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:share_handler/share_handler.dart';

void main() async {
  usePathUrlStrategy();
  GoRouter.optionURLReflectsImperativeAPIs = true;

  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Enable offline persistence
  FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'kilvish').settings = const Settings(persistenceEnabled: true);

  // Clear stale web cache before the app renders
  await CacheManager.clearStaleWebCacheIfNeeded();

  // Setup FCM background handler
  if (!kIsWeb) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  runApp(const MyApp());
}

/// Navigates to BulkImportScreen if there are pending imports or WIP expenses.
/// Returns true if navigation happened, false otherwise.
Future<bool> navigateToBulkImportIfRequired() async {
  final pending = await PendingImport.loadFromCache();
  final wips = await CacheManager.loadWIPExpenses() ?? [];
  if (pending.isNotEmpty || wips.isNotEmpty) {
    appRouter.go('/bulk-import');
    return true;
  }
  return false;
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  bool _fcmDisposed = false;
  StreamSubscription<Map<String, String>>? _navigationSubscription;

  void _handleSharedMedia(SharedMedia? media) {
    if (media?.attachments?.isNotEmpty != true) return;
    final attachment = media!.attachments!.first;
    if (attachment == null) return;
    appRouter.go('/import-receipt', extra: File(attachment.path));
  }

  Future<void> _handleFCMNavigation(Map<String, String> navData) async {
    print("inside _handleFCMNavigation with navData $navData");
    try {
      final navType = navData['type'];

      if (navType == 'home') {
        // extra is the optional messageOnLoad string shown as a banner in HomeScreen
        appRouter.go('/', extra: navData['message']);
      } else if (navType == 'tag') {
        final tagId = navData['tagId'];
        if (tagId == null) {
          print("inside _handleFCMNavigation - cant load tag detail screen as tagId is null");
          return;
        }

        final tag = await getTagData(tagId, fromCache: true);
        print("inside _handleFCMNavigation - going to home then pushing tag detail");
        appRouter.go('/');
        // Push tag detail after the frame settles so the home route is fully built first.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          appRouter.push('/tags/$tagId', extra: tag);
        });
      } else if (navType == 'bulk_import') {
        appRouter.go('/bulk-import');
      }
    } catch (e, stackTrace) {
      print('Error handling FCM navigation: $e $stackTrace');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !kIsWeb) {
      navigateToBulkImportIfRequired();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (!kIsWeb) {
      FCMService.instance.initialize();

      _navigationSubscription = FCMService.instance.navigationStream.listen((navData) {
        print('main.dart - inside navigationStream.listen');
        _handleFCMNavigation(navData);
      });

      // Subsequent shares while app is running
      ShareHandlerPlatform.instance.sharedMediaStream.listen(_handleSharedMedia);

      FileDownloader().updates.listen((update) async {
        if (update is TaskStatusUpdate) {
          final taskId = update.task.taskId;
          final isMainReceipt = !taskId.startsWith('extra_');

          if (update.status == TaskStatus.complete && isMainReceipt) {
            // Upload reached server — remove PendingImport (belt-and-suspenders alongside FCM wip_status_update)
            await PendingImport.removeFromCache(taskId);
          }

          if (update.status == TaskStatus.failed) {
            if (isMainReceipt) {
              // WIPExpense may not exist yet (upload never reached server); mark for user to see error
              await PendingImport.markError(taskId);
            } else {
              // Additional receipt on an existing WIPExpense — update its status
              final expenseId = taskId.split('_')[1];
              await updateWIPExpenseStatus(
                expenseId,
                ExpenseStatus.uploadingReceipt,
                errorMessage: 'Upload failed. Please try again.',
              );
            }
          }
        } else if (update is TaskProgressUpdate) {
          print("Progress: ${update.task.taskId} -> ${(update.progress * 100).toStringAsFixed(1)}%");
        }
      });

      FileDownloader().start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!kIsWeb && !_fcmDisposed) {
      _navigationSubscription?.cancel();
      FCMService.instance.dispose();
      _fcmDisposed = true;
    }

    if (!kIsWeb) FileDownloader().destroy();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Kilvish',
      routerConfig: appRouter,
      theme: ThemeData(
        primarySwatch: primaryColor,
        fontFamily: 'Roboto',
        textTheme: TextTheme(
          bodyLarge: TextStyle(fontSize: defaultFontSize, color: kTextColor, fontWeight: FontWeight.w500),
          bodyMedium: TextStyle(fontSize: defaultFontSize, color: kTextMedium, fontWeight: FontWeight.w500),
          bodySmall: TextStyle(fontWeight: FontWeight.w500),
          labelLarge: TextStyle(fontWeight: FontWeight.w500),
          labelMedium: TextStyle(fontWeight: FontWeight.w500),
          labelSmall: TextStyle(fontWeight: FontWeight.w500),
          titleLarge: TextStyle(fontSize: titleFontSize, color: kTextColor, fontWeight: FontWeight.bold),
          titleMedium: TextStyle(fontWeight: FontWeight.w600),
          titleSmall: TextStyle(fontWeight: FontWeight.w600),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderSide: BorderSide(color: bordercolor)),
          focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: primaryColor, width: 2.0)),
        ),
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}

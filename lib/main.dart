import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:kilvish/app_router.dart';
import 'package:kilvish/bulk_import_screen.dart';
import 'home_screen.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/firestore.dart';
import 'package:kilvish/tag_detail_screen.dart';
import 'style.dart';
import 'firebase_options.dart';
import 'fcm_handler.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:share_handler/share_handler.dart';
import 'import_receipt_screen.dart';

void main() async {
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

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _fcmDisposed = false;
  StreamSubscription<Map<String, String>>? _navigationSubscription;

  void _handleSharedMedia(SharedMedia? media) {
    if (media?.attachments?.isNotEmpty != true) return;
    final attachment = media!.attachments!.first;
    if (attachment == null) return;
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => ImportReceiptScreen(receiptFile: File(attachment.path))),
      (route) => false,
    );
  }

  Future<void> _handleFCMNavigation(Map<String, String> navData) async {
    print("inside _handleFCMNavigation with navData $navData");
    try {
      final navType = navData['type'];

      if (navType == 'home') {
        await navigatorKey.currentState?.pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => HomeScreen(messageOnLoad: navData['message'])),
          (route) => false,
        );
      } else if (navType == 'tag') {
        final tagId = navData['tagId'];
        if (tagId == null) {
          print("inside _handleFCMNavigation - cant load tag detail screen as tagId is null");
          return;
        }
        final tag = await getTagData(tagId, fromCache: true);
        print("inside _handleFCMNavigation - pushAndRemove Home screen");
        navigatorKey.currentState?.pushAndRemoveUntil(MaterialPageRoute(builder: (context) => HomeScreen()), (route) => false);
        print("inside _handleFCMNavigation - now rendering tag detail screen");
        await navigatorKey.currentState?.push(MaterialPageRoute(builder: (context) => TagDetailScreen(tag: tag)));
      } else if (navType == 'bulk_import') {
        await navigatorKey.currentState?.pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => BulkImportScreen()),
          (route) => false,
        );
      }
    } catch (e, stackTrace) {
      print('Error handling FCM navigation: $e $stackTrace');
    }
  }

  @override
  void initState() {
    super.initState();

    if (!kIsWeb) {
      FCMService.instance.initialize();

      _navigationSubscription = FCMService.instance.navigationStream.listen((navData) {
        print('main.dart - inside navigationStream.listen');
        _handleFCMNavigation(navData);
      });

      // Handle shared media (receipts) — both stream and initial launch
      ShareHandlerPlatform.instance.sharedMediaStream.listen(_handleSharedMedia);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ShareHandlerPlatform.instance.getInitialSharedMedia().then(_handleSharedMedia);
      });
    }

    if (!kIsWeb) {
      FileDownloader().updates.listen((update) {
        if (update is TaskStatusUpdate) {
          print("Status: ${update.task.taskId} -> ${update.status.name}");

          if (update.status == TaskStatus.failed) {
            FileDownloader().taskForId(update.task.taskId).then((task) async {
              final result = await FileDownloader().database.recordForId(update.task.taskId);
              print("Failed result: $result");
              print("Exception: ${result?.exception}");
            });
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
          bodyLarge: TextStyle(fontSize: defaultFontSize, color: kTextColor),
          bodyMedium: TextStyle(fontSize: defaultFontSize, color: kTextMedium),
          titleLarge: TextStyle(fontSize: titleFontSize, color: kTextColor, fontWeight: FontWeight.bold),
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

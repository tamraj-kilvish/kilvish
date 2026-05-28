import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:background_downloader/background_downloader.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/models_pending_import.dart';

const int maxConcurrentImports = 4;
bool _processNextInProgress = false;

/// Picks pending imports with status=pending and enqueues their uploads up to [maxConcurrentImports].
/// WIPExpense creation is now server-side (uploadReceiptApi). PendingImport is removed via FCM or
/// on TaskStatus.completed — not here.
Future<void> processNextPendingImport({
  void Function()? onUploading,
  void Function(String pendingId)? onError,
}) async {
  if (_processNextInProgress) return;

  try {
    final wips = await CacheManager.loadWIPExpenses() ?? [];
    final processingCount = wips
        .where((w) => w.status != ExpenseStatus.readyForReview && (w.errorMessage == null || w.errorMessage!.isEmpty))
        .length;

    if (processingCount >= maxConcurrentImports) {
      print('[BulkProcess] At capacity ($processingCount/$maxConcurrentImports) — waiting for FCM');
      return;
    }

    // Only process items that haven't been enqueued yet (skip uploading and error)
    final pending = (await PendingImport.loadFromCache())
        .where((p) => p.status == PendingImportStatus.pending)
        .toList();

    if (pending.isEmpty) {
      print('[BulkProcess] No pending imports ready to enqueue');
      return;
    }

    if (_processNextInProgress) return;
    _processNextInProgress = true;

    await Future.wait(
      pending
          .take(maxConcurrentImports - processingCount)
          .map((item) => processPendingImport(item, onUploading: onUploading, onError: onError)),
    );
  } finally {
    _processNextInProgress = false;
  }
}

Future<void> processPendingImport(
  PendingImport next, {
  void Function()? onUploading,
  void Function(String pendingId)? onError,
}) async {
  print('[BulkProcess] processPendingImport: id=${next.id} tagId=${next.tagId}');

  final receiptFile = File(next.stagedPath);
  if (!receiptFile.existsSync()) {
    print('[BulkProcess] processPendingImport: staged file missing for id=${next.id}, removing stale PendingImport');
    await PendingImport.removeFromCache(next.id);
    return;
  }

  // Move to permanent location so it survives until FileDownloader completes the upload
  final appDir = await getApplicationDocumentsDirectory();
  final filename = p.basename(next.stagedPath);
  final destPath = p.join(appDir.path, filename);
  if (!File(destPath).existsSync()) {
    await receiptFile.copy(destPath);
  }
  await receiptFile.delete().catchError((_) => receiptFile);

  final token = await getFirebaseAuthInstance().currentUser!.getIdToken();
  final userId = (await getLoggedInUserData())?.id ?? '';

  final task = UploadTask(
    taskId: next.id, // same id as wipExpenseId — FileDownloader deduplicates across sessions
    url: 'https://asia-south1-tamraj-kilvish.cloudfunctions.net/uploadReceiptApi',
    filename: filename,
    headers: {'Authorization': 'Bearer $token'},
    fields: {
      'wipExpenseId': next.id,
      'collectionType': 'WIPExpenses',
      'userId': userId,
      if (next.tagId != null) 'tagId': next.tagId!,
      if (next.isLoanPayback) 'loanPaybackTagName': '',
      'createdAt': next.createdAt.millisecondsSinceEpoch.toString(),
    },
    updates: Updates.statusAndProgress,
  );

  final enqueued = await FileDownloader().enqueue(task);
  print('[BulkProcess] processPendingImport: enqueue result=$enqueued for id=${next.id}');

  if (enqueued) {
    await PendingImport.markUploading(next.id);
    onUploading?.call();
  } else {
    print('[BulkProcess] processPendingImport: failed to enqueue id=${next.id}');
    onError?.call(next.id);
  }
}

Future<WIPExpense?> handleSharedReceipt(File receiptFile, {WIPExpense? wipExpenseAsParam}) async {
  try {
    // 1. Move file to a permanent location so it survives app closure
    final appDir = await getApplicationDocumentsDirectory();
    final filePath = p.join(appDir.path, p.basename(receiptFile.path));

    final wipExpense = wipExpenseAsParam ?? await createWIPExpense();
    if (wipExpense == null) return null;

    final savedFile = await receiptFile.copy(filePath);
    print("savedFile path ${savedFile.path}");
    await attachLocalPathToWIPExpense(wipExpense.id, savedFile.path);

    //deleting shared (temp) file
    receiptFile.delete().then((value) {
      print("temp shared file ${receiptFile.path} deleted");
    });

    // 2. Create the Upload Task
    // Replace URL with your Firebase Function URL after deployment
    final task = UploadTask(
      taskId: wipExpense.id,
      url: 'https://asia-south1-tamraj-kilvish.cloudfunctions.net/uploadReceiptApi',
      //directory: appDir.path,
      filename: p.basename(receiptFile.path),
      headers: {'Authorization': 'Bearer ${await getFirebaseAuthInstance().currentUser!.getIdToken()}'},
      fields: {'expenseId': wipExpense.id, 'collectionType': 'WIPExpenses', 'userId': (await getLoggedInUserData())?.id ?? ''},
      //httpRequestMethod: 'POST',
      updates: Updates.statusAndProgress,
    );

    // 3. Start Upload
    final enqueueStatus = await FileDownloader().enqueue(task);
    print("Task enqueue status $enqueueStatus");

    // Update local UI state
    //TODO - change this to uploadReceipt when background job actually starts uploading
    if (enqueueStatus) {
      await updateWIPExpenseStatus(wipExpense.id, ExpenseStatus.uploadingReceipt);
      return wipExpense;
    } else {
      print("handleSharedReceipt - upload could not be enqueued");
      return null;
    }
  } catch (e) {
    print("Background Downloader Error: $e");
    return null;
  }
}

/// Uploads an additional image (no OCR) for an existing Expense or WIPExpense.
/// Persists the local file path to Firestore before upload so the file isn't lost on crash.
/// Calls [onDownloadUrl] with the Firebase Storage URL on success, [onError] on failure.
Future<void> handleAdditionalReceipt({
  required File imageFile,
  required String expenseId,
  required bool isWIPExpense,
  required int arrayIndex,
  required void Function(String downloadUrl) onDownloadUrl,
  required void Function() onError,
}) async {
  try {
    final appDir = await getApplicationDocumentsDirectory();
    final savedFile = await imageFile.copy(p.join(appDir.path, p.basename(imageFile.path)));

    final collectionType = isWIPExpense ? 'WIPExpenses' : 'Expenses';

    // Persist local path first — receipt survives app crash before upload completes
    await setOtherReceiptUrlAtIndex(expenseId, collectionType, arrayIndex, savedFile.path);

    final userId = (await getLoggedInUserData())?.id ?? '';
    final task = UploadTask(
      taskId: 'extra_${expenseId}_$arrayIndex',
      url: 'https://asia-south1-tamraj-kilvish.cloudfunctions.net/uploadReceiptApi',
      filename: p.basename(savedFile.path),
      headers: {'Authorization': 'Bearer ${await getFirebaseAuthInstance().currentUser!.getIdToken()}'},
      fields: {
        'userId': userId,
        'expenseId': expenseId,
        'collectionType': collectionType,
        'arrayIndex': '$arrayIndex',
        'isAdditionalReceipt': 'true',
      },
      updates: Updates.statusAndProgress,
    );

    final result = await FileDownloader().upload(task);
    if (result.status == TaskStatus.complete && result.responseBody != null) {
      final data = jsonDecode(result.responseBody!) as Map<String, dynamic>;
      onDownloadUrl(data['downloadUrl'] as String);
    } else {
      onError();
    }
  } catch (e) {
    print('[handleAdditionalReceipt] error: $e');
    onError();
  }
}

const _uploadReceiptApiUrl = 'https://asia-south1-tamraj-kilvish.cloudfunctions.net/uploadReceiptApi';

/// Web-specific: uploads receipt bytes directly via HTTP (no FileDownloader).
/// Pass [arrayIndex] for additional receipts; omit for the main receipt.
/// Returns the Firebase Storage download URL on success, null on failure.
Future<String?> handleReceiptWeb(Uint8List imageBytes, String filename, BaseExpense expense, {int? arrayIndex}) async {
  try {
    final token = await getFirebaseAuthInstance().currentUser!.getIdToken();
    final userId = (await getLoggedInUserData())?.id ?? '';
    final collectionType = expense is WIPExpense ? 'WIPExpenses' : 'Expenses';
    final request = http.MultipartRequest('POST', Uri.parse(_uploadReceiptApiUrl))
      ..headers['Authorization'] = 'Bearer $token'
      ..fields['expenseId'] = expense.id
      ..fields['collectionType'] = collectionType
      ..fields['userId'] = userId;
    if (arrayIndex != null) {
      request.fields['arrayIndex'] = '$arrayIndex';
      request.fields['isAdditionalReceipt'] = 'true';
    }
    request.files.add(http.MultipartFile.fromBytes('file', imageBytes, filename: filename));
    final streamed = await request.send();
    if (streamed.statusCode == 200) {
      final body = await streamed.stream.bytesToString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      return data['downloadUrl'] as String?;
    }
    return null;
  } catch (e) {
    print('[handleReceiptWeb] error: $e');
    return null;
  }
}

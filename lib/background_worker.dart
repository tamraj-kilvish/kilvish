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

/// Picks pending imports and starts processing them up to [maxConcurrentImports].
/// Optional callbacks fire on the calling isolate (pass null from background handler).
Future<void> processNextPendingImport({
  void Function(String pendingId, WIPExpense wip)? onConverted,
  void Function(WIPExpense wip)? onUploading,
  void Function(String pendingId)? onDuplicate,
}) async {
  if (_processNextInProgress) return;

  final wips = await CacheManager.loadWIPExpenses() ?? [];
  final processingCount = wips
      .where((w) => w.status != ExpenseStatus.readyForReview && (w.errorMessage == null || w.errorMessage!.isEmpty))
      .length;

  if (processingCount >= maxConcurrentImports) {
    print('[BulkProcess] At capacity ($processingCount/$maxConcurrentImports) — waiting for FCM');
    return;
  }

  final pending = await PendingImport.loadFromCache();
  if (pending.isEmpty) {
    print('[BulkProcess] No pending imports');
    return;
  }

  _processNextInProgress = true;
  try {
    await Future.wait(
      pending.take(maxConcurrentImports - processingCount).map(
        (item) => processPendingImport(
          item,
          onConverted: onConverted,
          onUploading: onUploading,
          onDuplicate: onDuplicate,
        ),
      ),
    );
  } finally {
    _processNextInProgress = false;
  }
}

Future<void> processPendingImport(
  PendingImport next, {
  void Function(String pendingId, WIPExpense wip)? onConverted,
  void Function(WIPExpense wip)? onUploading,
  void Function(String pendingId)? onDuplicate,
}) async {
  print('[BulkProcess] processPendingImport: id=${next.id} tagId=${next.tagId}');

  final wipExpense = await createWIPExpense(
    tagIds: next.tagId != null ? [next.tagId!] : null,
    loanPaybackTagName: next.isLoanPayback ? '' : null,
    createdAt: next.createdAt,
  );
  if (wipExpense == null) {
    print('[BulkProcess] createWIPExpense returned null — aborting id=${next.id}');
    return;
  }

  // Remove from pending cache before processing so concurrent callers (timer, FCM)
  // don't pick it up again while handleSharedReceipt is running.
  await PendingImport.removeFromCache(next.id);
  await CacheManager.addOrUpdateWIPExpense(wipExpense);
  onConverted?.call(next.id, wipExpense);

  final updatedWip = await handleSharedReceipt(File(next.stagedPath), wipExpenseAsParam: wipExpense);
  if (updatedWip == null) {
    print('[BulkProcess] handleSharedReceipt null (duplicate) — skipping id=${next.id}');
    await CacheManager.removeWIPExpense(wipExpense.id);
    onDuplicate?.call(next.id);
  } else {
    await CacheManager.addOrUpdateWIPExpense(updatedWip);
    onUploading?.call(updatedWip);
  }

  print('[BulkProcess] processPendingImport: done for id=${next.id}');
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
      fields: {
        'expenseId': wipExpense.id,
        'collectionType': 'WIPExpenses',
        'userId': (await getLoggedInUserData())?.id ?? '',
      },
      //httpRequestMethod: 'POST',
      updates: Updates.statusAndProgress,
    );

    // 3. Start Upload
    final enqueueStatus = await FileDownloader().enqueue(task);
    print("Task enqueue status $enqueueStatus");

    // Update local UI state
    //TODO - change this to uploadReceipt when background job actually starts uploading
    await updateWIPExpenseStatus(wipExpense.id, ExpenseStatus.uploadingReceipt);

    return wipExpense;
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
Future<String?> handleReceiptWeb(
  Uint8List imageBytes,
  String filename,
  BaseExpense expense, {
  int? arrayIndex,
}) async {
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

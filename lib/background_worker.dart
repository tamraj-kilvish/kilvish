import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
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
      fields: {'wipExpenseId': wipExpense.id, 'userId': (await getLoggedInUserData())?.id ?? ''},
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

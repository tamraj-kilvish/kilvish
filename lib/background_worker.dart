import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:kilvish/firestore_common.dart';
import 'package:kilvish/firestore_expenses.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/model_expenses.dart';
import 'package:path/path.dart' as p;

Future<WIPExpense> startReceiptUploadViaBackgroundTask(WIPExpense wipExpense) async {
  try {
    final filePath = wipExpense.localReceiptPath;
    if (filePath == null) throw 'No local receipt path';

    final task = UploadTask(
      taskId: wipExpense.id,
      url: 'https://asia-south1-tamraj-kilvish.cloudfunctions.net/uploadReceiptApi',
      filename: p.basename(filePath),
      headers: {'Authorization': 'Bearer ${await getFirebaseAuthInstance().currentUser!.getIdToken()}'},
      fields: {'wipExpenseId': wipExpense.id, 'userId': (await getLoggedInUserData())?.id ?? ''},
      updates: Updates.statusAndProgress,
    );

    final enqueueStatus = await FileDownloader().enqueue(task);
    print("Task enqueue status $enqueueStatus");

    await updateWIPExpenseStatus(wipExpense.id, ExpenseStatus.uploadingReceipt);

    // Return updated WIPExpense
    wipExpense.status = ExpenseStatus.uploadingReceipt;
    return wipExpense;
  } catch (e) {
    print("Upload error: $e");
    rethrow;
  }
}

Future<void> cleanupReceiptFile(String? localPath) async {
  if (localPath == null) return;
  try {
    final file = File(localPath);
    if (file.existsSync()) {
      await file.delete();
      print("Cleaned up receipt file: $localPath");
    }
  } catch (e) {
    print("Error cleaning up file: $e");
  }
}

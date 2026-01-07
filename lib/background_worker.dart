import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models_expense.dart';

Future<WIPExpense?> handleSharedReceipt(File receiptFile, {WIPExpense? wipExpenseAsParam}) async {
  try {
    // 1. Move file to a permanent location so it survives app closure
    final appDir = await getApplicationDocumentsDirectory();
    final filePath = p.join(appDir.path, p.basename(receiptFile.path));
    if (File(filePath).existsSync()) {
      //receipt already processed
      print("Shared receipt $filePath already present in saved files.");
      return null;
    }

    final wipExpense = wipExpenseAsParam ?? await createWIPExpense();
    if (wipExpense == null) return null;

    final savedFile = await receiptFile.copy(filePath);
    print("savedFile path ${savedFile.path}");
    await attachLocalPathToWIPExpense(wipExpense.id, savedFile.path);

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
    await updateWIPExpenseStatus(wipExpense.id, ExpenseStatus.uploadingReceipt);

    return wipExpense;
  } catch (e) {
    print("Background Downloader Error: $e");
    return null;
  }
}

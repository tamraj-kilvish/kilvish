import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:kilvish/firebase_options.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models_expense.dart';
import 'package:workmanager/workmanager.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

// NEW: Handle shared receipt asynchronously
Future<WIPExpense?> handleSharedReceipt(File receiptFile, {WIPExpense? wipExpenseAsParam}) async {
  print("Handling shared receipt: ${receiptFile.path}");

  try {
    // Create WIPExpense immediately
    final wipExpense = wipExpenseAsParam ?? await createWIPExpense();
    if (wipExpense == null) {
      print("Failed to create WIPExpense");
      return null;
    }

    // Queue background upload task
    //if (!kIsWeb) {
    await Workmanager().registerOneOffTask(
      "upload_${wipExpense.id}",
      "uploadReceipt",
      inputData: {'wipExpenseId': wipExpense.id, 'receiptPath': receiptFile.path},
    );
    print("Background upload task queued for ${wipExpense.id}");
    return wipExpense;
    //}
  } catch (e, stackTrace) {
    print("Error handling shared receipt: $e, $stackTrace");
  }
  return null;
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    print("Background task started: $task");

    final wipExpenseId = inputData!['wipExpenseId'] as String;
    final receiptPath = inputData['receiptPath'] as String;

    print('Uploading receipt for WIPExpense: $wipExpenseId');

    try {
      // Get userId from auth
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      FirebaseAuth auth = getFirebaseAuthInstance();

      String? userId = await getUserIdFromClaim(authParam: auth);
      if (userId == null) {
        throw Exception('userId not found in claims');
      }

      // Upload receipt to Firebase Storage
      final receiptFile = File(receiptPath);
      if (!await receiptFile.exists()) {
        throw Exception('Receipt file not found: $receiptPath');
      }

      final extension = receiptPath.split('.').last.toLowerCase();
      final fileName = 'receipts/${userId}_$wipExpenseId.$extension';

      final ref = FirebaseStorage.instanceFor(bucket: 'gs://tamraj-kilvish.firebasestorage.app').ref().child(fileName);

      print('Uploading to: $fileName');
      updateWIPExpenseStatus(wipExpenseId, ExpenseStatus.uploadingReceipt);

      await ref.putFile(receiptFile);

      final downloadUrl = await ref.getDownloadURL();
      print('Receipt uploaded: $downloadUrl');

      if (await attachReceiptURLtoWIPExpense(wipExpenseId, downloadUrl)) {
        print("updated WIPExpense with receiptURL .. check server logs for next processing steps");
      }

      // Delete local file to save space
      try {
        // 2. MOVE TO PERSISTENT STORAGE
        final appDir = await getApplicationDocumentsDirectory();
        final fileName = p.basename(receiptPath);
        final persistentPath = p.join(appDir.path, 'receipts', fileName);

        // Create directory if it doesn't exist
        await Directory(p.dirname(persistentPath)).create(recursive: true);

        // Move the file instead of deleting it
        final persistentFile = await receiptFile.copy(persistentPath);
        print('File saved locally for zero-latency viewing: ${persistentFile.path}');

        // 3. ATTACH LOCAL PATH TO DOCUMENT
        // You should update your WIPExpense model to include a 'localPath' field
        await attachLocalPathToWIPExpense(wipExpenseId, persistentFile.path);
        await receiptFile.delete();
        print('Local receipt file deleted');
      } catch (e) {
        print('Could not save file locally & attach path to WIPExpense: $e');
      }

      return Future.value(true);
    } catch (e, stackTrace) {
      print('Error in upload task: $e, $stackTrace');
      await updateWIPExpenseStatus(wipExpenseId, ExpenseStatus.uploadingReceipt, errorMessage: e.toString());
      //throw e;
      return Future.value(false);
    }
  });
}

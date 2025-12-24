import 'dart:io';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models_expense.dart';
import 'package:workmanager/workmanager.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'models.dart';

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
      final auth = FirebaseAuth.instance;
      final user = auth.currentUser;

      if (user == null) {
        throw Exception('User not authenticated');
      }

      // Get userId from custom claims
      final idTokenResult = await user.getIdTokenResult();
      final userId = idTokenResult.claims?['userId'] as String?;

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
      updateWIPExpenseStatus(
        wipExpenseId,
        ExpenseStatus.uploadingReceipt,
      ); //this will trigger FCM from server & status of expense on home screen should get updated
      await ref.putFile(receiptFile);

      final downloadUrl = await ref.getDownloadURL();
      print('Receipt uploaded: $downloadUrl');

      // Delete local file to save space
      try {
        await receiptFile.delete();
        print('Local receipt file deleted');
      } catch (e) {
        print('Could not delete local file: $e');
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

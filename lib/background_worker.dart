import 'dart:io';
import 'package:workmanager/workmanager.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';
import 'models.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    print("Background task started: $task");

    try {
      // Initialize Firebase
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

      if (task == 'uploadReceipt') {
        await _uploadReceiptTask(inputData!);
      }

      return Future.value(true);
    } catch (e, stackTrace) {
      print('Background task error: $e, $stackTrace');

      // Update WIPExpense with error
      if (inputData != null && inputData['wipExpenseId'] != null) {
        try {
          await _updateWIPExpenseError(inputData['wipExpenseId'] as String, 'Upload failed: ${e.toString()}');
        } catch (updateError) {
          print('Failed to update error status: $updateError');
        }
      }

      return Future.value(false);
    }
  });
}

Future<void> _uploadReceiptTask(Map<String, dynamic> inputData) async {
  final wipExpenseId = inputData['wipExpenseId'] as String;
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

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final extension = receiptPath.split('.').last.toLowerCase();
    final fileName = 'receipts/${userId}_${wipExpenseId}_$timestamp.$extension';

    final ref = FirebaseStorage.instanceFor(bucket: 'gs://tamraj-kilvish.firebasestorage.app').ref().child(fileName);

    print('Uploading to: $fileName');
    await ref.putFile(receiptFile);

    final downloadUrl = await ref.getDownloadURL();
    print('Receipt uploaded: $downloadUrl');

    // Update WIPExpense with receiptUrl and status
    final firestore = FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'kilvish');

    await firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpenseId).update({
      'receiptUrl': downloadUrl,
      'status': ExpenseStatus.extractingData.name,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    print('WIPExpense updated with receipt URL, OCR will be triggered on server');

    // Delete local file to save space
    try {
      await receiptFile.delete();
      print('Local receipt file deleted');
    } catch (e) {
      print('Could not delete local file: $e');
    }
  } catch (e, stackTrace) {
    print('Error in upload task: $e, $stackTrace');
    throw e;
  }
}

Future<void> _updateWIPExpenseError(String wipExpenseId, String errorMessage) async {
  try {
    final auth = FirebaseAuth.instance;
    final user = auth.currentUser;
    if (user == null) return;

    final idTokenResult = await user.getIdTokenResult();
    final userId = idTokenResult.claims?['userId'] as String?;
    if (userId == null) return;

    final firestore = FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'kilvish');

    await firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpenseId).update({
      'status': ExpenseStatus.uploadingReceipt.name,
      'errorMessage': errorMessage,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    print('WIPExpense error status updated');
  } catch (e) {
    print('Failed to update error status: $e');
  }
}

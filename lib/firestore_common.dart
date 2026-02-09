import 'dart:developer';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:kilvish/firestore_recoveries.dart';
import 'package:kilvish/firestore_tags.dart';
import 'package:kilvish/firestore_user.dart';

FirebaseFirestore getFirestoreInstance() {
  return FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'kilvish');
}

FirebaseAuth getFirebaseAuthInstance() {
  return FirebaseAuth.instance;
}

final FirebaseFirestore firestore = getFirestoreInstance();
final FirebaseAuth firebaseAuth = getFirebaseAuthInstance();

// final FirebaseFirestore _firestore = FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'kilvish');
// final FirebaseAuth _auth = FirebaseAuth.instance;

/// Handle FCM message - route to appropriate handler based on type
Future<void> updateFirestoreLocalCache(Map<String, dynamic> data) async {
  print('Updating firestore local cache with data - $data');

  try {
    final type = data['type'] as String?;

    switch (type) {
      case 'expense_created':
      case 'expense_updated':
        await storeTagMonetarySummaryUpdate(data);
        await handleExpenseCreatedOrUpdated(data);
        break;
      case 'expense_deleted':
        await storeTagMonetarySummaryUpdate(data);
        await handleExpenseDeleted(data);
        break;
      case 'tag_shared':
        await handleTagShared(data);
        break;
      case 'tag_removed':
        await handleTagRemoved(data);
        break;
      case 'wip_status_update':
        if (data['wipExpenseId'] == null) break;

        String? userId = await getUserIdFromClaim();
        if (userId == null) break;

        await firestore.collection('Users').doc(userId).collection("WIPExpenses").doc(data['wipExpenseId'] as String).get();
        break;

      case 'settlement_created':
      case 'settlement_updated':
        await storeTagMonetarySummaryUpdate(data);
        await handleExpenseCreatedOrUpdated(data, collection: "Settlements");
        break;
      case 'settlement_deleted':
        await storeTagMonetarySummaryUpdate(data);
        await handleExpenseDeleted(data, collection: "Settlements");
        break;

      // Recovery handlers
      case 'recovery_expense_created':
      case 'recovery_expense_updated':
        await handleRecoveryExpenseCreatedOrUpdated(data);
        break;
      case 'recovery_expense_deleted':
        await handleRecoveryExpenseDeleted(data);
        break;
      case 'recovery_settlement_created':
      case 'recovery_settlement_updated':
        await handleRecoverySettlementCreatedOrUpdated(data);
        break;
      case 'recovery_settlement_deleted':
        await handleRecoverySettlementDeleted(data);
        break;
      case 'recovery_shared':
        await handleRecoveryShared(data);
        break;

      default:
        log('Unknown FCM message type: $type');
    }
  } catch (e, stackTrace) {
    print('Error handling FCM message: $e, $stackTrace');
  }
}

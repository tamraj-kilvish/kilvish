import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:kilvish/firestore_expenses.dart';
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
      default:
        print('Unknown FCM message type: $type');
    }
  } catch (e, stackTrace) {
    print('Error handling FCM message: $e, $stackTrace');
  }
}

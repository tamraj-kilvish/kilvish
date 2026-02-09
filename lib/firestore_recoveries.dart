import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:kilvish/firestore_common.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/models_tags.dart';

Map<String, Recovery> recoveryIdRecoveryDataCache = {};

Future<Recovery> getRecoveryData(String recoveryId, {bool? includeMostRecentExpense, bool invalidateCache = false}) async {
  if (invalidateCache) {
    recoveryIdRecoveryDataCache.remove(recoveryId);
  }

  if (recoveryIdRecoveryDataCache[recoveryId] != null) {
    Recovery recovery = recoveryIdRecoveryDataCache[recoveryId]!;
    if (includeMostRecentExpense != null) {
      recovery.mostRecentExpense = await getMostRecentExpenseFromRecovery(recovery.id);
    }
    return recovery;
  }

  DocumentReference recoveryRef = firestore.collection("Recoveries").doc(recoveryId);
  DocumentSnapshot<Map<String, dynamic>> recoveryDoc = await (recoveryRef.get()) as DocumentSnapshot<Map<String, dynamic>>;

  final recoveryData = recoveryDoc.data();
  Recovery recovery = Recovery.fromFirestoreObject(recoveryDoc.id, recoveryData);
  if (includeMostRecentExpense != null) {
    recovery.mostRecentExpense = await getMostRecentExpenseFromRecovery(recoveryDoc.id);
  }
  recoveryIdRecoveryDataCache[recovery.id] = recovery;

  return recovery;
}

Future<Recovery?> createOrUpdateRecovery(Map<String, Object> recoveryDataInput, String? recoveryId) async {
  String? ownerId = await getUserIdFromClaim();
  if (ownerId == null) return null;

  Map<String, Object> recoveryData = {'updatedAt': FieldValue.serverTimestamp()};
  recoveryData.addAll(recoveryDataInput);

  if (recoveryId != null) {
    await firestore.collection('Recoveries').doc(recoveryId).update(recoveryData);
    Recovery recovery = await getRecoveryData(recoveryId, invalidateCache: true);
    return recovery;
  }

  // create new recovery flow
  recoveryData.addAll({
    'createdAt': FieldValue.serverTimestamp(),
    'ownerId': ownerId,
    'allowRecovery': true,
    'totalTillDate': {'expense': 0, 'recovery': 0},
    'monthWiseTotal': {},
    'userWiseTotal': {},
    'sharedWith': [ownerId],
  });

  WriteBatch batch = firestore.batch();

  DocumentReference recoveryDoc = firestore.collection('Recoveries').doc();
  batch.set(recoveryDoc, recoveryData);
  batch.update(firestore.collection("Users").doc(ownerId), {
    'accessibleRecoveryIds': FieldValue.arrayUnion([recoveryDoc.id]),
  });

  await batch.commit();

  return getRecoveryData(recoveryDoc.id, invalidateCache: true);
}

Future<List<QueryDocumentSnapshot<Object?>>> getExpenseDocsUnderRecovery(String recoveryId) async {
  DocumentSnapshot<Map<String, dynamic>> recoveryDoc = await firestore.collection("Recoveries").doc(recoveryId).get();
  QuerySnapshot expensesSnapshot = await recoveryDoc.reference
      .collection('Expenses')
      .orderBy('timeOfTransaction', descending: true)
      .get();

  return expensesSnapshot.docs;
}

Future<List<Expense>> getExpensesOfRecovery(String recoveryId) async {
  List<QueryDocumentSnapshot<Object?>> expenseDocs = await getExpenseDocsUnderRecovery(recoveryId);
  List<Expense> expenses = [];
  for (DocumentSnapshot doc in expenseDocs) {
    expenses.add(await Expense.getExpenseFromFirestoreObject(doc.id, doc.data() as Map<String, dynamic>));
  }
  return expenses;
}

Future<List<Expense>> getSettlementsOfRecovery(String recoveryId) async {
  DocumentSnapshot<Map<String, dynamic>> recoveryDoc = await firestore.collection("Recoveries").doc(recoveryId).get();
  QuerySnapshot settlementsSnapshot = await recoveryDoc.reference
      .collection('Settlements')
      .orderBy('timeOfTransaction', descending: true)
      .get();

  List<Expense> settlements = [];
  for (DocumentSnapshot doc in settlementsSnapshot.docs) {
    settlements.add(await Expense.getExpenseFromFirestoreObject(doc.id, doc.data() as Map<String, dynamic>));
  }
  return settlements;
}

Future<Expense?> getMostRecentExpenseFromRecovery(String recoveryId) async {
  QuerySnapshot expenseSnapshot = await firestore
      .collection('Recoveries')
      .doc(recoveryId)
      .collection('Expenses')
      .orderBy('timeOfTransaction', descending: true)
      .limit(1)
      .get();

  if (expenseSnapshot.docs.isEmpty) return null;

  return Expense.getExpenseFromFirestoreObject(
    expenseSnapshot.docs.first.id,
    expenseSnapshot.docs.first.data() as Map<String, dynamic>,
  );
}

Future<BaseExpense?> getRecoveryExpense(String recoveryId, String expenseId, {bool isSettlement = false}) async {
  final collectionName = isSettlement ? 'Settlements' : 'Expenses';
  DocumentSnapshot expenseDoc = await firestore
      .collection('Recoveries')
      .doc(recoveryId)
      .collection(collectionName)
      .doc(expenseId)
      .get();

  if (!expenseDoc.exists) return null;

  return Expense.getExpenseFromFirestoreObject(expenseDoc.id, expenseDoc.data() as Map<String, dynamic>);
}

Future<void> addUserToRecovery(String recoveryId, String userId) async {
  WriteBatch batch = firestore.batch();

  batch.update(firestore.collection('Recoveries').doc(recoveryId), {
    'sharedWith': FieldValue.arrayUnion([userId]),
  });

  batch.update(firestore.collection('Users').doc(userId), {
    'accessibleRecoveryIds': FieldValue.arrayUnion([recoveryId]),
  });

  await batch.commit();

  // Invalidate cache
  recoveryIdRecoveryDataCache.remove(recoveryId);
}

Future<List<Recovery>> getUserAccessibleRecoveries({bool includeMostRecentExpense = false}) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return [];

  final userDoc = await firestore.collection('Users').doc(userId).get();
  final userData = userDoc.data();
  final recoveryIds = (userData?['accessibleRecoveryIds'] as List?)?.cast<String>() ?? [];

  if (recoveryIds.isEmpty) return [];

  List<Recovery> recoveries = [];
  for (String recoveryId in recoveryIds) {
    try {
      final recovery = await getRecoveryData(recoveryId, includeMostRecentExpense: includeMostRecentExpense);
      recoveries.add(recovery);
    } catch (e) {
      print('Error loading recovery $recoveryId: $e');
    }
  }

  return recoveries;
}

Future<void> handleRecoveryExpenseCreatedOrUpdated(Map<String, dynamic> data) async {
  final recoveryId = data['recoveryId'] as String?;
  if (recoveryId == null) return;

  // Invalidate recovery cache
  recoveryIdRecoveryDataCache.remove(recoveryId);
}

Future<void> handleRecoveryExpenseDeleted(Map<String, dynamic> data) async {
  final recoveryId = data['recoveryId'] as String?;
  if (recoveryId == null) return;

  // Invalidate recovery cache
  recoveryIdRecoveryDataCache.remove(recoveryId);
}

Future<void> handleRecoverySettlementCreatedOrUpdated(Map<String, dynamic> data) async {
  final recoveryId = data['recoveryId'] as String?;
  if (recoveryId == null) return;

  // Invalidate recovery cache
  recoveryIdRecoveryDataCache.remove(recoveryId);
}

Future<void> handleRecoverySettlementDeleted(Map<String, dynamic> data) async {
  final recoveryId = data['recoveryId'] as String?;
  if (recoveryId == null) return;

  // Invalidate recovery cache
  recoveryIdRecoveryDataCache.remove(recoveryId);
}

Future<void> handleRecoveryShared(Map<String, dynamic> data) async {
  final recoveryId = data['recoveryId'] as String?;
  if (recoveryId == null) return;

  // User has been added to recovery - reload from Firestore
  try {
    await getRecoveryData(recoveryId, invalidateCache: true);
  } catch (e) {
    print('Error loading shared recovery: $e');
  }
}

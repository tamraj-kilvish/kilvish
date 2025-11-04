import 'dart:developer';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'models.dart';

final FirebaseFirestore _firestore = FirebaseFirestore.instanceFor(
  app: Firebase.app(),
  databaseId: 'kilvish',
);
final FirebaseAuth _auth = FirebaseAuth.instance;

Future<KilvishUser?> getLoggedInUserData() async {
  final authUser = _auth.currentUser;
  if (authUser == null) return null;

  final idTokenResult = await authUser.getIdTokenResult();
  final userId = idTokenResult.claims?['userId'] as String?;

  CollectionReference userRef = _firestore.collection('Users');
  DocumentSnapshot userDoc = await userRef.doc(userId).get();

  Map<String, dynamic> userData = userDoc.data() as Map<String, dynamic>;
  userData['id'] = userDoc.id;
  return KilvishUser.fromFirestoreObject(userData);
}

Future<Tag> getTagData(String tagId) async {
  DocumentSnapshot<Map<String, dynamic>> tagDoc = await _firestore
      .collection("Tags")
      .doc(tagId)
      .get();

  final tagData = tagDoc.data();
  return Tag.fromFirestoreObject(tagDoc.id, tagData);
}

Future<List<QueryDocumentSnapshot<Object?>>> getExpenseDocsUnderTag(
  String tagId,
) async {
  DocumentSnapshot<Map<String, dynamic>> tagDoc = await _firestore
      .collection("Tags")
      .doc(tagId)
      .get();
  QuerySnapshot expensesSnapshot = await tagDoc.reference
      .collection('Expenses')
      .orderBy('timeOfTransaction', descending: true)
      .get();

  return expensesSnapshot.docs;
}

Future<List<Expense>> getExpensesOfTag(String tagId) async {
  List<QueryDocumentSnapshot<Object?>> expenseDocs =
      await getExpenseDocsUnderTag(tagId);
  List<Expense> expenses = [];
  for (DocumentSnapshot doc in expenseDocs) {
    expenses.add(
      Expense.fromFirestoreObject(doc.id, doc.data() as Map<String, dynamic>),
    );
  }
  return expenses;
}

Future<Expense> getMostRecentExpenseFromTag(String tagId) async {
  DocumentSnapshot<Map<String, dynamic>> tagDoc = await _firestore
      .collection("Tags")
      .doc(tagId)
      .get();
  QuerySnapshot<Map<String, dynamic>> expensesSnapshot = await tagDoc.reference
      .collection('Expenses')
      .orderBy('timeOfTransaction', descending: true)
      .limit(1)
      .get();

  DocumentSnapshot expenseDoc = expensesSnapshot.docs[0];
  return Expense.fromFirestoreObject(
    expenseDoc.id,
    expenseDoc.data() as Map<String, dynamic>,
  );
}

Future<String?> getUserIdFromClaim() async {
  final authUser = _auth.currentUser;
  if (authUser == null) return null;

  final idTokenResult = await authUser.getIdTokenResult();
  return idTokenResult.claims?['userId'] as String?;
}

Future<void> addOrUpdateUserExpense(
  Map<String, Object?> expenseData,
  String? expenseId,
) async {
  final String? userId = await getUserIdFromClaim();
  if (userId == null) return;

  CollectionReference userExpensesRef = _firestore
      .collection('Users')
      .doc(userId)
      .collection("Expenses");

  if (expenseId != null) {
    await userExpensesRef.doc(expenseId).update(expenseData);
  } else {
    await userExpensesRef.add(expenseData);
  }
}

/// Handle FCM message - route to appropriate handler based on type
Future<void> handleFCMMessage(Map<String, dynamic> data) async {
  try {
    final type = data['type'] as String?;

    switch (type) {
      case 'expense_created':
      case 'expense_updated':
        await _handleExpenseCreatedOrUpdated(data);
        break;
      case 'expense_deleted':
        await _handleExpenseDeleted(data);
        break;
      case 'tag_shared':
        // Tag shared - no local caching needed, just refresh on open
        log('Tag shared notification received: ${data['tagId']}');
        break;
      default:
        log('Unknown FCM message type: $type');
    }
  } catch (e, stackTrace) {
    log('Error handling FCM message: $e', error: e, stackTrace: stackTrace);
  }
}

/// Handle expense created or updated - cache to local Firestore
Future<void> _handleExpenseCreatedOrUpdated(Map<String, dynamic> data) async {
  try {
    final tagId = data['tagId'] as String?;
    final expenseId = data['expenseId'] as String?;
    final expenseString = data['expense'] as String?;

    if (tagId == null || expenseId == null || expenseString == null) {
      log('Invalid expense data in FCM payload');
      return;
    }

    // Parse JSON string to Map
    final expenseData = jsonDecode(expenseString) as Map<String, dynamic>;

    // Convert timestamp strings to Timestamps
    if (expenseData['timeOfTransaction'] is String) {
      expenseData['timeOfTransaction'] = Timestamp.fromDate(
        DateTime.parse(expenseData['timeOfTransaction']),
      );
    }
    if (expenseData['updatedAt'] is String) {
      expenseData['updatedAt'] = Timestamp.fromDate(
        DateTime.parse(expenseData['updatedAt']),
      );
    }

    // Convert amount string to number
    if (expenseData['amount'] is String) {
      expenseData['amount'] = num.parse(expenseData['amount']);
    }

    // Write to local Firestore cache
    final expenseRef = _firestore
        .collection('Tags')
        .doc(tagId)
        .collection('Expenses')
        .doc(expenseId);

    await expenseRef.set(expenseData, SetOptions(merge: true));
    log('Expense cached locally from FCM: $expenseId');
  } catch (e, stackTrace) {
    log('Error caching expense: $e', error: e, stackTrace: stackTrace);
  }
}

/// Handle expense deleted - remove from local cache
Future<void> _handleExpenseDeleted(Map<String, dynamic> data) async {
  try {
    final tagId = data['tagId'] as String?;
    final expenseId = data['expenseId'] as String?;

    if (tagId == null || expenseId == null) {
      log('Invalid delete data in FCM payload');
      return;
    }

    // Remove from local Firestore cache
    final expenseRef = _firestore
        .collection('Tags')
        .doc(tagId)
        .collection('Expenses')
        .doc(expenseId);

    await expenseRef.delete();
    log('Expense deleted from local cache: $expenseId');
  } catch (e, stackTrace) {
    log('Error deleting expense: $e', error: e, stackTrace: stackTrace);
  }
}

Future<void> saveFCMToken(String token) async {
  try {
    String? userId = await getUserIdFromClaim();

    await _firestore.collection('Users').doc(userId).update({
      'fcmToken': token,
      'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
    });

    log('FCM token saved for user: $userId');
  } catch (e, stackTrace) {
    log('Error saving FCM token: $e', error: e, stackTrace: stackTrace);
  }
}

Future<void> markTagAsSeen(String tagId) async {
  try {
    final userId = await getUserIdFromClaim();
    if (userId == null) return;

    // Use set with merge to create the field if it doesn't exist
    await _firestore.collection('Users').doc(userId).set({
      'tagLastSeen': {tagId: FieldValue.serverTimestamp()},
    }, SetOptions(merge: true));

    log('Tag marked as seen: $tagId');
  } catch (e, stackTrace) {
    log('Error marking tag as seen: $e', error: e, stackTrace: stackTrace);
  }
}

Future<DateTime?> getLastSeenTime(String tagId) async {
  try {
    final userId = await getUserIdFromClaim();
    if (userId == null) return null;

    final userDoc = await _firestore.collection('Users').doc(userId).get();
    final data = userDoc.data();

    if (data == null) return null;

    final tagLastSeen = data['tagLastSeen'] as Map<String, dynamic>?;
    if (tagLastSeen == null) return null;

    final timestamp = tagLastSeen[tagId] as Timestamp?;
    return timestamp?.toDate();
  } catch (e, stackTrace) {
    log('Error getting last seen time: $e', error: e, stackTrace: stackTrace);
    return null;
  }
}

bool isExpenseUnread(Expense expense, DateTime? lastSeenTime) {
  if (lastSeenTime == null) return true;
  return expense.updatedAt.isAfter(lastSeenTime);
}

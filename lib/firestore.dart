import 'dart:convert';
import 'dart:developer';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:intl/intl.dart';
import 'models.dart';

final FirebaseFirestore _firestore = FirebaseFirestore.instanceFor(
  app: Firebase.app(),
  databaseId: 'kilvish',
);
final FirebaseAuth _auth = FirebaseAuth.instance;

Future<KilvishUser?> getLoggedInUserData() async {
  // fetch authUser everytime as the user might not be logged in when the file got loaded
  final authUser = _auth.currentUser;

  if (authUser == null) {
    return null;
  }

  // Get userId from custom claims
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
  // Get userId from custom claims
  final authUser = _auth.currentUser;

  if (authUser == null) {
    return null;
  }
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

Future<void> storeExpenseforFCM(Map<String, dynamic> data) async {
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

    // Convert ISO timestamp strings back to Firestore Timestamps
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

    if (expenseData['amount'] is String) {
      expenseData['amount'] = num.parse(expenseData['amount']);
    }

    // Write to local Firestore cache
    // This will be available instantly when user opens the app
    final expenseRef = _firestore
        .collection('Tags')
        .doc(tagId)
        .collection('Expenses')
        .doc(expenseId);

    await expenseRef.set(expenseData, SetOptions(merge: true));
    log('Expense cached locally from FCM: $expenseId');
  } catch (e, stackTrace) {
    log('Error caching expense from FCM: $e', error: e, stackTrace: stackTrace);
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
  } catch (e) {
    log('Error saving FCM token: $e', error: e);
  }
}

// Add these functions to firestore.dart

Future<void> markTagAsSeen(String tagId) async {
  try {
    final userId = await getUserIdFromClaim();
    if (userId == null) return;

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
  if (lastSeenTime == null) return true; // Never seen = all unread
  return expense.updatedAt.isAfter(lastSeenTime);
}

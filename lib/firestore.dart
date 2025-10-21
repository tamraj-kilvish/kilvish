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

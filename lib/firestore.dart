import 'dart:developer';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:kilvish/models_expense.dart';
import 'models.dart';

FirebaseFirestore getFirestoreInstance() {
  return FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'kilvish');
}

FirebaseAuth getFirebaseAuthInstance() {
  return FirebaseAuth.instance;
}

final FirebaseFirestore _firestore = getFirestoreInstance();
final FirebaseAuth _auth = getFirebaseAuthInstance();

// final FirebaseFirestore _firestore = FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'kilvish');
// final FirebaseAuth _auth = FirebaseAuth.instance;

Future<KilvishUser?> getLoggedInUserData() async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return null;

  DocumentSnapshot userDoc = await _firestore.collection('Users').doc(userId).get();
  if (!userDoc.exists) return null;

  Map<String, dynamic> userData = userDoc.data() as Map<String, dynamic>;
  userData['id'] = userDoc.id;

  DocumentSnapshot publicInfoDoc = await _firestore.collection("PublicInfo").doc(userId).get();
  if (publicInfoDoc.exists) {
    userData.addAll(publicInfoDoc.data() as Map<String, dynamic>);
  }
  return KilvishUser.fromFirestoreObject(userData);
}

Map<String, String> userIdKilvishIdHash = {};

Future<String?> getUserKilvishId(String userId) async {
  if (userIdKilvishIdHash[userId] != null) {
    String cachedKilvishId = userIdKilvishIdHash[userId]!;
    refreshUserIdKilvishIdCache(userId);
    return cachedKilvishId;
  }

  await refreshUserIdKilvishIdCache(userId);
  return userIdKilvishIdHash[userId];
}

Future<void> refreshUserIdKilvishIdCache(String userId) async {
  DocumentSnapshot publicInfoDoc = await _firestore.collection("PublicInfo").doc(userId).get();
  if (!publicInfoDoc.exists) return;

  PublicUserInfo publicUserInfo = PublicUserInfo.fromFirestore(userId, publicInfoDoc.data() as Map<String, dynamic>);
  //TODO - make this write thread safe as we are also reading the value & returning
  userIdKilvishIdHash[userId] = publicUserInfo.kilvishId;
}

Future<bool> updateUserKilvishId(String userId, String kilvishId) async {
  String? userKilvishId = await getUserKilvishId(userId);

  if (userKilvishId == null) {
    if (await isKilvishIdTaken(kilvishId)) return false;

    await _firestore.collection("PublicInfo").doc(userId).set({
      'kilvishId': kilvishId,
      'updatedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
      'lastLogin': FieldValue.serverTimestamp(),
    });
    return true;
  }

  if (userKilvishId != kilvishId && await isKilvishIdTaken(kilvishId)) return false;

  final Map<String, dynamic> updateData = {'lastLogin': FieldValue.serverTimestamp()};
  if (userKilvishId != kilvishId) {
    updateData.addAll({'kilvishId': kilvishId, 'updatedAt': FieldValue.serverTimestamp()});
  }

  await _firestore.collection("PublicInfo").doc(userId).update(updateData);

  return true;
}

Future<bool> isKilvishIdTaken(String kilvishId) async {
  QuerySnapshot alreadyPresentEntries = await _firestore
      .collection("PublicInfo")
      .where("kilvishId", isEqualTo: kilvishId)
      .limit(1)
      .get();
  return alreadyPresentEntries.size == 0 ? false : true;
}

Future<Tag> getTagData(String tagId, {bool? fromCache, bool? includeMostRecentExpense}) async {
  DocumentReference tagRef = _firestore.collection("Tags").doc(tagId);
  DocumentSnapshot<Map<String, dynamic>> tagDoc =
      await (fromCache != null ? tagRef.get(GetOptions(source: Source.cache)) : tagRef.get())
          as DocumentSnapshot<Map<String, dynamic>>;

  final tagData = tagDoc.data();
  //print("Got tagData for tagId $tagId - $tagData");

  Tag tag = Tag.fromFirestoreObject(tagDoc.id, tagData);
  if (includeMostRecentExpense != null) {
    tag.mostRecentExpense = await getMostRecentExpenseFromTag(tagDoc.id);
  }

  return tag;
}

Future<Tag?> createOrUpdateTag(Map<String, Object> tagDataInput, String? tagId) async {
  String? ownerId = await getUserIdFromClaim();
  if (ownerId == null) return null;

  Map<String, Object> tagData = {'updatedAt': FieldValue.serverTimestamp()};
  tagData.addAll(tagDataInput);
  print("Dumping tagData in createOrUpdateTag $tagData");

  if (tagId != null) {
    await _firestore.collection('Tags').doc(tagId).update(tagData);
    return await getTagData(tagId);
  }
  tagData.addAll({
    'createdAt': FieldValue.serverTimestamp(),
    'ownerId': ownerId,
    'total': {'acrossUsers': {'expense': 0, 'recovery': 0}},
    'monthWiseTotal': {},
  });

  //TODO - add all operations below as batch/transaction
  DocumentReference tagDoc = await _firestore.collection('Tags').add(tagData);
  await _firestore.collection("Users").doc(ownerId).update({
    'accessibleTagIds': FieldValue.arrayUnion([tagDoc.id]),
  });
  return getTagData(tagDoc.id);
}

Future<List<QueryDocumentSnapshot<Object?>>> getExpenseDocsOfUser(String userId) async {
  QuerySnapshot expensesSnapshot = await _firestore
      .collection("Users")
      .doc(userId)
      .collection('Expenses')
      .orderBy('timeOfTransaction', descending: true)
      .get();

  return expensesSnapshot.docs;
}

Future<List<QueryDocumentSnapshot<Object?>>> getExpenseDocsUnderTag(String tagId) async {
  DocumentSnapshot<Map<String, dynamic>> tagDoc = await _firestore.collection("Tags").doc(tagId).get();
  QuerySnapshot expensesSnapshot = await tagDoc.reference
      .collection('Expenses')
      .orderBy('timeOfTransaction', descending: true)
      .get();

  return expensesSnapshot.docs;
}

Future<List<Expense>> getExpensesOfTag(String tagId) async {
  List<QueryDocumentSnapshot<Object?>> expenseDocs = await getExpenseDocsUnderTag(tagId);
  List<Expense> expenses = [];
  for (DocumentSnapshot doc in expenseDocs) {
    expenses.add(await Expense.getExpenseFromFirestoreObject(doc.id, doc.data() as Map<String, dynamic>));
  }
  return expenses;
}

Future<Expense?> getMostRecentExpenseFromTag(String tagId) async {
  DocumentSnapshot<Map<String, dynamic>> tagDoc = await _firestore.collection("Tags").doc(tagId).get();
  QuerySnapshot<Map<String, dynamic>> expensesSnapshot = await tagDoc.reference
      .collection('Expenses')
      .orderBy('timeOfTransaction', descending: true)
      .limit(1)
      .get();

  if (expensesSnapshot.docs.isEmpty) return null;

  DocumentSnapshot expenseDoc = expensesSnapshot.docs[0];
  return Expense.getExpenseFromFirestoreObject(expenseDoc.id, expenseDoc.data() as Map<String, dynamic>);
}

Future<String?> getUserIdFromClaim({FirebaseAuth? authParam}) async {
  final auth = authParam ?? _auth;
  final authUser = auth.currentUser;
  if (authUser == null) return null;

  final idTokenResult = await authUser.getIdTokenResult();
  return idTokenResult.claims?['userId'] as String?;
}

Future<Expense?> updateExpense(Map<String, Object?> expenseData, BaseExpense expense, Set<Tag> tags) async {
  final String? userId = await getUserIdFromClaim();
  if (userId == null) return null;

  CollectionReference userExpensesRef = _firestore.collection('Users').doc(userId).collection("Expenses");

  final WriteBatch batch = _firestore.batch();

  DocumentReference userDocRef = _firestore.collection("Users").doc(userId);
  batch.update(userDocRef, {
    'txIds': FieldValue.arrayUnion([expenseData['txId']]),
  });

  if (expense is Expense) {
    batch.update(userExpensesRef.doc(expense.id), expenseData);
    batch.update(userDocRef, {
      //remove old txId form user
      'txIds': FieldValue.arrayRemove([expense.txId]),
    });
  } else {
    //create new Expense
    batch.set(userExpensesRef.doc(expense.id), expenseData);
    // delete WIPExpense
    batch.delete(_firestore.collection('Users').doc(userId).collection("WIPExpenses").doc(expense.id));
  }

  if (tags.isNotEmpty) {
    expenseData['ownerId'] = userId;

    final tagDocs = tags.map((tag) => _firestore.collection('Tags').doc(tag.id).collection("Expenses").doc(expense.id)).toList();
    tagDocs.forEach((tagDoc) => expense is Expense ? batch.update(tagDoc, expenseData) : batch.set(tagDoc, expenseData));
  }

  await batch.commit();

  Expense? newExpense = await getExpense(expense.id);
  //attach tags so that tags on homescreen for expense will show up quickly
  if (newExpense != null && tags.isNotEmpty) newExpense.tags = tags;
  return newExpense;
}

/// Handle FCM message - route to appropriate handler based on type

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

// -------------------- NEW: Expense Unseen Management --------------------

/// Function called when a new/updated expense is send to user via FCM
Future<void> markExpenseAsUnseen(String expenseId) async {
  print('marking $expenseId as unseen');
  try {
    final userId = await getUserIdFromClaim();
    if (userId == null) return;

    await _firestore.collection('Users').doc(userId).update({
      'unseenExpenseIds': FieldValue.arrayUnion([expenseId]),
    });

    print('Expense marked as unseen: $expenseId');
  } catch (e, stackTrace) {
    log('Error marking expense as unseen: $e', error: e, stackTrace: stackTrace);
  }
}

///Called when user views the Expense in Expense Detail Screen
Future<void> markExpenseAsSeen(String expenseId) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return;

  await _firestore.collection('Users').doc(userId).update({
    'unseenExpenseIds': FieldValue.arrayRemove([expenseId]),
  });

  print('Expense marked as seen: $expenseId');
}

Future<List<UserFriend>?> getAllUserFriendsFromFirestore() async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return null;

  final friendsSnapshot = await _firestore.collection('Users').doc(userId).collection('Friends').get();

  List<UserFriend> userFriends = [];

  for (var doc in friendsSnapshot.docs) {
    Map<String, dynamic> data = doc.data();
    userFriends.add(await UserFriend.appendKilvishIdAndReturnObject(doc.id, data, _firestore));
  }

  print('Loaded ${userFriends.length} user friends');
  return userFriends;
}

Future<PublicUserInfo?> getPublicInfoUserFromKilvishId(String query) async {
  // Search for exact kilvishId match in top-level PublicInfo collection
  final publicInfoQuery = await _firestore.collection('PublicInfo').where('kilvishId', isEqualTo: query).limit(1).get();

  if (publicInfoQuery.docs.isNotEmpty) {
    final doc = publicInfoQuery.docs.first;
    if (!doc.exists) return null;

    final data = doc.data();
    return PublicUserInfo.fromFirestore(doc.id, data);
  } else {
    return null;
  }
}

Future<UserFriend?> getUserFriendWithGivenPhoneNumber(String phoneNumber) async {
  String? userId = await getUserIdFromClaim();
  if (userId == null) return null;

  // Check if friend with same phone already exists
  final existingFriends = await _firestore
      .collection('Users')
      .doc(userId)
      .collection('Friends')
      .where('phoneNumber', isEqualTo: phoneNumber)
      .limit(1)
      .get();

  if (existingFriends.docs.isNotEmpty) {
    // Friend already exists
    final friend = UserFriend.fromFirestore(existingFriends.docs.first.id, existingFriends.docs.first.data());
    return friend;
  }
  return null;
}

Future<UserFriend?> addUserFriendFromContact(LocalContact contact) async {
  String? userId = await getUserIdFromClaim();
  if (userId == null) return null;
  // Create new friend
  Map<String, dynamic> friendData = {
    'name': contact.name,
    'phoneNumber': contact.phoneNumber,
    'createdAt': FieldValue.serverTimestamp(),
  };

  final friendRef = await _firestore.collection('Users').doc(userId).collection('Friends').add(friendData);
  final friendDoc = await _firestore.collection('Users').doc(userId).collection('Friends').doc(friendRef.id).get();

  return UserFriend.fromFirestore(friendRef.id, friendDoc.data()!);
}

Future<UserFriend?> addFriendFromPublicInfoIfNotExist(PublicUserInfo publicInfo) async {
  String? userId = await getUserIdFromClaim();
  if (userId == null) return null;

  // Check if friend already exists
  final existingFriends = await _firestore
      .collection('Users')
      .doc(userId)
      .collection('Friends')
      .where('kilvishUserId', isEqualTo: publicInfo.userId)
      .limit(1)
      .get();

  if (existingFriends.docs.isNotEmpty) {
    Map<String, dynamic> data = existingFriends.docs.first.data();
    data['kilvishId'] = publicInfo.kilvishId;

    return UserFriend.fromFirestore(existingFriends.docs.first.id, data);
  } else {
    // Create new friend from publicInfo
    final friendData = {
      //'kilvishId': publicInfo.kilvishId,
      'kilvishUserId': publicInfo.userId,
      'createdAt': FieldValue.serverTimestamp(),
    };

    final friendRef = await _firestore.collection('Users').doc(userId).collection('Friends').add(friendData);

    friendData['kilvishId'] = publicInfo.kilvishId;
    return UserFriend.fromFirestore(friendRef.id, friendData);
  }
}

Future<BaseExpense?> getTagExpense(String tagId, String expenseId) async {
  final doc = await _firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId).get();

  if (!doc.exists) return null;

  final data = doc.data()!;
  final ownerId = data['ownerId'] as String?;
  final ownerKilvishId = ownerId != null ? await getUserKilvishId(ownerId) : null;

  // Check if it's a WIPExpense by status field
  if (data['status'] != null) {
    return WIPExpense.fromFirestoreObject(expenseId, data, ownerKilvishIdParam: ownerKilvishId);
  }

  return Expense.getExpenseFromFirestoreObject(expenseId, data);
}

Future<void> addExpenseToTag(String tagId, String expenseId, {num totalOutstandingAmount = 0}) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return;

  final expenseDoc = await _firestore.collection('Users').doc(userId).collection('Expenses').doc(expenseId).get();
  if (!expenseDoc.exists) return;

  final expenseData = expenseDoc.data();
  if (expenseData == null) return;

  expenseData['ownerId'] = userId;
  expenseData['createdAt'] = FieldValue.serverTimestamp();
  expenseData['totalOutstandingAmount'] = totalOutstandingAmount;

  await _firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId).set(expenseData);
  print('Expense $expenseId added to tag $tagId (outstanding: $totalOutstandingAmount)');
}

Future<void> updateExpenseOutstandingInTag(String tagId, String expenseId, num totalOutstandingAmount) async {
  await _firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId).update({
    'totalOutstandingAmount': totalOutstandingAmount,
  });
}

Future<void> addOrUpdateRecipient(String tagId, String expenseId, String recipientUserId, num amount) async {
  await _firestore
      .collection('Tags')
      .doc(tagId)
      .collection('Expenses')
      .doc(expenseId)
      .collection('Recipients')
      .doc(recipientUserId)
      .set({'userId': recipientUserId, 'amount': amount, 'updatedAt': FieldValue.serverTimestamp()});
  print('Recipient $recipientUserId set to $amount for expense $expenseId in tag $tagId');
}

Future<void> removeRecipient(String tagId, String expenseId, String recipientUserId) async {
  await _firestore
      .collection('Tags')
      .doc(tagId)
      .collection('Expenses')
      .doc(expenseId)
      .collection('Recipients')
      .doc(recipientUserId)
      .delete();
  print('Recipient $recipientUserId removed from expense $expenseId in tag $tagId');
}

Future<Map<String, num>> getRecipients(String tagId, String expenseId) async {
  final snapshot = await _firestore
      .collection('Tags')
      .doc(tagId)
      .collection('Expenses')
      .doc(expenseId)
      .collection('Recipients')
      .get();
  return {for (final doc in snapshot.docs) doc.id: (doc.data()['amount'] as num?) ?? 0};
}

Future<void> removeExpenseFromTag(String tagId, String expenseId) async {
  print("Inside removing tag from expense - tagId $tagId, expenseId $expenseId");
  await _firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId).delete();

  print('Expense $expenseId removed from tag $tagId');
}

Future<List<Tag>?> getExpenseTags(String expenseId) async {
  try {
    final user = await getLoggedInUserData();
    if (user == null) return null;

    List<Tag> tags = [];

    // Check each accessible tag to see if this expense is in it
    for (String tagId in user.accessibleTagIds) {
      final tagExpenseDoc = await _firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId).get();

      if (tagExpenseDoc.exists) {
        final tag = await getTagData(tagId, fromCache: true);
        tags.add(tag);
      }
    }
    return tags;
  } catch (e, stackTrace) {
    print('Error loading expense tags: $e, $stackTrace');
  }
  return null;
}

Future<Expense?> getExpense(String expenseId) async {
  String? userId = await getUserIdFromClaim();
  if (userId == null) return null;

  final expenseDoc = await _firestore.collection("Users").doc(userId).collection("Expenses").doc(expenseId).get();
  if (!expenseDoc.exists) return null;

  return Expense.getExpenseFromFirestoreObject(expenseId, expenseDoc.data()!);
}

Future<void> deleteExpense(Expense expense) async {
  String? userId = await getUserIdFromClaim();
  if (userId == null) return;

  final WriteBatch batch = _firestore.batch();

  DocumentReference expenseDoc = _firestore.collection("Users").doc(userId).collection("Expenses").doc(expense.id);
  DocumentSnapshot expenseDocSnapshot = await expenseDoc.get();
  if (!expenseDocSnapshot.exists) {
    print("Tried to delete Expense ${expense.id} but it does not exist in User -> Expenses");
  } else {
    // add to batch
    batch.delete(expenseDoc);
    print("${expense.id} scheduled to be deleted from User -> Expenses collection");
  }

  for (Tag tag in expense.tags) {
    expenseDoc = _firestore.collection("Tags").doc(tag.id).collection("Expenses").doc(expense.id);
    expenseDocSnapshot = await expenseDoc.get();
    if (!expenseDocSnapshot.exists) {
      print("Tried to delete Expense ${expense.id} from ${tag.name} but it does not exist in Tag -> Expenses");
    } else {
      // add to batch
      batch.delete(expenseDoc);
      print("${expense.id} scheduled to be deleted from ${tag.name} -> Expenses collection");
    }
  }

  batch.update(_firestore.collection("Users").doc(userId), {
    //remove old txId form user
    'txIds': FieldValue.arrayRemove([expense.txId]),
  });

  await batch.commit();

  //no awaits for below two operations
  markExpenseAsSeen(expense.id);
  deleteReceipt(expense.receiptUrl);

  print("Successfully deleted ${expense.id}");
}

Future<void> deleteTag(Tag tag) async {
  String? userId = await getUserIdFromClaim();
  if (userId == null) return;

  final WriteBatch batch = _firestore.batch();

  DocumentReference tagDocRef = _firestore.collection("Tags").doc(tag.id);
  CollectionReference expensesCollectionRef = tagDocRef.collection("Expenses");
  QuerySnapshot expenseDocsRef = await expensesCollectionRef.get();

  for (var doc in expenseDocsRef.docs) {
    batch.delete(doc.reference);
  }
  batch.delete(tagDocRef);

  DocumentReference userDocRef = _firestore.collection("Users").doc(userId);
  batch.update(userDocRef, {
    'accessibleTagIds': FieldValue.arrayRemove([tag.id]),
  });

  await batch.commit();
  print("Successfully deleted ${tag.name}");
}

Future<void> updateLastLoginOfUser(String userId) async {
  final publicInfoRef = _firestore.collection("PublicInfo").doc(userId);
  final publicInfoDoc = await publicInfoRef.get();
  if (!publicInfoDoc.exists) return;

  await publicInfoRef.update({'lastLogin': FieldValue.serverTimestamp()});
  print("lastLogin updated for $userId");
}

// Add these methods to your existing firestore.dart file

// -------------------- WIPExpense Management --------------------

/// Create a new WIPExpense document and return its ID
Future<WIPExpense?> createWIPExpense() async {
  // final userId = await getUserIdFromClaim();
  // if (userId == null) return null;
  final user = await getLoggedInUserData();
  if (user == null) return null;

  try {
    final wipExpenseData = {
      'status': ExpenseStatus.waitingToStartProcessing.name,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'tags': Expense.jsonEncodeExpensesList([]),
      // ownerKilvishId should not be stored in the DB
      //'ownerKilvishId': user.kilvishId!,
    };

    final docRef = await _firestore.collection('Users').doc(user.id).collection('WIPExpenses').add(wipExpenseData);

    print('WIPExpense created with ID: ${docRef.id}');
    return getWIPExpense(docRef.id);
  } catch (e, stackTrace) {
    print('Error creating WIPExpense: $e, $stackTrace');
    return null;
  }
}

/// Update WIPExpense status
Future<void> updateWIPExpenseStatus(String wipExpenseId, ExpenseStatus status, {String? errorMessage}) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return;

  try {
    final updateData = {'status': status.name, 'updatedAt': FieldValue.serverTimestamp()};

    updateData['errorMessage'] = errorMessage ?? FieldValue.delete();

    await _firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpenseId).update(updateData);

    print('WIPExpense $wipExpenseId status updated to ${status.name}');
  } catch (e, stackTrace) {
    print('Error updating WIPExpense status: $e, $stackTrace');
  }
}

Future<bool> attachReceiptURLtoWIPExpense(String wipExpenseId, String receiptUrl) async {
  try {
    final userId = await getUserIdFromClaim();
    if (userId == null) return false;

    DocumentReference wipExpenseDoc = _firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpenseId);

    await wipExpenseDoc.update({'receiptUrl': receiptUrl});
    return true;
  } catch (e, stackTrace) {
    print("Could not attach receiptUrl to wipExpense $e - $stackTrace");
    return false;
  }
}

Future<bool> attachLocalPathToWIPExpense(String wipExpenseId, String localReceiptPath) async {
  try {
    final userId = await getUserIdFromClaim();
    if (userId == null) return false;

    DocumentReference wipExpenseDoc = _firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpenseId);

    await wipExpenseDoc.update({'localReceiptPath': localReceiptPath});
    return true;
  } catch (e, stackTrace) {
    print("Could not attach localReceiptPath to wipExpense $e - $stackTrace");
    return false;
  }
}

/// Get all WIPExpenses for current user
Future<List<WIPExpense>> getAllWIPExpenses() async {
  final user = await getLoggedInUserData();
  if (user == null) return [];

  try {
    final snapshot = await _firestore
        .collection('Users')
        .doc(user.id)
        .collection('WIPExpenses')
        .orderBy('createdAt' /*, descending: true*/)
        .get();

    List<WIPExpense> wipExpenses = [];

    for (final doc in snapshot.docs) {
      try {
        wipExpenses.add(WIPExpense.fromFirestoreObject(doc.id, doc.data(), ownerKilvishIdParam: user.kilvishId));
      } catch (e) {
        print("Error processing ${doc.id}");
      }
    }

    return wipExpenses;

    // return snapshot.docs.map((doc) {
    //   try {
    //     return WIPExpense.fromFirestoreObject(doc.id, doc.data());
    //   } catch (e) {
    //     print("Error processing ${doc.id}");
    //     return null;
    //   }
    // }).toList();
  } catch (e, stackTrace) {
    print('Error getting WIPExpenses: $e, $stackTrace');
    return [];
  }
}

/// Get single WIPExpense by ID
Future<WIPExpense?> getWIPExpense(String wipExpenseId) async {
  final user = await getLoggedInUserData();
  if (user == null) return null;

  try {
    final doc = await _firestore.collection('Users').doc(user.id).collection('WIPExpenses').doc(wipExpenseId).get();

    if (!doc.exists) return null;

    return WIPExpense.fromFirestoreObject(doc.id, doc.data()!, ownerKilvishIdParam: user.kilvishId);
  } catch (e, stackTrace) {
    print('Error getting WIPExpense: $e, $stackTrace');
    return null;
  }
}

/// Convert WIPExpense to Expense (move from WIP to Expenses collection)
Future<WIPExpense?> convertExpenseToWIPExpense(Expense expense) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return null;

  try {
    final WriteBatch batch = _firestore.batch();

    final expenseDoc = _firestore.collection('Users').doc(userId).collection('Expenses').doc(expense.id);
    batch.delete(expenseDoc);

    if (expense.tags.isNotEmpty) {
      expense.tags.map((Tag tag) {
        batch.delete(_firestore.collection('Tags').doc(tag.id));
      });
    }

    WIPExpense wipExpense = WIPExpense.fromExpense(expense);

    batch.set(_firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(expense.id), wipExpense.toFirestore());

    await batch.commit();

    print("${expense.id} is now converted to WIPExpense from Expense for user $userId");

    return wipExpense;

    // // Create expense with the same ID as WIPExpense
    // await _firestore.collection('Users').doc(userId).collection('Expenses').doc(wipExpenseId).set(expenseData);

    // // If tags are provided, add to tags
    // if (tags != null && tags.isNotEmpty) {
    //   await addOrUpdateUserExpense(expenseData, wipExpenseId, tags);
    // }

    // // Delete WIPExpense
    // await _firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpenseId).delete();

    // print('WIPExpense $wipExpenseId converted to Expense');
    // return wipExpenseId;
  } catch (e, stackTrace) {
    print('Error converting WIPExpense to Expense: $e, $stackTrace');
    return null;
  }
}

/// Delete WIPExpense and its receipt
Future<void> deleteWIPExpense(String wipExpenseId, String? receiptUrl, String? localReceiptPath) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return;

  try {
    _firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpenseId).delete().then((value) async {
      deleteReceipt(receiptUrl);

      if (localReceiptPath != null) {
        try {
          File(localReceiptPath).deleteSync();
          print('localFile $localReceiptPath for WIPExpense deleted successfully');
        } catch (e) {
          print('Unable to delete localFile $localReceiptPath  of WIPExpense - $e');
        }
      }
    });

    print('WIPExpense $wipExpenseId deleted');
  } catch (e, stackTrace) {
    print('Error deleting WIPExpense: $e, $stackTrace');
  }
}

Future<void> updateWIPExpenseTags(String wipExpenseId, List<Tag> tags) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return;
  await _firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpenseId).update({
    'tags': Tag.jsonEncodeTagsList(tags),
    'updatedAt': FieldValue.serverTimestamp(),
  });
}

Future<void> markWIPExpenseAsLoanPayback(String wipExpenseId) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return;
  await _firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpenseId).update({
    'loanPaybackTagName': '', // empty string marks intent; user fills actual name in Add/Edit
    'updatedAt': FieldValue.serverTimestamp(),
  });
}

Future<bool> deleteReceipt(String? receiptUrl) async {
  if (receiptUrl != null && receiptUrl.isNotEmpty) {
    try {
      final ref = FirebaseStorage.instanceFor(bucket: 'gs://tamraj-kilvish.firebasestorage.app').refFromURL(receiptUrl);
      await ref.delete();
      print('Receipt deleted: $receiptUrl');
    } catch (e) {
      print('Error deleting receipt: $e');
      return false;
    }
  }
  return true;
}

/// Count WIPExpenses that are ready for review
Future<int> getReadyForReviewCount() async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return 0;

  try {
    final snapshot = await _firestore
        .collection('Users')
        .doc(userId)
        .collection('WIPExpenses')
        .where('status', isEqualTo: ExpenseStatus.readyForReview.name)
        .get();

    return snapshot.docs.length;
  } catch (e, stackTrace) {
    print('Error getting ready for review count: $e, $stackTrace');
    return 0;
  }
}

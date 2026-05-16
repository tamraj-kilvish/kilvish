import 'dart:developer';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/models_expense_taglinks.dart';
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

Future<void> clearFirestorePersistence() async {
  await _firestore.terminate();
  await _firestore.clearPersistence();
}

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

Future<String?> getUserKilvishId(String? userId) async {
  if (userId == null) return null;
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

Future<Tag> getTagData(String tagId, {bool? fromCache}) async {
  DocumentReference tagRef = _firestore.collection("Tags").doc(tagId);
  DocumentSnapshot<Map<String, dynamic>> tagDoc =
      await (fromCache != null ? tagRef.get(GetOptions(source: Source.cache)) : tagRef.get())
          as DocumentSnapshot<Map<String, dynamic>>;

  final tagData = tagDoc.data();
  return Tag.fromFirestoreObject(tagDoc.id, tagData);
}

Future<void> touchTagUpdatedAt(String tagId) async {
  try {
    await _firestore.collection('Tags').doc(tagId).update({'updatedAt': FieldValue.serverTimestamp()});
  } catch (e) {
    print('touchTagUpdatedAt error: $e');
  }
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
    'total': {
      'acrossUsers': {'expense': 0, 'recovery': 0},
    },
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
  final expenseDocs = await getExpenseDocsUnderTag(tagId);
  return Future.wait(
    expenseDocs.map((doc) => Expense.getExpenseFromFirestoreObject(doc.id, doc.data() as Map<String, dynamic>, tagId: tagId)),
  );
}

Future<Expense?> getMostRecentExpenseFromTag(String tagId) async {
  DocumentSnapshot<Map<String, dynamic>> tagDoc = await _firestore.collection("Tags").doc(tagId).get();
  QuerySnapshot<Map<String, dynamic>> expensesSnapshot = await tagDoc.reference
      .collection('Expenses')
      .orderBy('timeOfTransaction', descending: true)
      .limit(1)
      .get();

  if (expensesSnapshot.docs.isEmpty) return null;

  final expenseDoc = expensesSnapshot.docs[0];
  return Expense.getExpenseFromFirestoreObject(expenseDoc.id, expenseDoc.data(), tagId: tagId);
}

Future<String?> getUserIdFromClaim({FirebaseAuth? authParam}) async {
  final auth = authParam ?? _auth;
  final authUser = auth.currentUser;
  if (authUser == null) return null;

  final idTokenResult = await authUser.getIdTokenResult();
  return idTokenResult.claims?['userId'] as String?;
}

Future<Expense?> updateExpense(Map<String, Object?> expenseData, BaseExpense expense) async {
  final String? userId = await getUserIdFromClaim();
  if (userId == null) return null;

  final WriteBatch batch = _firestore.batch();

  DocumentReference userDocRef = _firestore.collection("Users").doc(userId).collection("Expenses").doc(expense.id);
  batch.set(userDocRef, expenseData);

  for (final tagLink in expense.tagLinks) {
    await addToOrUpdateTagExpense(
      tagLink.tagId,
      expense.id,
      batchParam: batch,
      expenseDataParam: expenseData,
    ); //not saveTagLink as for Expense, they were already saved before
  }

  if (expense is Expense) {
    await batch.commit();
    return getExpense(expense.id);
  }
  //WIPExpense now .. delete WIPExpense, create Expense & save tagLinks
  batch.delete(_firestore.collection('Users').doc(userId).collection("WIPExpenses").doc(expense.id));
  await batch.commit();

  final updatedExpense = (await getExpense(expense.id))!; //we need Expense object & we have WIPExpense so far, for saveTagLink
  await Future.wait(expense.tagLinks.map((tagLink) => updatedExpense.saveTagLink(tagLink)));

  return getExpense(expense.id);
}

/// Handle FCM message - route to appropriate handler based on type

Future<void> saveFCMToken(String token) async {
  try {
    String? userId = await getUserIdFromClaim();
    if (userId == null) {
      print('[FCM] ⚠️ saveFCMToken skipped — no authenticated user');
      return;
    }
    print('[FCM] saving token for userId=$userId token=${token.substring(0, token.length.clamp(0, 30))}...');
    await _firestore.collection('Users').doc(userId).update({
      'fcmToken': token,
      'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
    });
    print('[FCM] token saved ok');
  } catch (e, stackTrace) {
    print('[FCM] ❌ Error saving FCM token: $e\n$stackTrace');
  }
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

Future<Expense?> getTagExpense(String tagId, String expenseId) async {
  final doc = await _firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId).get();

  if (!doc.exists) return null;

  final data = doc.data()!;
  return Expense.getExpenseFromFirestoreObject(expenseId, data, tagId: tagId);
}

Future<void> addToOrUpdateTagExpense(
  String tagId,
  String expenseId, {
  WriteBatch? batchParam,
  Map<String, Object?>? expenseDataParam,
}) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return;

  final userExpenseRef = _firestore.collection('Users').doc(userId).collection('Expenses').doc(expenseId);
  final userExpenseDoc = await userExpenseRef.get();
  if (!userExpenseDoc.exists) return;

  final tagExpenseRef = _firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId);
  final tagDocAlreadyExists = (await tagExpenseRef.get()).exists;
  if (expenseDataParam == null && tagDocAlreadyExists) return; //Expense already part of it

  final expenseData = expenseDataParam ?? userExpenseDoc.data();
  if (expenseData == null) return;

  expenseData['ownerId'] = userId;
  final kilvishId = await getUserKilvishId(userId);
  expenseData['updatedBy'] = {'userId': userId, if (kilvishId != null) 'kilvishId': kilvishId};
  expenseData['createdAt'] = FieldValue.serverTimestamp();
  expenseData.remove('tagIds');

  final batch = batchParam ?? _firestore.batch();

  if (tagDocAlreadyExists) {
    batch.update(tagExpenseRef, expenseData);
  } else {
    // Initialise tag-specific expenseAmount from total amount on first creation.
    // dont update it subsequently, they should be updated by tagLink only, hence not part of batch.update()
    expenseData['expenseAmount'] = expenseData['amount'];
    batch.set(tagExpenseRef, expenseData);
    batch.update(userExpenseRef, {
      'tagIds': FieldValue.arrayUnion([tagId]),
    });
  }

  if (batchParam == null) {
    await batch.commit();
    print('Expense $expenseId added to tag $tagId');
  }
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

Future<void> removeExpenseFromTag(String tagId, String expenseId, {WriteBatch? batchParam}) async {
  WriteBatch batch = batchParam ?? _firestore.batch();

  print("Inside removing tag from expense - tagId $tagId, expenseId $expenseId");
  final expenseDoc = _firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId);
  batch.delete(expenseDoc);

  //delete all Recipients
  final recipientDocs = await expenseDoc.collection("Recipients").get();
  for (final doc in recipientDocs.docs) {
    batch.delete(doc.reference);
  }

  //remove tagId from User Expense
  final userId = await getUserIdFromClaim();
  final userExpenseDoc = _firestore.collection('Users').doc(userId).collection('Expenses').doc(expenseId);
  batch.update(userExpenseDoc, {
    'tagIds': FieldValue.arrayRemove([tagId]),
  });

  if (batchParam == null) {
    await batch.commit();
    print('Expense $expenseId removed from tag $tagId');
  }
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

Future<void> deleteExpense(Expense expense, {WriteBatch? batchParam}) async {
  String? userId = await getUserIdFromClaim();
  if (userId == null) return;

  final WriteBatch batch = batchParam ?? _firestore.batch();

  DocumentReference expenseDoc = _firestore.collection("Users").doc(userId).collection("Expenses").doc(expense.id);
  DocumentSnapshot expenseDocSnapshot = await expenseDoc.get();
  if (!expenseDocSnapshot.exists) {
    print("Tried to delete Expense ${expense.id} but it does not exist in User -> Expenses");
    return;
  }
  // add to batch
  batch.delete(expenseDoc);
  print("${expense.id} scheduled to be deleted from User -> Expenses collection");

  final fullExpense = await getExpense(expense.id);
  for (String tagId in fullExpense!.tagIds) {
    try {
      expenseDoc = _firestore.collection("Tags").doc(tagId).collection("Expenses").doc(expense.id);
      expenseDocSnapshot = await expenseDoc.get();

      final docsRef = await _firestore
          .collection("Tags")
          .doc(tagId)
          .collection("Expenses")
          .doc(expense.id)
          .collection("Recipients")
          .get();
      for (final doc in docsRef.docs) {
        batch.delete(doc.reference);
        print("Scheduled to delete Recipient ${doc.id} for expense ${expense.id}");
      }

      batch.delete(expenseDoc);
      print("${expense.id} scheduled to be deleted from tag $tagId -> Expenses collection");
    } catch (e) {
      print("Tried to delete Expense ${expense.id} from tag $tagId but it does not exist in Tag -> Expenses");
    }
  }

  if (batchParam == null) await batch.commit();

  deleteReceipt(expense.receiptUrl);

  print("Successfully deleted ${expense.id}");
}

Future<void> deleteTag(Tag tag) async {
  if (tag.sharedWith.isNotEmpty) {
    throw Exception('Remove all members from the tag before deleting it.');
  }

  String? userId = await getUserIdFromClaim();
  if (userId == null) return;

  final WriteBatch batch = _firestore.batch();

  DocumentReference tagDocRef = _firestore.collection("Tags").doc(tag.id);
  CollectionReference expensesCollectionRef = tagDocRef.collection("Expenses");
  QuerySnapshot expenseDocsRef = await expensesCollectionRef.get();

  for (var doc in expenseDocsRef.docs) {
    batch.delete(doc.reference);
    // Remove this tag from the owner's personal expense doc if it belongs to the current user
    final expenseData = doc.data() as Map<String, dynamic>;
    if ((expenseData['ownerId'] as String?) == userId) {
      final userExpenseRef = _firestore.collection('Users').doc(userId).collection('Expenses').doc(doc.id);
      batch.update(userExpenseRef, {
        'tagIds': FieldValue.arrayRemove([tag.id]),
      });
    }
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
Future<WIPExpense?> createWIPExpense({List<String>? tagIds, String? loanPaybackTagName, DateTime? createdAt}) async {
  // final userId = await getUserIdFromClaim();
  // if (userId == null) return null;
  final user = await getLoggedInUserData();
  if (user == null) return null;

  try {
    final wipExpenseData = {
      'status': ExpenseStatus.waitingToStartProcessing.name,
      'createdAt': createdAt != null ? Timestamp.fromDate(createdAt) : FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'tagIds': <String>[],
    };

    if (tagIds != null) {
      final tagLinks = tagIds.map((tagId) => TagExpenseConfig(tagId: tagId)).toList();
      wipExpenseData['tagLinks'] = tagLinks.map((tagLink) => tagLink.toJson()).toList();
    }
    if (loanPaybackTagName != null) {
      wipExpenseData['loanPaybackTagName'] = loanPaybackTagName;
    }

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
        wipExpenses.add(
          await WIPExpense.fromFirestoreObject(doc.id, doc.data(), ownerKilvishIdParam: user.kilvishId, ownerIdParam: user.id),
        );
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

    return WIPExpense.fromFirestoreObject(doc.id, doc.data()!, ownerKilvishIdParam: user.kilvishId, ownerIdParam: user.id);
  } catch (e, stackTrace) {
    print('Error getting WIPExpense: $e, $stackTrace');
    return null;
  }
}

/// Convert WIPExpense to Expense (move from WIP to Expenses collection)
Future<WIPExpense?> convertExpenseToWIPExpense(Expense expense) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return null;

  WIPExpense wipExpense = WIPExpense.fromExpense(expense);
  try {
    final WriteBatch batch = _firestore.batch();

    await deleteExpense(expense, batchParam: batch);
    batch.set(_firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(expense.id), wipExpense.toFirestore());

    await batch.commit();

    print("${expense.id} is now converted to WIPExpense from Expense for user $userId");

    return wipExpense;
  } catch (e, stackTrace) {
    print('Error converting WIPExpense to Expense: $e, $stackTrace');
    return null;
  }
}

/// Delete WIPExpense and its receipt
Future<void> deleteWIPExpense(String wipExpenseId, String? receiptUrl, String? localReceiptPath) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return;

  _firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpenseId).delete().then((value) async {
    deleteReceipt(receiptUrl);
    print('WIPExpense $wipExpenseId deleted');
  });
}

Future<void> updateWIPExpenseTagLinks(String wipExpenseId, List<TagExpenseConfig> tagLinks) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return;
  await _firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpenseId).update({
    'tagLinks': tagLinks.map((t) => t.toJson()).toList(),
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

Future<void> updateLastFCMProcessedAt() async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return;
  await getFirestoreInstance().collection('Users').doc(userId).update({'lastFCMProcessedAt': FieldValue.serverTimestamp()});
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

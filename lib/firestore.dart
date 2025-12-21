import 'dart:developer';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'models.dart';

final FirebaseFirestore _firestore = FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'kilvish');
final FirebaseAuth _auth = FirebaseAuth.instance;

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

Future<bool> updateUserKilvishId(String userId, String kilvishId) async {
  DocumentSnapshot publicInfoDoc = await _firestore.collection("PublicInfo").doc(userId).get();

  if (!publicInfoDoc.exists) {
    if (await isKilvishIdTaken(kilvishId)) return false;

    await _firestore.collection("PublicInfo").doc(userId).set({
      'kilvishId': kilvishId,
      'updatedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
      'lastLogin': FieldValue.serverTimestamp(),
    });
    return true;
  }

  PublicUserInfo publicUserInfo = PublicUserInfo.fromFirestore(userId, publicInfoDoc.data() as Map<String, dynamic>);
  if (publicUserInfo.kilvishId != kilvishId && await isKilvishIdTaken(kilvishId)) return false;

  final updateData = {'lastLogin': FieldValue.serverTimestamp()};
  if (publicUserInfo.kilvishId != kilvishId) {
    updateData.addAll({'kilvishId': kilvishId as FieldValue, 'updatedAt': FieldValue.serverTimestamp()});
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
  tagData.addAll({'createdAt': FieldValue.serverTimestamp(), 'ownerId': ownerId, 'totalAmountTillDate': 0, 'monthWiseTotal': {}});

  //TODO - add all operations below as batch/transaction
  DocumentReference tagDoc = await _firestore.collection('Tags').add(tagData);
  await _firestore.collection("Users").doc(ownerId).update({
    'accessibleTagIds': FieldValue.arrayUnion([tagDoc.id]),
  });
  final tagDataRefetched = (await _firestore.collection("Tags").doc(tagDoc.id).get()).data();
  return Tag.fromFirestoreObject(tagDoc.id, tagDataRefetched!);
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
    expenses.add(Expense.fromFirestoreObject(doc.id, doc.data() as Map<String, dynamic>));
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
  return Expense.fromFirestoreObject(expenseDoc.id, expenseDoc.data() as Map<String, dynamic>);
}

Future<String?> getUserIdFromClaim() async {
  final authUser = _auth.currentUser;
  if (authUser == null) return null;

  final idTokenResult = await authUser.getIdTokenResult();
  return idTokenResult.claims?['userId'] as String?;
}

Future<String?> addOrUpdateUserExpense(Map<String, Object?> expenseData, String? expenseId, Set<Tag>? tags, String txId) async {
  final String? userId = await getUserIdFromClaim();
  if (userId == null) return null;

  CollectionReference userExpensesRef = _firestore.collection('Users').doc(userId).collection("Expenses");

  final WriteBatch batch = _firestore.batch();

  DocumentReference userDocRef = _firestore.collection("Users").doc(userId);
  batch.update(userDocRef, {
    'txIds': FieldValue.arrayUnion([txId]),
  });

  if (expenseId != null) {
    batch.update(userExpensesRef.doc(expenseId), expenseData);

    if (tags != null) {
      expenseData['ownerId'] = userId;

      List<DocumentReference> tagDocs = tags
          .map((tag) => _firestore.collection('Tags').doc(tag.id).collection("Expenses").doc(expenseId))
          .toList();
      tagDocs.forEach((doc) => batch.update(doc, expenseData));
    }

    await batch.commit();
    return null;
  }
  // DocumentReference doc = await userExpensesRef.add(expenseData);
  // return doc.id;
  final newDocRef = userExpensesRef.doc();
  final String docId = newDocRef.id;

  batch.set(newDocRef, expenseData);
  await batch.commit();

  return docId;
}

/// Handle FCM message - route to appropriate handler based on type
Future<void> updateFirestoreLocalCache(Map<String, dynamic> data) async {
  print('Updating firestore local cache with data - $data');

  try {
    final type = data['type'] as String?;

    switch (type) {
      case 'expense_created':
      case 'expense_updated':
        await _storeTagMonetarySummaryUpdate(data);
        await _handleExpenseCreatedOrUpdated(data);
        break;
      case 'expense_deleted':
        await _storeTagMonetarySummaryUpdate(data);
        await _handleExpenseDeleted(data);
        break;
      case 'tag_shared':
        await _handleTagShared(data);
        break;
      case 'tag_removed':
        await _handleTagRemoved(data);
        break;
      default:
        log('Unknown FCM message type: $type');
    }
  } catch (e, stackTrace) {
    print('Error handling FCM message: $e, $stackTrace');
  }
  print('Firestore cache updated successful');
}

Future<void> _storeTagMonetarySummaryUpdate(Map<String, dynamic> data) async {
  try {
    final tagId = data['tagId'] as String?;
    final tagString = data['tag'] as String?;

    if (tagId == null || tagString == null) {
      log('Invalid tag data in FCM payload');
      return;
    }

    // Parse JSON string to Map
    // final tagData = jsonDecode(tagString) as Map<String, dynamic>;
    // final Map<String, dynamic> tagDataToWrite = {};

    // tagDataToWrite['name'] = tagData['name']; // if at all tag name is updated

    // tagDataToWrite['totalAmountTillDate'] = num.parse(tagData['totalAmountTillDate']);

    // final monthWiseTotal = tagData['monthWiseTotal'] as Map<String, dynamic>;
    // for (var entry in monthWiseTotal.entries) {
    //   final year = entry.key;
    //   final monthAmountHash = entry.value as Map<String, dynamic>;
    //   final monthValue = monthAmountHash.entries.first;
    //   final month = monthValue.key;
    //   final amount = monthValue.value as num;
    //   tagDataToWrite['monthWiseTotal'] = {
    //     year: {month: amount},
    //   };
    // }

    // Write to local Firestore cache
    final tagRef = _firestore.collection('Tags').doc(tagId);
    //final tagDoc = await _firestore.collection('Tags').doc(tagId).get();
    final tagDoc = await tagRef.get(const GetOptions(source: Source.server)); //intentionally not putting await
    // try {
    //   //this operation will update locally but also throw error due to security rules on cloud update
    //   //hence wrapping around try catch
    //   await tagDoc.reference.update(tagDataToWrite);
    //  await tagRef.set(tagData, SetOptions(merge: true));
    // } catch (e) {
    //   print('trying to update $tagId .. Error - $e .. error is ignored & continuining operation');
    // }
    print('Refetched data for tag - ${tagDoc.get('name')} for local cache update - ${tagDoc.data()}');
  } catch (e, stackTrace) {
    print('Error caching tag monetary updates: $e $stackTrace');
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
      expenseData['timeOfTransaction'] = Timestamp.fromDate(DateTime.parse(expenseData['timeOfTransaction']));
    }
    if (expenseData['updatedAt'] is String) {
      expenseData['updatedAt'] = Timestamp.fromDate(DateTime.parse(expenseData['updatedAt']));
    }

    // Convert amount string to number
    if (expenseData['amount'] is String) {
      expenseData['amount'] = num.parse(expenseData['amount']);
    }

    // Write to local Firestore cache
    final expenseRef = _firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId);

    try {
      //this operation will update locally but also throw error due to security rules on cloud update
      // hence wrapping around try catch
      await expenseRef.set(expenseData, SetOptions(merge: true));
    } catch (e) {
      print('trying to update $expenseId .. this error will be thrown .. ignore');
    }
    print('Local cache for $expenseId updated');

    // Mark expense as unseen for current user
    await markExpenseAsUnseen(expenseId);
  } catch (e, stackTrace) {
    print('Error caching expense: $e $stackTrace');
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
    final expenseDocRef = _firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId);

    try {
      await (await expenseDocRef.get()).reference.delete();
    } catch (e) {
      print("Trying to delete $expenseId' .. ignore this error ");
    }
    print('successfully deleted referenced to $expenseId');

    // Remove from unseen expenses
    //TODO - this expense could be in other tags too, handle this in future
    await markExpenseAsSeen(expenseId);

    log('Expense deleted from local cache: $expenseId');
  } catch (e, stackTrace) {
    log('Error deleting expense from cache: $e', error: e, stackTrace: stackTrace);
  }
}

/// Handle tag shared - fetch and cache the tag document
Future<void> _handleTagShared(Map<String, dynamic> data) async {
  try {
    final tagId = data['tagId'] as String?;

    if (tagId == null) {
      log('Invalid tag_shared data in FCM payload');
      return;
    }

    log('Tag shared notification received: $tagId - fetching tag data');

    // Fetch the tag document from server and cache it locally
    await getTagData(tagId);

    log('Tag data fetched and cached: $tagId');
  } catch (e, stackTrace) {
    log('Error fetching shared tag: $e', error: e, stackTrace: stackTrace);
  }
}

/// Handle tag removed - delete tag and all its expenses from local cache
Future<void> _handleTagRemoved(Map<String, dynamic> data) async {
  try {
    final tagId = data['tagId'] as String?;

    if (tagId == null) {
      log('Invalid tag_removed data in FCM payload');
      return;
    }

    log('Tag access removed: $tagId - removing from local cache');

    // First, delete all expenses under this tag
    final tagRef = _firestore.collection('Tags').doc(tagId);
    final expensesSnapshot = await tagRef.collection('Expenses').get();

    // Delete all expenses and remove from unseen
    for (var expenseDoc in expensesSnapshot.docs) {
      try {
        await expenseDoc.reference.delete();
      } catch (e) {
        print('Deleting ${expenseDoc.id} will throw error while connected to upstrea. Ignore. Error - $e');
      }
      // await markExpenseAsSeen(
      //   expenseDoc.id,
      // ); //TODO - the expense could be visible elsewhere, fix this later
      log('Deleted expense from cache: ${expenseDoc.id}');
    }

    // Then delete the tag document itself
    final tagDoc = await tagRef.get();
    tagDoc.reference.delete();

    log('Tag and its expenses removed from local cache: $tagId');
  } catch (e, stackTrace) {
    log('Error removing tag from cache: $e', error: e, stackTrace: stackTrace);
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

Future<void> addExpenseToTag(String tagId, String expenseId) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return;

  // Get the expense data from Users/{userId}/Expenses
  final expenseDoc = await _firestore.collection('Users').doc(userId).collection('Expenses').doc(expenseId).get();

  if (!expenseDoc.exists) return;

  final expenseData = expenseDoc.data();
  if (expenseData == null) return;

  expenseData['ownerId'] = userId;

  // Add expense to tag's Expenses subcollection
  await _firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId).set(expenseData);

  print('Expense $expenseId added to tag $tagId');
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
  } catch (e) {
    print('Error loading expense tags: $e');
  }
  return null;
}

Future<Expense?> getExpense(String expenseId) async {
  String? userId = await getUserIdFromClaim();
  if (userId == null) return null;

  final expenseDoc = await _firestore.collection("Users").doc(userId).collection("Expenses").doc(expenseId).get();
  if (!expenseDoc.exists) return null;

  return Expense.fromFirestoreObject(expenseId, expenseDoc.data()!);
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
  await batch.commit();
  await markExpenseAsSeen(expense.id);

  //TODO delete the receipt

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

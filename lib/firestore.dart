import 'dart:developer';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:kilvish/cache_manager.dart';
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
  String kilvishId = userIdKilvishIdHash[userId] ?? "kilvishId_not_found";

  return kilvishId;
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

Map<String, Tag> tagIdTagDataCache = {};

Future<Tag> getTagData(String tagId, {bool? includeMostRecentExpense, bool invalidateCache = false}) async {
  if (invalidateCache) {
    tagIdTagDataCache.remove(tagId);
  }

  if (tagIdTagDataCache[tagId] != null) {
    Tag tag = tagIdTagDataCache[tagId]!;
    if (includeMostRecentExpense != null) {
      tag.mostRecentExpense = await getMostRecentExpenseFromTag(tag.id);
    }
    return tag;
  }

  DocumentReference tagRef = _firestore.collection("Tags").doc(tagId);
  DocumentSnapshot<Map<String, dynamic>> tagDoc = await (tagRef.get()) as DocumentSnapshot<Map<String, dynamic>>;

  final tagData = tagDoc.data();
  //print("Got tagData for tagId $tagId - $tagData");

  Tag tag = Tag.fromFirestoreObject(tagDoc.id, tagData);
  if (includeMostRecentExpense != null) {
    tag.mostRecentExpense = await getMostRecentExpenseFromTag(tagDoc.id);
  }
  tagIdTagDataCache[tag.id] = tag;

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

    Tag tag = await getTagData(tagId, invalidateCache: true);
    return tag;
  }

  // create new tag flow

  tagData.addAll({
    'createdAt': FieldValue.serverTimestamp(),
    'ownerId': ownerId,
    'totalAmountTillDate': 0,
    'monthWiseTotal': {},
    'userWiseTotalTillDate': {},
  });

  WriteBatch batch = _firestore.batch();

  DocumentReference tagDoc = _firestore.collection('Tags').doc();
  batch.set(tagDoc, tagData);
  batch.update(_firestore.collection("Users").doc(ownerId), {
    'accessibleTagIds': FieldValue.arrayUnion([tagDoc.id]),
  });

  await batch.commit();

  return getTagData(tagDoc.id, invalidateCache: true);
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

Future<List<Expense>> getSettlementsOfTag(String tagId) async {
  DocumentSnapshot<Map<String, dynamic>> tagDoc = await _firestore.collection("Tags").doc(tagId).get();
  QuerySnapshot<Map<String, dynamic>> settlementsSnapshot = await tagDoc.reference
      .collection('Settlements')
      .orderBy('timeOfTransaction', descending: true)
      .get();

  List<Expense> settlements = [];
  for (DocumentSnapshot doc in settlementsSnapshot.docs) {
    final settlement = await Expense.getExpenseFromFirestoreObject(doc.id, doc.data() as Map<String, dynamic>);

    settlements.add(settlement);
  }
  return settlements;
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

Future<Expense?> updateExpense(
  Map<String, Object?> expenseData,
  BaseExpense expense,
  Set<Tag> tags,
  List<SettlementEntry>? settlements,
) async {
  final String? userId = await getUserIdFromClaim();
  if (userId == null) return null;

  CollectionReference userExpensesRef = _firestore.collection('Users').doc(userId).collection("Expenses");

  final WriteBatch batch = _firestore.batch();

  DocumentReference userDocRef = _firestore.collection("Users").doc(userId);
  batch.update(userDocRef, {
    'txIds': FieldValue.arrayUnion([expenseData['txId']]),
  });

  List<String> tagIds = tags.map((t) => t.id).toList();
  final settlementJsonList = settlements?.map((s) => s.toJson()).toList();

  if (expense is Expense) {
    batch.update(userExpensesRef.doc(expense.id), expenseData); //tags & settlements are updated from TagSelection screen itself.
    batch.update(userDocRef, {
      //remove old txId form user
      'txIds': FieldValue.arrayRemove([expense.txId]),
    });
  }

  if (expense is WIPExpense) {
    //create new Expense
    batch.set(userExpensesRef.doc(expense.id), {...expenseData, 'tagIds': tagIds, 'settlements': settlementJsonList});
    // delete WIPExpense
    batch.delete(_firestore.collection('Users').doc(userId).collection("WIPExpenses").doc(expense.id));

    final expenseDataWithOwnerId = {...expenseData, 'ownerId': userId};

    if (tags.isNotEmpty) {
      final tagExpensesDocs = tags
          .map((tag) => _firestore.collection('Tags').doc(tag.id).collection("Expenses").doc(expense.id))
          .toList();

      tagExpensesDocs.forEach((expenseDoc) => batch.set(expenseDoc, expenseDataWithOwnerId));
    }

    // Handle settlements - add to Tags/{tagId}/Settlements collection
    if (settlements != null && settlements.isNotEmpty) {
      for (var settlement in settlements) {
        final expenseDoc = _firestore.collection('Tags').doc(settlement.tagId).collection('Settlements').doc(expense.id);
        batch.set(expenseDoc, {
          ...expenseDataWithOwnerId,
          "settlements": [settlement.toJson()],
        });
      }
    }
  }

  await batch.commit();

  Expense? newExpense = await getExpenseFromUserCollection(expense.id);
  //attach tags and settlements so that they show up quickly
  if (newExpense != null) {
    if (tags.isNotEmpty) newExpense.tags = tags;
    if (settlements != null && settlements.isNotEmpty) newExpense.settlements = settlements;
  }
  return newExpense;
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
      case 'wip_status_update':
        if (data['wipExpenseId'] == null) break;

        String? userId = await getUserIdFromClaim();
        if (userId == null) break;

        await _firestore.collection('Users').doc(userId).collection("WIPExpenses").doc(data['wipExpenseId'] as String).get();
        break;

      case 'settlement_created':
      case 'settlement_updated':
        await _storeTagMonetarySummaryUpdate(data);
        await _handleExpenseCreatedOrUpdated(data, collection: "Settlements");
        break;
      case 'settlement_deleted':
        await _storeTagMonetarySummaryUpdate(data);
        await _handleExpenseDeleted(data, collection: "Settlements");
        break;
      default:
        log('Unknown FCM message type: $type');
    }
  } catch (e, stackTrace) {
    print('Error handling FCM message: $e, $stackTrace');
  }
}

Future<void> _storeTagMonetarySummaryUpdate(Map<String, dynamic> data) async {
  try {
    final tagId = data['tagId'] as String?;
    //final tagString = data['tag'] as String?;

    if (tagId == null /*|| tagString == null*/ ) {
      print('_storeTagMonetarySummaryUpdate is called without tagId .. exiting');
      return;
    }

    await getTagData(tagId, invalidateCache: true);
  } catch (e, stackTrace) {
    print('Error caching tag monetary updates: $e $stackTrace');
  }
}

/// Handle expense created or updated - cache to local Firestore
Future<void> _handleExpenseCreatedOrUpdated(Map<String, dynamic> data, {String collection = "Expenses"}) async {
  try {
    final tagId = data['tagId'] as String?;
    final expenseId = data['expenseId'] as String?;
    final expenseString = data['expense'] as String?;

    if (tagId == null || expenseId == null || expenseString == null) {
      log('Invalid expense data in FCM payload');
      return;
    }

    final expenseRef = _firestore.collection('Tags').doc(tagId).collection(collection).doc(expenseId);
    await expenseRef.get();

    print('Local cache for $expenseId updated');

    // Mark expense as unseen for current user
    await markExpenseAsUnseen(expenseId);
  } catch (e, stackTrace) {
    print('Error caching expense: $e $stackTrace');
  }
}

/// Handle expense deleted - remove from local cache
Future<void> _handleExpenseDeleted(Map<String, dynamic> data, {String collection = "Expenses"}) async {
  try {
    final tagId = data['tagId'] as String?;
    final expenseId = data['expenseId'] as String?;

    if (tagId == null || expenseId == null) {
      log('Invalid delete data in FCM payload');
      return;
    }

    // Remove from local Firestore cache
    final expenseDocRef = _firestore.collection('Tags').doc(tagId).collection(collection).doc(expenseId);

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

    tagIdTagDataCache.remove(tagId);

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

Future<BaseExpense?> getTagExpense(String tagId, String expenseId, {bool isSettlement = false}) async {
  final doc = await _firestore
      .collection('Tags')
      .doc(tagId)
      .collection(isSettlement ? 'Settlements' : 'Expenses')
      .doc(expenseId)
      .get();

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

Future<void> addExpenseOrSettlementToTag(String expenseId, {String? tagId, SettlementEntry? settlementData}) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return;

  Expense? userExpense = await getExpenseFromUserCollection(expenseId);
  if (userExpense == null) return;

  final WriteBatch batch = _firestore.batch();

  if (settlementData != null) {
    List<SettlementEntry> updatedUserExpenseSettlements = userExpense.settlements
        .map((settlement) => settlement.tagId == settlementData.tagId! ? settlementData : settlement)
        .toList();

    // user did not have any settlements originally
    if (updatedUserExpenseSettlements.isEmpty) updatedUserExpenseSettlements = [settlementData];

    batch.update(_firestore.collection('Users').doc(userId).collection('Expenses').doc(expenseId), {
      'settlements': updatedUserExpenseSettlements.map((settlement) => settlement.toJson()).toList(),
    });

    //check if settlementData tag has settlement, if yes, update it. if no, add it.
    Expense? tagExpense = await getTagExpense(settlementData.tagId!, expenseId, isSettlement: true) as Expense?;

    if (tagExpense == null) {
      final expenseData = userExpense.toFirestore();
      expenseData['ownerId'] = userId;
      expenseData['createdAt'] = FieldValue.serverTimestamp(); //UPDATED: Override with current time
      expenseData.remove('tagIds');
      expenseData['settlements'] = [settlementData.toJson()];

      batch.set(_firestore.collection('Tags').doc(settlementData.tagId).collection('Settlements').doc(expenseId), expenseData);
      print('addExpenseToTag: ${settlementData.tagId} did not have settlement, added ${settlementData.toJson()}');
    } else {
      batch.update(_firestore.collection('Tags').doc(settlementData.tagId).collection('Settlements').doc(expenseId), {
        'settlements': [settlementData.toJson()],
      });
      print('addExpenseToTag: ${settlementData.tagId} had settlements, over-rode with ${settlementData.toJson()}');
    }

    await batch.commit();
    return;
  }

  //update Tag
  if (tagId != null) {
    batch.update(_firestore.collection('Users').doc(userId).collection('Expenses').doc(expenseId), {
      'tagIds': FieldValue.arrayUnion([tagId]),
    });

    Expense? tagExpense = await getTagExpense(tagId, expenseId) as Expense?;

    if (tagExpense == null) {
      final expenseData = userExpense.toFirestore();
      expenseData['ownerId'] = userId;
      expenseData['createdAt'] = FieldValue.serverTimestamp();
      expenseData.remove('tagIds');
      expenseData.remove('settlements');

      batch.set(_firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId), expenseData);
      print('addExpenseToTag: Expense $expenseId added to tag $tagId');
    } else {
      // nothing to be done as Expense Doc already exists for the tag
      print('addExpenseToTag: Expense $expenseId already exists for $tagId .. ideally this should not happen.');
    }
  }

  await batch.commit();
}

Future<void> removeExpenseFromTag(String tagId, String expenseId, {bool isSettlement = false}) async {
  print("Inside removing tag from expense - tagId $tagId, expenseId $expenseId");

  final WriteBatch batch = _firestore.batch();

  // Delete from Tags/{tagId}/Settlements or Expenses
  batch.delete(_firestore.collection('Tags').doc(tagId).collection(isSettlement ? 'Settlements' : 'Expenses').doc(expenseId));

  final userId = await getUserIdFromClaim();
  if (userId == null) return;

  if (isSettlement) {
    // Remove settlement from User's Expense document
    Expense? userExpense = await getExpenseFromUserCollection(expenseId);
    if (userExpense != null) {
      List<SettlementEntry> settlements = userExpense.settlements.where((settlement) => settlement.tagId != tagId).toList();

      batch.update(_firestore.collection('Users').doc(userId).collection('Expenses').doc(expenseId), {
        'settlements': settlements.map((s) => s.toJson()).toList(),
      });
    }
  } else {
    // Remove tagId from User's Expense document
    batch.update(_firestore.collection('Users').doc(userId).collection('Expenses').doc(expenseId), {
      'tagIds': FieldValue.arrayRemove([tagId]),
    });
  }

  await batch.commit();
  print('${isSettlement ? 'Settlement' : 'Expense'} $expenseId removed from tag $tagId');
}

Future<Map<String, dynamic>?> getUserAccessibleTagsHavingExpense(String expenseId) async {
  try {
    final user = await getLoggedInUserData();
    if (user == null) return null;

    List<Tag> tags = [];
    List<SettlementEntry> settlements = [];

    // Check each accessible tag to see if this expense is in it
    for (String tagId in user.accessibleTagIds) {
      final tagExpenseDoc = await _firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId).get();

      if (tagExpenseDoc.exists) {
        final tag = await getTagData(tagId);
        tags.add(tag);
      }

      final settlementDoc = await _firestore.collection('Tags').doc(tagId).collection('Settlements').doc(expenseId).get();
      if (settlementDoc.exists) {
        Map<String, dynamic> settlementData = settlementDoc.data() as Map<String, dynamic>;
        settlementData = (settlementData['settlements'] as List<dynamic>)[0] as Map<String, dynamic>;
        print("SettlementData: id - ${settlementDoc.id}, data - $settlementData");

        settlementData['tagId'] = tagId;
        settlements.add(SettlementEntry.fromJson(settlementData));
      }
    }
    return {'tags': tags, 'settlements': settlements};
  } catch (e, stackTrace) {
    print('Error loading expense tags: $e, $stackTrace');
  }
  return null;
}

Future<Expense?> getExpenseFromUserCollection(String expenseId, {bool getExpenseTags = false}) async {
  String? userId = await getUserIdFromClaim();
  if (userId == null) return null;

  final expenseDoc = await _firestore.collection("Users").doc(userId).collection("Expenses").doc(expenseId).get();
  if (!expenseDoc.exists) return null;

  Expense expense = await Expense.getExpenseFromFirestoreObject(expenseId, expenseDoc.data()!);
  if (getExpenseTags && expense.tagIds != null && expense.tagIds!.isNotEmpty) {
    for (final tagId in expense.tagIds!) {
      expense.tags.add(await getTagData(tagId));
    }
  }
  return expense;
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

  // delete Expenses
  QuerySnapshot expenseDocsRef = await tagDocRef.collection("Expenses").get();

  for (var doc in expenseDocsRef.docs) {
    Expense expense = Expense.fromFirestoreObject(doc.id, doc.data() as Map<String, dynamic>, "");
    if (expense.ownerId! == userId) {
      //remove this tagId from the user's Expense doc
      batch.update(_firestore.collection("Users").doc(userId).collection('Expenses').doc(doc.id), {
        'tagIds': FieldValue.arrayRemove([tag.id]),
      });
    }
    batch.delete(doc.reference);
  }

  // delete Settlements
  QuerySnapshot settlementDocsRef = await tagDocRef.collection("Settlements").get();

  for (var doc in settlementDocsRef.docs) {
    Expense expense = Expense.fromFirestoreObject(doc.id, doc.data() as Map<String, dynamic>, "");
    if (expense.ownerId! == userId) {
      //extract settlement & remove it from User's Expense doc
      Expense? userExpense = await getExpenseFromUserCollection(doc.id);
      List<SettlementEntry> prunedSettlements = userExpense!.settlements;
      prunedSettlements.removeWhere((settlement) => settlement.tagId == tag.id);

      batch.update(_firestore.collection("Users").doc(userId).collection('Expenses').doc(doc.id), {
        'settlements': prunedSettlements.map((settlement) => settlement.toJson()),
      });
    }
    batch.delete(doc.reference);
  }

  // delete tag doc itself
  batch.delete(tagDocRef);

  // remove from accessible tag id of the user
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
      'tags': Tag.jsonEncodeTagsList([]),
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

/// Update WIPExpense with tags and settlement data
Future<void> updateWIPExpenseWithTagsAndSettlement(
  WIPExpense wipExpense,
  List<Tag> tags,
  List<SettlementEntry> settlement,
) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return;

  try {
    final updateData = {
      'tags': Tag.jsonEncodeTagsList(tags),
      'settlements': settlement.map((s) => s.toJson()).toList(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    await _firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpense.id).update(updateData);

    print('WIPExpense ${wipExpense.id} updated with tags and settlement');
  } catch (e, stackTrace) {
    print('Error updating WIPExpense: $e, $stackTrace');
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
Future<void> deleteWIPExpense(BaseExpense wipExpense) async {
  String wipExpenseId = wipExpense.id;
  String? receiptUrl = wipExpense.receiptUrl;
  String? localReceiptPath = wipExpense.localReceiptPath;

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

Future<List<QueryDocumentSnapshot<Object?>>> getUntaggedExpenseDocsOfUser(String userId) async {
  QuerySnapshot expensesSnapshot = await _firestore
      .collection("Users")
      .doc(userId)
      .collection('Expenses')
      .orderBy('timeOfTransaction', descending: true)
      .get();

  //check if expense is part of user's tags & if found, update tagIds
  KilvishUser? user = await getLoggedInUserData();
  if (user == null) throw Error();

  List<QueryDocumentSnapshot> returnDocs = [];

  for (final doc in expensesSnapshot.docs) {
    final data = doc.data() as Map<String, dynamic>;

    List<String>? tagIds = data["tagIds"] != null ? (data['tagIds'] as List<dynamic>).cast<String>() : null;

    if (tagIds == null) {
      //TODO - remove this code as this is to migrate existing users & populate tagIds in their Expenses
      tagIds = [];
      for (String tagId in user.accessibleTagIds) {
        final tagDoc = await _firestore.collection("Tags").doc(tagId).collection("Expenses").doc(doc.id).get();
        if (tagDoc.exists) {
          tagIds.add(tagId);
        }
      }
      if (tagIds.isNotEmpty) {
        print("Adding tagIds $tagIds to expense doc ${doc.id}");
        await _firestore.collection("Users").doc(userId).collection("Expenses").doc(doc.id).update({"tagIds": tagIds});
      }
    }

    bool isSettlementsEmpty =
        data['settlements'] == null || (data['settlements'] as List<dynamic>).cast<SettlementEntry>().isEmpty;

    if (tagIds.isEmpty && isSettlementsEmpty) {
      returnDocs.add(doc);
    }
  }

  return returnDocs;
}

Future<int> getUnseenExpenseCountForTag(String tagId, Set<String> unseenExpenseIds) async {
  if (unseenExpenseIds.isEmpty) return 0;

  final expensesSnapshot = await _firestore
      .collection('Tags')
      .doc(tagId)
      .collection('Expenses')
      .where(FieldPath.documentId, whereIn: unseenExpenseIds.toList())
      .get();

  return expensesSnapshot.docs.length;
}

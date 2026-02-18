import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:kilvish/firestore_common.dart';
import 'package:kilvish/firestore_expenses.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/model_expenses.dart';
import 'package:kilvish/model_tags.dart';

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

  DocumentReference tagRef = firestore.collection("Tags").doc(tagId);
  DocumentSnapshot<Map<String, dynamic>> tagDoc = await (tagRef.get()) as DocumentSnapshot<Map<String, dynamic>>;

  final tagData = tagDoc.data();
  //print("Got tagData for tagId $tagId - $tagData");

  Tag tag = Tag.fromFirestoreObject(tagDoc.id, tagData);
  if (includeMostRecentExpense != null) {
    tag.mostRecentExpense = await getMostRecentExpenseFromTag(tagDoc.id);
  }
  tagIdTagDataCache[tag.id] = tag;

  print("getTagData .. returning data fresh, not from cache ");
  return tag;
}

Future<Tag?> createOrUpdateTag(Map<String, Object> tagDataInput, String? tagId) async {
  String? ownerId = await getUserIdFromClaim();
  if (ownerId == null) return null;

  Map<String, Object> tagData = {'updatedAt': FieldValue.serverTimestamp()};
  tagData.addAll(tagDataInput);
  print("Dumping tagData in createOrUpdateTag $tagData");

  if (tagId != null) {
    await firestore.collection('Tags').doc(tagId).update(tagData);

    Tag tag = await getTagData(tagId, includeMostRecentExpense: true, invalidateCache: true);
    return tag;
  }

  // create new tag flow

  tagData.addAll({
    'createdAt': FieldValue.serverTimestamp(),
    'ownerId': ownerId,
    'total': {
      'acrossUsers': {'expense': 0, 'recovery': 0},
    },
    'monthWiseTotal': {},
  });

  WriteBatch batch = firestore.batch();

  DocumentReference tagDoc = firestore.collection('Tags').doc();
  batch.set(tagDoc, tagData);
  batch.update(firestore.collection("Users").doc(ownerId), {
    'accessibleTagIds': FieldValue.arrayUnion([tagDoc.id]),
  });
  batch.update(tagDoc, {'link': 'kilvish://tag/${tagDoc.id}'});

  await batch.commit();

  return getTagData(tagDoc.id, includeMostRecentExpense: true, invalidateCache: true);
}

Future<List<QueryDocumentSnapshot<Object?>>> getExpenseDocsOfUser(String userId) async {
  QuerySnapshot expensesSnapshot = await firestore
      .collection("Users")
      .doc(userId)
      .collection('Expenses')
      .orderBy('timeOfTransaction', descending: true)
      .get();

  return expensesSnapshot.docs;
}

Future<List<QueryDocumentSnapshot<Object?>>> getExpenseDocsUnderTag(String tagId, {bool isSettlement = false}) async {
  DocumentSnapshot<Map<String, dynamic>> tagDoc = await firestore.collection("Tags").doc(tagId).get();
  QuerySnapshot expensesSnapshot = await tagDoc.reference
      .collection(isSettlement ? 'Settlements' : 'Expenses')
      .orderBy('timeOfTransaction', descending: true)
      .get();

  return expensesSnapshot.docs;
}

Future<List<Expense>> getExpensesOfTag(String tagId, {bool isSettlement = false}) async {
  List<QueryDocumentSnapshot<Object?>> expenseDocs = await getExpenseDocsUnderTag(tagId, isSettlement: isSettlement);
  List<Expense> expenses = [];
  Tag tag = await getTagData(tagId);

  for (DocumentSnapshot doc in expenseDocs) {
    Expense expense = await Expense.getExpenseFromFirestoreObject(doc.id, doc.data() as Map<String, dynamic>);
    expense.tags.add(tag);
    expenses.add(expense);
  }
  return expenses;
}

Future<Expense?> getMostRecentExpenseFromTag(String tagId) async {
  DocumentSnapshot<Map<String, dynamic>> tagDoc = await firestore.collection("Tags").doc(tagId).get();
  QuerySnapshot<Map<String, dynamic>> expensesSnapshot = await tagDoc.reference
      .collection('Expenses')
      .orderBy('timeOfTransaction', descending: true)
      .limit(1)
      .get();

  if (expensesSnapshot.docs.isEmpty) return null;

  DocumentSnapshot expenseDoc = expensesSnapshot.docs[0];
  return Expense.getExpenseFromFirestoreObject(expenseDoc.id, expenseDoc.data() as Map<String, dynamic>);
}

Future<void> storeTagMonetarySummaryUpdate(Map<String, dynamic> data) async {
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

/// Handle tag shared - fetch and cache the tag document
Future<void> handleTagShared(Map<String, dynamic> data) async {
  try {
    final tagId = data['tagId'] as String?;

    if (tagId == null) {
      print('Invalid tag_shared data in FCM payload');
      return;
    }

    print('Tag shared notification received: $tagId - fetching tag data');

    // Fetch the tag document from server and cache it locally
    await getTagData(tagId);

    print('Tag data fetched and cached: $tagId');
  } catch (e, stackTrace) {
    print('Error fetching shared tag: $e $stackTrace');
  }
}

/// Handle tag removed - delete tag and all its expenses from local cache
Future<void> handleTagRemoved(Map<String, dynamic> data) async {
  try {
    final tagId = data['tagId'] as String?;

    if (tagId == null) {
      print('Invalid tag_removed data in FCM payload');
      return;
    }

    print('Tag access removed: $tagId - removing from local cache');

    // First, delete all expenses under this tag
    final tagRef = firestore.collection('Tags').doc(tagId);
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
      print('Deleted expense from cache: ${expenseDoc.id}');
    }

    // Then delete the tag document itself
    final tagDoc = await tagRef.get();
    tagDoc.reference.delete();

    tagIdTagDataCache.remove(tagId);

    print('Tag and its expenses removed from local cache: $tagId');
  } catch (e, stackTrace) {
    print('Error removing tag from cache: $e $stackTrace');
  }
}

Future<void> deleteTag(Tag tag) async {
  String? userId = await getUserIdFromClaim();
  if (userId == null) return;

  final WriteBatch batch = firestore.batch();

  DocumentReference tagDocRef = firestore.collection("Tags").doc(tag.id);

  // delete Expenses
  QuerySnapshot expenseDocsRef = await tagDocRef.collection("Expenses").get();

  for (var doc in expenseDocsRef.docs) {
    Expense expense = Expense.fromFirestoreObject(doc.id, doc.data() as Map<String, dynamic>, "");
    if (expense.ownerId! == userId) {
      //remove this tagId from the user's Expense doc
      batch.update(firestore.collection("Users").doc(userId).collection('Expenses').doc(doc.id), {
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

      batch.update(firestore.collection("Users").doc(userId).collection('Expenses').doc(doc.id), {
        'settlements': prunedSettlements.map((settlement) => settlement.toJson()),
      });
    }
    batch.delete(doc.reference);
  }

  // delete tag doc itself
  batch.delete(tagDocRef);

  // remove from accessible tag id of the user
  DocumentReference userDocRef = firestore.collection("Users").doc(userId);
  batch.update(userDocRef, {
    'accessibleTagIds': FieldValue.arrayRemove([tag.id]),
  });

  await batch.commit();
  print("Successfully deleted ${tag.name}");
}

Future<int> getUnseenExpenseCountForTag(String tagId, Set<String> unseenExpenseIds) async {
  if (unseenExpenseIds.isEmpty) return 0;

  final expensesSnapshot = await firestore
      .collection('Tags')
      .doc(tagId)
      .collection('Expenses')
      .where(FieldPath.documentId, whereIn: unseenExpenseIds.toList())
      .get();

  return expensesSnapshot.docs.length;
}

Future<BaseExpense?> getTagExpense(String tagId, String expenseId, {bool isSettlement = false}) async {
  final doc = await firestore
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

Future<void> addExpenseOrSettlementToTag(
  String expenseId, {
  String? tagId,
  SettlementEntry? settlementData,
  RecoveryEntry? recoveryData,
}) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return;

  Expense? userExpense = await getExpenseFromUserCollection(expenseId);
  if (userExpense == null) return;

  final expenseDocInUserCollection = firestore.collection('Users').doc(userId).collection('Expenses').doc(expenseId);
  final WriteBatch batch = firestore.batch();

  if (settlementData != null) {
    List<SettlementEntry> updatedUserExpenseSettlements = userExpense.settlements
        .map((settlement) => settlement.tagId == settlementData.tagId! ? settlementData : settlement)
        .toList();

    // user did not have any settlements originally
    if (updatedUserExpenseSettlements.isEmpty) updatedUserExpenseSettlements = [settlementData];

    batch.update(expenseDocInUserCollection, {
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

      batch.set(firestore.collection('Tags').doc(settlementData.tagId).collection('Settlements').doc(expenseId), expenseData);
      print('addExpenseOrSettlementToTag: ${settlementData.tagId} did not have settlement, added ${settlementData.toJson()}');
    } else {
      batch.update(firestore.collection('Tags').doc(settlementData.tagId).collection('Settlements').doc(expenseId), {
        'settlements': [settlementData.toJson()],
      });
      print('addExpenseOrSettlementToTag: ${settlementData.tagId} had settlements, over-rode with ${settlementData.toJson()}');
    }

    await batch.commit();
    return;
  }

  //update Tag
  if (tagId == null) {
    //nothing to do for tag ..
    return;
  }

  if (recoveryData != null) {
    // add recovery to user document
    List<RecoveryEntry> recoveries = userExpense.recoveries
        .map((recovery) => recovery.tagId == recoveryData.tagId ? recoveryData : recovery)
        .toList();

    if (recoveries.isEmpty) recoveries = [recoveryData];

    batch.update(expenseDocInUserCollection, {'recoveries': recoveries.map((recovery) => recovery.toJson()).toList()});
  } else {
    //add tagId to User's document
    batch.update(expenseDocInUserCollection, {
      'tagIds': FieldValue.arrayUnion([tagId]),
    });
  }

  // fetch expense document of the tag
  Expense? tagExpense = await getTagExpense(tagId, expenseId) as Expense?;

  if (tagExpense == null) {
    //create new expense document for the tag
    final expenseData = userExpense.toFirestore();
    expenseData['ownerId'] = userId;
    expenseData['createdAt'] = FieldValue.serverTimestamp();
    expenseData.remove('tagIds');
    expenseData.remove('settlements');
    expenseData.remove('recoveries'); // NEW: Remove recoveries array
    if (recoveryData != null) {
      expenseData['recoveryAmount'] = recoveryData.amount;
    }

    batch.set(firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId), expenseData);
    print('addExpenseOrSettlementToTag: Expense $expenseId added to tag $tagId with recoveryAmount: ${recoveryData?.amount}');

    await batch.commit();
    return;
  }

  // Expense already exists in tag - update recoveryAmount if changed
  final recoveryForThisTag = userExpense.recoveries.where((r) => r.tagId == tagId).firstOrNull;
  if (recoveryForThisTag != null) {
    batch.update(firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId), {
      'recoveryAmount': recoveryForThisTag.amount,
    });
  } else {
    // Remove recoveryAmount if no longer tracking recovery for this tag
    batch.update(firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId), {
      'recoveryAmount': FieldValue.delete(),
    });
  }
  print('addExpenseOrSettlementToTag: Updated $expenseId added to tag $tagId with recoveryAmount: ${recoveryForThisTag?.amount}');

  await batch.commit();
  return;
}

Future<void> removeExpenseFromTag(String tagId, String expenseId, {bool isSettlement = false}) async {
  print("Inside removing tag from expense - tagId $tagId, expenseId $expenseId");

  final WriteBatch batch = firestore.batch();

  // Delete from Tags/{tagId}/Settlements or Expenses
  batch.delete(firestore.collection('Tags').doc(tagId).collection(isSettlement ? 'Settlements' : 'Expenses').doc(expenseId));

  final userId = await getUserIdFromClaim();
  if (userId == null) return;

  if (isSettlement) {
    // Remove settlement from User's Expense document
    Expense? userExpense = await getExpenseFromUserCollection(expenseId);
    if (userExpense != null) {
      List<SettlementEntry> settlements = userExpense.settlements.where((settlement) => settlement.tagId != tagId).toList();

      batch.update(firestore.collection('Users').doc(userId).collection('Expenses').doc(expenseId), {
        'settlements': settlements.map((s) => s.toJson()).toList(),
      });
    }
  } else {
    // Remove tagId from User's Expense document
    batch.update(firestore.collection('Users').doc(userId).collection('Expenses').doc(expenseId), {
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
      final tagExpenseDoc = await firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId).get();

      if (tagExpenseDoc.exists) {
        final tag = await getTagData(tagId);
        tags.add(tag);
      }

      final settlementDoc = await firestore.collection('Tags').doc(tagId).collection('Settlements').doc(expenseId).get();
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

Future<String> createRecoveryTag({required String tagName, required String wipExpenseId}) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) throw Exception('User not authenticated');

  final WriteBatch batch = firestore.batch();

  // 1. Create Recovery Tag with same ID as WIPExpense for easy cross-referencing
  final tagDoc = firestore.collection('Tags').doc(wipExpenseId);
  final tagId = tagDoc.id;

  final tagData = {
    'name': tagName,
    'ownerId': userId,
    'isRecoveryExpense': true,
    'link': 'kilvish://tag/$tagId',
    'sharedWith': [],
    'total': {
      'acrossUsers': {'expense': 0, 'recovery': 0},
      userId: {'expense': 0, 'recovery': 0},
    },
    'monthWiseTotal': {},
    'createdAt': FieldValue.serverTimestamp(),
  };
  batch.set(tagDoc, tagData);

  // 2. Update user's accessibleTagIds
  batch.update(firestore.collection('Users').doc(userId), {
    'accessibleTagIds': FieldValue.arrayUnion([tagId]),
  });

  await batch.commit();

  return tagId;
}

Future<Map<String, dynamic>> joinTagViaUrl(String tagId) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) throw Exception('User not authenticated');

  final tagDoc = await firestore.collection('Tags').doc(tagId).get();
  if (!tagDoc.exists) throw Exception('Tag not found');

  final tagData = tagDoc.data()!;
  final sharedWith = List<String>.from(tagData['sharedWith'] ?? []);

  if (sharedWith.contains(userId)) {
    return {'success': true, 'message': 'Already a member', 'tagName': tagData['name']};
  }

  final batch = firestore.batch();

  batch.update(firestore.collection('Tags').doc(tagId), {
    'sharedWith': FieldValue.arrayUnion([userId]),
  });

  batch.update(firestore.collection('Users').doc(userId), {
    'accessibleTagIds': FieldValue.arrayUnion([tagId]),
  });

  await batch.commit();
  return {'success': true, 'message': 'Successfully joined tag', 'tagName': tagData['name']};
}

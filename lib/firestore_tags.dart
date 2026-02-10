import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:kilvish/firestore_common.dart';
import 'package:kilvish/firestore_expenses.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/models_tags.dart';

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

    Tag tag = await getTagData(tagId, invalidateCache: true);
    return tag;
  }

  // create new tag flow
  DocumentReference tagDoc = firestore.collection('Tags').doc();

  tagData.addAll({
    'createdAt': FieldValue.serverTimestamp(),
    'ownerId': ownerId,
    'link': 'kilvish://tag/${tagDoc.id}', // Generate shareable link
    'allowRecovery': tagData['allowRecovery'] ?? false,
    'isRecovery': tagData['isRecovery'] ?? false,
    'sharedWith': [ownerId], // Owner is always in sharedWith
    'totalTillDate': {'expense': 0, 'recovery': 0}, // Unified structure
    'monthWiseTotal': {},
    'userWiseTotal': {},
  });

  WriteBatch batch = firestore.batch();

  batch.set(tagDoc, tagData);
  batch.update(firestore.collection("Users").doc(ownerId), {
    'accessibleTagIds': FieldValue.arrayUnion([tagDoc.id]),
  });

  await batch.commit();

  return getTagData(tagDoc.id, invalidateCache: true);
}

/// Creates a Recovery Tag and attaches the expense to it atomically
/// Returns the created tag or null if failed
Future<Tag?> createRecoveryTag({
  required String recoveryName,
  required String expenseId,
  required double recoveryAmount,
  required Map<String, Object?> expenseData,
}) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return null;

  final WriteBatch batch = firestore.batch();

  // 1. Create Recovery Tag
  final tagDoc = firestore.collection('Tags').doc();
  final tagData = {
    'name': recoveryName,
    'ownerId': userId,
    'allowRecovery': true,
    'isRecovery': true,
    'link': 'kilvish://tag/${tagDoc.id}',
    'sharedWith': [userId],
    'totalTillDate': {'expense': 0, 'recovery': 0},
    'monthWiseTotal': {},
    'userWiseTotal': {},
    'createdAt': FieldValue.serverTimestamp(),
  };
  batch.set(tagDoc, tagData);

  // 2. Update user's accessibleTagIds
  batch.update(firestore.collection('Users').doc(userId), {
    'accessibleTagIds': FieldValue.arrayUnion([tagDoc.id]),
  });

  // 3. Add expense to User's collection with recoveries array
  final recoveryEntry = {'tagId': tagDoc.id, 'amount': recoveryAmount};
  batch.update(firestore.collection('Users').doc(userId).collection('Expenses').doc(expenseId), {
    'tagIds': FieldValue.arrayUnion([tagDoc.id]),
    'recoveries': FieldValue.arrayUnion([recoveryEntry]),
  });

  // 4. Add expense to Tag's Expenses collection with recoveryAmount
  final expenseDataForTag = Map<String, dynamic>.from(expenseData);
  expenseDataForTag['ownerId'] = userId;
  expenseDataForTag['recoveryAmount'] = recoveryAmount;
  expenseDataForTag.remove('tagIds');
  expenseDataForTag.remove('settlements');
  expenseDataForTag.remove('recoveries');

  batch.set(firestore.collection('Tags').doc(tagDoc.id).collection('Expenses').doc(expenseId), expenseDataForTag);

  await batch.commit();

  // Fetch and return the created tag
  return await getTagData(tagDoc.id);
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

Future<List<QueryDocumentSnapshot<Object?>>> getExpenseDocsUnderTag(String tagId) async {
  DocumentSnapshot<Map<String, dynamic>> tagDoc = await firestore.collection("Tags").doc(tagId).get();
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
  DocumentSnapshot<Map<String, dynamic>> tagDoc = await firestore.collection("Tags").doc(tagId).get();
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

/// Handle expense created or updated - cache to local Firestore
Future<void> handleExpenseCreatedOrUpdated(Map<String, dynamic> data, {String collection = "Expenses"}) async {
  try {
    final tagId = data['tagId'] as String?;
    final expenseId = data['expenseId'] as String?;
    final expenseString = data['expense'] as String?;

    if (tagId == null || expenseId == null || expenseString == null) {
      print('Invalid expense data in FCM payload');
      return;
    }

    final expenseRef = firestore.collection('Tags').doc(tagId).collection(collection).doc(expenseId);
    await expenseRef.get();

    print('Local cache for $expenseId updated');

    // Mark expense as unseen for current user
    await markExpenseAsUnseen(expenseId);
  } catch (e, stackTrace) {
    print('Error caching expense: $e $stackTrace');
  }
}

/// Handle expense deleted - remove from local cache
Future<void> handleExpenseDeleted(Map<String, dynamic> data, {String collection = "Expenses"}) async {
  try {
    final tagId = data['tagId'] as String?;
    final expenseId = data['expenseId'] as String?;

    if (tagId == null || expenseId == null) {
      print('Invalid delete data in FCM payload');
      return;
    }

    // Remove from local Firestore cache
    final expenseDocRef = firestore.collection('Tags').doc(tagId).collection(collection).doc(expenseId);

    try {
      await (await expenseDocRef.get()).reference.delete();
    } catch (e) {
      print("Trying to delete $expenseId' .. ignore this error ");
    }
    print('successfully deleted referenced to $expenseId');

    // Remove from unseen expenses
    //TODO - this expense could be in other tags too, handle this in future
    await markExpenseAsSeen(expenseId);

    print('Expense deleted from local cache: $expenseId');
  } catch (e, stackTrace) {
    print('Error deleting expense from cache: $e $stackTrace');
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
    print('Error removing tag from cache: $e, $stackTrace');
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

Future<void> updateLastLoginOfUser(String userId) async {
  final publicInfoRef = firestore.collection("PublicInfo").doc(userId);
  final publicInfoDoc = await publicInfoRef.get();
  if (!publicInfoDoc.exists) return;

  await publicInfoRef.update({'lastLogin': FieldValue.serverTimestamp()});
  print("lastLogin updated for $userId");
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

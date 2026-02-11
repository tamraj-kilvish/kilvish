import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:kilvish/firestore_tags.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/models_tags.dart';
import 'package:kilvish/firestore_common.dart';

Future<Expense?> updateExpense(
  Map<String, Object?> expenseData,
  BaseExpense expense, { // NEW
  WriteBatch? batch, // NEW - optional batch
}) async {
  final String? userId = await getUserIdFromClaim();
  if (userId == null) return null;

  Set<Tag> tags = expense.tags;
  List<SettlementEntry>? settlements = expense.settlements;
  List<RecoveryEntry>? recoveries = expense.recoveries;

  CollectionReference userExpensesRef = firestore.collection('Users').doc(userId).collection("Expenses");

  final WriteBatch writeBatch = batch ?? firestore.batch(); // Use provided or create new

  DocumentReference userDocRef = firestore.collection("Users").doc(userId);
  writeBatch.update(userDocRef, {
    'txIds': FieldValue.arrayUnion([expenseData['txId']]),
  });

  if (expense is Expense) {
    writeBatch.update(userExpensesRef.doc(expense.id), expenseData);
    writeBatch.update(userDocRef, {
      'txIds': FieldValue.arrayRemove([expense.txId]),
    });
  }

  if (expense is WIPExpense) {
    List<String> tagIds = tags.map((t) => t.id).toList();
    final settlementJsonList = settlements?.map((s) => s.toJson()).toList();
    final recoveryJsonList = recoveries?.map((r) => r.toJson()).toList();

    // Create new Expense
    writeBatch.set(userExpensesRef.doc(expense.id), {
      ...expenseData,
      'tagIds': tagIds,
      'settlements': settlementJsonList,
      'recoveries': recoveryJsonList,
    });

    // Delete WIPExpense
    writeBatch.delete(firestore.collection('Users').doc(userId).collection("WIPExpenses").doc(expense.id));

    final expenseDataWithOwnerId = {...expenseData, 'ownerId': userId};

    // Handle regular tag expenses
    if (tags.isNotEmpty) {
      for (var tag in tags) {
        final data = Map<String, dynamic>.from(expenseDataWithOwnerId);

        // Add recoveryAmount if this tag has a recovery entry
        final recoveryEntry = recoveries?.where((r) => r.tagId == tag.id).firstOrNull;
        if (recoveryEntry != null) {
          data['recoveryAmount'] = recoveryEntry.amount;
        }

        writeBatch.set(firestore.collection('Tags').doc(tag.id).collection('Expenses').doc(expense.id), data);
      }
    }

    // Handle settlements
    if (settlements != null && settlements.isNotEmpty) {
      for (var settlement in settlements) {
        writeBatch.set(firestore.collection('Tags').doc(settlement.tagId).collection('Settlements').doc(expense.id), {
          ...expenseDataWithOwnerId,
          "settlements": [settlement.toJson()],
        });
      }
    }

    // Handle recoveries (goes to Tag/Expenses with recoveryAmount)
    if (recoveries != null && recoveries.isNotEmpty) {
      for (var recovery in recoveries) {
        // Skip if already handled in tags loop above
        if (tags.any((t) => t.id == recovery.tagId)) continue;

        final data = Map<String, dynamic>.from(expenseDataWithOwnerId);
        data['recoveryAmount'] = recovery.amount;

        writeBatch.set(firestore.collection('Tags').doc(recovery.tagId).collection('Expenses').doc(expense.id), data);
      }
    }
  }

  await writeBatch.commit();

  Expense? newExpense = await getExpenseFromUserCollection(expense.id);
  if (newExpense != null) {
    if (tags.isNotEmpty) newExpense.tags = tags;
    if (settlements.isNotEmpty) newExpense.settlements = settlements;
    if (recoveries.isNotEmpty) newExpense.recoveries = recoveries;
  }
  return newExpense;
}

/// Function called when a new/updated expense is send to user via FCM
Future<void> markExpenseAsUnseen(String expenseId) async {
  print('marking $expenseId as unseen');
  try {
    final userId = await getUserIdFromClaim();
    if (userId == null) return;

    await firestore.collection('Users').doc(userId).update({
      'unseenExpenseIds': FieldValue.arrayUnion([expenseId]),
    });

    print('Expense marked as unseen: $expenseId');
  } catch (e, stackTrace) {
    print('Error marking expense as unseen: $e $stackTrace');
  }
}

///Called when user views the Expense in Expense Detail Screen
Future<void> markExpenseAsSeen(String expenseId) async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return;

  await firestore.collection('Users').doc(userId).update({
    'unseenExpenseIds': FieldValue.arrayRemove([expenseId]),
  });

  print('Expense marked as seen: $expenseId');
}

Future<Expense?> getExpenseFromUserCollection(String expenseId, {bool getExpenseTags = false}) async {
  String? userId = await getUserIdFromClaim();
  if (userId == null) return null;

  final expenseDoc = await firestore.collection("Users").doc(userId).collection("Expenses").doc(expenseId).get();
  if (!expenseDoc.exists) return null;

  Expense expense = await Expense.getExpenseFromFirestoreObject(expenseId, expenseDoc.data()!);
  if (getExpenseTags && expense.tagIds != null && expense.tagIds!.isNotEmpty) {
    for (final tagId in expense.tagIds!) {
      expense.tags.add(await getTagData(tagId));
    }
  }
  return expense;
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

  final WriteBatch batch = firestore.batch();

  if (settlementData != null) {
    List<SettlementEntry> updatedUserExpenseSettlements = userExpense.settlements
        .map((settlement) => settlement.tagId == settlementData.tagId! ? settlementData : settlement)
        .toList();

    // user did not have any settlements originally
    if (updatedUserExpenseSettlements.isEmpty) updatedUserExpenseSettlements = [settlementData];

    batch.update(firestore.collection('Users').doc(userId).collection('Expenses').doc(expenseId), {
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
      print('addExpenseToTag: ${settlementData.tagId} did not have settlement, added ${settlementData.toJson()}');
    } else {
      batch.update(firestore.collection('Tags').doc(settlementData.tagId).collection('Settlements').doc(expenseId), {
        'settlements': [settlementData.toJson()],
      });
      print('addExpenseToTag: ${settlementData.tagId} had settlements, over-rode with ${settlementData.toJson()}');
    }

    await batch.commit();
    return;
  }

  //update Tag
  if (tagId != null) {
    batch.update(firestore.collection('Users').doc(userId).collection('Expenses').doc(expenseId), {
      'tagIds': FieldValue.arrayUnion([tagId]),
    });

    Expense? tagExpense = await getTagExpense(tagId, expenseId) as Expense?;

    if (tagExpense == null) {
      final expenseData = userExpense.toFirestore();
      expenseData['ownerId'] = userId;
      expenseData['createdAt'] = FieldValue.serverTimestamp();
      expenseData.remove('tagIds');
      expenseData.remove('settlements');

      batch.set(firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId), expenseData);
      print('addExpenseToTag: Expense $expenseId added to tag $tagId');
    } else {
      // nothing to be done as Expense Doc already exists for the tag
      print('addExpenseToTag: Expense $expenseId already exists for $tagId .. ideally this should not happen.');
    }

    await batch.commit();
    return;
  }

  if (recoveryData != null) {
    // Update User's Expense with recovery entry
    List<RecoveryEntry> recoveries = userExpense.recoveries;

    if (recoveries.isEmpty) {
      recoveries.add(recoveryData);
    } else {
      bool found = false;

      recoveries = recoveries.map((recovery) {
        if (recovery.tagId == recoveryData.tagId) {
          found = true;
          return recoveryData;
        } else {
          return recovery;
        }
      }).toList();

      if (!found) {
        recoveries.add(recoveryData);
      }
    }

    batch.update(firestore.collection('Users').doc(userId).collection('Expenses').doc(expenseId), {
      'recoveries': recoveries.map((r) => r.toJson()).toList(),
    });

    // Check if recovery exists in tag
    Expense? tagExpense = await getTagExpense(recoveryData.tagId, expenseId) as Expense?;

    if (tagExpense == null) {
      final expenseData = userExpense.toFirestore();
      expenseData['ownerId'] = userId;
      expenseData['createdAt'] = FieldValue.serverTimestamp();
      expenseData.remove('tagIds');
      expenseData.remove('settlements');
      expenseData['recoveryAmount'] = recoveryData.amount;

      batch.set(firestore.collection('Tags').doc(recoveryData.tagId).collection('Expenses').doc(expenseId), expenseData);
      print('addExpenseToTag: Added recovery to tag ${recoveryData.tagId}');
    } else {
      batch.update(firestore.collection('Tags').doc(recoveryData.tagId).collection('Expenses').doc(expenseId), {
        'recoveryAmount': recoveryData.amount,
      });
      print('addExpenseToTag: Updated recovery amount for tag ${recoveryData.tagId}');
    }

    await batch.commit();
    return;
  }
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

Future<void> deleteExpense(Expense expense) async {
  String? userId = await getUserIdFromClaim();
  if (userId == null) return;

  final WriteBatch batch = firestore.batch();

  DocumentReference expenseDoc = firestore.collection("Users").doc(userId).collection("Expenses").doc(expense.id);
  DocumentSnapshot expenseDocSnapshot = await expenseDoc.get();
  if (!expenseDocSnapshot.exists) {
    print("Tried to delete Expense ${expense.id} but it does not exist in User -> Expenses");
  } else {
    // add to batch
    batch.delete(expenseDoc);
    print("${expense.id} scheduled to be deleted from User -> Expenses collection");
  }

  for (Tag tag in expense.tags) {
    expenseDoc = firestore.collection("Tags").doc(tag.id).collection("Expenses").doc(expense.id);
    expenseDocSnapshot = await expenseDoc.get();
    if (!expenseDocSnapshot.exists) {
      print("Tried to delete Expense ${expense.id} from ${tag.name} but it does not exist in Tag -> Expenses");
    } else {
      // add to batch
      batch.delete(expenseDoc);
      print("${expense.id} scheduled to be deleted from ${tag.name} -> Expenses collection");
    }
  }

  batch.update(firestore.collection("Users").doc(userId), {
    //remove old txId form user
    'txIds': FieldValue.arrayRemove([expense.txId]),
  });

  await batch.commit();

  //no awaits for below two operations
  markExpenseAsSeen(expense.id);
  deleteReceipt(expense.receiptUrl);

  print("Successfully deleted ${expense.id}");
}

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

    final docRef = await firestore.collection('Users').doc(user.id).collection('WIPExpenses').add(wipExpenseData);

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

    await firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpenseId).update(updateData);

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

    await firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpense.id).update(updateData);

    print('WIPExpense ${wipExpense.id} updated with tags and settlement');
  } catch (e, stackTrace) {
    print('Error updating WIPExpense: $e, $stackTrace');
  }
}

Future<bool> attachReceiptURLtoWIPExpense(String wipExpenseId, String receiptUrl) async {
  try {
    final userId = await getUserIdFromClaim();
    if (userId == null) return false;

    DocumentReference wipExpenseDoc = firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpenseId);

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

    DocumentReference wipExpenseDoc = firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpenseId);

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
    final snapshot = await firestore
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
    final doc = await firestore.collection('Users').doc(user.id).collection('WIPExpenses').doc(wipExpenseId).get();

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
    final WriteBatch batch = firestore.batch();

    final expenseDoc = firestore.collection('Users').doc(userId).collection('Expenses').doc(expense.id);
    batch.delete(expenseDoc);

    if (expense.tags.isNotEmpty) {
      expense.tags.map((Tag tag) {
        batch.delete(firestore.collection('Tags').doc(tag.id));
      });
    }

    WIPExpense wipExpense = WIPExpense.fromExpense(expense);

    batch.set(firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(expense.id), wipExpense.toFirestore());

    await batch.commit();

    print("${expense.id} is now converted to WIPExpense from Expense for user $userId");

    return wipExpense;

    // // Create expense with the same ID as WIPExpense
    // await firestore.collection('Users').doc(userId).collection('Expenses').doc(wipExpenseId).set(expenseData);

    // // If tags are provided, add to tags
    // if (tags != null && tags.isNotEmpty) {
    //   await addOrUpdateUserExpense(expenseData, wipExpenseId, tags);
    // }

    // // Delete WIPExpense
    // await firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpenseId).delete();

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
    firestore.collection('Users').doc(userId).collection('WIPExpenses').doc(wipExpenseId).delete().then((value) async {
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
    final snapshot = await firestore
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
  QuerySnapshot expensesSnapshot = await firestore
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
        final tagDoc = await firestore.collection("Tags").doc(tagId).collection("Expenses").doc(doc.id).get();
        if (tagDoc.exists) {
          tagIds.add(tagId);
        }
      }
      if (tagIds.isNotEmpty) {
        print("Adding tagIds $tagIds to expense doc ${doc.id}");
        await firestore.collection("Users").doc(userId).collection("Expenses").doc(doc.id).update({"tagIds": tagIds});
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

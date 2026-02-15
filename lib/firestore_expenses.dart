import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:kilvish/firestore_common.dart';
import 'package:kilvish/firestore_tags.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/model_expenses.dart';
import 'package:kilvish/model_tags.dart';
import 'package:kilvish/model_user.dart';

Future<Expense?> updateExpense(
  Map<String, Object?> expenseData,
  BaseExpense expense,
  Set<Tag> tags,
  List<SettlementEntry>? settlements,
) async {
  final String? userId = await getUserIdFromClaim();
  if (userId == null) return null;

  CollectionReference userExpensesRef = firestore.collection('Users').doc(userId).collection("Expenses");

  final WriteBatch batch = firestore.batch();

  DocumentReference userDocRef = firestore.collection("Users").doc(userId);
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
    batch.delete(firestore.collection('Users').doc(userId).collection("WIPExpenses").doc(expense.id));

    final expenseDataWithOwnerId = {...expenseData, 'ownerId': userId};

    if (tags.isNotEmpty) {
      final tagExpensesDocs = tags
          .map((tag) => firestore.collection('Tags').doc(tag.id).collection("Expenses").doc(expense.id))
          .toList();

      tagExpensesDocs.forEach((expenseDoc) => batch.set(expenseDoc, expenseDataWithOwnerId));
    }

    // Handle settlements - add to Tags/{tagId}/Settlements collection
    if (settlements != null && settlements.isNotEmpty) {
      for (var settlement in settlements) {
        final expenseDoc = firestore.collection('Tags').doc(settlement.tagId).collection('Settlements').doc(expense.id);
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

//WIP Expenses

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

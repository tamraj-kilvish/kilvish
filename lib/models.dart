import 'package:cloud_firestore/cloud_firestore.dart';

class KilvishUser {
  final String id;
  final String uid;
  final String phone;
  Set<String> accessibleTagIds = {};
  Set<String> unseenExpenseIds = {};
  String? kilvishId;
  DateTime? updatedAt;
  String? fcmToken;
  DateTime? fcmTokenUpdatedAt;

  KilvishUser({
    required this.id,
    required this.uid,
    required this.phone,
    this.kilvishId,
    this.updatedAt,
    this.fcmToken,
    this.fcmTokenUpdatedAt,
  });

  factory KilvishUser.fromFirestoreObject(Map<String, dynamic>? firestoreUser) {
    print("Dumping firestoreUser ${firestoreUser}");

    KilvishUser user = KilvishUser(
      id: firestoreUser?['id'],
      uid: firestoreUser?['uid'],
      phone: firestoreUser?['phone'],
      kilvishId: firestoreUser?['kilvishId'] != null
          ? (firestoreUser?['kilvishId'] as String?)
          : null,
      updatedAt: firestoreUser?['updatedAt'] != null
          ? (firestoreUser?['updatedAt'] as Timestamp).toDate() as DateTime?
          : null,
      fcmToken: firestoreUser?['fcmToken'] != null
          ? (firestoreUser?['fcmToken'] as String?)
          : null,
      fcmTokenUpdatedAt: firestoreUser?['fcmTokenUpdatedAt'] != null
          ? (firestoreUser?['fcmTokenUpdatedAt'] as Timestamp).toDate()
                as DateTime?
          : null,
    );

    // Parse accessibleTagIds
    if (firestoreUser?['accessibleTagIds'] != null) {
      List<dynamic> dynamicList =
          firestoreUser?['accessibleTagIds'] as List<dynamic>;
      final List<String> stringList = dynamicList.cast<String>();
      user.accessibleTagIds = stringList.toSet();
    }

    // Parse unseenExpenseIds
    if (firestoreUser?['unseenExpenseIds'] != null) {
      List<dynamic> dynamicList =
          firestoreUser?['unseenExpenseIds'] as List<dynamic>;
      final List<String> stringList = dynamicList.cast<String>();
      user.unseenExpenseIds = stringList.toSet();
    }

    return user;
  }
}

typedef MonthwiseAggregatedExpense = Map<num, Map<num, num>>;

class Tag {
  String id;
  String name;
  final String ownerId;
  Set<String> sharedWith = {};
  num totalAmountTillDate = 0;
  MonthwiseAggregatedExpense monthWiseTotal = {};

  Tag({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.totalAmountTillDate,
    required this.monthWiseTotal,
  });

  factory Tag.fromFirestoreObject(
    String tagId,
    Map<String, dynamic>? firestoreTag,
  ) {
    Map<String, dynamic> rawTags = firestoreTag?['monthWiseTotal'];
    MonthwiseAggregatedExpense monthWiseTotal = {};
    rawTags.forEach((key, value) {
      num? outerKey = num.tryParse(key);
      if (outerKey != null && value is Map<String, dynamic>) {
        Map<num, num> innerMap = {};
        value.forEach((innerKey, innerValue) {
          num? parsedInnerKey = num.tryParse(innerKey);
          if (parsedInnerKey != null && innerValue is num) {
            innerMap[parsedInnerKey] = innerValue;
          }
        });
        monthWiseTotal[outerKey] = innerMap;
      }
    });

    Tag tag = Tag(
      id: tagId,
      name: firestoreTag?['name'],
      ownerId: firestoreTag?['ownerId'],
      totalAmountTillDate: firestoreTag?['totalAmountTillDate'] as num,
      monthWiseTotal: monthWiseTotal,
    );

    // Parse sharedWith if present
    if (firestoreTag?['sharedWith'] != null) {
      List<dynamic> dynamicList = firestoreTag?['sharedWith'] as List<dynamic>;
      final List<String> stringList = dynamicList.cast<String>();
      tag.sharedWith = stringList.toSet();
    }

    return tag;
  }

  // Override equality and hashCode for Set operations
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Tag && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

class Expense {
  final String id;
  final String txId;
  final String to;
  final DateTime timeOfTransaction;
  final DateTime updatedAt;
  final num amount;
  String? notes;
  String? receiptUrl;
  Set<Tag> tags = {};
  bool isUnseen =
      false; // Derived field - set when loading based on User's unseenExpenseIds

  Expense({
    required this.id,
    required this.txId,
    required this.to,
    required this.timeOfTransaction,
    required this.amount,
    required this.updatedAt,
    this.isUnseen = false,
  });

  factory Expense.fromFirestoreObject(
    String expenseId,
    Map<String, dynamic> firestoreExpense,
  ) {
    Expense expense = Expense(
      id: expenseId,
      to: firestoreExpense['to'] as String,
      timeOfTransaction: (firestoreExpense['timeOfTransaction'] as Timestamp)
          .toDate(),
      updatedAt: (firestoreExpense['updatedAt'] as Timestamp).toDate(),
      amount: firestoreExpense['amount'] as num,
      txId: firestoreExpense['txId'] as String,
    );
    if (firestoreExpense['notes'] != null) {
      expense.notes = firestoreExpense['notes'] as String;
    }
    if (firestoreExpense['receiptUrl'] != null) {
      expense.receiptUrl = firestoreExpense['receiptUrl'] as String;
    }

    return expense;
  }

  void addTagToExpense(Tag tag) {
    tags.add(tag);
  }

  // Mark this expense as seen (updates local state only)
  void markAsSeen() {
    isUnseen = false;
  }

  // Set unseen status based on User's unseenExpenseIds
  void setUnseenStatus(Set<String> unseenExpenseIds) {
    isUnseen = unseenExpenseIds.contains(id);
  }
}

enum HomePageItemType { tag, url }

enum TagStatus { selected, unselected }

class ExpenseTag {
  final Tag tag;
  final Expense expense;
  final bool isSaved;
  const ExpenseTag({
    required this.tag,
    required this.expense,
    this.isSaved = true,
  });
}

class ContactModel {
  ContactModel({required this.name, required this.phoneNumber, this.kilvishId});

  final String name;
  final String? kilvishId;
  final String phoneNumber;

  // Override equality and hashCode for Set operations
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContactModel &&
          runtimeType == other.runtimeType &&
          phoneNumber == other.phoneNumber;

  @override
  int get hashCode => phoneNumber.hashCode;
}

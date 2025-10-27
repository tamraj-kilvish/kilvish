import 'package:cloud_firestore/cloud_firestore.dart';

class KilvishUser {
  final String id;
  final String uid;
  final String phone;
  Set<String> accessibleTagIds = {};

  KilvishUser({required this.id, required this.uid, required this.phone});

  factory KilvishUser.fromFirestoreObject(Map<String, dynamic>? firestoreUser) {
    KilvishUser user = KilvishUser(
      id: firestoreUser?['id'],
      uid: firestoreUser?['uid'],
      phone: firestoreUser?['phone'],
    );
    List<dynamic> dynamicList =
        firestoreUser?['accessibleTagIds'] as List<dynamic>;
    final List<String> stringList = dynamicList.cast<String>();
    user.accessibleTagIds = stringList.toSet();
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

    return tag;
  }
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

  Expense({
    required this.id,
    required this.txId,
    required this.to,
    required this.timeOfTransaction,
    required this.amount,
    required this.updatedAt,
  });

  factory Expense.fromFirestoreObject(
    String expenseId,
    Map<String, dynamic> firestoreExpense,
  ) {
    Expense expense = Expense(
      id: expenseId,
      txId: firestoreExpense['txId'] as String,
      to: firestoreExpense['to'] as String,
      timeOfTransaction: (firestoreExpense['timeOfTransaction'] as Timestamp)
          .toDate(),
      updatedAt: (firestoreExpense['updatedAt'] as Timestamp).toDate(),
      amount: firestoreExpense['amount'] as num,
    );
    return expense;
  }

  void addTagToExpense(Tag tag) {
    tags.add(tag);
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
}

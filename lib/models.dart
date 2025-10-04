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
    user.accessibleTagIds = firestoreUser?['accessibleTagIds'];
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
  MonthwiseAggregatedExpense monthWiseTotal = {}; //key is year-month

  Tag({required this.id, required this.name, required this.ownerId});

  factory Tag.fromFirestoreObject(
    String tagId,
    Map<String, dynamic>? firestoreTag,
  ) {
    Tag tag = Tag(
      id: tagId,
      name: firestoreTag?['name'],
      ownerId: firestoreTag?['ownerId'],
    );

    //ToDo - populate other fields .. but they are not needed in the Expense screen at the moment

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
      timeOfTransaction: firestoreExpense['timeOfTransaction'] as DateTime,
      updatedAt: firestoreExpense['updatedAt'] as DateTime,
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

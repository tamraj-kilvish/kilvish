import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/firestore.dart';

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
    //print("Dumping firestoreUser $firestoreUser");

    KilvishUser user = KilvishUser(
      id: firestoreUser?['id'],
      uid: firestoreUser?['uid'],
      phone: firestoreUser?['phone'],
      kilvishId: firestoreUser?['kilvishId'] != null ? (firestoreUser?['kilvishId'] as String?) : null,
      updatedAt: firestoreUser?['updatedAt'] != null ? (firestoreUser?['updatedAt'] as Timestamp).toDate() as DateTime? : null,
      fcmToken: firestoreUser?['fcmToken'] != null ? (firestoreUser?['fcmToken'] as String?) : null,
      fcmTokenUpdatedAt: firestoreUser?['fcmTokenUpdatedAt'] != null
          ? (firestoreUser?['fcmTokenUpdatedAt'] as Timestamp).toDate() as DateTime?
          : null,
    );

    // Parse accessibleTagIds
    if (firestoreUser?['accessibleTagIds'] != null) {
      List<dynamic> dynamicList = firestoreUser?['accessibleTagIds'] as List<dynamic>;
      final List<String> stringList = dynamicList.cast<String>();
      user.accessibleTagIds = stringList.toSet();
    }

    // Parse unseenExpenseIds
    if (firestoreUser?['unseenExpenseIds'] != null) {
      List<dynamic> dynamicList = firestoreUser?['unseenExpenseIds'] as List<dynamic>;
      final List<String> stringList = dynamicList.cast<String>();
      user.unseenExpenseIds = stringList.toSet();
    }

    return user;
  }
}

typedef MonthwiseAggregatedExpense = Map<num, Map<num, num>>;

class Tag {
  final String id;
  final String name;
  final String ownerId;
  Set<String> sharedWith = {};
  Set<String> sharedWithFriends = {};
  num totalAmountTillDate = 0;
  MonthwiseAggregatedExpense monthWiseTotal = {};

  Tag({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.totalAmountTillDate,
    required this.monthWiseTotal,
  });

  factory Tag.fromFirestoreObject(String tagId, Map<String, dynamic>? firestoreTag) {
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

    if (firestoreTag?['sharedWithFriends'] != null) {
      List<dynamic> dynamicList = firestoreTag?['sharedWithFriends'] as List<dynamic>;
      final List<String> stringList = dynamicList.cast<String>();
      tag.sharedWithFriends = stringList.toSet();
    }

    return tag;
  }

  // Override equality and hashCode for Set operations
  @override
  bool operator ==(Object other) => identical(this, other) || other is Tag && runtimeType == other.runtimeType && id == other.id;

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
  bool isUnseen = false; // Derived field - set when loading based on User's unseenExpenseIds
  String? ownerId;

  Expense({
    required this.id,
    required this.txId,
    required this.to,
    required this.timeOfTransaction,
    required this.amount,
    required this.updatedAt,
    this.isUnseen = false,
  });

  factory Expense.fromFirestoreObject(String expenseId, Map<String, dynamic> firestoreExpense) {
    Expense expense = Expense(
      id: expenseId,
      to: firestoreExpense['to'] as String,
      timeOfTransaction: (firestoreExpense['timeOfTransaction'] as Timestamp).toDate(),
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
    if (firestoreExpense['ownerId'] != null) {
      expense.ownerId = firestoreExpense['ownerId'] as String;
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

  Future<bool> isExpenseOwner() async {
    final userId = await getUserIdFromClaim();
    if (userId == null) return false;

    if (ownerId == null) return true; // ideally we should check if User doc -> Expenses contain this expense but later ..
    if (ownerId != null && ownerId == userId) return true;
    return false;
  }
}

enum TagStatus { selected, unselected }

class LocalContact {
  LocalContact({required this.name, required this.phoneNumber});

  final String name;
  final String phoneNumber;

  // Override equality and hashCode for Set operations
  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is LocalContact && runtimeType == other.runtimeType && phoneNumber == other.phoneNumber;

  @override
  int get hashCode => phoneNumber.hashCode;
}

class UserFriend {
  String id; // Document ID in Friends subcollection
  String? name;
  String? phoneNumber;
  String? kilvishId;
  String? kilvishUserId;
  DateTime? createdAt;

  UserFriend({required this.id, this.name, this.phoneNumber, this.kilvishId, this.kilvishUserId, this.createdAt});

  factory UserFriend.fromFirestore(String docId, Map<String, dynamic> data) {
    return UserFriend(
      id: docId,
      name: data['name'] as String?,
      phoneNumber: data['phoneNumber'] as String?,
      kilvishId: data['kilvishId'] as String?,
      kilvishUserId: data['kilvishUserId'] as String?,
      createdAt: data['createdAt'] != null ? (data['createdAt'] as Timestamp).toDate() : null,
    );
  }

  static Future<UserFriend> appendKilvishIdAndReturnObject(
    String docId,
    Map<String, dynamic> data,
    FirebaseFirestore _firestore,
  ) async {
    if (data['kilvishUserId'] != null) {
      String kilvishUserId = data['kilvishUserId'] as String;
      final publicInfoDoc = await _firestore.collection('PublicInfo').doc(kilvishUserId).get();
      if (publicInfoDoc.exists) {
        final publicInfoDocData = publicInfoDoc.data();
        if (publicInfoDocData != null && publicInfoDocData['kilvishId'] != null) {
          data['kilvishId'] = publicInfoDocData['kilvishId'] as String;
        }
      }
    }
    return UserFriend.fromFirestore(docId, data);
  }

  Map<String, dynamic> toFirestore() {
    return {
      if (name != null) 'name': name,
      if (phoneNumber != null) 'phoneNumber': phoneNumber,
      if (kilvishId != null) 'kilvishId': kilvishId,
      if (kilvishUserId != null) 'kilvishUserId': kilvishUserId,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  // Override equality and hashCode for Set operations
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserFriend &&
          runtimeType == other.runtimeType &&
          (kilvishUserId != null ? kilvishUserId == other.kilvishUserId : phoneNumber == other.phoneNumber);

  @override
  int get hashCode => kilvishUserId?.hashCode ?? phoneNumber.hashCode;
}

class PublicUserInfo {
  String userId;
  String kilvishId;
  DateTime createdAt;
  DateTime updatedAt;
  DateTime lastLogin;

  PublicUserInfo({
    required this.userId,
    required this.kilvishId,
    required this.createdAt,
    required this.updatedAt,
    required this.lastLogin,
  });

  factory PublicUserInfo.fromFirestore(String userId, Map<String, dynamic> data) {
    return PublicUserInfo(
      userId: userId,
      kilvishId: data['kilvishId'] as String,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      updatedAt: (data['updatedAt'] as Timestamp).toDate(),
      lastLogin: (data['lastLogin'] as Timestamp).toDate(),
    );
  }
}

enum ContactSelection { singleSelect, multiSelect }

enum ContactType { userFriend, localContact, publicInfo }

class SelectableContact {
  final ContactType type;
  final UserFriend? userFriend;
  final LocalContact? localContact;
  final PublicUserInfo? publicInfo;

  SelectableContact.fromUserFriend(this.userFriend) : type = ContactType.userFriend, localContact = null, publicInfo = null;

  SelectableContact.fromLocalContact(this.localContact) : type = ContactType.localContact, userFriend = null, publicInfo = null;

  SelectableContact.fromPublicInfo(this.publicInfo) : type = ContactType.publicInfo, userFriend = null, localContact = null;

  String get displayName {
    switch (type) {
      case ContactType.userFriend:
        return userFriend!.kilvishId ?? userFriend!.name ?? 'Unknown';
      case ContactType.localContact:
        return localContact!.name;
      case ContactType.publicInfo:
        return publicInfo!.kilvishId;
    }
  }

  String? get subtitle {
    switch (type) {
      case ContactType.userFriend:
        return userFriend!.phoneNumber;
      case ContactType.localContact:
        return localContact!.phoneNumber;
      case ContactType.publicInfo:
        return "Last Login: ${DateFormat('MMM d, yyyy, h:mm a').format(publicInfo!.lastLogin)}";
    }
  }

  String? get kilvishId {
    switch (type) {
      case ContactType.userFriend:
        return userFriend!.kilvishId;
      case ContactType.localContact:
        return null;
      case ContactType.publicInfo:
        return publicInfo!.kilvishId;
    }
  }

  bool get hasKilvishId => kilvishId != null;

  @override
  String toString() {
    switch (type) {
      case ContactType.userFriend:
        return "userFriend ${userFriend!.phoneNumber ?? userFriend!.name ?? userFriend!.id}";
      case ContactType.localContact:
        return "localContact ${localContact!.phoneNumber}";
      case ContactType.publicInfo:
        return "publicInfo ${publicInfo!.kilvishId}";
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelectableContact &&
          runtimeType == other.runtimeType &&
          type == other.type &&
          ((type == ContactType.userFriend && userFriend == other.userFriend) ||
              (type == ContactType.localContact && localContact == other.localContact) ||
              (type == ContactType.publicInfo && publicInfo?.userId == other.publicInfo?.userId));

  @override
  int get hashCode {
    switch (type) {
      case ContactType.userFriend:
        return userFriend.hashCode;
      case ContactType.localContact:
        return localContact.hashCode;
      case ContactType.publicInfo:
        return publicInfo!.userId.hashCode;
    }
  }
}

class TagMonetaryUpdate {
  final String name;
  final num totalAmountTillDate;
  final Map<int, Map<int, num>> monthWiseTotal;

  TagMonetaryUpdate({required this.name, required this.totalAmountTillDate, required this.monthWiseTotal});

  factory TagMonetaryUpdate.fromJson(Map<String, dynamic> json) {
    final Map<int, Map<int, num>> parsedMonthWiseTotal = {};

    final monthWiseTotalRaw = json['monthWiseTotal'];
    if (monthWiseTotalRaw is Map) {
      monthWiseTotalRaw.forEach((yearKey, yearValue) {
        if (yearValue is Map) {
          final int? year = int.tryParse(yearKey.toString());
          if (year == null) return;

          parsedMonthWiseTotal[year] = {};

          yearValue.forEach((monthKey, monthValue) {
            final int? month = int.tryParse(monthKey.toString());
            if (month == null) return;

            num amount = 0;
            if (monthValue is num) {
              amount = monthValue;
            } else if (monthValue is String) {
              amount = num.tryParse(monthValue) ?? 0;
            }

            parsedMonthWiseTotal[year]![month] = amount;
          });
        }
      });
    }

    return TagMonetaryUpdate(
      name: json['name'] as String? ?? '',
      totalAmountTillDate: _parseNum(json['totalAmountTillDate']),
      monthWiseTotal: parsedMonthWiseTotal,
    );
  }

  static num _parseNum(dynamic value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value) ?? 0;
    return 0;
  }

  Map<String, dynamic> toFirestoreUpdate() {
    final Map<String, dynamic> update = {};

    update['name'] = name;
    update['totalAmountTillDate'] = totalAmountTillDate;

    // Convert Map<int, Map<int, num>> to Map<String, Map<String, num>> for Firestore
    final Map<String, dynamic> firestoreMonthWiseTotal = {};
    monthWiseTotal.forEach((year, months) {
      firestoreMonthWiseTotal[year.toString()] = {};
      months.forEach((month, amount) {
        firestoreMonthWiseTotal[year.toString()][month.toString()] = amount;
      });
    });

    update['monthWiseTotal'] = firestoreMonthWiseTotal;

    return update;
  }
}

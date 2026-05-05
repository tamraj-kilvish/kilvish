import 'dart:convert';
import 'dart:core';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/models_expense.dart';

class KilvishUser {
  final String id;
  final String uid;
  final String phone;
  Set<String> accessibleTagIds = {};
  String? kilvishId;
  DateTime? updatedAt;
  String? fcmToken;
  DateTime? fcmTokenUpdatedAt;
  Set<String> txIds = {};

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
    KilvishUser user = KilvishUser(
      id: firestoreUser?['id'],
      uid: firestoreUser?['uid'],
      phone: firestoreUser?['phone'],
      kilvishId: firestoreUser?['kilvishId'] as String?,
      updatedAt: firestoreUser?['updatedAt'] != null ? (firestoreUser?['updatedAt'] as Timestamp).toDate() : null,
      fcmToken: firestoreUser?['fcmToken'] as String?,
      fcmTokenUpdatedAt: firestoreUser?['fcmTokenUpdatedAt'] != null
          ? (firestoreUser?['fcmTokenUpdatedAt'] as Timestamp).toDate()
          : null,
    );

    if (firestoreUser?['accessibleTagIds'] != null) {
      user.accessibleTagIds = (firestoreUser?['accessibleTagIds'] as List<dynamic>).cast<String>().toSet();
    }
    if (firestoreUser?['txIds'] != null) {
      user.txIds = (firestoreUser?['txIds'] as List<dynamic>).cast<String>().toSet();
    }

    return user;
  }

  bool expenseAlreadyExist(String txId) => txIds.contains(txId);
  void addToUserTxIds(String txId) => txIds.add(txId);
}

// Monetary data for a single user (or acrossUsers aggregate) in a tag
class UserMonetaryData {
  num expense;
  num recovery;

  UserMonetaryData({this.expense = 0, this.recovery = 0});

  factory UserMonetaryData.fromJson(Map<String, dynamic> json) => UserMonetaryData(
    expense: (json['expense'] as num?) ?? 0,
    recovery: (json['recovery'] as num?) ?? 0,
  );

  Map<String, dynamic> toJson() => {'expense': expense, 'recovery': recovery};
}

// Total monetary data for a tag — acrossUsers aggregate + per-user breakdown
class TagTotal {
  UserMonetaryData acrossUsers;
  Map<String, UserMonetaryData> userWise; // userId -> monetary data

  TagTotal({required this.acrossUsers, required this.userWise});

  factory TagTotal.empty() => TagTotal(acrossUsers: UserMonetaryData(), userWise: {});

  factory TagTotal.fromJson(Map<String, dynamic> json) {
    final acrossUsers = json['acrossUsers'] != null
        ? UserMonetaryData.fromJson((json['acrossUsers'] as Map).cast<String, dynamic>())
        : UserMonetaryData();
    final userWise = <String, UserMonetaryData>{};
    for (final entry in json.entries) {
      if (entry.key != 'acrossUsers' && entry.value is Map) {
        userWise[entry.key] = UserMonetaryData.fromJson((entry.value as Map).cast<String, dynamic>());
      }
    }
    return TagTotal(acrossUsers: acrossUsers, userWise: userWise);
  }

  Map<String, dynamic> toJson() => {
    'acrossUsers': acrossUsers.toJson(),
    for (final entry in userWise.entries) entry.key: entry.value.toJson(),
  };
}

class Tag {
  final String id;
  final String name;
  final String ownerId;
  Set<String> sharedWith = {};
  Set<String> sharedWithFriends = {};
  TagTotal total;
  Map<String, TagTotal> monthWiseTotal; // key: "YYYY-MM"
  bool dontShowOutstanding = false;
  DateTime? updatedAt;
  int unseenCount = 0;

  Tag({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.total,
    required this.monthWiseTotal,
  });

  String get formattedExpense => NumberFormat.compact().format(total.acrossUsers.expense.round());

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'ownerId': ownerId,
    'sharedWith': sharedWith.toList(),
    'sharedWithFriends': sharedWithFriends.toList(),
    'total': total.toJson(),
    'monthWiseTotal': monthWiseTotal.map((k, v) => MapEntry(k, v.toJson())),
    'dontShowOutstanding': dontShowOutstanding,
    'updatedAt': updatedAt?.toIso8601String(),
    'unseenCount': unseenCount,
  };

  static String jsonEncodeTagsList(List<Tag> tags) => jsonEncode(tags.map((t) => t.toJson()).toList());

  static List<Tag> jsonDecodeTagsList(String tagsListString) {
    final List<dynamic> list = jsonDecode(tagsListString);
    return list.map((m) => Tag.fromJson(m as Map<String, dynamic>)).toList();
  }

  factory Tag.fromJson(Map<String, dynamic> json) {
    final tag = Tag.fromFirestoreObject(json['id'] as String, json);
    tag.unseenCount = json['unseenCount'] as int? ?? 0;
    return tag;
  }

  factory Tag.fromFirestoreObject(String tagId, Map<String, dynamic>? data) {
    final rawTotal = data?['total'];
    final total = rawTotal != null
        ? TagTotal.fromJson((rawTotal as Map).cast<String, dynamic>())
        : TagTotal.empty();

    final monthWiseTotal = <String, TagTotal>{};
    final rawMonthWise = data?['monthWiseTotal'] as Map<String, dynamic>?;
    if (rawMonthWise != null) {
      for (final entry in rawMonthWise.entries) {
        if (entry.value is Map) {
          monthWiseTotal[entry.key] = TagTotal.fromJson((entry.value as Map).cast<String, dynamic>());
        }
      }
    }

    final tag = Tag(
      id: tagId,
      name: data?['name'] as String? ?? '',
      ownerId: data?['ownerId'] as String? ?? '',
      total: total,
      monthWiseTotal: monthWiseTotal,
    );

    if (data?['sharedWith'] != null) {
      tag.sharedWith = (data!['sharedWith'] as List).cast<String>().toSet();
    }
    if (data?['sharedWithFriends'] != null) {
      tag.sharedWithFriends = (data!['sharedWithFriends'] as List).cast<String>().toSet();
    }
    tag.dontShowOutstanding = data?['dontShowOutstanding'] as bool? ?? false;

    final rawUpdatedAt = data?['updatedAt'];
    if (rawUpdatedAt is Timestamp) {
      tag.updatedAt = rawUpdatedAt.toDate();
    } else if (rawUpdatedAt is String) {
      tag.updatedAt = DateTime.tryParse(rawUpdatedAt);
    }

    return tag;
  }

  @override
  bool operator ==(Object other) => identical(this, other) || other is Tag && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

enum TagStatus { selected, unselected }

class LocalContact {
  final String name;
  final String phoneNumber;

  LocalContact({required this.name, required this.phoneNumber});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is LocalContact && phoneNumber == other.phoneNumber;

  @override
  int get hashCode => phoneNumber.hashCode;
}

class UserFriend {
  String id;
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
    FirebaseFirestore firestore,
  ) async {
    if (data['kilvishUserId'] != null) {
      final publicInfoDoc = await firestore.collection('PublicInfo').doc(data['kilvishUserId'] as String).get();
      if (publicInfoDoc.exists) {
        final info = publicInfoDoc.data();
        if (info?['kilvishId'] != null) data['kilvishId'] = info!['kilvishId'];
      }
    }
    return UserFriend.fromFirestore(docId, data);
  }

  Map<String, dynamic> toFirestore() => {
    if (name != null) 'name': name,
    if (phoneNumber != null) 'phoneNumber': phoneNumber,
    if (kilvishId != null) 'kilvishId': kilvishId,
    if (kilvishUserId != null) 'kilvishUserId': kilvishUserId,
    'updatedAt': FieldValue.serverTimestamp(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserFriend &&
          (kilvishUserId != null ? kilvishUserId == other.kilvishUserId : phoneNumber == other.phoneNumber);

  @override
  int get hashCode => kilvishUserId?.hashCode ?? phoneNumber.hashCode;
}

class PublicUserInfo {
  String userId;
  String kilvishId;
  DateTime createdAt;
  DateTime updatedAt;
  DateTime? lastLogin;

  PublicUserInfo({
    required this.userId,
    required this.kilvishId,
    required this.createdAt,
    required this.updatedAt,
    this.lastLogin,
  });

  factory PublicUserInfo.fromFirestore(String userId, Map<String, dynamic> data) {
    return PublicUserInfo(
      userId: userId,
      kilvishId: data['kilvishId'] as String,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      updatedAt: (data['updatedAt'] as Timestamp).toDate(),
      lastLogin: data['lastLogin'] != null ? (data['lastLogin'] as Timestamp).toDate() : null,
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
        return "Last Login: ${publicInfo!.lastLogin != null ? DateFormat('MMM d, yyyy, h:mm a').format(publicInfo!.lastLogin!) : 'NA'}";
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

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

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

    if (firestoreUser?['txIds'] != null) {
      List<dynamic> dynamicList = firestoreUser?['txIds'] as List<dynamic>;
      final List<String> stringList = dynamicList.cast<String>();
      user.txIds = stringList.toSet();
    }

    return user;
  }

  bool expenseAlreadyExist(String txId) {
    if (txIds.isEmpty) return false;
    if (txIds.contains(txId)) return true;
    return false;
  }

  void addToUserTxIds(String txId) {
    txIds.add(txId);
  }
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
      lastLogin: data['lastlogin'] != null ? (data['lastLogin'] as Timestamp).toDate() : null,
    );
  }
}

enum ContactSelection { singleSelect, multiSelect }

enum ContactType { userFriend, localContact, publicInfo }

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

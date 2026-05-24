import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/firestore.dart';
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
  DateTime? lastFCMSentAt;
  DateTime? lastFCMProcessedAt;

  KilvishUser({
    required this.id,
    required this.uid,
    required this.phone,
    this.kilvishId,
    this.updatedAt,
    this.fcmToken,
    this.fcmTokenUpdatedAt,
    this.lastFCMProcessedAt,
    this.lastFCMSentAt,
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
      lastFCMSentAt: firestoreUser?['lastFCMSentAt'] != null ? (firestoreUser?['lastFCMSentAt'] as Timestamp).toDate() : null,
      lastFCMProcessedAt: firestoreUser?['lastFCMProcessedAt'] != null
          ? (firestoreUser?['lastFCMProcessedAt'] as Timestamp).toDate()
          : null,
    );

    if (firestoreUser?['accessibleTagIds'] != null) {
      user.accessibleTagIds = (firestoreUser?['accessibleTagIds'] as List<dynamic>).cast<String>().toSet();
    }
    return user;
  }
}

class LocalContact {
  final String name;
  final String phoneNumber;

  LocalContact({required this.name, required this.phoneNumber});

  @override
  bool operator ==(Object other) => identical(this, other) || other is LocalContact && phoneNumber == other.phoneNumber;

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

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'phoneNumber': phoneNumber,
    'kilvishUserId': kilvishUserId,
    'createdAt': createdAt?.toIso8601String(),
  };

  static Future<UserFriend> fromJson(Map<String, dynamic> json) async {
    json['kilvishId'] = await getUserKilvishId(json['id']);
    return UserFriend.fromFirestore(json['id'], json);
  }

  factory UserFriend.fromFirestore(String docId, Map<String, dynamic> data) {
    return UserFriend(
      id: docId,
      name: data['name'] as String?,
      phoneNumber: data['phoneNumber'] as String?,
      kilvishId: data['kilvishId'] as String?,
      kilvishUserId: data['kilvishUserId'] as String?,
      createdAt: data['createdAt'] != null ? BaseExpense.decodeDateTime(data, 'createdAt') : null,
    );
  }

  static Future<UserFriend?> getFriend(String ownerId, String userId) async {
    return getFriendByUserId(ownerId, userId);
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
      other is UserFriend && (kilvishUserId != null ? kilvishUserId == other.kilvishUserId : phoneNumber == other.phoneNumber);

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

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'lastLogin': lastLogin?.toIso8601String(),
  };

  static Future<PublicUserInfo> fromJson(Map<String, dynamic> json) async {
    json['kilvishId'] = await getUserKilvishId(json['userId']);
    return PublicUserInfo.fromFirestore(json['userId'] as String, json);
  }

  factory PublicUserInfo.fromFirestore(String userId, Map<String, dynamic> data) {
    return PublicUserInfo(
      userId: userId,
      kilvishId: data['kilvishId'] as String,
      createdAt: BaseExpense.decodeDateTime(data, 'createdAt'),
      updatedAt: BaseExpense.decodeDateTime(data, 'updatedAt'),
      lastLogin: data['lastLogin'] != null ? BaseExpense.decodeDateTime(data, 'lastLogin') : null,
    );
  }

  static Future<PublicUserInfo?> getForUser(String userId) async {
    DocumentSnapshot publicInfoDoc = await getFirestoreInstance().collection("PublicInfo").doc(userId).get();
    if (!publicInfoDoc.exists) return null;
    return PublicUserInfo.fromFirestore(userId, publicInfoDoc.data() as Map<String, dynamic>);
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

  static Future<SelectableContact?> fromFirestore(String viewerId, String friendId) async {
    final userFriend = await UserFriend.getFriend(viewerId, friendId);
    if (userFriend != null) return SelectableContact.fromUserFriend(userFriend);

    final publicInfo = await PublicUserInfo.getForUser(friendId);
    if (publicInfo != null) return SelectableContact.fromPublicInfo(publicInfo);

    print('[models_user] SelectableContact -> get is returning null .. this is an error, should not happen');
    return null;
  }

  Map<String, dynamic> toJson() {
    switch (type) {
      case ContactType.userFriend:
        return userFriend!.toJson();
      case ContactType.localContact:
        return {};
      case ContactType.publicInfo:
        return publicInfo!.toJson();
    }
  }

  static Future<SelectableContact> fromJson(Map<String, dynamic> json) async {
    if (json['name'] != null || json['phoneNumber'] != null) {
      return SelectableContact.fromUserFriend(await UserFriend.fromJson(json));
    }
    return SelectableContact.fromPublicInfo(await PublicUserInfo.fromJson(json));
  }

  String get displayName {
    switch (type) {
      case ContactType.userFriend:
        final kid = userFriend!.kilvishId;
        return kid != null ? '@$kid' : userFriend!.name ?? 'Unknown';
      case ContactType.localContact:
        return localContact!.name;
      case ContactType.publicInfo:
        return '@${publicInfo!.kilvishId}';
    }
  }

  /// First character for avatars — never includes '@'.
  String get initials {
    switch (type) {
      case ContactType.userFriend:
        return (userFriend!.kilvishId ?? userFriend!.name ?? '?')[0].toUpperCase();
      case ContactType.localContact:
        return localContact!.name[0].toUpperCase();
      case ContactType.publicInfo:
        return publicInfo!.kilvishId[0].toUpperCase();
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

  String? get userId {
    switch (type) {
      case ContactType.userFriend:
        return userFriend!.kilvishUserId;
      case ContactType.localContact:
        return null;
      case ContactType.publicInfo:
        return publicInfo!.userId;
    }
  }

  String? get phoneNumber {
    switch (type) {
      case ContactType.userFriend:
        return userFriend!.phoneNumber;
      case ContactType.localContact:
        return localContact!.phoneNumber;
      case ContactType.publicInfo:
        return null;
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

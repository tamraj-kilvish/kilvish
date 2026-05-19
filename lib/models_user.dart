import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

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

// A participant in a Tag — loaded from sharedWith, enriched via current user's Friends sub-collection.
// contact is non-null when the participant is in the current user's friend list.
// kilvishId is the resolved display id (from sharedWithAndOwnerKilvishIds) used as fallback display name.
class TagParticipant {
  final String userId;
  final String? kilvishId;
  final SelectableContact? contact;

  TagParticipant({required this.userId, this.kilvishId, this.contact});

  String get displayName => contact?.displayName ?? kilvishId ?? userId;

  String? get phoneNumber {
    if (contact?.type == ContactType.userFriend) return contact!.userFriend?.phoneNumber;
    if (contact?.type == ContactType.localContact) return contact!.localContact?.phoneNumber;
    return null;
  }

  Map<String, dynamic> toJson() => {
    'userId': userId,
    if (kilvishId != null) 'kilvishId': kilvishId,
  };

  // contact is not cached — re-derived from Friends sub-collection on next Firestore load
  factory TagParticipant.fromJson(Map<String, dynamic> json) => TagParticipant(
    userId: json['userId'] as String,
    kilvishId: json['kilvishId'] as String?,
  );
}

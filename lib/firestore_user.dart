import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:kilvish/firestore_common.dart';
import 'package:kilvish/firestore_tags.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/models_tags.dart';

Future<KilvishUser?> getLoggedInUserData() async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return null;

  DocumentSnapshot userDoc = await firestore.collection('Users').doc(userId).get();
  if (!userDoc.exists) return null;

  Map<String, dynamic> userData = userDoc.data() as Map<String, dynamic>;
  userData['id'] = userDoc.id;

  DocumentSnapshot publicInfoDoc = await firestore.collection("PublicInfo").doc(userId).get();
  if (publicInfoDoc.exists) {
    userData.addAll(publicInfoDoc.data() as Map<String, dynamic>);
  }
  return KilvishUser.fromFirestoreObject(userData);
}

Map<String, String> userIdKilvishIdHash = {};

Future<String?> getUserKilvishId(String userId) async {
  if (userIdKilvishIdHash[userId] != null) {
    String cachedKilvishId = userIdKilvishIdHash[userId]!;
    refreshUserIdKilvishIdCache(userId);
    return cachedKilvishId;
  }

  return await refreshUserIdKilvishIdCache(userId);
}

Future<String?> refreshUserIdKilvishIdCache(String userId) async {
  DocumentSnapshot publicInfoDoc = await firestore.collection("PublicInfo").doc(userId).get();
  if (!publicInfoDoc.exists) return null;

  PublicUserInfo publicUserInfo = PublicUserInfo.fromFirestore(userId, publicInfoDoc.data() as Map<String, dynamic>);
  //TODO - make this write thread safe as we are also reading the value & returning
  userIdKilvishIdHash[userId] = publicUserInfo.kilvishId;
  return userIdKilvishIdHash[userId];
}

Future<bool> updateUserKilvishId(String userId, String kilvishId) async {
  String? userKilvishId = await getUserKilvishId(userId);

  if (userKilvishId == null) {
    if (await isKilvishIdTaken(kilvishId)) return false;

    await firestore.collection("PublicInfo").doc(userId).set({
      'kilvishId': kilvishId,
      'updatedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
      'lastLogin': FieldValue.serverTimestamp(),
    });
    return true;
  }

  if (userKilvishId != kilvishId && await isKilvishIdTaken(kilvishId)) return false;

  final Map<String, dynamic> updateData = {'lastLogin': FieldValue.serverTimestamp()};
  if (userKilvishId != kilvishId) {
    updateData.addAll({'kilvishId': kilvishId, 'updatedAt': FieldValue.serverTimestamp()});
  }

  await firestore.collection("PublicInfo").doc(userId).update(updateData);

  return true;
}

Future<bool> isKilvishIdTaken(String kilvishId) async {
  QuerySnapshot alreadyPresentEntries = await firestore
      .collection("PublicInfo")
      .where("kilvishId", isEqualTo: kilvishId)
      .limit(1)
      .get();
  return alreadyPresentEntries.size == 0 ? false : true;
}

Future<String?> getUserIdFromClaim({FirebaseAuth? authParam}) async {
  final auth = authParam ?? firebaseAuth;
  final authUser = auth.currentUser;
  if (authUser == null) return null;

  final idTokenResult = await authUser.getIdTokenResult();
  return idTokenResult.claims?['userId'] as String?;
}

Future<void> saveFCMToken(String token) async {
  try {
    String? userId = await getUserIdFromClaim();

    await firestore.collection('Users').doc(userId).update({
      'fcmToken': token,
      'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
    });

    print('FCM token saved for user: $userId');
  } catch (e, stackTrace) {
    print('Error saving FCM token: $e $stackTrace');
  }
}

Future<List<UserFriend>?> getAllUserFriendsFromFirestore() async {
  final userId = await getUserIdFromClaim();
  if (userId == null) return null;

  final friendsSnapshot = await firestore.collection('Users').doc(userId).collection('Friends').get();

  List<UserFriend> userFriends = [];

  for (var doc in friendsSnapshot.docs) {
    Map<String, dynamic> data = doc.data();
    userFriends.add(await UserFriend.appendKilvishIdAndReturnObject(doc.id, data, firestore));
  }

  print('Loaded ${userFriends.length} user friends');
  return userFriends;
}

Future<PublicUserInfo?> getPublicInfoUserFromKilvishId(String query) async {
  // Search for exact kilvishId match in top-level PublicInfo collection
  final publicInfoQuery = await firestore.collection('PublicInfo').where('kilvishId', isEqualTo: query).limit(1).get();

  if (publicInfoQuery.docs.isNotEmpty) {
    final doc = publicInfoQuery.docs.first;
    if (!doc.exists) return null;

    final data = doc.data();
    return PublicUserInfo.fromFirestore(doc.id, data);
  } else {
    return null;
  }
}

Future<UserFriend?> getUserFriendWithGivenPhoneNumber(String phoneNumber) async {
  String? userId = await getUserIdFromClaim();
  if (userId == null) return null;

  // Check if friend with same phone already exists
  final existingFriends = await firestore
      .collection('Users')
      .doc(userId)
      .collection('Friends')
      .where('phoneNumber', isEqualTo: phoneNumber)
      .limit(1)
      .get();

  if (existingFriends.docs.isNotEmpty) {
    // Friend already exists
    final friend = UserFriend.fromFirestore(existingFriends.docs.first.id, existingFriends.docs.first.data());
    return friend;
  }
  return null;
}

Future<UserFriend?> addUserFriendFromContact(LocalContact contact) async {
  String? userId = await getUserIdFromClaim();
  if (userId == null) return null;
  // Create new friend
  Map<String, dynamic> friendData = {
    'name': contact.name,
    'phoneNumber': contact.phoneNumber,
    'createdAt': FieldValue.serverTimestamp(),
  };

  final friendRef = await firestore.collection('Users').doc(userId).collection('Friends').add(friendData);
  final friendDoc = await firestore.collection('Users').doc(userId).collection('Friends').doc(friendRef.id).get();

  return UserFriend.fromFirestore(friendRef.id, friendDoc.data()!);
}

Future<UserFriend?> addFriendFromPublicInfoIfNotExist(PublicUserInfo publicInfo) async {
  String? userId = await getUserIdFromClaim();
  if (userId == null) return null;

  // Check if friend already exists
  final existingFriends = await firestore
      .collection('Users')
      .doc(userId)
      .collection('Friends')
      .where('kilvishUserId', isEqualTo: publicInfo.userId)
      .limit(1)
      .get();

  if (existingFriends.docs.isNotEmpty) {
    Map<String, dynamic> data = existingFriends.docs.first.data();
    data['kilvishId'] = publicInfo.kilvishId;

    return UserFriend.fromFirestore(existingFriends.docs.first.id, data);
  } else {
    // Create new friend from publicInfo
    final friendData = {
      //'kilvishId': publicInfo.kilvishId,
      'kilvishUserId': publicInfo.userId,
      'createdAt': FieldValue.serverTimestamp(),
    };

    final friendRef = await firestore.collection('Users').doc(userId).collection('Friends').add(friendData);

    friendData['kilvishId'] = publicInfo.kilvishId;
    return UserFriend.fromFirestore(friendRef.id, friendData);
  }
}

Future<Map<String, dynamic>?> getUserAccessibleTagsHavingExpense(String expenseId) async {
  try {
    final user = await getLoggedInUserData();
    if (user == null) return null;

    List<Tag> tags = [];
    List<SettlementEntry> settlements = [];

    // Check each accessible tag to see if this expense is in it
    for (String tagId in user.accessibleTagIds) {
      final tagExpenseDoc = await firestore.collection('Tags').doc(tagId).collection('Expenses').doc(expenseId).get();

      if (tagExpenseDoc.exists) {
        final tag = await getTagData(tagId);
        tags.add(tag);
      }

      final settlementDoc = await firestore.collection('Tags').doc(tagId).collection('Settlements').doc(expenseId).get();
      if (settlementDoc.exists) {
        Map<String, dynamic> settlementData = settlementDoc.data() as Map<String, dynamic>;
        settlementData = (settlementData['settlements'] as List<dynamic>)[0] as Map<String, dynamic>;
        print("SettlementData: id - ${settlementDoc.id}, data - $settlementData");

        settlementData['tagId'] = tagId;
        settlements.add(SettlementEntry.fromJson(settlementData));
      }
    }
    return {'tags': tags, 'settlements': settlements};
  } catch (e, stackTrace) {
    print('Error loading expense tags: $e, $stackTrace');
  }
  return null;
}

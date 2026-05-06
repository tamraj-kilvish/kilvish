import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collection/collection.dart';
import 'package:kilvish/firestore.dart';

// ─── RecipientBreakdown ──────────────────────────────────────────────────────

class RecipientBreakdown {
  final String userId; // recipient (= Firestore doc ID)
  final String? userKilvishId;
  final num amount;
  final String expenseOwnerId; // always known at write time
  final num expenseAmount; // always known at write time
  final String? settlementMonth;
  final String? expenseMonth; // null for WIPExpense before timeOfTransaction is set

  const RecipientBreakdown({
    required this.userId,
    required this.userKilvishId,
    required this.amount,
    required this.expenseOwnerId,
    required this.expenseAmount,
    this.settlementMonth,
    this.expenseMonth,
  });

  static Future<RecipientBreakdown> fromFirestore(String docId, Map<String, dynamic> data) async {
    return RecipientBreakdown(
      userId: docId,
      userKilvishId: await getUserKilvishId(docId),
      amount: data['amount'] as num? ?? 0,
      expenseOwnerId: data['expenseOwnerId'] as String? ?? '',
      expenseAmount: data['expenseAmount'] as num? ?? 0,
      settlementMonth: data['settlementMonth'] as String?,
      expenseMonth: data['expenseMonth'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'amount': amount,
    'expenseOwnerId': expenseOwnerId,
    'expenseAmount': expenseAmount,
    if (settlementMonth != null) 'settlementMonth': settlementMonth,
    if (expenseMonth != null) 'expenseMonth': expenseMonth,
  };

  static Future<RecipientBreakdown> fromJson(Map<String, dynamic> json) async {
    return RecipientBreakdown(
      userId: json['userId'] as String,
      userKilvishId: await getUserKilvishId(json['userId']),
      amount: json['amount'] as num,
      expenseOwnerId: json['expenseOwnerId'] as String? ?? '',
      expenseAmount: json['expenseAmount'] as num? ?? 0,
      settlementMonth: json['settlementMonth'] as String?,
      expenseMonth: json['expenseMonth'] as String?,
    );
  }

  static Future<List<RecipientBreakdown>> fetchAll(String tagId, String expenseId) async {
    final snap = await getFirestoreInstance()
        .collection('Tags')
        .doc(tagId)
        .collection('Expenses')
        .doc(expenseId)
        .collection('Recipients')
        .get();
    return Future.wait(snap.docs.map((d) => RecipientBreakdown.fromFirestore(d.id, d.data())).toList());
  }

  Future<void> addOrUpdate(String tagId, String expenseId) async {
    final currentUserId = await getUserIdFromClaim();
    final kilvishId = currentUserId != null ? await getUserKilvishId(currentUserId) : null;
    final recipientKilvishId = await getUserKilvishId(userId);

    await getFirestoreInstance()
        .collection('Tags')
        .doc(tagId)
        .collection('Expenses')
        .doc(expenseId)
        .collection('Recipients')
        .doc(userId)
        .set({
          'userId': userId,
          'amount': amount,
          'expenseOwnerId': expenseOwnerId,
          'expenseAmount': expenseAmount,
          if (expenseMonth != null) 'expenseMonth': expenseMonth,
          if (settlementMonth != null) 'settlementMonth': settlementMonth,
          'updatedAt': FieldValue.serverTimestamp(),
          if (currentUserId != null) 'updatedBy': {'userId': currentUserId, if (kilvishId != null) 'kilvishId': kilvishId},
          if (recipientKilvishId != null) 'recipientKilvishId': recipientKilvishId,
        });
  }

  Future<void> remove(String tagId, String expenseId) async {
    await getFirestoreInstance()
        .collection('Tags')
        .doc(tagId)
        .collection('Expenses')
        .doc(expenseId)
        .collection('Recipients')
        .doc(userId)
        .delete();
  }
}

// ─── TagExpenseConfig ────────────────────────────────────────────────────────

class TagExpenseConfig {
  final String tagId;
  final List<RecipientBreakdown> recipients;

  const TagExpenseConfig({required this.tagId, this.recipients = const []});

  bool get isSettlement => recipients.any((r) => r.settlementMonth != null);

  String? get settlementMonth => recipients.firstWhereOrNull((r) => r.settlementMonth != null)?.settlementMonth;

  String? get settlementCounterpartyId => recipients.firstWhereOrNull((r) => r.settlementMonth != null)?.userId;

  num ownerShareFor(String ownerId) => recipients.firstWhereOrNull((r) => r.userId == ownerId)?.amount ?? 0;

  num outstandingFor(String ownerId, num expenseAmount) => expenseAmount - ownerShareFor(ownerId);

  num ownerOutstanding() {
    final ownerEntry = recipients.firstWhereOrNull((r) => r.userId == r.expenseOwnerId);
    if (ownerEntry == null) return 0;

    return ownerEntry.expenseAmount - ownerEntry.amount;
  }

  Map<String, num> nonOwnerAmounts(String ownerId) => {
    for (final r in recipients)
      if (r.userId != ownerId && r.settlementMonth == null) r.userId: r.amount,
  };

  Map<String, dynamic> toJson() => {'tagId': tagId, 'recipients': recipients.map((r) => r.toJson()).toList()};

  static Future<TagExpenseConfig> fromJson(Map<String, dynamic> json) async {
    return TagExpenseConfig(
      tagId: json['tagId'] as String,
      recipients: await Future.wait(
        (json['recipients'] as List? ?? []).map((r) => RecipientBreakdown.fromJson(r as Map<String, dynamic>)).toList(),
      ),
    );
  }

  String getSummary(String ownerKilvishId, {num showCount = 2}) {
    if (isSettlement) {
      final recipient = recipients.firstOrNull;
      if (recipient == null) return '';
      return "@$ownerKilvishId settled ₹${recipient.amount.toStringAsFixed(0)} with @${recipient.userKilvishId}";
    }

    String message = "";
    final _ownerOutstanding = ownerOutstanding();
    if (_ownerOutstanding > 0) {
      message += '@$ownerKilvishId is owed ₹${_ownerOutstanding.toStringAsFixed(0)}. ';
    }

    num count = 0;
    for (final recipient in recipients) {
      if (recipient.userId == recipient.expenseOwnerId) continue;
      if (recipient.userKilvishId == null) continue;
      if (recipient.amount == 0) continue;

      if (count == showCount) {
        message += "& more ...";
        break;
      }

      message += "@${recipient.userKilvishId} owes ₹${recipient.amount.toStringAsFixed(0)} ";
      count += 1;
    }

    return message;
  }
}

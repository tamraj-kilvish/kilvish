import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collection/collection.dart';
import 'package:kilvish/firestore.dart';

// ─── RecipientBreakdown ──────────────────────────────────────────────────────

class RecipientBreakdown {
  final String userId; // recipient (= Firestore doc ID)
  final num amount;
  final String expenseOwnerId; // always known at write time
  final num expenseAmount; // always known at write time
  final String? settlementMonth;
  final String? expenseMonth; // null for WIPExpense before timeOfTransaction is set

  const RecipientBreakdown({
    required this.userId,
    required this.amount,
    required this.expenseOwnerId,
    required this.expenseAmount,
    this.settlementMonth,
    this.expenseMonth,
  });

  factory RecipientBreakdown.fromFirestore(String docId, Map<String, dynamic> data) =>
      RecipientBreakdown(
        userId: docId,
        amount: data['amount'] as num? ?? 0,
        expenseOwnerId: data['expenseOwnerId'] as String? ?? '',
        expenseAmount: data['expenseAmount'] as num? ?? 0,
        settlementMonth: data['settlementMonth'] as String?,
        expenseMonth: data['expenseMonth'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'amount': amount,
        'expenseOwnerId': expenseOwnerId,
        'expenseAmount': expenseAmount,
        if (settlementMonth != null) 'settlementMonth': settlementMonth,
        if (expenseMonth != null) 'expenseMonth': expenseMonth,
      };

  factory RecipientBreakdown.fromJson(Map<String, dynamic> json) => RecipientBreakdown(
        userId: json['userId'] as String,
        amount: json['amount'] as num,
        expenseOwnerId: json['expenseOwnerId'] as String? ?? '',
        expenseAmount: json['expenseAmount'] as num? ?? 0,
        settlementMonth: json['settlementMonth'] as String?,
        expenseMonth: json['expenseMonth'] as String?,
      );

  static Future<List<RecipientBreakdown>> fetchAll(String tagId, String expenseId) async {
    final snap = await FirebaseFirestore.instance
        .collection('Tags')
        .doc(tagId)
        .collection('Expenses')
        .doc(expenseId)
        .collection('Recipients')
        .get();
    return snap.docs.map((d) => RecipientBreakdown.fromFirestore(d.id, d.data())).toList();
  }

  Future<void> addOrUpdate(String tagId, String expenseId) async {
    final currentUserId = await getUserIdFromClaim();
    final kilvishId = currentUserId != null ? await getUserKilvishId(currentUserId) : null;
    final recipientKilvishId = await getUserKilvishId(userId);

    await FirebaseFirestore.instance
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
      if (currentUserId != null)
        'updatedBy': {
          'userId': currentUserId,
          if (kilvishId != null) 'kilvishId': kilvishId,
        },
      if (recipientKilvishId != null) 'recipientKilvishId': recipientKilvishId,
    });
  }

  Future<void> remove(String tagId, String expenseId) async {
    await FirebaseFirestore.instance
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

  String? get settlementMonth =>
      recipients.firstWhereOrNull((r) => r.settlementMonth != null)?.settlementMonth;

  String? get settlementCounterpartyId =>
      recipients.firstWhereOrNull((r) => r.settlementMonth != null)?.userId;

  num ownerShareFor(String ownerId) =>
      recipients.firstWhereOrNull((r) => r.userId == ownerId)?.amount ?? 0;

  num outstandingFor(String ownerId, num expenseAmount) =>
      expenseAmount - ownerShareFor(ownerId);

  Map<String, num> nonOwnerAmounts(String ownerId) => {
        for (final r in recipients)
          if (r.userId != ownerId && r.settlementMonth == null) r.userId: r.amount,
      };

  Map<String, dynamic> toJson() => {
        'tagId': tagId,
        'recipients': recipients.map((r) => r.toJson()).toList(),
      };

  factory TagExpenseConfig.fromJson(Map<String, dynamic> json) => TagExpenseConfig(
        tagId: json['tagId'] as String,
        recipients: (json['recipients'] as List? ?? [])
            .map((r) => RecipientBreakdown.fromJson(r as Map<String, dynamic>))
            .toList(),
      );
}

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collection/collection.dart';
import 'package:kilvish/firestore.dart';

// ─── RecipientBreakdown ──────────────────────────────────────────────────────

class RecipientBreakdown {
  final String userId;
  final String? userKilvishId;
  final num amount;
  final String? settlementMonth;

  const RecipientBreakdown({required this.userId, required this.userKilvishId, required this.amount, this.settlementMonth});

  static Future<RecipientBreakdown> fromFirestore(String docId, Map<String, dynamic> data) async {
    return RecipientBreakdown(
      userId: docId,
      userKilvishId: await getUserKilvishId(docId),
      amount: data['amount'] as num? ?? 0,
      settlementMonth: data['settlementMonth'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'amount': amount,
    if (settlementMonth != null) 'settlementMonth': settlementMonth,
  };

  static Future<RecipientBreakdown> fromJson(Map<String, dynamic> json) async {
    return RecipientBreakdown(
      userId: json['userId'] as String,
      userKilvishId: await getUserKilvishId(json['userId']),
      amount: json['amount'] as num,
      settlementMonth: json['settlementMonth'] as String?,
    );
  }

  /// Builds a RecipientBreakdown list from the `recipients` map stored on the
  /// Expense doc. The map shape is { userId: { amount, settlementMonth? } }.
  static Future<List<RecipientBreakdown>> fromRecipientsMap(Map<String, dynamic> recipientsMap) async {
    return Future.wait(
      recipientsMap.entries.map((entry) async {
        final data = entry.value as Map<String, dynamic>;
        return RecipientBreakdown(
          userId: entry.key,
          userKilvishId: await getUserKilvishId(entry.key),
          amount: data['amount'] as num,
          settlementMonth: data['settlementMonth'] as String?,
        );
      }).toList(),
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

  Future<void> addOrUpdate(String tagId, String expenseId, {WriteBatch? batchParam}) async {
    final currentUserId = await getUserIdFromClaim();
    final kilvishId = currentUserId != null ? await getUserKilvishId(currentUserId) : null;

    final docRef = getFirestoreInstance()
        .collection('Tags')
        .doc(tagId)
        .collection('Expenses')
        .doc(expenseId)
        .collection('Recipients')
        .doc(userId);

    final data = {
      'amount': amount,
      if (settlementMonth != null) 'settlementMonth': settlementMonth,
      'updatedAt': FieldValue.serverTimestamp(),
      if (currentUserId != null) 'updatedBy': {'userId': currentUserId, if (kilvishId != null) 'kilvishId': kilvishId},
    };

    if (batchParam != null) {
      batchParam.set(docRef, data);
      return;
    }

    await docRef.set(data);
    print("RecipientBreakdown addOrUpdate - updated recipient $userId for expense $expenseId in tag $tagId");
  }

  Future<void> remove(String tagId, String expenseId, {WriteBatch? batch}) async {
    if (batch != null) {
      batch.delete(
        getFirestoreInstance()
            .collection('Tags')
            .doc(tagId)
            .collection('Expenses')
            .doc(expenseId)
            .collection('Recipients')
            .doc(userId),
      );
      return;
    }
    await getFirestoreInstance()
        .collection('Tags')
        .doc(tagId)
        .collection('Expenses')
        .doc(expenseId)
        .collection('Recipients')
        .doc(userId)
        .delete();
    print("RecipientBreakdown remove - removed recipient $userId for expense $expenseId in tag $tagId");
  }
}

// ─── TagExpenseConfig ────────────────────────────────────────────────────────

class TagExpenseConfig {
  final String tagId;
  final List<RecipientBreakdown> recipients;
  num? expenseAmount;
  // Members at the time of expense creation — written by saveTagLink() for
  // simple mode so onExpenseCreated can skip the Expense doc stamp.
  List<String> simpleParticipants;

  TagExpenseConfig({required this.tagId, this.expenseAmount, this.recipients = const [], this.simpleParticipants = const []});

  bool get isSimpleMode => recipients.isEmpty;

  bool get isSettlement => recipients.any((r) => r.settlementMonth != null);

  String? get settlementMonth => recipients.firstWhereOrNull((r) => r.settlementMonth != null)?.settlementMonth;

  String? get settlementCounterpartyId => recipients.firstWhereOrNull((r) => r.settlementMonth != null)?.userId;

  num ownerShareFor(String ownerId) => recipients.firstWhereOrNull((r) => r.userId == ownerId)?.amount ?? 0;

  num outstandingFor(String ownerId, num totalAmount) => totalAmount - ownerShareFor(ownerId);

  Map<String, num> nonOwnerAmounts(String ownerId) => {
    for (final r in recipients)
      if (r.userId != ownerId && r.settlementMonth == null) r.userId: r.amount,
  };

  Map<String, dynamic> toJson() => {
    'tagId': tagId,
    'expenseAmount': expenseAmount,
    'recipients': recipients.map((r) => r.toJson()).toList(),
    if (simpleParticipants.isNotEmpty) 'simpleParticipants': simpleParticipants,
  };

  static Future<TagExpenseConfig> fromJson(Map<String, dynamic> json) async {
    return TagExpenseConfig(
      tagId: json['tagId'] as String,
      expenseAmount: json['expenseAmount'] != null ? json['expenseAmount'] as num : null,
      recipients: await Future.wait(
        (json['recipients'] as List? ?? []).map((r) => RecipientBreakdown.fromJson(r as Map<String, dynamic>)).toList(),
      ),
      simpleParticipants: List<String>.from(json['simpleParticipants'] as List? ?? []),
    );
  }

  /// [ownerId] is the expense owner's userId — used to compute outstanding and
  /// skip the owner's own entry when listing debts.
  String getSummary(String ownerKilvishId, {String ownerId = '', num showCount = 2}) {
    if (isSettlement) {
      final recipient = recipients.firstOrNull;
      if (recipient == null) return '';
      return "@$ownerKilvishId settled ₹${recipient.amount.toStringAsFixed(0)} with @${recipient.userKilvishId}";
    }

    String message = "";
    final outstanding = (expenseAmount ?? 0) - ownerShareFor(ownerId);
    if (outstanding > 0) {
      message += '@$ownerKilvishId is owed ₹${outstanding.toStringAsFixed(0)}. ';
    }

    num count = 0;
    for (final recipient in recipients) {
      if (recipient.userId == ownerId) continue;
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

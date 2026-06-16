import 'dart:convert';
import 'dart:core';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:jiffy/jiffy.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:kilvish/cache_manager.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense_taglinks.dart';

export 'package:kilvish/models_expense_taglinks.dart';

// ─── BaseExpense ─────────────────────────────────────────────────────────────

abstract class BaseExpense {
  String get id;
  String? get to;
  DateTime? get timeOfTransaction;
  DateTime get createdAt;
  DateTime get updatedAt;

  num? get amount;
  String? get notes;

  // Per-tag configuration — recipients, outstanding, settlement info
  List<TagExpenseConfig> tagLinks = [];

  List<Tag?> get tags => tagLinks.map((tagLink) => getTagFromCache(tagLink.tagId)).toList();

  String? ownerId;
  abstract String ownerKilvishId;
  String? receiptUrl;
  String? localReceiptPath;
  String? extractedText;
  List<String> otherReceiptUrls = [];

  Future<bool> isExpenseOwner() async {
    final userId = await getUserIdFromClaim();
    if (userId == null) return false;
    if (ownerId == null) return true;
    return ownerId == userId;
  }

  // Each subclass persists tagLinks differently:
  // Expense → writes to Tags/{tagId}/Expenses subcollections + Recipients
  // WIPExpense → writes tagLinks field on WIPExpense doc
  Future<void> saveTagLink(TagExpenseConfig tagLink, {bool isRemove = false});

  static String jsonEncodeExpensesList(List<BaseExpense> expenses) {
    return jsonEncode(expenses.map((expense) => expense.toJson()).toList());
  }

  Map<String, dynamic> toJson();

  static Future<List<BaseExpense>> jsonDecodeExpenseList(String expenseListString) async {
    final List<dynamic> expenseMapList = jsonDecode(expenseListString);

    String userId = (await getUserIdFromClaim())!;

    return Future.wait(
      expenseMapList.map((map) async {
        Map<String, dynamic> typecastedMap = map as Map<String, dynamic>;
        BaseExpense expense = typecastedMap['status'] != null
            ? await WIPExpense.fromJson(typecastedMap)
            : await Expense.fromJson(typecastedMap, (await CacheManager.getUserKilvishId(typecastedMap['ownerId'] ?? userId))!);

        return expense;
      }).toList(),
    );
  }

  static DateTime decodeDateTime(Map<String, dynamic> object, String key) {
    if (object[key] is Timestamp) {
      return (object[key] as Timestamp).toDate();
    } else {
      return DateTime.parse(object[key] as String);
    }
  }

  String getTagLinkSummary(String tagId) {
    if (tagLinks.isEmpty) return formatRelativeTime(timeOfTransaction);

    for (final tagLink in tagLinks) {
      if (tagLink.tagId == tagId) {
        if (tagLink.recipients.isEmpty) {
          return formatRelativeTime(timeOfTransaction);
        }
        return tagLink.getSummary(ownerKilvishId, ownerId: ownerId ?? '');
      }
    }

    return formatRelativeTime(timeOfTransaction);
  }
}

// ─── Expense ─────────────────────────────────────────────────────────────────

class Expense extends BaseExpense {
  @override
  final String id;
  @override
  final String to;
  @override
  final DateTime timeOfTransaction;
  @override
  final DateTime createdAt;
  @override
  DateTime updatedAt;
  @override
  final num amount;
  @override
  String? notes;
  bool isUnseen = false;
  @override
  String ownerKilvishId;

  // Stored in Firestore/JSON as array of tag IDs
  List<String> tagIds = [];

  num? expenseAmount;
  // Server-stamped by onExpenseCreated — the members at the time the expense was created.
  List<String> simpleParticipants = [];

  Expense({
    required this.id,
    required this.to,
    required this.timeOfTransaction,
    required this.amount,
    required this.createdAt,
    required this.updatedAt,
    this.isUnseen = false,
    required this.ownerKilvishId,
  });

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'to': to,
    'timeOfTransaction': timeOfTransaction.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'amount': amount,
    'notes': notes,
    'receiptUrl': receiptUrl,
    'otherReceiptUrls': otherReceiptUrls,
    'tagIds': tagIds,
    'isUnseen': isUnseen,
    'ownerId': ownerId,
    //'ownerKilvishId': ownerKilvishId,
    'tagLinks': tagLinks.map((t) => t.toJson()).toList(),
    'expenseAmount': expenseAmount,
  };

  Map<String, dynamic> toFirestore() => {
    'id': id,
    'to': to,
    'timeOfTransaction': timeOfTransaction,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'amount': amount,
    'notes': notes,
    'receiptUrl': receiptUrl,
    'otherReceiptUrls': otherReceiptUrls,
    'tagIds': tagIds,
    'isUnseen': isUnseen,
    'ownerId': ownerId,
    'expenseAmount': expenseAmount,
    if (extractedText != null) 'extractedText': extractedText,
    //'ownerKilvishId': ownerKilvishId,
    //'tagLinks': tagLinks.map((t) => t.toJson()).toList(), - tagLinks never get saved in DB as is for Expense object.
  };

  static String jsonEncodeExpensesList(List<Expense> expenses) {
    return jsonEncode(expenses.map((expense) => expense.toJson()).toList());
  }

  static Future<List<Expense>> jsonDecodeExpenseListCacheForTagExpenses(String expenseListString) async {
    final List<dynamic> expenseMapList = jsonDecode(expenseListString);
    return Future.wait(
      expenseMapList.map((map) async {
        Map<String, dynamic> firestoreObject = map as Map<String, dynamic>;
        String kilvishId = (await CacheManager.getUserKilvishId(firestoreObject['ownerId'])) ?? "-";
        return Expense.fromJson(firestoreObject, kilvishId);
      }).toList(),
    );
  }

  static Future<Expense> fromJson(Map<String, dynamic> jsonObject, String ownerKilvishId) async {
    final expense = Expense.fromFirestoreObject(jsonObject['id'] as String, jsonObject, ownerKilvishId);

    expense.isUnseen = jsonObject['isUnseen'] as bool? ?? false;

    if (jsonObject['tagLinks'] != null) {
      expense.tagLinks = await Future.wait(
        (jsonObject['tagLinks'] as List).map((t) => TagExpenseConfig.fromJson(t as Map<String, dynamic>)).toList(),
      );
    }

    return expense;
  }

  /// Builds an Expense from a Firestore document and optionally hydrates tagLinks.
  /// [tagId]: hydrate only this tag's tagLink (pass when loading from Tags/{tagId}/Expenses).
  /// No tagId: hydrate all tagIds on the expense in parallel (pass when loading My Expenses).
  static Future<Expense> getExpenseFromFirestoreObject(
    String expenseId,
    Map<String, dynamic> firestoreExpense, {
    String? tagId,
  }) async {
    final String ownerId = (firestoreExpense['ownerId'] as String?) ?? (await getUserIdFromClaim())!;
    final String ownerKilvishId = (await CacheManager.getUserKilvishId(ownerId)) ?? '-';
    final expense = Expense.fromFirestoreObject(expenseId, firestoreExpense, ownerKilvishId);

    expense.ownerId ??= ownerId;

    final idsToHydrate = tagId != null ? [tagId] : expense.tagIds;
    if (idsToHydrate.isNotEmpty) {
      expense.tagLinks = await Future.wait(
        idsToHydrate.map((tid) async {
          try {
            if (tagId != null) {
              // Read recipients from the map on the Expense doc — no subcollection fetch needed.
              final rawMap = (firestoreExpense['recipients'] as Map<String, dynamic>?) ?? {};
              final recipients = rawMap.isEmpty ? <RecipientBreakdown>[] : await RecipientBreakdown.fromRecipientsMap(rawMap);
              final expenseAmount = expense.expenseAmount ?? expense.amount;
              return TagExpenseConfig(
                tagId: tid,
                expenseAmount: expenseAmount,
                recipients: recipients,
                simpleParticipants: expense.simpleParticipants,
              );
            }
            // User Expense, get expenseAmount from Tag -> Expense
            final tagExpense = await getTagExpense(tid, expenseId);
            return tagExpense!.tagLinks.first;
          } catch (e) {
            print('getExpenseFromFirestoreObject: failed to hydrate tagLink for $tid: $e');
            return TagExpenseConfig(tagId: tid, expenseAmount: firestoreExpense['expenseAmount'] as num?);
          }
        }),
      );
    }

    return expense;
  }

  factory Expense.fromFirestoreObject(String expenseId, Map<String, dynamic> firestoreExpense, String ownerKilvishIdParam) {
    final expense = Expense(
      id: expenseId,
      to: firestoreExpense['to'] as String,
      timeOfTransaction: BaseExpense.decodeDateTime(firestoreExpense, 'timeOfTransaction'),
      createdAt: BaseExpense.decodeDateTime(firestoreExpense, 'createdAt'),
      updatedAt: BaseExpense.decodeDateTime(firestoreExpense, 'updatedAt'),
      amount: firestoreExpense['amount'] as num,
      ownerKilvishId: ownerKilvishIdParam,
    );

    if (firestoreExpense['notes'] != null) expense.notes = firestoreExpense['notes'] as String;
    if (firestoreExpense['receiptUrl'] != null) expense.receiptUrl = firestoreExpense['receiptUrl'] as String;
    expense.otherReceiptUrls = List<String>.from(firestoreExpense['otherReceiptUrls'] as List? ?? []);
    expense.ownerId = firestoreExpense['ownerId'] as String?;
    expense.tagIds = List<String>.from(firestoreExpense['tagIds'] as List? ?? []);

    expense.expenseAmount = firestoreExpense['expenseAmount'] != null ? firestoreExpense['expenseAmount'] as num : expense.amount;
    expense.simpleParticipants = List<String>.from(firestoreExpense['simpleParticipants'] as List? ?? []);

    return expense;
  }

  void markAsSeen() => isUnseen = false;

  @override
  Future<void> saveTagLink(TagExpenseConfig tagLink, {bool isRemove = false}) async {
    if (isRemove) {
      await removeExpenseFromTag(tagLink.tagId, id);
      tagLinks.removeWhere((t) => t.tagId == tagLink.tagId);
      await CacheManager.removeTagExpense(tagLink.tagId, id);
      return;
    }

    final expenseRef = getFirestoreInstance().collection('Tags').doc(tagLink.tagId).collection('Expenses').doc(id);

    // Read existing Recipient docs so we can sync them in the same batch (Option A).
    final existingRecipientSnap = await expenseRef.collection('Recipients').get();

    // Firestore-serializable recipients map for the Expense doc.
    final firestoreRecipientsMap = {for (final r in tagLink.recipients) r.userId: r.toJson()};
    // Lookup map for the Recipient subdoc sync loop.
    final recipientsByUserId = {for (final r in tagLink.recipients) r.userId: r};

    final batch = getFirestoreInstance().batch();

    // Create/update the Expense doc in the Tag's Expenses collection.
    await addToOrUpdateTagExpense(tagLink.tagId, id, batchParam: batch);

    // Write recipients map (and optionally simpleParticipants) directly.
    batch.update(expenseRef, <String, dynamic>{
      'recipients': firestoreRecipientsMap,
      if (tagLink.expenseAmount != null) 'expenseAmount': tagLink.expenseAmount,
      if (tagLink.simpleParticipants.isNotEmpty) 'simpleParticipants': tagLink.simpleParticipants,
    });

    // Sync existing Recipient sub-docs: update if in new distribution, delete otherwise.
    for (final doc in existingRecipientSnap.docs) {
      final newRecipient = recipientsByUserId[doc.id];
      if (newRecipient != null && newRecipient.amount > 0) {
        newRecipient.addOrUpdate(tagLink.tagId, id, batchParam: batch);
      } else {
        batch.delete(doc.reference);
      }
    }

    await batch.commit();

    final idx = tagLinks.indexWhere((t) => t.tagId == tagLink.tagId);
    if (idx >= 0) {
      final updated = List<TagExpenseConfig>.from(tagLinks);
      updated[idx] = tagLink;
      tagLinks = updated;
    } else {
      tagLinks = [...tagLinks, tagLink];
    }

    await CacheManager.addOrUpdateTagExpense(tagLink.tagId, (await getTagExpense(tagLink.tagId, id))!, markPending: true);
    await CacheManager.addOrUpdateMyExpense((await getExpense(id))!);
  }

  Future<WIPExpense?> convertToWIP() => convertExpenseToWIPExpense(this);

  static Expense fromWIPExpense(WIPExpense wipExpense) {
    final expense = Expense(
      id: wipExpense.id,
      to: wipExpense.to!,
      timeOfTransaction: wipExpense.timeOfTransaction!,
      amount: wipExpense.amount!,
      createdAt: wipExpense.createdAt,
      updatedAt: DateTime.now(),
      ownerKilvishId: wipExpense.ownerKilvishId,
    );
    expense.receiptUrl = wipExpense.receiptUrl;
    expense.otherReceiptUrls = List.from(wipExpense.otherReceiptUrls);
    expense.extractedText = wipExpense.extractedText;
    return expense;
  }
}

// ─── ExpenseStatus ───────────────────────────────────────────────────────────

enum ExpenseStatus {
  @JsonValue('waitingToStartProcessing')
  waitingToStartProcessing,
  @JsonValue('uploadingReceipt')
  uploadingReceipt,
  @JsonValue('extractingData')
  extractingData,
  @JsonValue('readyForReview')
  readyForReview,
  // Created from FAB — never persisted to Firestore. Back press discards silently.
  inMemory,
}

// ─── WIPExpense ──────────────────────────────────────────────────────────────

class WIPExpense extends BaseExpense {
  @override
  final String id;
  @override
  String? to;
  @override
  DateTime? timeOfTransaction;
  @override
  num? amount;
  @override
  String? notes;

  ExpenseStatus status;

  @override
  final DateTime createdAt;
  @override
  DateTime updatedAt;
  String? errorMessage;

  String? loanPaybackTagName;
  num? loanPaybackAmount;

  @override
  String ownerKilvishId;

  List<String> get tagIds => tagLinks.map((tagLink) => tagLink.tagId).toList();

  WIPExpense({
    required this.id,
    this.to,
    this.timeOfTransaction,
    this.amount,
    this.notes,
    String? receiptUrl,
    required this.status,
    this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
    required this.ownerKilvishId,
    this.loanPaybackTagName,
    this.loanPaybackAmount,
  }) {
    this.receiptUrl = receiptUrl;
  }

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'to': to,
    'timeOfTransaction': timeOfTransaction?.toIso8601String(),
    'amount': amount,
    'notes': notes,
    'receiptUrl': receiptUrl,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'errorMessage': errorMessage,
    'localReceiptPath': localReceiptPath,
    'otherReceiptUrls': otherReceiptUrls,
    'ownerId': ownerId,
    'tagLinks': tagLinks.map((t) => t.toJson()).toList(),
    if (loanPaybackTagName != null) 'loanPaybackTagName': loanPaybackTagName,
    if (loanPaybackAmount != null) 'loanPaybackAmount': loanPaybackAmount,
    if (extractedText != null) 'extractedText': extractedText,
  };

  static Future<WIPExpense> fromJson(Map<String, dynamic> jsonObject) async {
    final wipExpense = await WIPExpense.fromFirestoreObject(jsonObject['id'] as String, jsonObject);
    return wipExpense;
  }

  factory WIPExpense.fromExpense(Expense expense) {
    final wipExpense = WIPExpense(
      id: expense.id,
      to: expense.to,
      timeOfTransaction: expense.timeOfTransaction,
      createdAt: expense.createdAt,
      updatedAt: DateTime.now(),
      amount: expense.amount,
      notes: expense.notes,
      receiptUrl: expense.receiptUrl,
      status: ExpenseStatus.waitingToStartProcessing,
      errorMessage: null,
      ownerKilvishId: expense.ownerKilvishId,
    );
    wipExpense.ownerId = expense.ownerId;
    wipExpense.tagLinks = List.from(expense.tagLinks);
    wipExpense.otherReceiptUrls = List.from(expense.otherReceiptUrls);
    return wipExpense;
  }

  static Future<WIPExpense> fromFirestoreObject(
    String docId,
    Map<String, dynamic> data, {
    String? ownerKilvishIdParam,
    String? ownerIdParam,
  }) async {
    final wipExpense = WIPExpense(
      id: docId,
      to: data['to'] as String?,
      timeOfTransaction: data['timeOfTransaction'] != null ? BaseExpense.decodeDateTime(data, 'timeOfTransaction') : null,
      createdAt: BaseExpense.decodeDateTime(data, 'createdAt'),
      updatedAt: BaseExpense.decodeDateTime(data, 'updatedAt'),
      amount: data['amount'] as num?,
      notes: data['notes'] as String?,
      receiptUrl: data['receiptUrl'] as String?,
      status: ExpenseStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => ExpenseStatus.waitingToStartProcessing,
      ),
      errorMessage: data['errorMessage'] as String?,
      ownerKilvishId: ownerKilvishIdParam ?? '',
    );
    wipExpense.ownerId = ownerIdParam ?? data['ownerId'] as String?;
    wipExpense.localReceiptPath = data['localReceiptPath'];
    wipExpense.extractedText = data['extractedText'] as String?;
    wipExpense.otherReceiptUrls = List<String>.from(data['otherReceiptUrls'] as List? ?? []);
    wipExpense.loanPaybackTagName = data['loanPaybackTagName'] as String?;
    wipExpense.loanPaybackAmount = data['loanPaybackAmount'] as num?;
    if (data['tagLinks'] != null) {
      wipExpense.tagLinks = await Future.wait(
        (data['tagLinks'] as List).map((t) => TagExpenseConfig.fromJson(t as Map<String, dynamic>)).toList(),
      );
    }
    return wipExpense;
  }

  Map<String, dynamic> toFirestore() {
    return {
      if (to != null) 'to': to,
      if (timeOfTransaction != null) 'timeOfTransaction': Timestamp.fromDate(timeOfTransaction!),
      if (amount != null) 'amount': amount,
      if (notes != null) 'notes': notes,
      if (receiptUrl != null) 'receiptUrl': receiptUrl,
      'status': status.name,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      if (errorMessage != null) 'errorMessage': errorMessage,
      if (ownerId != null) 'ownerId': ownerId,
      'tagLinks': tagLinks.map((t) => t.toJson()).toList(),
    };
  }

  bool canAutoConvert() {
    if (status == ExpenseStatus.readyForReview &&
        loanPaybackTagName == null &&
        to != null &&
        amount != null &&
        timeOfTransaction != null) {
      return true;
    }
    return false;
  }

  Future<Expense?> convertToExpense() async {
    final expenseData = Expense.fromWIPExpense(this).toFirestore();
    Expense? expense = await updateExpense(expenseData, this);
    return expense;
  }

  @override
  Future<void> saveTagLink(TagExpenseConfig tagLink, {bool isRemove = false}) async {
    if (isRemove) {
      tagLinks.removeWhere((t) => t.tagId == tagLink.tagId);
    } else {
      final idx = tagLinks.indexWhere((t) => t.tagId == tagLink.tagId);
      if (idx >= 0) {
        final updated = List<TagExpenseConfig>.from(tagLinks);
        updated[idx] = tagLink;
        tagLinks = updated;
      } else {
        tagLinks = [...tagLinks, tagLink];
      }
    }
    // In-memory WIPExpenses are never persisted — skip all Firestore/cache writes.
    if (status == ExpenseStatus.inMemory) return;

    await updateWIPExpenseTagLinks(id, tagLinks);
    await CacheManager.addOrUpdateWIPExpense(this);
  }

  String getStatusDisplayText() {
    switch (status) {
      case ExpenseStatus.waitingToStartProcessing:
        return 'Waiting to start processing...';
      case ExpenseStatus.uploadingReceipt:
        return 'Uploading receipt...';
      case ExpenseStatus.extractingData:
        return 'Extracting data...';
      case ExpenseStatus.readyForReview:
        return 'Ready for review';
      case ExpenseStatus.inMemory:
        return 'New expense';
    }
  }

  MaterialColor getStatusColor() {
    switch (status) {
      case ExpenseStatus.uploadingReceipt:
      case ExpenseStatus.extractingData:
        return Colors.orange;
      case ExpenseStatus.readyForReview:
        return Colors.green;
      default:
        return Colors.blue;
    }
  }

  /// Creates a WIPExpense purely in memory — no Firestore write.
  /// Used for FAB-initiated expense creation. Back press discards silently.
  static Future<WIPExpense> createWIPExpenseInMemory({
    required String currentUserId,
    required String currentUserKilvishId,
    Tag? tag,
    bool isSettlement = false,
  }) async {
    final now = DateTime.now();
    final monthKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';

    final wip = WIPExpense(
      id: FirebaseFirestore.instance.collection('WIPExpenses').doc().id,
      status: ExpenseStatus.inMemory,
      createdAt: now,
      updatedAt: now,
      ownerKilvishId: currentUserKilvishId,
    );
    wip.ownerId = currentUserId;

    if (tag != null) {
      if (!isSettlement) {
        wip.tagLinks = [TagExpenseConfig(tagId: tag.id)];
        return wip;
      }

      // Pick the counterparty: first other user with outstanding > 0 (they are owed money)
      final counterparty = tag.total.userWise.entries.where((e) => e.key != currentUserId && e.value.outstanding > 0).firstOrNull;
      if (counterparty == null) {
        wip.tagLinks = [TagExpenseConfig(tagId: tag.id)];
        return wip;
      }

      wip.tagLinks = [
        TagExpenseConfig(
          tagId: tag.id,
          expenseAmount: null, // TagExpenseConfigScreen will use expense.amount
          recipients: [
            RecipientBreakdown(
              userId: counterparty.key,
              userKilvishId: null, // resolved at save time in TagExpenseConfigScreen._done()
              amount: 0,
              settlementMonth: monthKey, // makes isSettlement == true
            ),
          ],
        ),
      ];
    }

    return wip;
  }
}

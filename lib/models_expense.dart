import 'dart:convert';
import 'dart:core';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';

// ─── TagExpenseConfig ────────────────────────────────────────────────────────
// Unified class for both UI state (ownerShare, removed) and persistence
// (tagId, isSettlement, recipientAmounts, settlementMonth, settlementCounterpartyId).

class TagExpenseConfig {
  final String tagId;
  final bool isSettlement;
  final String? settlementMonth;
  final String? settlementCounterpartyId;
  final Map<String, num> recipientAmounts; // userId → amount
  final num ownerShare;
  final bool removed; // UI-only flag, never serialized

  const TagExpenseConfig({
    required this.tagId,
    this.isSettlement = false,
    this.settlementMonth,
    this.settlementCounterpartyId,
    this.recipientAmounts = const {},
    this.ownerShare = 0,
    this.removed = false,
  });

  num computeOutstanding(num expenseAmount) => expenseAmount - ownerShare;

  Map<String, dynamic> toJson() => {
    'tagId': tagId,
    'isSettlement': isSettlement,
    if (settlementMonth != null) 'settlementMonth': settlementMonth,
    if (settlementCounterpartyId != null) 'settlementCounterpartyId': settlementCounterpartyId,
    'recipientAmounts': recipientAmounts,
    'ownerShare': ownerShare,
  };

  factory TagExpenseConfig.fromJson(Map<String, dynamic> json) => TagExpenseConfig(
    tagId: json['tagId'] as String,
    isSettlement: json['isSettlement'] as bool? ?? false,
    settlementMonth: json['settlementMonth'] as String?,
    settlementCounterpartyId: json['settlementCounterpartyId'] as String?,
    recipientAmounts: (json['recipientAmounts'] as Map<String, dynamic>? ?? {}).map((k, v) => MapEntry(k, v as num)),
    ownerShare: json['ownerShare'] as num? ?? 0,
  );

  // Only Firestore-relevant fields for updating the tag expense doc.
  Map<String, dynamic> toFirestore(num expenseAmount) => {
    'totalOutstandingAmount': isSettlement ? 0 : computeOutstanding(expenseAmount),
    'isSettlement': isSettlement,
  };
}

// ─── RecipientBreakdown ──────────────────────────────────────────────────────

class RecipientBreakdown {
  final String userId;
  final num amount;
  final String? settlementMonth;

  RecipientBreakdown({required this.userId, required this.amount, this.settlementMonth});

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'amount': amount,
    if (settlementMonth != null) 'settlementMonth': settlementMonth,
  };

  factory RecipientBreakdown.fromJson(Map<String, dynamic> json) => RecipientBreakdown(
    userId: json['userId'] as String,
    amount: json['amount'] as num,
    settlementMonth: json['settlementMonth'] as String?,
  );
}

// ─── BaseExpense ─────────────────────────────────────────────────────────────

abstract class BaseExpense {
  String get id;
  String? get to;
  DateTime? get timeOfTransaction;
  DateTime get createdAt;
  DateTime get updatedAt;

  num? get amount;
  String? get receiptUrl;
  String? get notes;

  // Runtime display field — hydrated from tags cache, never stored
  Set<Tag> tags = {};
  // Stored in Firestore/JSON as array of tag IDs
  List<String> tagIds = [];
  // Per-tag configuration — recipients, outstanding, settlement info
  List<TagExpenseConfig> tagLinks = [];

  String? ownerId;
  abstract String ownerKilvishId;
  String? localReceiptPath;

  Future<bool> isExpenseOwner() async {
    final userId = await getUserIdFromClaim();
    if (userId == null) return false;
    if (ownerId == null) return true;
    return ownerId == userId;
  }

  // Each subclass persists tagLinks differently:
  // Expense → writes to Tags/{tagId}/Expenses subcollections + Recipients
  // WIPExpense → writes tagLinks field on WIPExpense doc
  Future<void> saveTagData(List<TagExpenseConfig> newTagLinks);

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
            ? WIPExpense.fromJson(typecastedMap)
            : Expense.fromJson(typecastedMap, (await getUserKilvishId(typecastedMap['ownerId'] ?? userId))!);

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
}

// ─── Expense ─────────────────────────────────────────────────────────────────

class Expense extends BaseExpense {
  @override
  final String id;
  final String txId;
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
  @override
  String? receiptUrl;
  bool isUnseen = false;
  @override
  String ownerKilvishId;

  Expense({
    required this.id,
    required this.txId,
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
    'txId': txId,
    'to': to,
    'timeOfTransaction': timeOfTransaction.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'amount': amount,
    'notes': notes,
    'receiptUrl': receiptUrl,
    'tagIds': tagIds,
    'isUnseen': isUnseen,
    'ownerId': ownerId,
    //'ownerKilvishId': ownerKilvishId,
    'tagLinks': tagLinks.map((t) => t.toJson()).toList(),
  };

  static String jsonEncodeExpensesList(List<Expense> expenses) {
    return jsonEncode(expenses.map((expense) => expense.toJson()).toList());
  }

  static Future<List<Expense>> jsonDecodeExpenseListCacheForTagExpenses(String expenseListString) async {
    final List<dynamic> expenseMapList = jsonDecode(expenseListString);
    return Future.wait(
      expenseMapList.map((map) async {
        Map<String, dynamic> firestoreObject = map as Map<String, dynamic>;
        String kilvishId = (await getUserKilvishId(firestoreObject['ownerId'])) ?? "-";
        return Expense.fromJson(firestoreObject, kilvishId);
      }).toList(),
    );
  }

  factory Expense.fromJson(Map<String, dynamic> jsonObject, String ownerKilvishId) {
    final expense = Expense.fromFirestoreObject(jsonObject['id'] as String, jsonObject, ownerKilvishId);
    expense.isUnseen = jsonObject['isUnseen'] as bool? ?? false;
    if (jsonObject['tagLinks'] != null) {
      expense.tagLinks = (jsonObject['tagLinks'] as List)
          .map((t) => TagExpenseConfig.fromJson(t as Map<String, dynamic>))
          .toList();
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
    final String ownerKilvishId = (await getUserKilvishId(ownerId)) ?? '-';
    final expense = Expense.fromFirestoreObject(expenseId, firestoreExpense, ownerKilvishId);

    final idsToHydrate = tagId != null ? [tagId] : expense.tagIds;
    if (idsToHydrate.isNotEmpty) {
      final tagLinks = await Future.wait(
        idsToHydrate.map((tid) async {
          try {
            final recipients = await fetchExpenseRecipients(tid, expenseId);
            return buildTagLinkFromRecipients(tid, recipients, expense.amount);
          } catch (e) {
            print('getExpenseFromFirestoreObject: failed to hydrate tagLink for $tid: $e');
            return TagExpenseConfig(tagId: tid);
          }
        }),
      );
      expense.tagLinks = tagLinks;
    }

    return expense;
  }

  static TagExpenseConfig buildTagLinkFromRecipients(
    String tagId,
    List<RecipientBreakdown> recipients,
    num expenseAmount,
  ) {
    final recipientAmounts = <String, num>{};
    String? settlementCounterpartyId;
    String? settlementMonth;

    for (final r in recipients) {
      recipientAmounts[r.userId] = r.amount;
      if (r.settlementMonth != null) {
        settlementCounterpartyId = r.userId;
        settlementMonth = r.settlementMonth;
      }
    }

    final isSettlement = settlementMonth != null;
    final totalOutstanding = isSettlement
        ? 0
        : recipients.fold<num>(0, (sum, r) => sum + r.amount);
    final ownerShare = expenseAmount - totalOutstanding;

    return TagExpenseConfig(
      tagId: tagId,
      isSettlement: isSettlement,
      settlementMonth: settlementMonth,
      settlementCounterpartyId: settlementCounterpartyId,
      recipientAmounts: isSettlement ? const {} : recipientAmounts,
      ownerShare: ownerShare > 0 ? ownerShare : 0,
    );
  }

  factory Expense.fromFirestoreObject(String expenseId, Map<String, dynamic> firestoreExpense, String ownerKilvishIdParam) {
    final expense = Expense(
      id: expenseId,
      to: firestoreExpense['to'] as String,
      timeOfTransaction: BaseExpense.decodeDateTime(firestoreExpense, 'timeOfTransaction'),
      createdAt: BaseExpense.decodeDateTime(firestoreExpense, 'createdAt'),
      updatedAt: BaseExpense.decodeDateTime(firestoreExpense, 'updatedAt'),
      amount: firestoreExpense['amount'] as num,
      txId: firestoreExpense['txId'] as String,
      ownerKilvishId: ownerKilvishIdParam,
    );

    if (firestoreExpense['notes'] != null) expense.notes = firestoreExpense['notes'] as String;
    if (firestoreExpense['receiptUrl'] != null) expense.receiptUrl = firestoreExpense['receiptUrl'] as String;
    expense.ownerId = firestoreExpense['ownerId'] as String?;
    expense.tagIds = List<String>.from(firestoreExpense['tagIds'] as List? ?? []);

    return expense;
  }

  void markAsSeen() => isUnseen = false;
  void setUnseenStatus(Set<String> unseenExpenseIds) => isUnseen = unseenExpenseIds.contains(id);

  // Diffs newTagLinks against current tagLinks, writes to Firestore, updates this object.
  @override
  Future<void> saveTagData(List<TagExpenseConfig> newTagLinks) async {
    final oldTagIds = tagLinks.map((t) => t.tagId).toSet();
    final newTagIds = newTagLinks.map((t) => t.tagId).toSet();

    for (final tagId in oldTagIds.difference(newTagIds)) {
      await removeExpenseFromTag(tagId, id);
    }

    for (final config in newTagLinks) {
      final outstanding = config.isSettlement ? 0 : config.computeOutstanding(amount);
      if (!oldTagIds.contains(config.tagId)) {
        await addExpenseToTag(config.tagId, id, totalOutstandingAmount: outstanding, isSettlement: config.isSettlement);
      } else {
        await updateTagExpenseData(config.tagId, id, totalOutstandingAmount: outstanding, isSettlement: config.isSettlement);
      }
      await _saveTagRecipients(config);
    }

    tagIds = newTagIds.toList();
    await updateExpenseTagIds(id, tagIds);
    tagLinks = List.from(newTagLinks);
  }

  Future<void> _saveTagRecipients(TagExpenseConfig config) async {
    if (config.isSettlement) {
      final counterparty = config.settlementCounterpartyId;
      if (counterparty != null) {
        await addOrUpdateRecipient(config.tagId, id, counterparty, amount, settlementMonth: config.settlementMonth);
      }
    } else {
      for (final entry in config.recipientAmounts.entries) {
        if (entry.value > 0) {
          await addOrUpdateRecipient(config.tagId, id, entry.key, entry.value);
        } else {
          await removeRecipient(config.tagId, id, entry.key);
        }
      }
    }
  }

  Future<WIPExpense?> convertToWIP() => convertExpenseToWIPExpense(this);
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
  @override
  String? receiptUrl;

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

  WIPExpense({
    required this.id,
    this.to,
    this.timeOfTransaction,
    this.amount,
    this.notes,
    this.receiptUrl,
    required this.status,
    this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
    required this.ownerKilvishId,
    this.loanPaybackTagName,
    this.loanPaybackAmount,
  });

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'to': to,
    'timeOfTransaction': timeOfTransaction?.toIso8601String(),
    'amount': amount,
    'notes': notes,
    'receiptUrl': receiptUrl,
    'tagIds': tagIds,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'errorMessage': errorMessage,
    'localReceiptPath': localReceiptPath,
    'ownerId': ownerId,
    'tagLinks': tagLinks.map((t) => t.toJson()).toList(),
    if (loanPaybackTagName != null) 'loanPaybackTagName': loanPaybackTagName,
    if (loanPaybackAmount != null) 'loanPaybackAmount': loanPaybackAmount,
  };

  factory WIPExpense.fromJson(Map<String, dynamic> jsonObject) {
    final wipExpense = WIPExpense.fromFirestoreObject(jsonObject['id'] as String, jsonObject);
    wipExpense.tagIds = List<String>.from(jsonObject['tagIds'] as List? ?? []);
    if (jsonObject['tagLinks'] != null) {
      wipExpense.tagLinks = (jsonObject['tagLinks'] as List)
          .map((t) => TagExpenseConfig.fromJson(t as Map<String, dynamic>))
          .toList();
    }
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
    wipExpense.tagIds = List.from(expense.tagIds);
    wipExpense.tagLinks = List.from(expense.tagLinks);
    return wipExpense;
  }

  factory WIPExpense.fromFirestoreObject(
    String docId,
    Map<String, dynamic> data, {
    String? ownerKilvishIdParam,
    String? ownerIdParam,
  }) {
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
    wipExpense.tagIds = List<String>.from(data['tagIds'] as List? ?? []);
    wipExpense.localReceiptPath = data['localReceiptPath'];
    wipExpense.loanPaybackTagName = data['loanPaybackTagName'] as String?;
    wipExpense.loanPaybackAmount = data['loanPaybackAmount'] as num?;
    if (data['tagLinks'] != null) {
      wipExpense.tagLinks = (data['tagLinks'] as List).map((t) => TagExpenseConfig.fromJson(t as Map<String, dynamic>)).toList();
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
      'tagIds': tagIds,
      'tagLinks': tagLinks.map((t) => t.toJson()).toList(),
      if (loanPaybackTagName != null) 'loanPaybackTagName': loanPaybackTagName,
      if (loanPaybackAmount != null) 'loanPaybackAmount': loanPaybackAmount,
    };
  }

  // WIPExpense saveTagData just updates its own Firestore doc — no subcollection writes.
  // Those happen when WIPExpense is converted to Expense.
  @override
  Future<void> saveTagData(List<TagExpenseConfig> newTagLinks) async {
    tagIds = newTagLinks.map((t) => t.tagId).toList();
    tagLinks = List.from(newTagLinks);
    await updateWIPExpenseTagLinks(id, tagIds, tagLinks);
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
}

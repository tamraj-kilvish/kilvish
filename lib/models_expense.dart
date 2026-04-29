import 'dart:convert';
import 'dart:core';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';

class RecipientBreakdown {
  final String userId;
  final num amount;

  RecipientBreakdown({required this.userId, required this.amount});

  Map<String, dynamic> toJson() => {'userId': userId, 'amount': amount};

  factory RecipientBreakdown.fromJson(Map<String, dynamic> json) => RecipientBreakdown(
    userId: json['userId'] as String,
    amount: json['amount'] as num,
  );
}

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

  abstract String ownerKilvishId;
  String? localReceiptPath;

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
  String? ownerId;
  @override
  String ownerKilvishId;

  // Only populated when loaded from Tags/{tagId}/Expenses context
  num? totalOutstandingAmount;
  List<RecipientBreakdown> recipients = [];

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
    if (totalOutstandingAmount != null) 'totalOutstandingAmount': totalOutstandingAmount,
    'recipients': recipients.map((r) => r.toJson()).toList(),
  };

  static String jsonEncodeExpensesList(List<Expense> expenses) {
    return jsonEncode(expenses.map((expense) => expense.toJson()).toList());
  }

  static Future<List<Expense>> jsonDecodeExpenseList(String expenseListString) async {
    final List<dynamic> expenseMapList = jsonDecode(expenseListString);
    return Future.wait(
      expenseMapList.map((map) async {
        Map<String, dynamic> firestoreObject = map as Map<String, dynamic>;
        return await Expense.getExpenseFromFirestoreObject(firestoreObject['id'], firestoreObject);
      }).toList(),
    );
  }

  factory Expense.fromJson(Map<String, dynamic> jsonObject, String ownerKilvishId) {
    final expense = Expense.fromFirestoreObject(jsonObject['id'] as String, jsonObject, ownerKilvishId);
    expense.isUnseen = jsonObject['isUnseen'] as bool? ?? false;
    return expense;
  }

  static Future<Expense> getExpenseFromFirestoreObject(String expenseId, Map<String, dynamic> firestoreExpense) async {
    String ownerId = firestoreExpense['ownerId'] ?? await getUserIdFromClaim();
    String ownerKilvishId = (await getUserKilvishId(ownerId))!;
    return Expense.fromFirestoreObject(expenseId, firestoreExpense, ownerKilvishId);
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
    if (firestoreExpense['ownerId'] != null) expense.ownerId = firestoreExpense['ownerId'] as String;
    expense.tagIds = List<String>.from(firestoreExpense['tagIds'] as List? ?? []);
    if (firestoreExpense['totalOutstandingAmount'] != null) {
      expense.totalOutstandingAmount = firestoreExpense['totalOutstandingAmount'] as num;
    }
    if (firestoreExpense['recipients'] != null) {
      expense.recipients = (firestoreExpense['recipients'] as List)
          .map((r) => RecipientBreakdown.fromJson(r as Map<String, dynamic>))
          .toList();
    }

    return expense;
  }

  void markAsSeen() {
    isUnseen = false;
  }

  void setUnseenStatus(Set<String> unseenExpenseIds) {
    isUnseen = unseenExpenseIds.contains(id);
  }

  Future<bool> isExpenseOwner() async {
    final userId = await getUserIdFromClaim();
    if (userId == null) return false;
    if (ownerId == null) return true;
    if (ownerId != null && ownerId == userId) return true;
    return false;
  }
}

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
    if (loanPaybackTagName != null) 'loanPaybackTagName': loanPaybackTagName,
    if (loanPaybackAmount != null) 'loanPaybackAmount': loanPaybackAmount,
  };

  factory WIPExpense.fromJson(Map<String, dynamic> jsonObject) {
    final wipExpense = WIPExpense.fromFirestoreObject(jsonObject['id'] as String, jsonObject);
    wipExpense.tagIds = List<String>.from(jsonObject['tagIds'] as List? ?? []);
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
    wipExpense.tagIds = List.from(expense.tagIds);
    return wipExpense;
  }

  factory WIPExpense.fromFirestoreObject(String docId, Map<String, dynamic> data, {String? ownerKilvishIdParam}) {
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

    wipExpense.tagIds = List<String>.from(data['tagIds'] as List? ?? []);
    wipExpense.localReceiptPath = data['localReceiptPath'];
    wipExpense.loanPaybackTagName = data['loanPaybackTagName'] as String?;
    wipExpense.loanPaybackAmount = data['loanPaybackAmount'] as num?;
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
      'tagIds': tagIds,
      if (loanPaybackTagName != null) 'loanPaybackTagName': loanPaybackTagName,
      if (loanPaybackAmount != null) 'loanPaybackAmount': loanPaybackAmount,
    };
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

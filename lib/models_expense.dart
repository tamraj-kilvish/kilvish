import 'dart:convert';
import 'dart:core';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';

class SettlementEntry {
  final String to; // recipient userId
  final int month;
  final int year;
  final String tagId;

  SettlementEntry({required this.to, required this.month, required this.year, required this.tagId});

  Map<String, dynamic> toJson() => {'to': to, 'month': month, 'year': year, 'tagId': tagId};

  factory SettlementEntry.fromJson(Map<String, dynamic> json) {
    return SettlementEntry(
      to: json['to'] as String,
      month: json['month'] as int,
      year: json['year'] as int,
      tagId: json['tagId'] as String,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SettlementEntry &&
          runtimeType == other.runtimeType &&
          to == other.to &&
          month == other.month &&
          year == other.year &&
          tagId == other.tagId;

  @override
  int get hashCode => to.hashCode ^ month.hashCode ^ year.hashCode ^ tagId.hashCode;
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
  Set<Tag> get tags;
  abstract String ownerKilvishId;
  String? localReceiptPath; //only used for WIPExpense .. never saved to Firestore
  List<SettlementEntry> settlements = []; // settlement data

  static String jsonEncodeExpensesList(List<BaseExpense> expenses) {
    return jsonEncode(expenses.map((expense) => expense.toJson()).toList());
  }

  Map<String, dynamic> toJson();
  void setTags(Set<Tag> tags);

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
  @override
  Set<Tag> tags = {};
  bool isUnseen = false; // Derived field - set when loading based on User's unseenExpenseIds
  String? ownerId;
  @override
  String ownerKilvishId;

  Set<String>? tagIds;

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
    'tags': tags.isNotEmpty ? jsonEncode(tags.map((tag) => tag.toJson()).toList()) : null,
    'isUnseen': isUnseen,
    'ownerId': ownerId,
    //'ownerKilvishId': ownerKilvishId, //kilvishId is never stored but always calculated during runtime as person could have updated it
    'tagIds': tagIds?.toList(),
    'settlements': settlements.isNotEmpty ? settlements.map((s) => s.toJson()).toList() : null,
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
    Expense expense = Expense.fromFirestoreObject(jsonObject['id'] as String, jsonObject, ownerKilvishId);

    if (jsonObject['tags'] != null) {
      List<dynamic> tagsList = jsonDecode(jsonObject['tags']);
      expense.tags = tagsList.map((map) => Tag.fromJson(map as Map<String, dynamic>)).toSet();
    }

    if (jsonObject['tagIds'] != null) {
      expense.tagIds = (jsonObject['tagIds'] as List<dynamic>).map((e) => e.toString()).toSet();
    }

    if (jsonObject['settlements'] != null) {
      expense.settlements = (jsonObject['settlements'] as List<dynamic>)
          .map((s) => SettlementEntry.fromJson(s as Map<String, dynamic>))
          .toList();
    }

    expense.isUnseen = jsonObject['isUnseen'] as bool;

    return expense;
  }

  static Future<Expense> getExpenseFromFirestoreObject(String expenseId, Map<String, dynamic> firestoreExpense) async {
    String ownerId = firestoreExpense['ownerId'] ?? await getUserIdFromClaim();

    String ownerKilvishId = (await getUserKilvishId(ownerId))!;
    return Expense.fromFirestoreObject(expenseId, firestoreExpense, ownerKilvishId);
  }

  factory Expense.fromFirestoreObject(String expenseId, Map<String, dynamic> firestoreExpense, String ownerKilvishIdParam) {
    Expense expense = Expense(
      id: expenseId,
      to: firestoreExpense['to'] as String,
      timeOfTransaction: BaseExpense.decodeDateTime(firestoreExpense, 'timeOfTransaction'),
      createdAt: BaseExpense.decodeDateTime(firestoreExpense, 'createdAt'),
      updatedAt: BaseExpense.decodeDateTime(firestoreExpense, 'updatedAt'),

      amount: firestoreExpense['amount'] as num,
      txId: firestoreExpense['txId'] as String,
      ownerKilvishId: ownerKilvishIdParam,
    );

    if (firestoreExpense['notes'] != null) {
      expense.notes = firestoreExpense['notes'] as String;
    }
    if (firestoreExpense['receiptUrl'] != null) {
      expense.receiptUrl = firestoreExpense['receiptUrl'] as String;
    }
    if (firestoreExpense['ownerId'] != null) {
      expense.ownerId = firestoreExpense['ownerId'] as String;
    }
    if (firestoreExpense['tagIds'] != null) {
      expense.tagIds = (firestoreExpense['tagIds'] as List<dynamic>).map((e) => e.toString()).toSet();
      // cant get Tags from tagIds & attach to expense as it would require an await
    }
    if (firestoreExpense['settlements'] != null) {
      expense.settlements = (firestoreExpense['settlements'] as List<dynamic>)
          .map((s) => SettlementEntry.fromJson(s as Map<String, dynamic>))
          .toList();
    }

    return expense;
  }

  void addTagToExpense(Tag tag) {
    tags.add(tag);
  }

  // Mark this expense as seen (updates local state only)
  void markAsSeen() {
    isUnseen = false;
  }

  // Set unseen status based on User's unseenExpenseIds
  void setUnseenStatus(Set<String> unseenExpenseIds) {
    isUnseen = unseenExpenseIds.contains(id);
  }

  Future<bool> isExpenseOwner() async {
    final userId = await getUserIdFromClaim();
    if (userId == null) return false;

    if (ownerId == null) return true; // ideally we should check if User doc -> Expenses contain this expense but later ..
    if (ownerId != null && ownerId == userId) return true;
    return false;
  }

  @override
  void setTags(Set<Tag> tagsParam) {
    tags = tagsParam;
  }
}

enum ExpenseStatus {
  @JsonValue('waitingToStartProcessing')
  waitingToStartProcessing,
  @JsonValue('uploadingReceipt')
  uploadingReceipt, // Upload in progress
  @JsonValue('extractingData')
  extractingData, // OCR in progress (server-side)
  @JsonValue('readyForReview')
  readyForReview, // OCR complete, needs user review
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

  @override
  Set<Tag> tags = {};

  ExpenseStatus status;

  @override
  final DateTime createdAt;
  @override
  DateTime updatedAt; //need updatedAt for sorting in home screen
  String? errorMessage;

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
    required this.tags,
    required this.ownerKilvishId,
  });

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'to': to,
    'timeOfTransaction': timeOfTransaction?.toIso8601String(),
    'amount': amount,
    'notes': notes,
    'receiptUrl': receiptUrl,
    'tags': jsonEncode(tags.map((tag) => tag.toJson()).toList()),

    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'errorMessage': errorMessage,
    //'ownerKilvishId': ownerKilvishId,
    'localReceiptPath': localReceiptPath,
    'settlements': settlements.isNotEmpty ? settlements.map((s) => s.toJson()).toList() : null,
  };

  static Future<List<WIPExpense>> jsonDecodeWIPExpenseList(String expenseListString) async {
    final List<dynamic> expenseMapList = jsonDecode(expenseListString);
    return Future.wait(
      expenseMapList.map((map) async {
        Map<String, dynamic> firestoreObject = map as Map<String, dynamic>;
        WIPExpense expense = WIPExpense.fromJson(firestoreObject);
        expense.ownerKilvishId = (await getUserKilvishId(firestoreObject['ownerId'] ?? await getUserIdFromClaim()))!;
        return expense;
      }).toList(),
    );
  }

  factory WIPExpense.fromJson(Map<String, dynamic> jsonObject) {
    WIPExpense wipExpense = WIPExpense.fromFirestoreObject(jsonObject['id'] as String, jsonObject);

    //if (jsonObject['tags'] != null) {
    List<dynamic> tagsList = jsonDecode(jsonObject['tags']);
    wipExpense.tags = tagsList.map((map) => Tag.fromJson(map as Map<String, dynamic>)).toSet();
    //}

    if (jsonObject['settlements'] != null) {
      wipExpense.settlements = (jsonObject['settlements'] as List<dynamic>)
          .map((s) => SettlementEntry.fromJson(s as Map<String, dynamic>))
          .toList();
    }

    return wipExpense;
  }

  factory WIPExpense.fromExpense(Expense expense) {
    return WIPExpense(
      id: expense.id,
      to: expense.to,
      timeOfTransaction: expense.timeOfTransaction,
      createdAt: expense.createdAt, //keep the creation time of original Expense
      updatedAt: DateTime.now(),
      amount: expense.amount,
      notes: expense.notes,
      receiptUrl: expense.receiptUrl,
      tags: expense.tags,

      status: ExpenseStatus.waitingToStartProcessing,
      errorMessage: null,
      ownerKilvishId: expense.ownerKilvishId,
    );
  }

  factory WIPExpense.fromFirestoreObject(String docId, Map<String, dynamic> data, {String? ownerKilvishIdParam}) {
    WIPExpense wipExpense = WIPExpense(
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
      tags: Tag.jsonDecodeTagsList(data['tags'] as String).toSet(),
      ownerKilvishId: ownerKilvishIdParam ?? "",
    );

    wipExpense.localReceiptPath = data['localReceiptPath'];

    if (data['settlements'] != null) {
      wipExpense.settlements = (data['settlements'] as List<dynamic>)
          .map((s) => SettlementEntry.fromJson(s as Map<String, dynamic>))
          .toList();
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
      'tags': Tag.jsonEncodeTagsList(tags.toList()),
      if (settlements.isNotEmpty) 'settlements': settlements.map((s) => s.toJson()).toList(),
    };
  }

  String getStatusDisplayText() {
    switch (status) {
      case ExpenseStatus.uploadingReceipt:
        return 'Uploading receipt...';
      case ExpenseStatus.extractingData:
        return 'Extracting data...';
      case ExpenseStatus.readyForReview:
        return 'Ready for review';
      default:
        return "Attach receipt to start processing";
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

  @override
  void setTags(Set<Tag> tagsParam) {
    tags = tagsParam;
  }
}

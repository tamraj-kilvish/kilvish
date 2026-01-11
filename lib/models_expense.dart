import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
            : Expense.fromJson(typecastedMap);
        expense.ownerKilvishId = (await getUserKilvishId(typecastedMap['ownerId'] ?? userId))!;

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
    //'ownerKilvishId': ownerKilvishId, //I think it might be ok to store ownerKilvishId locally
  };

  static String jsonEncodeExpensesList(List<Expense> expenses) {
    return jsonEncode(expenses.map((expense) => expense.toJson()).toList());
  }

  static Future<List<Expense>> jsonDecodeExpenseList(String expenseListString) async {
    final List<dynamic> expenseMapList = jsonDecode(expenseListString);
    return Future.wait(
      expenseMapList.map((map) async {
        Map<String, dynamic> firestoreObject = map as Map<String, dynamic>;
        Expense expense = Expense.fromJson(firestoreObject);
        expense.ownerKilvishId = (await getUserKilvishId(firestoreObject['ownerId'] ?? await getUserIdFromClaim()))!;
        return expense;
      }).toList(),
    );
  }

  factory Expense.fromJson(Map<String, dynamic> jsonObject) {
    Expense expense = Expense.fromFirestoreObject(jsonObject['id'] as String, jsonObject);

    if (jsonObject['tags'] != null) {
      List<dynamic> tagsList = jsonDecode(jsonObject['tags']);
      expense.tags = tagsList.map((map) => Tag.fromJson(map as Map<String, dynamic>)).toSet();
    }

    expense.isUnseen = jsonObject['isUnseen'] as bool;

    return expense;
  }

  static Future<Expense> getExpenseFromFirestoreObject(
    String expenseId,
    Map<String, dynamic> firestoreExpense, {
    String? ownerId,
  }) async {
    String ownerKilvishId = (await getUserKilvishId(ownerId ?? firestoreExpense['ownerId']))!;
    return Expense.fromFirestoreObject(expenseId, firestoreExpense, ownerKilvishIdParam: ownerKilvishId);
  }

  factory Expense.fromFirestoreObject(String expenseId, Map<String, dynamic> firestoreExpense, {String? ownerKilvishIdParam}) {
    Expense expense = Expense(
      id: expenseId,
      to: firestoreExpense['to'] as String,
      timeOfTransaction: BaseExpense.decodeDateTime(
        firestoreExpense,
        'timeOfTransaction',
      ), //(firestoreExpense['timeOfTransaction'] as Timestamp).toDate(),
      //(firestoreExpense['updatedAt'] as Timestamp).toDate(),
      createdAt: BaseExpense.decodeDateTime(firestoreExpense, 'createdAt'),
      updatedAt: BaseExpense.decodeDateTime(firestoreExpense, 'updatedAt'),

      amount: firestoreExpense['amount'] as num,
      txId: firestoreExpense['txId'] as String,
      ownerKilvishId: ownerKilvishIdParam ?? "",
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

  static Future<List<Expense>?> getHomeScreenExpenses(KilvishUser user) async {
    try {
      Map<String, Expense> allExpensesMap = {};

      // Get user own expenses
      List<QueryDocumentSnapshot<Object?>> expensesSnapshotDocs = await getExpenseDocsOfUser(user.id);

      print("Got ${expensesSnapshotDocs.length} own expenses of user");

      for (QueryDocumentSnapshot expenseDoc in expensesSnapshotDocs) {
        Expense? expense = allExpensesMap[expenseDoc.id];

        if (expense == null) {
          expense = Expense.fromFirestoreObject(
            expenseDoc.id,
            expenseDoc.data() as Map<String, dynamic>,
            ownerKilvishIdParam: user.kilvishId,
          );
          // Set unseen status based on user's unseenExpenseIds
          expense.setUnseenStatus(user.unseenExpenseIds);
          allExpensesMap[expenseDoc.id] = expense;
        }
      }

      // For each tag, get its expenses
      if (user.accessibleTagIds.isNotEmpty) {
        for (String tagId in user.accessibleTagIds.toList()) {
          try {
            final Tag tag = await getTagData(tagId);

            List<QueryDocumentSnapshot<Object?>> expensesSnapshotDocs = await getExpenseDocsUnderTag(tagId);

            print("Got ${expensesSnapshotDocs.length} expenses from $tagId");

            for (QueryDocumentSnapshot expenseDoc in expensesSnapshotDocs) {
              Expense? expense = allExpensesMap[expenseDoc.id];

              if (expense == null) {
                expense = await Expense.getExpenseFromFirestoreObject(expenseDoc.id, expenseDoc.data() as Map<String, dynamic>);
                // Set unseen status based on user's unseenExpenseIds
                expense.setUnseenStatus(user.unseenExpenseIds);

                allExpensesMap[expenseDoc.id] = expense;
              }

              expense.addTagToExpense(tag);
            }
          } catch (e, stackTrace) {
            print('Error processing expenses from $tagId');
            print('$e $stackTrace');
          }
        }
      }

      List<Expense> allExpenses = allExpensesMap.values.toList();

      // Sort all expenses by date (most recent first)
      allExpenses.sort((a, b) {
        DateTime dateA = a.updatedAt;
        DateTime dateB = b.updatedAt;

        return dateB.compareTo(dateA);
      });

      return allExpenses;
      //_expenses = allExpenses;
      //asyncPrefs.setString('_expenses', Expense.jsonEncodeExpensesList(_expenses));
    } catch (e, stackTrace) {
      print('Error loading expenses - $e, $stackTrace');
      return null;
    }
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

bool loadDataRunning = false;

List<Expense>? cachedExpenses;
final asyncPrefs = SharedPreferencesAsync();

Future<void> loadData(String eventType) async {
  if (loadDataRunning) return;
  loadDataRunning = true;

  KilvishUser? user = await getLoggedInUserData();
  if (user == null) return;

  if (eventType == 'wip_status_update' || eventType == 'wip_ready') {
    if (cachedExpenses != null) {
      List<WIPExpense> wipExpenses = await getAllWIPExpenses();
      print('Got ${wipExpenses.length} wipExpenses');

      asyncPrefs.setString('_expenses', BaseExpense.jsonEncodeExpensesList([...wipExpenses, ...cachedExpenses!]));

      loadDataRunning = false;
      return;
    }
  }

  List<Tag> tags = await Tag.loadTags(user);

  List<WIPExpense> wipExpenses = await getAllWIPExpenses();
  print('Got ${wipExpenses.length} wipExpenses');

  List<Expense>? expenses = await Expense.getHomeScreenExpenses(user);
  if (expenses != null) cachedExpenses = expenses;

  asyncPrefs.setString('_tags', Tag.jsonEncodeTagsList(tags));
  asyncPrefs.setString('_expenses', BaseExpense.jsonEncodeExpensesList([...wipExpenses, ...expenses!]));
  //asyncPrefs.setBool('freshDataLoaded', true);

  loadDataRunning = false;
}

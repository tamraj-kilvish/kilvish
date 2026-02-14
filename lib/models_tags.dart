import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/models_expense.dart';

/// Summary of expense and recovery amounts
class Summary {
  final num expense;
  final num recovery;

  Summary({required this.expense, required this.recovery});

  Map<String, num> toJson() => {'expense': expense, 'recovery': recovery};

  factory Summary.fromJson(Map<String, dynamic> json) {
    return Summary(expense: json['expense'] ?? 0, recovery: json['recovery'] ?? 0);
  }

  Summary operator +(Summary other) {
    return Summary(expense: expense + other.expense, recovery: recovery + other.recovery);
  }

  // Formatted getters
  String get expenseFormatted => NumberFormat.compact().format(expense.round());
  String get recoveryFormatted => NumberFormat.compact().format(recovery.round());
}

/// Month key in YYYY-MM format
class MonthKey {
  final int year;
  final int month;

  MonthKey(this.year, this.month);

  String toKey() => '$year-${month.toString().padLeft(2, '0')}';

  factory MonthKey.fromKey(String key) {
    final parts = key.split('-');
    return MonthKey(int.parse(parts[0]), int.parse(parts[1]));
  }

  factory MonthKey.fromDateTime(DateTime date) {
    return MonthKey(date.year, date.month);
  }

  @override
  String toString() => toKey();
}

/// Monthly breakdown: acrossUsers summary + per-user summaries
class MonthlyBreakdown {
  final Summary acrossUsers;
  final Map<String, Summary> userSummaries;

  MonthlyBreakdown({required this.acrossUsers, required this.userSummaries});

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{'acrossUsers': acrossUsers.toJson()};
    userSummaries.forEach((userId, summary) {
      result[userId] = summary.toJson();
    });
    return result;
  }

  factory MonthlyBreakdown.fromJson(Map<String, dynamic> json) {
    final acrossUsers = Summary.fromJson(json['acrossUsers'] ?? {});
    final userSummaries = <String, Summary>{};

    json.forEach((key, value) {
      if (key != 'acrossUsers' && value is Map) {
        userSummaries[key] = Summary.fromJson(Map<String, dynamic>.from(value));
      }
    });

    return MonthlyBreakdown(acrossUsers: acrossUsers, userSummaries: userSummaries);
  }
}

/// Unified Tag class
/// When allowRecovery = false, it's a regular Tag for expense tracking
/// When allowRecovery = true, it tracks both expenses and recovery amounts
class Tag {
  final String id;
  final String name;
  final String ownerId;
  bool allowRecovery;
  bool isRecovery;
  Set<String> sharedWith = {};
  final DateTime createdAt;
  final String link; // Shareable link: kilvish://tag/{id}

  // Unified typed structure
  Summary _acrossUsersSummary = Summary(expense: 0, recovery: 0);
  Map<String, Summary> _userSummaries = {}; // userId -> Summary
  Map<String, MonthlyBreakdown> _monthWiseTotal = {}; // 'YYYY-MM' -> MonthlyBreakdown

  Expense? mostRecentExpense;
  int unseenExpenseCount = 0;

  // Formatted getters
  Map<String, String> get totalTillDate {
    return {'expense': _acrossUsersSummary.expenseFormatted, 'recovery': _acrossUsersSummary.recoveryFormatted};
  }

  Map<String, Map<String, String>> get userWiseTotal {
    return _userSummaries.map((userId, summary) {
      return MapEntry(userId, {'expense': summary.expenseFormatted, 'recovery': summary.recoveryFormatted});
    });
  }

  Map<String, Map<String, dynamic>> get monthWiseTotal {
    return _monthWiseTotal.map((monthKey, breakdown) {
      final result = <String, dynamic>{
        'acrossUsers': {'expense': breakdown.acrossUsers.expenseFormatted, 'recovery': breakdown.acrossUsers.recoveryFormatted},
      };

      breakdown.userSummaries.forEach((userId, summary) {
        result[userId] = {'expense': summary.expenseFormatted, 'recovery': summary.recoveryFormatted};
      });

      return MapEntry(monthKey, result);
    });
  }

  // Raw getters for internal use
  Summary get acrossUsersSummary => _acrossUsersSummary;
  Map<String, Summary> get userSummaries => _userSummaries;
  Map<String, MonthlyBreakdown> get monthWiseTotalRaw => _monthWiseTotal;

  // Legacy getter for backward compatibility (returns only expense amount)
  String get totalAmountTillDate {
    return _acrossUsersSummary.expenseFormatted;
  }

  Tag({
    required this.id,
    required this.name,
    required this.ownerId,
    required Summary acrossUsersSummary,
    required Map<String, Summary> userSummaries,
    required Map<String, MonthlyBreakdown> monthWiseTotal,
    required this.link,
    this.allowRecovery = false,
    this.isRecovery = false,
    DateTime? createdAt,
  }) : _acrossUsersSummary = acrossUsersSummary,
       _userSummaries = userSummaries,
       _monthWiseTotal = monthWiseTotal,
       createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() {
    // Build total structure
    final totalMap = <String, dynamic>{'acrossUsers': _acrossUsersSummary.toJson()};
    _userSummaries.forEach((userId, summary) {
      totalMap[userId] = summary.toJson();
    });

    // Build monthWiseTotal structure
    final monthWiseMap = <String, dynamic>{};
    _monthWiseTotal.forEach((monthKey, breakdown) {
      monthWiseMap[monthKey] = breakdown.toJson();
    });

    return {
      'id': id,
      'name': name,
      'ownerId': ownerId,
      'allowRecovery': allowRecovery,
      'isRecovery': isRecovery,
      'link': link,
      'createdAt': createdAt.toIso8601String(),
      'sharedWith': sharedWith.toList(),
      'total': totalMap,
      'monthWiseTotal': monthWiseMap,
    };
  }

  Map<String, dynamic> toFirestore() {
    final totalMap = <String, dynamic>{'acrossUsers': _acrossUsersSummary.toJson()};
    _userSummaries.forEach((userId, summary) {
      totalMap[userId] = summary.toJson();
    });

    final monthWiseMap = <String, dynamic>{};
    _monthWiseTotal.forEach((monthKey, breakdown) {
      monthWiseMap[monthKey] = breakdown.toJson();
    });

    return {
      'name': name,
      'ownerId': ownerId,
      'allowRecovery': allowRecovery,
      'isRecovery': isRecovery,
      'link': link,
      'createdAt': Timestamp.fromDate(createdAt),
      'sharedWith': sharedWith.toList(),
      'total': totalMap,
      'monthWiseTotal': monthWiseMap,
    };
  }

  static String jsonEncodeTagsList(List<Tag> tags) {
    String jsonEncodedTagList = jsonEncode(tags.map((tag) => tag.toJson()).toList());
    return jsonEncodedTagList;
  }

  static List<Tag> jsonDecodeTagsList(String tagsListString) {
    final List<dynamic> tagMapList = jsonDecode(tagsListString);
    return tagMapList.map((map) => Tag.fromJson(map as Map<String, dynamic>)).toList();
  }

  factory Tag.fromJson(Map<String, dynamic> json) {
    // Parse total structure
    final totalData = json['total'] as Map<String, dynamic>? ?? {};
    final acrossUsersSummary = Summary.fromJson(totalData['acrossUsers'] ?? {});
    final userSummaries = <String, Summary>{};

    totalData.forEach((key, value) {
      if (key != 'acrossUsers' && value is Map) {
        userSummaries[key] = Summary.fromJson(Map<String, dynamic>.from(value));
      }
    });

    // Parse monthWiseTotal structure
    final monthWiseData = json['monthWiseTotal'] as Map<String, dynamic>? ?? {};
    final monthWiseTotal = <String, MonthlyBreakdown>{};

    monthWiseData.forEach((monthKey, value) {
      if (value is Map) {
        monthWiseTotal[monthKey] = MonthlyBreakdown.fromJson(Map<String, dynamic>.from(value));
      }
    });

    return Tag(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      ownerId: json['ownerId'] ?? '',
      acrossUsersSummary: acrossUsersSummary,
      userSummaries: userSummaries,
      monthWiseTotal: monthWiseTotal,
      link: json['link'] ?? '',
      allowRecovery: json['allowRecovery'] ?? false,
      isRecovery: json['isRecovery'] ?? false,
      createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt']) : DateTime.now(),
    )..sharedWith = Set<String>.from(json['sharedWith'] ?? []);
  }

  static Tag fromFirestoreObject(
    String tagId,
    Map<String, dynamic>? firestoreTag, {
    Expense? mostRecentExpense,
    int? unseenExpenseCount,
  }) {
    if (firestoreTag == null) {
      throw Exception('Tag data is null for tagId: $tagId');
    }

    // Parse total structure
    final totalData = firestoreTag['total'] as Map<String, dynamic>? ?? {};
    final acrossUsersSummary = Summary.fromJson(totalData['acrossUsers'] ?? {});
    final userSummaries = <String, Summary>{};

    totalData.forEach((key, value) {
      if (key != 'acrossUsers' && value is Map) {
        userSummaries[key] = Summary.fromJson(Map<String, dynamic>.from(value));
      }
    });

    // Parse monthWiseTotal structure
    final monthWiseData = firestoreTag['monthWiseTotal'] as Map<String, dynamic>? ?? {};
    final monthWiseTotal = <String, MonthlyBreakdown>{};

    monthWiseData.forEach((monthKey, value) {
      if (value is Map) {
        monthWiseTotal[monthKey] = MonthlyBreakdown.fromJson(Map<String, dynamic>.from(value));
      }
    });

    final tag = Tag(
      id: tagId,
      name: firestoreTag['name'] ?? '',
      ownerId: firestoreTag['ownerId'] ?? '',
      acrossUsersSummary: acrossUsersSummary,
      userSummaries: userSummaries,
      monthWiseTotal: monthWiseTotal,
      link: firestoreTag['link'] ?? '',
      allowRecovery: firestoreTag['allowRecovery'] ?? false,
      isRecovery: firestoreTag['isRecovery'] ?? false,
      createdAt: (firestoreTag['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );

    tag.sharedWith = Set<String>.from(firestoreTag['sharedWith'] ?? []);
    tag.mostRecentExpense = mostRecentExpense;
    tag.unseenExpenseCount = unseenExpenseCount ?? 0;

    return tag;
  }
}

enum TagStatus { unselected, expense, settlement, recovery }

// year -> month -> {total: num, userId1: num, userId2: num}
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/models_expense.dart';

typedef MonthwiseAggregatedExpense = Map<num, Map<num, Map<String, num>>>;

// Flattened monthly structure: 'YYYY-MM' -> {expense, recovery, userId1: {expense, recovery}, ...}
typedef MonthwiseRecoveryTotal = Map<String, Map<String, dynamic>>;

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

  // Unified structure for both regular tags and recovery tags
  Map<String, num> _totalTillDate = {'expense': 0, 'recovery': 0};
  Map<String, Map<String, num>> _userWiseTotal = {}; // userId -> {expense: num, recovery: num}
  MonthwiseRecoveryTotal _monthWiseTotal = {}; // 'YYYY-MM' -> {expense, recovery, userId: {expense, recovery}}

  Expense? mostRecentExpense;
  int unseenExpenseCount = 0;

  // Formatted getters
  Map<String, String> get totalTillDate {
    return _totalTillDate.map((key, value) => MapEntry(key, NumberFormat.compact().format(value.round())));
  }

  Map<String, Map<String, String>> get userWiseTotal {
    return _userWiseTotal.map((userId, amounts) {
      return MapEntry(userId, amounts.map((key, value) => MapEntry(key, NumberFormat.compact().format(value.round()))));
    });
  }

  Map<String, Map<String, dynamic>> get monthWiseTotal {
    return _monthWiseTotal.map((monthKey, monthData) {
      final formatted = Map<String, dynamic>.from(monthData);
      if (formatted['expense'] is num) {
        formatted['expense'] = NumberFormat.compact().format((formatted['expense'] as num).round());
      }
      if (formatted['recovery'] is num) {
        formatted['recovery'] = NumberFormat.compact().format((formatted['recovery'] as num).round());
      }
      // Format user-wise data
      formatted.forEach((key, value) {
        if (key != 'expense' && key != 'recovery' && value is Map) {
          formatted[key] = (value as Map).map((k, v) {
            if (v is num) {
              return MapEntry(k.toString(), NumberFormat.compact().format(v.round()));
            }
            return MapEntry(k.toString(), v);
          });
        }
      });
      return MapEntry(monthKey, formatted);
    });
  }

  // Legacy getter for backward compatibility (returns only expense amount)
  String get totalAmountTillDate {
    return NumberFormat.compact().format(_totalTillDate['expense']!.round());
  }

  Tag({
    required this.id,
    required this.name,
    required this.ownerId,
    required Map<String, num> totalTillDate,
    required Map<String, Map<String, num>> userWiseTotal,
    required MonthwiseRecoveryTotal monthWiseTotal,
    required this.link,
    this.allowRecovery = false,
    this.isRecovery = false,
    DateTime? createdAt,
  }) : _totalTillDate = totalTillDate,
       _userWiseTotal = userWiseTotal,
       _monthWiseTotal = monthWiseTotal,
       createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'ownerId': ownerId,
    'allowRecovery': allowRecovery,
    'isRecovery': isRecovery,
    'link': link,
    'createdAt': createdAt.toIso8601String(),
    'sharedWith': sharedWith.toList(),
    'totalTillDate': _totalTillDate,
    'userWiseTotal': _userWiseTotal,
    'monthWiseTotal': _monthWiseTotal,
    'mostRecentExpense': mostRecentExpense?.toJson(),
    'unseenExpenseCount': unseenExpenseCount,
  };

  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'ownerId': ownerId,
      'allowRecovery': allowRecovery,
      'isRecovery': isRecovery,
      'link': link,
      'createdAt': Timestamp.fromDate(createdAt),
      'sharedWith': sharedWith.toList(),
      'totalTillDate': _totalTillDate,
      'userWiseTotal': _userWiseTotal,
      'monthWiseTotal': _monthWiseTotal,
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

  factory Tag.fromJson(Map<String, dynamic> jsonObject) {
    Tag tag = Tag.fromFirestoreObject(jsonObject['id'] as String, jsonObject);

    if (jsonObject['mostRecentExpense'] != null) {
      tag.mostRecentExpense = Expense.fromJson(
        jsonObject['mostRecentExpense'] as Map<String, dynamic>,
        "" /* ownerKilvishId of this tx will not be used/shown on the UI*/,
      );
    }
    tag.unseenExpenseCount = jsonObject['unseenExpenseCount'] ?? 0;
    return tag;
  }

  // Helper to decode old monthWiseTotal format (year/month structure)
  static MonthwiseAggregatedExpense decodeOldMonthWiseTotal(Map<String, dynamic> monthWiseTotalWithStringKeys) {
    MonthwiseAggregatedExpense monthWiseTotal = {};

    monthWiseTotalWithStringKeys.forEach((yearInString, monthDataWithStringKeys) {
      num? year = num.tryParse(yearInString);

      if (year != null && monthDataWithStringKeys is Map<String, dynamic>) {
        Map<num, Map<String, num>> monthData = {};

        monthDataWithStringKeys.forEach((monthInString, totalAmounts) {
          num? month = num.tryParse(monthInString);
          if (month != null) {
            monthData[month] = (totalAmounts as Map).cast<String, num>();
          }
        });
        monthWiseTotal[year] = monthData;
      }
    });
    return monthWiseTotal;
  }

  factory Tag.fromFirestoreObject(String tagId, Map<String, dynamic>? firestoreTag) {
    // Migration support: handle both old and new formats
    Map<String, num> totalTillDate;
    Map<String, Map<String, num>> userWiseTotal;
    MonthwiseRecoveryTotal monthWiseTotal;

    // Check if new format exists (totalTillDate as Map)
    if (firestoreTag?['totalTillDate'] != null && firestoreTag?['totalTillDate'] is Map) {
      // New unified format
      totalTillDate = (firestoreTag?['totalTillDate'] as Map).cast<String, num>();

      userWiseTotal = firestoreTag?['userWiseTotal'] != null
          ? (firestoreTag?['userWiseTotal'] as Map).map(
              (key, value) => MapEntry(key.toString(), (value as Map).cast<String, num>()),
            )
          : {};

      monthWiseTotal = firestoreTag?['monthWiseTotal'] != null
          ? (firestoreTag?['monthWiseTotal'] as Map).map(
              (key, value) => MapEntry(key.toString(), Map<String, dynamic>.from(value as Map)),
            )
          : {};
    } else {
      // Old format - migrate on the fly
      final oldTotal = firestoreTag?['totalAmountTillDate'] as num? ?? 0;
      totalTillDate = {'expense': oldTotal, 'recovery': 0};

      // Migrate old userWiseTotalTillDate
      final oldUserWise = firestoreTag?['userWiseTotalTillDate'] as Map?;
      if (oldUserWise != null) {
        userWiseTotal = oldUserWise.map((userId, amount) {
          return MapEntry(userId.toString(), {'expense': amount as num, 'recovery': 0});
        });
      } else {
        userWiseTotal = {};
      }

      // Migrate old monthWiseTotal
      final oldMonthWise = firestoreTag?['monthWiseTotal'];
      if (oldMonthWise != null) {
        monthWiseTotal = {};
        final decoded = decodeOldMonthWiseTotal(oldMonthWise);
        // Convert old year/month structure to YYYY-MM format
        decoded.forEach((year, months) {
          months.forEach((month, userData) {
            final monthKey = '$year-${month.toString().padLeft(2, '0')}';
            final expense = userData['total'] as num? ?? 0;
            monthWiseTotal[monthKey] = {'expense': expense, 'recovery': 0};
            userData.forEach((userId, amount) {
              if (userId != 'total') {
                monthWiseTotal[monthKey]![userId] = {'expense': amount, 'recovery': 0};
              }
            });
          });
        });
      } else {
        monthWiseTotal = {};
      }
    }

    // Generate link if not present (for old tags)
    final link = firestoreTag?['link'] as String? ?? 'kilvish://tag/$tagId';

    Tag tag = Tag(
      id: tagId,
      name: firestoreTag?['name'],
      ownerId: firestoreTag?['ownerId'],
      totalTillDate: totalTillDate,
      userWiseTotal: userWiseTotal,
      monthWiseTotal: monthWiseTotal,
      link: link,
      allowRecovery: firestoreTag?['allowRecovery'] as bool? ?? false,
      isRecovery: firestoreTag?['isRecovery'] as bool? ?? false,
      createdAt: firestoreTag?['createdAt'] != null ? (firestoreTag?['createdAt'] as Timestamp).toDate() : DateTime.now(),
    );

    // Parse sharedWith if present
    if (firestoreTag?['sharedWith'] != null) {
      List<dynamic> dynamicList = firestoreTag?['sharedWith'] as List<dynamic>;
      final List<String> stringList = dynamicList.cast<String>();
      tag.sharedWith = stringList.toSet();
    }

    return tag;
  }

  // Override equality and hashCode for Set operations
  @override
  bool operator ==(Object other) => identical(this, other) || other is Tag && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

enum TagStatus {
  unselected,
  expense,
  settlement,
  recovery, // ADD THIS
}

class TagMonetaryUpdate {
  final String name;
  final num totalAmountTillDate;
  final Map<int, Map<int, num>> monthWiseTotal;

  TagMonetaryUpdate({required this.name, required this.totalAmountTillDate, required this.monthWiseTotal});

  factory TagMonetaryUpdate.fromJson(Map<String, dynamic> json) {
    final Map<int, Map<int, num>> parsedMonthWiseTotal = {};

    final monthWiseTotalRaw = json['monthWiseTotal'];
    if (monthWiseTotalRaw is Map) {
      monthWiseTotalRaw.forEach((yearKey, yearValue) {
        if (yearValue is Map) {
          final int? year = int.tryParse(yearKey.toString());
          if (year == null) return;

          parsedMonthWiseTotal[year] = {};

          yearValue.forEach((monthKey, monthValue) {
            final int? month = int.tryParse(monthKey.toString());
            if (month == null) return;

            num amount = 0;
            if (monthValue is num) {
              amount = monthValue;
            } else if (monthValue is String) {
              amount = num.tryParse(monthValue) ?? 0;
            }

            parsedMonthWiseTotal[year]![month] = amount;
          });
        }
      });
    }

    return TagMonetaryUpdate(
      name: json['name'] as String? ?? '',
      totalAmountTillDate: _parseNum(json['totalAmountTillDate']),
      monthWiseTotal: parsedMonthWiseTotal,
    );
  }

  static num _parseNum(dynamic value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value) ?? 0;
    return 0;
  }

  Map<String, dynamic> toFirestoreUpdate() {
    final Map<String, dynamic> update = {};

    update['name'] = name;
    update['totalAmountTillDate'] = totalAmountTillDate;

    // Convert Map<int, Map<int, num>> to Map<String, Map<String, num>> for Firestore
    final Map<String, dynamic> firestoreMonthWiseTotal = {};
    monthWiseTotal.forEach((year, months) {
      firestoreMonthWiseTotal[year.toString()] = {};
      months.forEach((month, amount) {
        firestoreMonthWiseTotal[year.toString()][month.toString()] = amount;
      });
    });

    update['monthWiseTotal'] = firestoreMonthWiseTotal;

    return update;
  }
}

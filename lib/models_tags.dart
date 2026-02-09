// year -> month -> {total: num, userId1: num, userId2: num}
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/models_expense.dart';

typedef MonthwiseAggregatedExpense = Map<num, Map<num, Map<String, num>>>;

// Flattened monthly structure: 'YYYY-MM' -> {totalExpense, totalRecovery, userId1: {expense, recovery}, ...}
typedef MonthwiseRecoveryTotal = Map<String, Map<String, dynamic>>;

// Abstract base class for Tag and Recovery
abstract class BaseContainer {
  String get id;
  String get name;
  String get ownerId;
  bool get allowRecovery;
  Set<String> get sharedWith;

  Map<String, dynamic> toJson();
}

class Tag extends BaseContainer {
  @override
  final String id;
  @override
  final String name;
  @override
  final String ownerId;
  @override
  bool allowRecovery = false;
  @override
  Set<String> sharedWith = {};
  Set<String> sharedWithFriends = {};
  num _totalAmountTillDate = 0;
  MonthwiseAggregatedExpense _monthWiseTotal = {};
  Map<String, num> _userWiseTotalTillDate = {};
  Expense? mostRecentExpense;
  int unseenExpenseCount = 0;

  Map<num, Map<num, Map<String, String>>> get monthWiseTotal {
    return _monthWiseTotal.map((year, yearMap) {
      final Map<num, Map<String, String>> serializedYearMap = yearMap.map((month, monthMap) {
        final Map<String, String> serializedMonthMap = monthMap.map(
          (userId, value) => MapEntry(userId, NumberFormat.compact().format(value.round())),
        );
        return MapEntry(month, serializedMonthMap);
      });

      return MapEntry(year, serializedYearMap);
    });
  }

  String get totalAmountTillDate {
    return NumberFormat.compact().format(_totalAmountTillDate.round());
  }

  Map<String, String> get userWiseTotalTillDate {
    return _userWiseTotalTillDate.map((key, amount) => MapEntry(key, NumberFormat.compact().format(amount.round())));
  }

  Tag({
    required this.id,
    required this.name,
    required this.ownerId,
    required num totalAmountTillDate,
    required Map<String, num> userWiseTotalTillDate,
    required MonthwiseAggregatedExpense monthWiseTotal,
    this.allowRecovery = false,
  }) : _monthWiseTotal = monthWiseTotal,
       _totalAmountTillDate = totalAmountTillDate,
       _userWiseTotalTillDate = userWiseTotalTillDate;

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'ownerId': ownerId,
    'allowRecovery': allowRecovery,
    'sharedWith': sharedWith.toList(),
    'sharedWithFriends': sharedWithFriends.toList(),
    'totalAmountTillDate': _totalAmountTillDate,
    'userWiseTotalTillDate': _userWiseTotalTillDate,
    'monthWiseTotal': _monthWiseTotal.map((year, monthData) {
      final Map<String, Map<String, num>> monthMap = monthData.map(
        (month, totalAndUserWiseTotalData) => MapEntry(month.toString(), totalAndUserWiseTotalData),
      );

      return MapEntry(year.toString(), monthMap);
    }),
    'mostRecentExpense': mostRecentExpense?.toJson(),
    'unseenExpenseCount': unseenExpenseCount,
  };

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

  static String dumpMonthlyTotal(Map<num, Map<num, Map<String, num>>> data) {
    // 1. Create a "pretty" encoder
    final encoder = JsonEncoder.withIndent('  ');

    // 2. Convert numeric keys to Strings so JSON can handle them
    // This recursively converts all numeric keys in your nested structure
    dynamic stringifyKeys(dynamic item) {
      if (item is Map) {
        return item.map((key, value) => MapEntry(key.toString(), stringifyKeys(value)));
      }
      return item;
    }

    try {
      final readableString = encoder.convert(stringifyKeys(data));
      return readableString;
    } catch (e) {
      print("Error dumping map: $e");
      return "";
    }
  }

  static MonthwiseAggregatedExpense decodeMonthWiseTotal(Map<String, dynamic> monthWiseTotalWithStringKeys) {
    MonthwiseAggregatedExpense monthWiseTotal = {};

    monthWiseTotalWithStringKeys.forEach((yearInString, monthDataWithStringKeys) {
      num? year = num.tryParse(yearInString);

      if (year != null && monthDataWithStringKeys is Map<String, dynamic>) {
        Map<num, Map<String, num>> monthData = {};

        monthDataWithStringKeys.forEach((monthInString, totalAmounts) {
          num? month = num.tryParse(monthInString);
          if (month != null /*&& totalAmounts is Map<String, num>*/ ) {
            monthData[month] = (totalAmounts as Map).cast<String, num>();
          }
        });
        monthWiseTotal[year] = monthData;
      }
    });
    //print("monthWiseTotal extracted from firebase ${dumpMonthlyTotal(monthWiseTotal)}");
    return monthWiseTotal;
  }

  factory Tag.fromFirestoreObject(String tagId, Map<String, dynamic>? firestoreTag) {
    Tag tag = Tag(
      id: tagId,
      name: firestoreTag?['name'],
      ownerId: firestoreTag?['ownerId'],
      totalAmountTillDate: firestoreTag?['totalAmountTillDate'] as num,
      userWiseTotalTillDate: (firestoreTag?['userWiseTotalTillDate'] as Map).cast<String, num>(),
      monthWiseTotal: decodeMonthWiseTotal(firestoreTag?['monthWiseTotal']),
      allowRecovery: firestoreTag?['allowRecovery'] as bool? ?? false,
    );

    // Parse sharedWith if present
    if (firestoreTag?['sharedWith'] != null) {
      List<dynamic> dynamicList = firestoreTag?['sharedWith'] as List<dynamic>;
      final List<String> stringList = dynamicList.cast<String>();
      tag.sharedWith = stringList.toSet();
    }

    if (firestoreTag?['sharedWithFriends'] != null) {
      List<dynamic> dynamicList = firestoreTag?['sharedWithFriends'] as List<dynamic>;
      final List<String> stringList = dynamicList.cast<String>();
      tag.sharedWithFriends = stringList.toSet();
    }

    return tag;
  }

  // Override equality and hashCode for Set operations
  @override
  bool operator ==(Object other) => identical(this, other) || other is Tag && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

class Recovery extends BaseContainer {
  @override
  final String id;
  @override
  final String name;
  @override
  final String ownerId;
  @override
  final bool allowRecovery = true; // Always true
  @override
  Set<String> sharedWith = {};

  final DateTime createdAt;

  // Aggregated totals
  Map<String, num> _totalTillDate = {'expense': 0, 'recovery': 0};
  Map<String, Map<String, num>> _userWiseTotal = {}; // userId -> {expense: num, recovery: num}
  MonthwiseRecoveryTotal _monthWiseTotal = {}; // 'YYYY-MM' -> {totalExpense, totalRecovery, userId1: {expense, recovery}}

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
      if (formatted['totalExpense'] is num) {
        formatted['totalExpense'] = NumberFormat.compact().format((formatted['totalExpense'] as num).round());
      }
      if (formatted['totalRecovery'] is num) {
        formatted['totalRecovery'] = NumberFormat.compact().format((formatted['totalRecovery'] as num).round());
      }
      // Format user-wise data
      formatted.forEach((key, value) {
        if (key != 'totalExpense' && key != 'totalRecovery' && value is Map) {
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

  Recovery({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.createdAt,
    required Map<String, num> totalTillDate,
    required Map<String, Map<String, num>> userWiseTotal,
    required MonthwiseRecoveryTotal monthWiseTotal,
  }) : _totalTillDate = totalTillDate,
       _userWiseTotal = userWiseTotal,
       _monthWiseTotal = monthWiseTotal;

  @override
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'ownerId': ownerId,
    'allowRecovery': true,
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
      'allowRecovery': true,
      'createdAt': Timestamp.fromDate(createdAt),
      'sharedWith': sharedWith.toList(),
      'totalTillDate': _totalTillDate,
      'userWiseTotal': _userWiseTotal,
      'monthWiseTotal': _monthWiseTotal,
    };
  }

  static String jsonEncodeRecoveryList(List<Recovery> recoveries) {
    return jsonEncode(recoveries.map((recovery) => recovery.toJson()).toList());
  }

  static List<Recovery> jsonDecodeRecoveryList(String recoveryListString) {
    final List<dynamic> recoveryMapList = jsonDecode(recoveryListString);
    return recoveryMapList.map((map) => Recovery.fromJson(map as Map<String, dynamic>)).toList();
  }

  factory Recovery.fromJson(Map<String, dynamic> jsonObject) {
    Recovery recovery = Recovery.fromFirestoreObject(jsonObject['id'] as String, jsonObject);

    if (jsonObject['mostRecentExpense'] != null) {
      recovery.mostRecentExpense = Expense.fromJson(jsonObject['mostRecentExpense'] as Map<String, dynamic>, "");
    }
    recovery.unseenExpenseCount = jsonObject['unseenExpenseCount'] ?? 0;
    return recovery;
  }

  factory Recovery.fromFirestoreObject(String recoveryId, Map<String, dynamic>? firestoreRecovery) {
    Recovery recovery = Recovery(
      id: recoveryId,
      name: firestoreRecovery?['name'],
      ownerId: firestoreRecovery?['ownerId'],
      createdAt: firestoreRecovery?['createdAt'] != null
          ? (firestoreRecovery?['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
      totalTillDate: firestoreRecovery?['totalTillDate'] != null
          ? (firestoreRecovery?['totalTillDate'] as Map).cast<String, num>()
          : {'expense': 0, 'recovery': 0},
      userWiseTotal: firestoreRecovery?['userWiseTotal'] != null
          ? (firestoreRecovery?['userWiseTotal'] as Map).map(
              (key, value) => MapEntry(key.toString(), (value as Map).cast<String, num>()),
            )
          : {},
      monthWiseTotal: firestoreRecovery?['monthWiseTotal'] != null
          ? (firestoreRecovery?['monthWiseTotal'] as Map).map(
              (key, value) => MapEntry(key.toString(), Map<String, dynamic>.from(value as Map)),
            )
          : {},
    );

    if (firestoreRecovery?['sharedWith'] != null) {
      List<dynamic> dynamicList = firestoreRecovery?['sharedWith'] as List<dynamic>;
      final List<String> stringList = dynamicList.cast<String>();
      recovery.sharedWith = stringList.toSet();
    }

    return recovery;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Recovery && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

enum TagStatus { unselected, expense, settlement }

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

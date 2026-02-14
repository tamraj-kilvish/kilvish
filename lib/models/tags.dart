import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:kilvish/models/expenses.dart';

typedef MonthwiseAggregatedExpense = Map<num, Map<num, Map<String, num>>>;

enum TagStatus { unselected, expense, settlement }

class Tag {
  final String id;
  final String name;
  final String ownerId;
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
  }) : _monthWiseTotal = monthWiseTotal,
       _totalAmountTillDate = totalAmountTillDate,
       _userWiseTotalTillDate = userWiseTotalTillDate;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'ownerId': ownerId,
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

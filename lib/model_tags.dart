import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:kilvish/model_expenses.dart';

enum TagStatus { unselected, expense, settlement, recovery }

// New data classes for monetary summary
class UserMonetaryData {
  final double expense;
  final double recovery;

  UserMonetaryData({required this.expense, required this.recovery});

  factory UserMonetaryData.fromJson(Map<String, dynamic>? json) {
    if (json == null) return UserMonetaryData(expense: 0, recovery: 0);
    return UserMonetaryData(
      expense: (json['expense'] as num?)?.toDouble() ?? 0,
      recovery: (json['recovery'] as num?)?.toDouble() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {'expense': expense, 'recovery': recovery};
}

class MonthlyMonetaryData {
  final UserMonetaryData acrossUsers;
  final Map<String, UserMonetaryData> userWise;

  MonthlyMonetaryData({required this.acrossUsers, required this.userWise});

  factory MonthlyMonetaryData.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return MonthlyMonetaryData(acrossUsers: UserMonetaryData(expense: 0, recovery: 0), userWise: {});
    }

    final acrossUsers = UserMonetaryData.fromJson(json['acrossUsers'] as Map<String, dynamic>?);
    final userWise = <String, UserMonetaryData>{};

    json.forEach((key, value) {
      if (key != 'acrossUsers' && value is Map<String, dynamic>) {
        userWise[key] = UserMonetaryData.fromJson(value);
      }
    });

    return MonthlyMonetaryData(acrossUsers: acrossUsers, userWise: userWise);
  }

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{'acrossUsers': acrossUsers.toJson()};
    userWise.forEach((key, value) {
      result[key] = value.toJson();
    });
    return result;
  }
}

class Tag {
  final String id;
  final String name;
  final String ownerId;
  Set<String> sharedWith = {};
  Set<String> sharedWithFriends = {};
  final bool isRecoveryExpense;

  // New schema - public for access
  MonthlyMonetaryData total;
  Map<String, MonthlyMonetaryData> monthWiseTotal; // "YYYY-MM" => data

  Expense? mostRecentExpense;
  int unseenExpenseCount = 0;

  // Formatted getters for backward compatibility (used in UI display)
  String get totalAmountTillDate {
    return NumberFormat.compact().format(total.acrossUsers.expense.round());
  }

  Map<String, String> get userWiseTotalTillDate {
    final result = <String, String>{};
    total.userWise.forEach((key, value) {
      result[key] = NumberFormat.compact().format(value.expense.round());
    });
    return result;
  }

  Tag({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.total,
    required this.monthWiseTotal,
    this.isRecoveryExpense = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'ownerId': ownerId,
    'sharedWith': sharedWith.toList(),
    'sharedWithFriends': sharedWithFriends.toList(),
    'isRecoveryExpense': isRecoveryExpense,
    'total': total.toJson(),
    'monthWiseTotal': monthWiseTotal.map((key, value) => MapEntry(key, value.toJson())),
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

  factory Tag.fromFirestoreObject(String tagId, Map<String, dynamic>? firestoreTag) {
    if (firestoreTag == null) {
      return Tag(
        id: tagId,
        name: '',
        ownerId: '',
        total: MonthlyMonetaryData(acrossUsers: UserMonetaryData(expense: 0, recovery: 0), userWise: {}),
        monthWiseTotal: {},
      );
    }

    // Parse new schema
    final total = MonthlyMonetaryData.fromJson(firestoreTag['total'] as Map<String, dynamic>?);

    final monthWiseTotal = <String, MonthlyMonetaryData>{};
    final monthWiseData = firestoreTag['monthWiseTotal'] as Map<String, dynamic>?;
    monthWiseData?.forEach((key, value) {
      if (value is Map<String, dynamic>) {
        monthWiseTotal[key] = MonthlyMonetaryData.fromJson(value);
      }
    });

    Tag tag = Tag(
      id: tagId,
      name: firestoreTag['name'] ?? '',
      ownerId: firestoreTag['ownerId'] ?? '',
      isRecoveryExpense: firestoreTag['isRecoveryExpense'] as bool? ?? false,
      total: total,
      monthWiseTotal: monthWiseTotal,
    );

    // Parse sharedWith if present
    if (firestoreTag['sharedWith'] != null) {
      List<dynamic> dynamicList = firestoreTag['sharedWith'] as List<dynamic>;
      final List<String> stringList = dynamicList.cast<String>();
      tag.sharedWith = stringList.toSet();
    }

    if (firestoreTag['sharedWithFriends'] != null) {
      List<dynamic> dynamicList = firestoreTag['sharedWithFriends'] as List<dynamic>;
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

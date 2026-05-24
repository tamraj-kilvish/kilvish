import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/models_user.dart';

export 'package:kilvish/models_user.dart';

// Monetary data for a single user (or acrossUsers aggregate) in a tag
class UserMonetaryData {
  num expense;
  num recovery;

  UserMonetaryData({this.expense = 0, this.recovery = 0});

  factory UserMonetaryData.fromJson(Map<String, dynamic> json) =>
      UserMonetaryData(expense: (json['expense'] as num?) ?? 0, recovery: (json['recovery'] as num?) ?? 0);

  Map<String, dynamic> toJson() => {'expense': expense, 'recovery': recovery};
}

// Total monetary data for a tag — acrossUsers aggregate + per-user breakdown
class TagTotal {
  UserMonetaryData acrossUsers;
  Map<String, UserMonetaryData> userWise; // userId -> monetary data

  TagTotal({required this.acrossUsers, required this.userWise});

  factory TagTotal.empty() => TagTotal(acrossUsers: UserMonetaryData(), userWise: {});

  factory TagTotal.fromJson(Map<String, dynamic> json) {
    final acrossUsers = json['acrossUsers'] != null
        ? UserMonetaryData.fromJson((json['acrossUsers'] as Map).cast<String, dynamic>())
        : UserMonetaryData();
    final userWise = <String, UserMonetaryData>{};
    for (final entry in json.entries) {
      if (entry.key != 'acrossUsers' && entry.value is Map) {
        userWise[entry.key] = UserMonetaryData.fromJson((entry.value as Map).cast<String, dynamic>());
      }
    }
    return TagTotal(acrossUsers: acrossUsers, userWise: userWise);
  }

  Map<String, dynamic> toJson() => {
    'acrossUsers': acrossUsers.toJson(),
    for (final entry in userWise.entries) entry.key: entry.value.toJson(),
  };

  String getTagTileSummary(List<SelectableContact> tagParticipants, {bool showOutstanding = false}) {
    String message = "";
    int totalCount = 0;
    int maxCount = 3;

    String nameFor(String userId) =>
        tagParticipants.where((p) => p.userId == userId).firstOrNull?.displayName ?? userId;

    if (showOutstanding && acrossUsers.recovery > 0) {
      // filter out userWise for keys not in tagParticipants
      final participants = userWise.entries.where((e) => e.value.recovery != 0 && tagParticipants.any((p) => p.userId == e.key)).toList()
        ..sort((a, b) => a.value.recovery.compareTo(b.value.recovery)); // owes first

      if (participants.isNotEmpty) {
        final shown = participants
            .take(maxCount)
            .map((e) {
              final r = e.value.recovery;
              final amt = NumberFormat.compact().format(r.abs().round());
              return r < 0 ? '${nameFor(e.key)} owes ₹$amt' : '${nameFor(e.key)} is owed ₹$amt';
            })
            .join(', ');

        message += shown;
        if (userWise.length == 1) {
          //user has not shared this tag with anyone
          message += '\nAdd user to this tag (Tag > Edit) so they settle by adding Expense marked "Settlement" to this tag';
          return message;
        }

        totalCount += participants.length;
        if (totalCount == maxCount) return message;

        if (totalCount > 0) message += ". ";
      }
    }

    //no participants with recovery data .. show expense data instead
    final participants = userWise.entries.where((e) => e.value.expense != 0 && tagParticipants.any((p) => p.userId == e.key)).toList()
      ..sort((a, b) => b.value.recovery.compareTo(a.value.recovery)); // biggest expense first

    if (participants.isNotEmpty) {
      final shown = participants
          .take(maxCount - totalCount)
          .map((e) {
            final r = e.value.expense;
            final amt = NumberFormat.compact().format(r.abs().round());
            return '${nameFor(e.key)} spent ₹$amt';
          })
          .join(', ');
      message += shown;
    }
    totalCount += participants.length;
    if (totalCount > 0) return message;

    return 'No expenses found, add some to see summary here';
  }
}

class Tag {
  final String id;
  final String name;
  final String ownerId;
  Set<String> sharedWith = {};
  Set<String> sharedWithFriends = {};
  TagTotal total;
  Map<String, TagTotal> monthWiseTotal; // key: "YYYY-MM"
  bool dontShowOutstanding = false;
  DateTime? updatedAt;
  int unseenCount = 0;
  List<SelectableContact> participants = [];

  Tag({required this.id, required this.name, required this.ownerId, required this.total, required this.monthWiseTotal});

  /// Returns the displayName (includes '@' for kilvish users) for a userId,
  /// looked up from the already-loaded participants list.
  String? displayNameForUserId(String userId) =>
      participants.where((p) => p.userId == userId).firstOrNull?.displayName;

  String get formattedExpense => NumberFormat.compact().format(total.acrossUsers.expense.round());

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'ownerId': ownerId,
    'sharedWith': sharedWith.toList(),
    'sharedWithFriends': sharedWithFriends.toList(),
    'total': total.toJson(),
    'monthWiseTotal': monthWiseTotal.map((k, v) => MapEntry(k, v.toJson())),
    'dontShowOutstanding': dontShowOutstanding,
    'updatedAt': updatedAt?.toIso8601String(),
    'unseenCount': unseenCount,
    'participants': participants.map((p) => p.toJson()).toList(),
  };

  static String jsonEncodeTagsList(List<Tag> tags) => jsonEncode(tags.map((t) => t.toJson()).toList());

  static Future<List<Tag>> jsonDecodeTagsList(String tagsListString) async {
    final List<dynamic> list = jsonDecode(tagsListString);
    return Future.wait(list.map((m) => Tag.fromJson(m as Map<String, dynamic>)).toList());
  }

  // Loads from local JSON cache — restores participants from JSON, no network calls for participants.
  static Future<Tag> fromJson(Map<String, dynamic> json) async {
    final tag = await Tag.fromFirestoreObject(json['id'] as String, json, loadParticipants: false);

    tag.unseenCount = json['unseenCount'] as int? ?? 0;

    if (json['participants'] != null) {
      tag.participants = (await Future.wait(
        (json['participants'] as List).map((p) => SelectableContact.fromJson((p as Map).cast<String, dynamic>())),
      )).toList();
    }
    return tag;
  }

  // Loads from Firestore. When loadParticipants=true (default), enriches each sharedWith
  // userId via the current user's Friends sub-collection to build TagParticipant list.
  static Future<Tag> fromFirestoreObject(String tagId, Map<String, dynamic>? data, {bool loadParticipants = true}) async {
    final rawTotal = data?['total'];
    final total = rawTotal != null ? TagTotal.fromJson((rawTotal as Map).cast<String, dynamic>()) : TagTotal.empty();

    final monthWiseTotal = <String, TagTotal>{};
    final rawMonthWise = data?['monthWiseTotal'] as Map<String, dynamic>?;
    if (rawMonthWise != null) {
      for (final entry in rawMonthWise.entries) {
        if (entry.value is Map) {
          monthWiseTotal[entry.key] = TagTotal.fromJson((entry.value as Map).cast<String, dynamic>());
        }
      }
    }

    final tag = Tag(
      id: tagId,
      name: data?['name'] as String? ?? '',
      ownerId: data?['ownerId'] as String? ?? '',
      total: total,
      monthWiseTotal: monthWiseTotal,
    );

    if (data?['sharedWith'] != null) {
      tag.sharedWith = (data!['sharedWith'] as List).cast<String>().toSet();
    }

    // Always load participants — covers personal/loan-payback tags with no sharedWith field.
    if (loadParticipants) {
      final currentUserId = await getUserIdFromClaim();
      if (currentUserId != null) {
        // Set deduplicates in case ownerId also appears in sharedWith
        final participantIds = {tag.ownerId, ...tag.sharedWith}.toList();
        await Future.wait(
          participantIds.map((userId) async {
            final c = await SelectableContact.fromFirestore(currentUserId, userId);
            if (c != null) tag.participants.add(c);
          }),
        );
      }
    }

    if (data?['sharedWithFriends'] != null) {
      tag.sharedWithFriends = (data!['sharedWithFriends'] as List).cast<String>().toSet();
    }
    tag.dontShowOutstanding = data?['dontShowOutstanding'] as bool? ?? false;

    tag.updatedAt = data?['updatedAt'] != null ? BaseExpense.decodeDateTime(data!, 'updatedAt') : null;

    return tag;
  }

  @override
  bool operator ==(Object other) => identical(this, other) || other is Tag && id == other.id;

  @override
  int get hashCode => id.hashCode;

  String getTagTileSummary() {
    if (sharedWith.isNotEmpty || total.acrossUsers.recovery > 0) {
      return total.getTagTileSummary(participants, showOutstanding: !dontShowOutstanding);
    }

    // give current & last month data
    final now = DateTime.now();
    final currentMonth = DateFormat('yyyy-MM').format(now);
    final previousMonth = DateFormat('yyyy-MM').format(DateTime(now.year, now.month - 1, 1));

    return 'This month: ₹${monthWiseTotal[currentMonth]?.acrossUsers.expense ?? "-"} \n Prev month: ₹${monthWiseTotal[previousMonth]?.acrossUsers.expense ?? "-"}';
  }
}

enum TagStatus { selected, unselected }

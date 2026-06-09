import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart' show Color;
import 'package:intl/intl.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/models_user.dart';
import 'package:kilvish/style.dart';

export 'package:kilvish/models_user.dart';

// Monetary data for a single user in a tag.
// Raw stored fields: spent, myShare, received, paid.
// Derived: expense = spent + paid - received (net cash outflow).
//          outstanding = spent - myShare - received + paid (unsettled balance).
class UserMonetaryData {
  num spent;
  num myShare;
  num received;
  num paid;
  // Only set when this object represents the acrossUsers aggregate in TagTotal,
  // where outstanding = Σ max(0, outstanding_per_user), not the formula result.
  num? _storedOutstanding;

  UserMonetaryData({this.spent = 0, this.myShare = 0, this.received = 0, this.paid = 0, num? storedOutstanding})
      : _storedOutstanding = storedOutstanding;

  num get expense => spent + paid - received;
  num get outstanding => _storedOutstanding ?? (spent - myShare - received + paid);

  factory UserMonetaryData.fromJson(Map<String, dynamic> json) => UserMonetaryData(
    spent: (json['spent'] as num?) ?? 0,
    myShare: (json['myShare'] as num?) ?? 0,
    received: (json['received'] as num?) ?? 0,
    paid: (json['paid'] as num?) ?? 0,
  );

  Map<String, dynamic> toJson() => {'spent': spent, 'myShare': myShare, 'received': received, 'paid': paid};
}

// Total monetary data for a tag — per-user breakdown.
// acrossUsers is fully derived from userWise; not stored in Firestore.
class TagTotal {
  Map<String, UserMonetaryData> userWise; // userId -> monetary data

  TagTotal({required this.userWise});

  factory TagTotal.empty() => TagTotal(userWise: {});

  // Derived aggregate: expense = Σspent (paid/received cancel at group level).
  // outstanding = Σ max(0, outstanding_per_user) — uses _storedOutstanding to override formula.
  UserMonetaryData get acrossUsers {
    num spent = 0, myShare = 0, received = 0, paid = 0, outstanding = 0;
    for (final u in userWise.values) {
      spent += u.spent;
      myShare += u.myShare;
      received += u.received;
      paid += u.paid;
      final o = u.outstanding;
      if (o > 0) outstanding += o;
    }
    return UserMonetaryData(spent: spent, myShare: myShare, received: received, paid: paid, storedOutstanding: outstanding);
  }

  factory TagTotal.fromJson(Map<String, dynamic> json) {
    final userWise = <String, UserMonetaryData>{};
    for (final entry in json.entries) {
      if (entry.key != 'acrossUsers' && entry.value is Map) {
        userWise[entry.key] = UserMonetaryData.fromJson((entry.value as Map).cast<String, dynamic>());
      }
    }
    return TagTotal(userWise: userWise);
  }

  Map<String, dynamic> toJson() => {
    for (final entry in userWise.entries) entry.key: entry.value.toJson(),
  };

  String getTagTileSummary(List<SelectableContact> tagParticipants, {bool showOutstanding = false}) {
    String message = "";
    int totalCount = 0;
    int maxCount = 3;

    String nameFor(String userId) => tagParticipants.where((p) => p.userId == userId).firstOrNull?.displayName ?? userId;

    if (showOutstanding && acrossUsers.outstanding > 0) {
      // filter out userWise for keys not in tagParticipants
      final participants =
          userWise.entries.where((e) => e.value.outstanding != 0 && tagParticipants.any((p) => p.userId == e.key)).toList()
            ..sort((a, b) => a.value.outstanding.compareTo(b.value.outstanding)); // owes first

      if (participants.isNotEmpty) {
        final shown = participants
            .take(maxCount)
            .map((e) {
              final r = e.value.outstanding;
              final amt = NumberFormat.compact().format(r.abs().round());
              return r < 0 ? '${nameFor(e.key)} owes ₹$amt' : '${nameFor(e.key)} is owed ₹$amt';
            })
            .join(', ');

        message += shown;
        if (userWise.length == 1) {
          //user has not shared this tag with anyone
          message += '\nAdd user to this tag (Tag > Edit) so they settle\n by adding Expense marked "Settlement" to this tag';
          return message;
        }

        totalCount += [participants.length, maxCount].reduce(min);
        if (totalCount == maxCount) return message;

        if (totalCount > 0) message += ". ";
      }
    }

    //no participants with outstanding data .. show expense data instead
    final participants =
        userWise.entries.where((e) => e.value.expense != 0 && tagParticipants.any((p) => p.userId == e.key)).toList()
          ..sort((a, b) => b.value.expense.compareTo(a.value.expense)); // biggest expense first

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
  // Transient — not serialized. Set when a user-initiated write is in flight;
  // cleared automatically when a fresh tag snapshot arrives from the server.
  DateTime? statsPendingAfter;
  int unseenCount = 0;
  List<SelectableContact> participants = [];

  Tag({required this.id, required this.name, required this.ownerId, required this.total, required this.monthWiseTotal});

  /// Returns the displayName (includes '@' for kilvish users) for a userId,
  /// looked up from the already-loaded participants list.
  String? displayNameForUserId(String userId) => participants.where((p) => p.userId == userId).firstOrNull?.displayName;

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
    try {
      if (sharedWith.isNotEmpty || total.acrossUsers.outstanding > 0) {
        return total.getTagTileSummary(participants, showOutstanding: !dontShowOutstanding);
      }

      // give current & last month data
      final now = DateTime.now();
      final currentMonth = DateFormat('yyyy-MM').format(now);
      final previousMonth = DateFormat('yyyy-MM').format(DateTime(now.year, now.month - 1, 1));

      return 'This month: ₹${monthWiseTotal[currentMonth]?.acrossUsers.expense ?? "-"} \nPrev month: ₹${monthWiseTotal[previousMonth]?.acrossUsers.expense ?? "-"}';
    } catch (e, stackTrace) {
      print('getTagTileSummary error - $e\nstacktrace\n$stackTrace');
      return 'Error in showing tag summary. Cant be shown now';
    }
  }

  /// Validates whether the given owner can create a settlement (optionally against a specific recipient).
  /// Returns a map with:
  ///   'result' : 'ok' | 'warning' | 'error'
  ///   'type'   : 'none' | 'owed' | 'no_share' | 'recipient'
  ///   'message': String (empty for 'ok')
  ///
  /// Checks in priority order:
  ///   error / owed      — owner's recovery > 0 (they are owed; should not settle)
  ///   error / recipient — owner's expense > recipient's expense (owner spent more; recipient should settle with them)
  ///   warning / no_share — acrossUsers.recovery > 0 but owner's recovery == 0 (hasn't marked share yet)
  Map<String, String> settlementCheck(String ownerId, {String? recipientId}) {
    final myOutstanding = total.userWise[ownerId]?.outstanding ?? 0;

    if (total.acrossUsers.outstanding > 0 && myOutstanding > 0) {
      return {
        'result': 'error',
        'type': 'owed',
        'message': 'Somebody owes you ₹${myOutstanding.round()} in this tag. You don\'t need to settle with anyone.',
      };
    }

    if (total.acrossUsers.outstanding > 0 && myOutstanding == 0) {
      return {
        'result': 'warning',
        'type': 'no_share',
        'message': 'It seems you have not marked your share in any expense in the group. Are you sure you want to settle?',
      };
    }

    return {'result': 'ok', 'type': 'none', 'message': ''};
  }

  /// Returns actionable guidance for the viewing user, or null if no action is needed.
  /// Keys: 'message' (String), 'color' (Color).
  ///
  /// Priority 1 — Mark share:
  ///   acrossUsers.recovery > 0 AND user's own recovery == 0
  ///   → someone in the tag is owed money, but this user hasn't marked their share yet.
  ///
  /// Priority 2 — Settle (negative recovery):
  ///   user's recovery < 0
  ///   → user owes money; direct them to settle with the user who has the largest positive recovery.
  ///
  /// Priority 3 — Settle (expense imbalance):
  ///   user's expense < another user's expense
  ///   → settle half the gap with the highest-spending user.
  Map<String, dynamic>? getActionGuidanceForViewingUser(String currentUserId) {
    if (sharedWith.isEmpty) return null;

    try {
      final myData = total.userWise[currentUserId];
      final myOutstanding = myData?.outstanding ?? 0;

      // Priority 1: someone is owed money but this user hasn't marked their share.
      if (total.acrossUsers.outstanding > 0 && myOutstanding == 0) {
        return {
          'message':
              'Open an expense & mark amount you owe by tapping the tag on it to reflect your oustanding amount accurately.',
          'color': outstandingColor,
        };
      }

      // Priority 2: user has negative outstanding — they owe money.
      if (total.acrossUsers.outstanding > 0 && myOutstanding < 0) {
        final amount = (-myOutstanding).round();
        return {
          'message':
              'You owe ₹$amount in this tag. Pay and log a Settlement with one of the member with positive outstanding value',
          'color': settlementCardColor,
        };
      }

      // Priority 3: user is owed money — ask them to nudge whoever has negative outstanding.
      if (total.acrossUsers.outstanding > 0 && myOutstanding > 0) {
        return {
          'message': 'You are owed ₹${myOutstanding.round()}. Ask the member with negative outstanding to log a Settlement.',
          'color': outstandingColor,
        };
      }
    } catch (e, stackTrace) {
      print("getActionGuidanceForViewingUser() error - $e\nstackTrace:\n $stackTrace");
      return null;
    }

    return null;
  }
}

enum TagStatus { selected, unselected }

import 'dart:convert';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _asyncPrefs = SharedPreferencesAsync();

const _keyMyExpenses = '_myExpenses';
const _keyWIPExpenses = '_wipExpenses';
const _keyTags = '_tags';
const _keyKnownTagIds = '_knownTagIds';

// ─── My Expenses ───

Future<List<Expense>> loadMyExpenses({bool forceReload = false}) async {
  if (!forceReload) {
    final json = await _asyncPrefs.getString(_keyMyExpenses);
    if (json != null) {
      try {
        final list = jsonDecode(json) as List<dynamic>;
        final userId = await getUserIdFromClaim();
        final ownerKilvishId = await getUserKilvishId(userId!);
        return list.map((m) => Expense.fromJson(m as Map<String, dynamic>, ownerKilvishId!)).toList();
      } catch (e) {
        print('loadMyExpenses cache decode error: $e');
      }
    }
  }
  try {
    final user = await getLoggedInUserData();
    if (user == null) return [];
    final docs = await getExpenseDocsOfUser(user.id);
    final expenses = await Future.wait(
      docs.map((doc) async {
        final e = await Expense.getExpenseFromFirestoreObject(doc.id, doc.data() as Map<String, dynamic>);
        e.setUnseenStatus(user.unseenExpenseIds);
        return e;
      }),
    );
    await saveMyExpenses(expenses);
    return expenses;
  } catch (e) {
    print('loadMyExpenses fetch error: $e');
    return [];
  }
}

Future<void> saveMyExpenses(List<Expense> expenses) async {
  await _asyncPrefs.setString(_keyMyExpenses, jsonEncode(expenses.map((e) => e.toJson()).toList()));
}

Future<void> addOrUpdateMyExpense(Expense expense) async {
  final expenses = await loadMyExpenses();
  final idx = expenses.indexWhere((e) => e.id == expense.id);
  if (idx >= 0) {
    expenses[idx] = expense;
  } else {
    expenses.insert(0, expense);
  }
  await saveMyExpenses(expenses);
}

Future<void> removeMyExpense(String expenseId) async {
  final expenses = await loadMyExpenses();
  expenses.removeWhere((e) => e.id == expenseId);
  await saveMyExpenses(expenses);
}

// ─── WIPExpenses ───

Future<List<WIPExpense>?> loadWIPExpenses() async {
  final json = await _asyncPrefs.getString(_keyWIPExpenses);
  if (json == null) return null;
  try {
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((m) => WIPExpense.fromJson(m as Map<String, dynamic>)).toList();
  } catch (e) {
    print('loadWIPExpenses error: $e');
    return null;
  }
}

Future<void> saveWIPExpenses(List<WIPExpense> wipExpenses) async {
  await _asyncPrefs.setString(_keyWIPExpenses, jsonEncode(wipExpenses.map((e) => e.toJson()).toList()));
}

Future<void> addOrUpdateWIPExpense(WIPExpense wipExpense) async {
  final wipExpenses = await loadWIPExpenses() ?? [];
  final idx = wipExpenses.indexWhere((e) => e.id == wipExpense.id);
  if (idx >= 0) {
    wipExpenses[idx] = wipExpense;
  } else {
    wipExpenses.insert(0, wipExpense);
  }
  await saveWIPExpenses(wipExpenses);
}

Future<void> removeWIPExpense(String wipExpenseId) async {
  final wipExpenses = await loadWIPExpenses() ?? [];
  wipExpenses.removeWhere((e) => e.id == wipExpenseId);
  await saveWIPExpenses(wipExpenses);
}

// ─── Tags ───

Future<List<Tag>> loadTags() async {
  final json = await _asyncPrefs.getString(_keyTags);
  if (json != null) {
    try {
      return Tag.jsonDecodeTagsList(json);
    } catch (e) {
      print('loadTags cache decode error: $e');
    }
  }
  try {
    final user = await getLoggedInUserData();
    if (user == null) return [];
    final tags = <Tag>[];
    for (final tagId in user.accessibleTagIds) {
      try {
        tags.add(await getTagData(tagId, includeMostRecentExpense: true));
      } catch (e) {
        print('loadTags: error fetching $tagId: $e');
      }
    }
    await saveTags(tags);
    return tags;
  } catch (e) {
    print('loadTags fetch error: $e');
    return [];
  }
}

Future<void> saveTags(List<Tag> tags) async {
  await _asyncPrefs.setString(_keyTags, Tag.jsonEncodeTagsList(tags));
}

Future<void> addOrUpdateTag(Tag tag) async {
  final tags = await loadTags();
  final idx = tags.indexWhere((t) => t.id == tag.id);
  if (idx >= 0) {
    tags[idx] = tag;
  } else {
    tags.insert(0, tag);
  }
  await saveTags(tags);
}

Future<void> removeTag(String tagId) async {
  final tags = await loadTags();
  tags.removeWhere((t) => t.id == tagId);
  await saveTags(tags);
  // no need to refresh MyExpenses as this event is for someone else's tag
}

// ─── Tag Expenses ───

String _keyTagExpenses(String tagId) => 'tag_${tagId}_expenses';

Future<List<Expense>> loadTagExpenses(String tagId, {bool forceReload = false}) async {
  if (!forceReload) {
    final json = await _asyncPrefs.getString(_keyTagExpenses(tagId));
    if (json != null) {
      try {
        return await Expense.jsonDecodeExpenseListCacheForTagExpenses(json);
      } catch (e) {
        print('loadTagExpenses $tagId cache decode error: $e');
      }
    }
  }
  try {
    final user = await getLoggedInUserData();
    if (user == null) return [];
    final expenses = await getExpensesOfTag(tagId);
    for (final e in expenses) {
      e.setUnseenStatus(user.unseenExpenseIds);
    }
    await saveTagExpenses(tagId, expenses);
    return expenses;
  } catch (e) {
    print('loadTagExpenses $tagId fetch error: $e');
    return [];
  }
}

Future<void> saveTagExpenses(String tagId, List<Expense> expenses) async {
  await _asyncPrefs.setString(_keyTagExpenses(tagId), Expense.jsonEncodeExpensesList(expenses));
  await _registerKnownTagId(tagId);
}

Future<void> updateTagExpensesIfCached(List<String> tagIds, Expense expense) async {
  for (final tagId in tagIds) {
    final json = await _asyncPrefs.getString(_keyTagExpenses(tagId));
    if (json == null) continue;
    await addOrUpdateTagExpense(tagId, expense);
  }
}

Future<void> removeExpenseFromTagCachesIfCached(List<String> tagIds, String expenseId) async {
  for (final tagId in tagIds) {
    final json = await _asyncPrefs.getString(_keyTagExpenses(tagId));
    if (json == null) continue;
    await removeTagExpense(tagId, expenseId);
  }
}

Future<void> addOrUpdateTagExpense(String tagId, Expense expense) async {
  final expenses = await loadTagExpenses(tagId);
  final idx = expenses.indexWhere((e) => e.id == expense.id);
  if (idx >= 0) {
    expenses[idx] = expense;
  } else {
    expenses.insert(0, expense);
  }
  await saveTagExpenses(tagId, expenses);
}

Future<void> removeTagExpense(String tagId, String expenseId) async {
  final expenses = await loadTagExpenses(tagId);
  expenses.removeWhere((e) => e.id == expenseId);
  await saveTagExpenses(tagId, expenses);
}

Future<void> _registerKnownTagId(String tagId) async {
  final json = await _asyncPrefs.getString(_keyKnownTagIds);
  final ids = json != null ? (jsonDecode(json) as List).cast<String>().toSet() : <String>{};
  if (ids.add(tagId)) {
    await _asyncPrefs.setString(_keyKnownTagIds, jsonEncode(ids.toList()));
  }
}

Future<Set<String>> _getKnownTagIds() async {
  final json = await _asyncPrefs.getString(_keyKnownTagIds);
  if (json == null) return {};
  return (jsonDecode(json) as List).cast<String>().toSet();
}

// ─── Clear All ───

Future<void> clearAllCache() async {
  await _asyncPrefs.remove(_keyMyExpenses);
  await _asyncPrefs.remove(_keyWIPExpenses);
  await _asyncPrefs.remove(_keyTags);
  final tagIds = await _getKnownTagIds();
  for (final tagId in tagIds) {
    await _asyncPrefs.remove(_keyTagExpenses(tagId));
  }
  await _asyncPrefs.remove(_keyKnownTagIds);
}

// ─── FCM-driven cache update ───

Future<void> updateHomeScreenExpensesAndCache({
  required String type,
  String? wipExpenseId,
  String? expenseId,
  String? tagId,
}) async {
  print('updateHomeScreenExpensesAndCache: type=$type, wipExpenseId=$wipExpenseId, expenseId=$expenseId, tagId=$tagId');

  try {
    switch (type) {
      case 'wip_status_update':
        if (wipExpenseId == null) {
          print('wip_status_update: wipExpenseId missing');
          return;
        }
        final updated = await getWIPExpense(wipExpenseId);
        if (updated != null) {
          await addOrUpdateWIPExpense(updated);
          print('updateHomeScreenExpensesAndCache: WIPExpense $wipExpenseId -> ${updated.status.name}');
        } else {
          await removeWIPExpense(wipExpenseId);
          print('updateHomeScreenExpensesAndCache: WIPExpense $wipExpenseId not found on server, removed from cache');
          final convertedExpense = await getExpense(wipExpenseId);
          if (convertedExpense != null) {
            await addOrUpdateMyExpense(convertedExpense);
            print('updateHomeScreenExpensesAndCache: Auto-converted expense $wipExpenseId added to My Expenses');
          }
        }
        break;

      case 'expense_created':
      case 'expense_updated':
      case 'expense_deleted':
        if (tagId == null) {
          print('$type: tagId missing');
          return;
        }
        final tag = await getTagData(tagId, includeMostRecentExpense: true);
        await addOrUpdateTag(tag);
        print('updateHomeScreenExpensesAndCache: Tag ${tag.name} cache updated for $type');

        if (expenseId != null) {
          if (type == 'expense_deleted') {
            await removeMyExpense(expenseId);
            await removeTagExpense(tagId, expenseId);
            print('updateHomeScreenExpensesAndCache: Removed $expenseId from caches');
          } else {
            // Update My Expenses if this user is the owner
            final myExpense = await getExpense(expenseId);
            if (myExpense != null) {
              await addOrUpdateMyExpense(myExpense);
              print('updateHomeScreenExpensesAndCache: Added/updated $expenseId in My Expenses');
            }
            // Update tag expense cache for all members
            final tagExpense = await getTagExpense(tagId, expenseId);
            if (tagExpense is Expense) {
              await addOrUpdateTagExpense(tagId, tagExpense);
              print('updateHomeScreenExpensesAndCache: Updated $expenseId in tag $tagId expense cache');
            }
          }
        }
        break;

      case 'recipient_written':
        if (tagId == null) {
          print('recipient_written: tagId missing');
          return;
        }
        final recipientTag = await getTagData(tagId, includeMostRecentExpense: true);
        await addOrUpdateTag(recipientTag);
        if (expenseId != null) {
          final tagExpense = await getTagExpense(tagId, expenseId);
          if (tagExpense is Expense) await addOrUpdateTagExpense(tagId, tagExpense);
        }
        print('updateHomeScreenExpensesAndCache: Tag ${recipientTag.name} refreshed for recipient_written');
        break;

      case 'tag_shared':
        if (tagId == null) {
          print('tag_shared: tagId missing');
          return;
        }
        final tag = await getTagData(tagId, includeMostRecentExpense: true);
        await addOrUpdateTag(tag);
        print('updateHomeScreenExpensesAndCache: Tag ${tag.name} added to cache for tag_shared');
        break;

      case 'tag_updated':
        if (tagId == null) {
          print('tag_updated: tagId missing');
          return;
        }
        final tag = await getTagData(tagId, includeMostRecentExpense: true);
        await addOrUpdateTag(tag);
        print('updateHomeScreenExpensesAndCache: Tag ${tag.name} cache refreshed for tag_updated');
        break;

      case 'tag_removed':
        if (tagId == null) {
          print('tag_removed: tagId missing');
          return;
        }
        await removeTag(tagId); // will automatically re-fetch user's MyExpenses.
        await removeTagExpense(tagId, tagId); // clears tag expense cache key
        print('updateHomeScreenExpensesAndCache: Tag $tagId removed from cache');
        break;

      default:
        print('updateHomeScreenExpensesAndCache: Unhandled type $type');
    }
  } catch (e, stackTrace) {
    print('updateHomeScreenExpensesAndCache: Error $e $stackTrace');
  }
}

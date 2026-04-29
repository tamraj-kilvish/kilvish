import 'dart:convert';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _asyncPrefs = SharedPreferencesAsync();

const _keyMyExpenses = '_myExpenses';
const _keyWIPExpenses = '_wipExpenses';
const _keyTags = '_tags';

// ─── My Expenses (local-only, seeded from Firestore once on empty cache) ───

Future<List<Expense>?> loadMyExpenses() async {
  final json = await _asyncPrefs.getString(_keyMyExpenses);
  if (json == null) return null;
  try {
    final list = jsonDecode(json) as List<dynamic>;
    return await Future.wait(list.map((m) async {
      final map = m as Map<String, dynamic>;
      return Expense.fromJson(map, (await _resolveKilvishId(map['ownerId'])));
    }));
  } catch (e) {
    print('loadMyExpenses error: $e');
    return null;
  }
}

Future<void> saveMyExpenses(List<Expense> expenses) async {
  await _asyncPrefs.setString(_keyMyExpenses, jsonEncode(expenses.map((e) => e.toJson()).toList()));
}

Future<void> addOrUpdateMyExpense(Expense expense) async {
  final expenses = await loadMyExpenses() ?? [];
  final idx = expenses.indexWhere((e) => e.id == expense.id);
  if (idx >= 0) {
    expenses[idx] = expense;
  } else {
    expenses.insert(0, expense);
  }
  await saveMyExpenses(expenses);
}

Future<void> removeMyExpense(String expenseId) async {
  final expenses = await loadMyExpenses() ?? [];
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

// ─── Tags (updated via FCM) ───

Future<List<Tag>?> loadTags() async {
  final json = await _asyncPrefs.getString(_keyTags);
  if (json == null) return null;
  try {
    return Tag.jsonDecodeTagsList(json);
  } catch (e) {
    print('loadTags error: $e');
    return null;
  }
}

Future<void> saveTags(List<Tag> tags) async {
  await _asyncPrefs.setString(_keyTags, Tag.jsonEncodeTagsList(tags));
}

Future<void> addOrUpdateTag(Tag tag) async {
  final tags = await loadTags() ?? [];
  final idx = tags.indexWhere((t) => t.id == tag.id);
  if (idx >= 0) {
    tags[idx] = tag;
  } else {
    tags.insert(0, tag);
  }
  await saveTags(tags);
}

Future<void> removeTag(String tagId) async {
  final tags = await loadTags() ?? [];
  tags.removeWhere((t) => t.id == tagId);
  await saveTags(tags);
}

Future<void> clearAllCache() async {
  await _asyncPrefs.remove(_keyMyExpenses);
  await _asyncPrefs.remove(_keyWIPExpenses);
  await _asyncPrefs.remove(_keyTags);
}

// ─── FCM-driven cache update ───

/// Called by the FCM handler on every incoming message.
/// Does ONE Firestore server fetch for the affected entity, then updates
/// SharedPreferences so the home screen can re-read from cache.
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
        if (wipExpenseId == null) { print('wip_status_update: wipExpenseId missing'); return; }
        final updated = await getWIPExpense(wipExpenseId);
        if (updated != null) {
          await addOrUpdateWIPExpense(updated);
          print('updateHomeScreenExpensesAndCache: WIPExpense $wipExpenseId -> ${updated.status.name}');
        } else {
          await removeWIPExpense(wipExpenseId);
          print('updateHomeScreenExpensesAndCache: WIPExpense $wipExpenseId not found on server, removed from cache');
        }
        break;

      case 'expense_created':
      case 'expense_updated':
      case 'expense_deleted':
        if (tagId == null) { print('$type: tagId missing'); return; }
        final tag = await getTagData(tagId, includeMostRecentExpense: true);
        await addOrUpdateTag(tag);
        print('updateHomeScreenExpensesAndCache: Tag ${tag.name} cache updated for $type');
        break;

      case 'tag_shared':
        if (tagId == null) { print('tag_shared: tagId missing'); return; }
        final tag = await getTagData(tagId, includeMostRecentExpense: true);
        await addOrUpdateTag(tag);
        print('updateHomeScreenExpensesAndCache: Tag ${tag.name} added to cache for tag_shared');
        break;

      case 'tag_removed':
        if (tagId == null) { print('tag_removed: tagId missing'); return; }
        await removeTag(tagId);
        print('updateHomeScreenExpensesAndCache: Tag $tagId removed from cache');
        break;

      default:
        print('updateHomeScreenExpensesAndCache: Unhandled type $type');
    }
  } catch (e, stackTrace) {
    print('updateHomeScreenExpensesAndCache: Error $e $stackTrace');
  }
}

// ─── Helpers ───

Future<String> _resolveKilvishId(String? ownerId) async {
  if (ownerId == null) return '';
  return await getUserKilvishId(ownerId) ?? '';
}

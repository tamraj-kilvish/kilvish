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

// ─── Helpers ───

Future<String> _resolveKilvishId(String? ownerId) async {
  if (ownerId == null) return '';
  return await getUserKilvishId(ownerId) ?? '';
}

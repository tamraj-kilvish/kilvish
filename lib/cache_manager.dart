import 'dart:convert';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense.dart';
import 'package:shared_preferences/shared_preferences.dart';

final asyncPrefs = SharedPreferencesAsync();

/// Fetches expense from Tag subcollection (works for both Expense & WIPExpense)
Future<BaseExpense?> getTagExpense(String tagId, String expenseId) async {
  final doc = await getFirestoreInstance().collection('Tags').doc(tagId).collection('Expenses').doc(expenseId).get();

  if (!doc.exists) return null;

  final data = doc.data()!;
  final ownerId = data['ownerId'] as String?;
  final ownerKilvishId = ownerId != null ? await getUserKilvishId(ownerId) : null;

  // Check if it's a WIPExpense by status field
  if (data['status'] != null) {
    return WIPExpense.fromFirestoreObject(expenseId, data, ownerKilvishIdParam: ownerKilvishId);
  }

  return Expense.fromFirestoreObject(expenseId, data, ownerKilvishIdParam: ownerKilvishId);
}

/// Rebuilds entire allExpenses from scratch
Future<Map<String, dynamic>> loadFromScratch(KilvishUser user) async {
  print('loadFromScratch: Building cache from Firestore');

  Map<String, BaseExpense> allExpensesMap = {};

  // Get WIPExpenses
  List<WIPExpense> wipExpenses = await getAllWIPExpenses();
  print('loadFromScratch: Got ${wipExpenses.length} WIPExpenses');

  for (var wip in wipExpenses) {
    allExpensesMap[wip.id] = wip;
  }

  // Get user's own expenses
  final userExpenseDocs = await getExpenseDocsOfUser(user.id);
  print('loadFromScratch: Got ${userExpenseDocs.length} user expenses');

  for (var doc in userExpenseDocs) {
    if (!allExpensesMap.containsKey(doc.id)) {
      final expense = Expense.fromFirestoreObject(
        doc.id,
        doc.data() as Map<String, dynamic>,
        ownerKilvishIdParam: user.kilvishId,
      );
      expense.setUnseenStatus(user.unseenExpenseIds);
      allExpensesMap[doc.id] = expense;
    }
  }

  // Get expenses from accessible tags
  for (String tagId in user.accessibleTagIds) {
    try {
      final tag = await getTagData(tagId);
      final tagExpenseDocs = await getExpenseDocsUnderTag(tagId);
      print('loadFromScratch: Got ${tagExpenseDocs.length} expenses from tag $tagId');

      for (var doc in tagExpenseDocs) {
        BaseExpense? expense = allExpensesMap[doc.id];

        if (expense == null) {
          expense = await Expense.getExpenseFromFirestoreObject(doc.id, doc.data() as Map<String, dynamic>);
          (expense as Expense).setUnseenStatus(user.unseenExpenseIds);
          allExpensesMap[doc.id] = expense;
        }

        if (expense is Expense) {
          expense.addTagToExpense(tag);
        }
      }
    } catch (e, stackTrace) {
      print('loadFromScratch: Error processing tag $tagId: $e $stackTrace');
    }
  }

  // Sort by createdAt descending
  List<BaseExpense> allExpenses = allExpensesMap.values.toList();
  allExpenses.sort((a, b) => b.createdAt.compareTo(a.createdAt));

  return {'allExpensesMap': allExpensesMap, 'allExpenses': allExpenses};
}

/// Incrementally updates SharedPreferences cache
Future<void> storeUpdatedHomeScreenStateInSharedPref({required String type, required String expenseId, String? tagId}) async {
  print('storeUpdatedHomeScreenStateInSharedPref: type=$type, expenseId=$expenseId, tagId=$tagId');

  try {
    // Try loading existing cache
    Map<String, BaseExpense> allExpensesMap = {};
    List<BaseExpense> allExpenses = [];

    final mapJson = await asyncPrefs.getString('_allExpensesMap');
    final listJson = await asyncPrefs.getString('_allExpenses');

    if (mapJson != null && listJson != null) {
      // Deserialize existing cache
      final mapData = jsonDecode(mapJson) as Map<String, dynamic>;
      for (var entry in mapData.entries) {
        allExpensesMap[entry.key] = await _deserializeExpense(entry.value);
      }

      final listData = jsonDecode(listJson) as List<dynamic>;
      for (var item in listData) {
        allExpenses.add(await _deserializeExpense(item));
      }
    } else {
      // No cache exists - build from scratch
      print('storeUpdatedHomeScreenStateInSharedPref: No cache found, building from scratch');
      final user = await getLoggedInUserData();
      if (user == null) return;

      final freshData = await loadFromScratch(user);
      allExpensesMap = freshData['allExpensesMap'];
      allExpenses = freshData['allExpenses'];
    }

    // Fetch updated expense
    BaseExpense? updatedExpense;
    if (tagId != null) {
      updatedExpense = await getTagExpense(tagId, expenseId);
    } else {
      // Try fetching from user's expenses
      final user = await getLoggedInUserData();
      if (user != null) {
        updatedExpense = await getExpense(expenseId);
      }
    }

    if (updatedExpense == null) {
      print('storeUpdatedHomeScreenStateInSharedPref: Could not fetch expense $expenseId');
      return;
    }

    // Apply updates based on type
    switch (type) {
      case 'expense_created':
      case 'wip_status_update':
        if (!allExpensesMap.containsKey(expenseId)) {
          // Add new expense
          allExpensesMap[expenseId] = updatedExpense;
          allExpenses.insert(0, updatedExpense);
          print('storeUpdatedHomeScreenStateInSharedPref: Added new expense $expenseId');
        } else {
          // Update existing (for wip_status_update)
          allExpensesMap[expenseId] = updatedExpense;
          allExpenses = allExpenses.map((e) => e.id == expenseId ? updatedExpense! : e).toList();
          print('storeUpdatedHomeScreenStateInSharedPref: Updated expense $expenseId');
        }
        break;

      case 'expense_updated':
        allExpensesMap[expenseId] = updatedExpense;
        allExpenses = allExpenses.map((e) => e.id == expenseId ? updatedExpense! : e).toList();
        print('storeUpdatedHomeScreenStateInSharedPref: Updated expense $expenseId');
        break;

      case 'expense_deleted':
        final expense = allExpensesMap[expenseId];
        if (expense != null) {
          // Check if expense has other tags
          if (expense is Expense && expense.tags.isNotEmpty) {
            // Only remove from this tag, keep in cache
            expense.tags.removeWhere((t) => t.id == tagId);
            if (expense.tags.isEmpty) {
              // No more tags, remove completely
              allExpensesMap.remove(expenseId);
              allExpenses.removeWhere((e) => e.id == expenseId);
            }
          } else {
            // Remove completely
            allExpensesMap.remove(expenseId);
            allExpenses.removeWhere((e) => e.id == expenseId);
          }
          print('storeUpdatedHomeScreenStateInSharedPref: Deleted expense $expenseId');
        }
        break;
    }

    // Re-sort by createdAt descending
    allExpenses.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    // Save back to SharedPreferences
    await asyncPrefs.setString('_allExpensesMap', jsonEncode(_serializeMap(allExpensesMap)));
    await asyncPrefs.setString('_allExpenses', jsonEncode(_serializeList(allExpenses)));

    print('storeUpdatedHomeScreenStateInSharedPref: Cache updated successfully');
  } catch (e, stackTrace) {
    print('storeUpdatedHomeScreenStateInSharedPref: Error $e $stackTrace');
  }
}

/// Loads from SharedPreferences
Future<Map<String, dynamic>?> loadHomeScreenStateFromSharedPref() async {
  print('loadHomeScreenStateFromSharedPref: Loading cache');

  try {
    final mapJson = await asyncPrefs.getString('_allExpensesMap');
    final listJson = await asyncPrefs.getString('_allExpenses');
    final tagsJson = await asyncPrefs.getString('_tags');

    if (mapJson == null || listJson == null) {
      print('loadHomeScreenStateFromSharedPref: No cache found');
      return null;
    }

    Map<String, BaseExpense> allExpensesMap = {};
    final mapData = jsonDecode(mapJson) as Map<String, dynamic>;
    for (var entry in mapData.entries) {
      allExpensesMap[entry.key] = await _deserializeExpense(entry.value);
    }

    List<BaseExpense> allExpenses = [];
    final listData = jsonDecode(listJson) as List<dynamic>;
    for (var item in listData) {
      allExpenses.add(await _deserializeExpense(item));
    }

    List<Tag> tags = [];
    if (tagsJson != null) {
      tags = Tag.jsonDecodeTagsList(tagsJson);
    }

    print('loadHomeScreenStateFromSharedPref: Loaded ${allExpenses.length} expenses, ${tags.length} tags');

    return {'allExpensesMap': allExpensesMap, 'allExpenses': allExpenses, 'tags': tags};
  } catch (e, stackTrace) {
    print('loadHomeScreenStateFromSharedPref: Error $e $stackTrace');
    return null;
  }
}

// Helper serialization methods
Map<String, dynamic> _serializeMap(Map<String, BaseExpense> map) {
  return map.map((key, value) => MapEntry(key, value.toJson()));
}

List<dynamic> _serializeList(List<BaseExpense> list) {
  return list.map((e) => e.toJson()).toList();
}

Future<BaseExpense> _deserializeExpense(dynamic json) async {
  final map = json as Map<String, dynamic>;

  if (map['status'] != null) {
    // It's a WIPExpense
    return WIPExpense.fromJson(map);
  } else {
    // It's an Expense
    return Expense.fromJson(map);
  }
}

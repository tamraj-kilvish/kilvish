import 'dart:convert';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense.dart';
import 'package:shared_preferences/shared_preferences.dart';

final asyncPrefs = SharedPreferencesAsync();

/// Rebuilds entire allExpenses from scratch
Future<Map<String, dynamic>> loadFromScratch(KilvishUser user) async {
  print('loadFromScratch: Building cache from Firestore');

  Map<String, BaseExpense> allExpensesMap = {};
  Set<Tag> tags = {};

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
      final expense = await Expense.getExpenseFromFirestoreObject(doc.id, doc.data() as Map<String, dynamic>);
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

      tag.mostRecentExpense = await getMostRecentExpenseFromTag(tagId);
      tags.add(tag);
    } catch (e, stackTrace) {
      print('loadFromScratch: Error processing tag $tagId: $e $stackTrace');
    }
  }

  // Sort by createdAt descending
  List<BaseExpense> allExpenses = allExpensesMap.values.toList();
  allExpenses.sort((a, b) => b.createdAt.compareTo(a.createdAt));

  return {'allExpensesMap': allExpensesMap, 'allExpenses': allExpenses, 'tags': tags.toList()};
}

/// Incrementally updates SharedPreferences cache
Future<void> updateHomeScreenExpensesAndCache({
  required String type,
  String? expenseId,
  String? wipExpenseId,
  String? tagId,
}) async {
  print('updateHomeScreenExpensesAndCache: type=$type, expenseId=$expenseId, wipExpenseId=$wipExpenseId tagId=$tagId');

  try {
    // Try loading existing cache
    Map<String, BaseExpense> allExpensesMap = {};
    List<BaseExpense> allExpenses = [];
    List<Tag> tags = [];

    final mapJson = await asyncPrefs.getString('_allExpensesMap');
    final listJson = await asyncPrefs.getString('_allExpenses');
    final tagsJson = await asyncPrefs.getString('_tags');

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

      tags = Tag.jsonDecodeTagsList(tagsJson!);
    } else {
      // No cache exists - build from scratch
      print('updateHomeScreenExpensesAndCache: No cache found, building from scratch');
      final user = await getLoggedInUserData();
      if (user == null) return;

      final freshData = await loadFromScratch(user);
      allExpensesMap = freshData['allExpensesMap'];
      allExpenses = freshData['allExpenses'];
      tags = freshData['tags'];
    }

    Tag? updatedTag;
    if (tagId != null) {
      updatedTag = await getTagData(tagId);
    }

    //tag updates
    switch (type) {
      case "expense_created":
      case "expense_updated":
      case "expense_deleted":
        if (updatedTag == null) {
          print('updateHomeScreenExpensesAndCache: Got type $type but updatedTag is null for $tagId !!!');
        } else {
          tags = tags.map((tag) => tag.id == tagId ? updatedTag! : tag).toList();
          print('updateHomeScreenExpensesAndCache: Monetary stats for tag ${updatedTag.name} should be updated now');
        }
        break;

      case "tag_shared":
        if (updatedTag == null) {
          print('updateHomeScreenExpensesAndCache: Got type $type but updatedTag is null for $tagId !!!');
        } else {
          tags.insert(0, updatedTag);
          print('updateHomeScreenExpensesAndCache: tag ${updatedTag.name} will show on the top of tag list');
        }
        break;

      case "tag_removed":
        tags.removeWhere((t) => t.id == tagId);
        print('updateHomeScreenExpensesAndCache: tag $tagId should be removed from the tag list');

        break;
    }

    // Now applying Expense updates

    String? baseExpenseId = wipExpenseId ?? expenseId;

    if (baseExpenseId == null) {
      print("Both expenseId & wipExpenseId are null. Exiting");
      return;
    }

    // Fetch updated expense
    BaseExpense? updatedExpense;

    if (expenseId != null) {
      if (tagId != null) {
        updatedExpense = await getTagExpense(tagId, expenseId);
      } else {
        // Try fetching from user's expenses
        final user = await getLoggedInUserData();
        if (user != null) {
          updatedExpense = await getExpense(expenseId);
        }
      }
    }

    if (wipExpenseId != null) {
      updatedExpense = await getWIPExpense(wipExpenseId);
    }

    if (updatedExpense == null) {
      print('updateHomeScreenExpensesAndCache: Could not fetch expense $expenseId / $wipExpenseId .. exiting');
      return;
    }
    //expense updates
    switch (type) {
      case 'expense_created':
        if (!allExpensesMap.containsKey(expenseId)) {
          // Add new expense
          allExpensesMap[baseExpenseId] = updatedExpense;
          allExpenses.insert(0, updatedExpense);
          print('updateHomeScreenExpensesAndCache: Added new expense $expenseId');
        } else {
          allExpensesMap[baseExpenseId] = updatedExpense;
          allExpenses = allExpenses.map((e) => e.id == expenseId ? updatedExpense! : e).toList();
          print('updateHomeScreenExpensesAndCache: Got expense_created but expense already present. Updated expense $expenseId');
        }
        break;

      case 'expense_updated':
      case 'wip_status_update':
        if (allExpensesMap[baseExpenseId] == null) {
          print("updateHomeScreenExpensesAndCache: Got $type for $baseExpenseId but it isnt there in allExpensesMap");
          allExpensesMap[baseExpenseId] = updatedExpense;
          allExpenses.insert(0, updatedExpense);
        } else {
          allExpensesMap[baseExpenseId] = updatedExpense;
          allExpenses = allExpenses.map((e) => e.id == baseExpenseId ? updatedExpense! : e).toList();
          print('updateHomeScreenExpensesAndCache: Updated expense/wipExpense - $baseExpenseId');
        }
        break;

      case 'expense_deleted':
        final expense = allExpensesMap[expenseId];
        if (expense != null) {
          // Check if expense has other tags
          if (expense is Expense && expense.tags.isNotEmpty) {
            // Only remove from this tag, keep in cache
            expense.tags.removeWhere((t) => t.id == tagId);
            print('updateHomeScreenExpensesAndCache: Removed tag $tagId from expense $expenseId');
            if (expense.tags.isEmpty) {
              // No more tags, remove completely
              allExpensesMap.remove(expenseId);
              allExpenses.removeWhere((e) => e.id == expenseId);
              print('updateHomeScreenExpensesAndCache: Deleted expense $expenseId as tags have become empty');
            }
          } else {
            // Remove completely
            allExpensesMap.remove(expenseId);
            allExpenses.removeWhere((e) => e.id == expenseId);
            print('updateHomeScreenExpensesAndCache: Deleted expense $expenseId');
          }
        }
        break;
    }

    // Re-sort by createdAt descending - not required .. maybe we create allExpenses fomr allExpensesMap
    // allExpenses.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    // Save back to SharedPreferences
    await asyncPrefs.setString('_allExpensesMap', jsonEncode(_serializeMap(allExpensesMap)));
    await asyncPrefs.setString('_allExpenses', jsonEncode(_serializeList(allExpenses)));
    await asyncPrefs.setString('_tags', Tag.jsonEncodeTagsList(tags));

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
    String userId = (await getUserIdFromClaim())!;
    return Expense.fromJson(map, (await getUserKilvishId(map['ownerId'] ?? userId))!);
  }
}

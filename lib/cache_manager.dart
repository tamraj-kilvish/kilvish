import 'dart:convert';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense.dart';
import 'package:shared_preferences/shared_preferences.dart';

final asyncPrefs = SharedPreferencesAsync();

/// Rebuilds entire cache from scratch - only untagged expenses + WIPExpenses
Future<Map<String, dynamic>> loadFromScratch(KilvishUser user) async {
  print('loadFromScratch: Building cache from Firestore');

  List<BaseExpense> allExpenses = [];
  Set<Tag> tags = {};

  // Get WIPExpenses
  List<WIPExpense> wipExpenses = await getAllWIPExpenses();
  print('loadFromScratch: Got ${wipExpenses.length} WIPExpenses');
  allExpenses.addAll(wipExpenses);

  // Get user's own expenses (only untagged ones)
  final userExpenseDocs = await getUntaggedExpenseDocsOfUser(user.id);
  print('loadFromScratch: Got ${userExpenseDocs.length} untagged user expenses');

  for (var doc in userExpenseDocs) {
    final expense = await Expense.getExpenseFromFirestoreObject(doc.id, doc.data() as Map<String, dynamic>);
    expense.setUnseenStatus(user.unseenExpenseIds);
    allExpenses.add(expense);
  }

  // Get tags with unseen counts
  for (String tagId in user.accessibleTagIds) {
    try {
      final tag = await getTagData(tagId);
      tag.mostRecentExpense = await getMostRecentExpenseFromTag(tagId);
      tag.unseenExpenseCount = await getUnseenExpenseCountForTag(tagId, user.unseenExpenseIds);
      tags.add(tag);
    } catch (e, stackTrace) {
      print('loadFromScratch: Error processing tag $tagId: $e $stackTrace');
    }
  }

  // Sort by createdAt descending
  allExpenses.sort((a, b) => b.createdAt.compareTo(a.createdAt));

  return {'allExpenses': allExpenses, 'tags': tags.toList()};
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
    List<BaseExpense> allExpenses = [];
    List<Tag> tags = [];

    final listJson = await asyncPrefs.getString('_allExpenses');
    final tagsJson = await asyncPrefs.getString('_tags');

    if (listJson != null) {
      allExpenses = await BaseExpense.jsonDecodeExpenseList(listJson);
      tags = Tag.jsonDecodeTagsList(tagsJson!);
    } else {
      // No cache exists - build from scratch
      print('updateHomeScreenExpensesAndCache: No cache found, building from scratch');
      final user = await getLoggedInUserData();
      if (user == null) return;

      final freshData = await loadFromScratch(user);
      allExpenses = freshData['allExpenses'];
      tags = freshData['tags'];
    }

    Tag? updatedTag;
    if (tagId != null) {
      updatedTag = await getTagData(tagId, includeMostRecentExpense: true);
      final user = await getLoggedInUserData();
      if (user != null) {
        updatedTag.unseenExpenseCount = await getUnseenExpenseCountForTag(tagId, user.unseenExpenseIds);
      }
    }

    // Tag updates
    switch (type) {
      case "expense_created":
      case "expense_updated":
      case "expense_deleted":
        if (updatedTag == null) {
          print('updateHomeScreenExpensesAndCache: Got type $type but updatedTag is null for $tagId !!!');
        } else {
          tags = tags.map((tag) => tag.id == tagId ? updatedTag! : tag).toList();
          print('updateHomeScreenExpensesAndCache: Tag ${updatedTag.name} stats updated');
        }
        break;

      case "tag_shared":
        if (updatedTag == null) {
          print('updateHomeScreenExpensesAndCache: Got type $type but updatedTag is null for $tagId !!!');
        } else {
          tags.insert(0, updatedTag);
          print('updateHomeScreenExpensesAndCache: tag ${updatedTag.name} added to top');
        }
        break;

      case "tag_removed":
        tags.removeWhere((t) => t.id == tagId);
        print('updateHomeScreenExpensesAndCache: tag $tagId removed from list');
        break;
    }

    await asyncPrefs.setString('_tags', Tag.jsonEncodeTagsList(tags));
    print('Tag Cache updated successfully');

    // Now applying Expense updates
    String? baseExpenseId = wipExpenseId ?? expenseId;

    if (baseExpenseId == null) {
      print("Both expenseId & wipExpenseId are null. Exiting");
      return;
    }

    // Fetch updated expense
    BaseExpense? updatedExpense;

    if (expenseId != null) {
      updatedExpense = await getExpense(expenseId);
    }

    if (wipExpenseId != null) {
      updatedExpense = await getWIPExpense(wipExpenseId);
    }

    if (updatedExpense == null && type != "expense_deleted") {
      print('updateHomeScreenExpensesAndCache: Could not fetch expense $expenseId / $wipExpenseId for $type .. exiting');
      return;
    }

    // Expense updates
    switch (type) {
      case 'expense_created':
        updatedExpense = updatedExpense!;

        // Only add to cache if it's untagged (or WIPExpense)
        if (updatedExpense is WIPExpense ||
            (updatedExpense is Expense && updatedExpense.tagIds != null && updatedExpense.tagIds!.isEmpty)) {
          bool existsInCache = allExpenses.any((e) => e.id == baseExpenseId);

          if (!existsInCache) {
            allExpenses.insert(0, updatedExpense);
            print('updateHomeScreenExpensesAndCache: Added new expense $expenseId to cache');
          } else {
            allExpenses = allExpenses.map((e) => e.id == baseExpenseId ? updatedExpense! : e).toList();
            print('updateHomeScreenExpensesAndCache: Updated existing expense $expenseId');
          }
        } else {
          // Tagged expense - remove from cache if exists
          allExpenses.removeWhere((e) => e.id == baseExpenseId);
          print('updateHomeScreenExpensesAndCache: Removed tagged expense $expenseId from cache');
        }
        break;

      case 'expense_updated':
      case 'wip_status_update':
        updatedExpense = updatedExpense!;

        // Only keep in cache if untagged
        if (updatedExpense is WIPExpense ||
            (updatedExpense is Expense && updatedExpense.tagIds != null && updatedExpense.tagIds!.isEmpty)) {
          bool existsInCache = allExpenses.any((e) => e.id == baseExpenseId);

          if (!existsInCache) {
            allExpenses.insert(0, updatedExpense);
            print('updateHomeScreenExpensesAndCache: Inserted $baseExpenseId (was missing)');
          } else {
            allExpenses = allExpenses.map((e) => e.id == baseExpenseId ? updatedExpense! : e).toList();
            print('updateHomeScreenExpensesAndCache: Updated expense/wipExpense - $baseExpenseId');
          }
        } else {
          // Now tagged - remove from cache
          allExpenses.removeWhere((e) => e.id == baseExpenseId);
          print('updateHomeScreenExpensesAndCache: Removed now-tagged expense $baseExpenseId from cache');
        }
        break;

      case 'expense_deleted':
        allExpenses.removeWhere((e) => e.id == expenseId);
        print('updateHomeScreenExpensesAndCache: Removed deleted expense $expenseId');
        break;
    }

    // Save back to SharedPreferences
    await asyncPrefs.setString('_allExpenses', BaseExpense.jsonEncodeExpensesList(allExpenses));

    print('Expense Cache updated successfully');
  } catch (e, stackTrace) {
    print('updateHomeScreenExpensesAndCache: Error $e $stackTrace');
  }
}

/// Loads from SharedPreferences
Future<Map<String, dynamic>?> loadHomeScreenStateFromSharedPref() async {
  print('loadHomeScreenStateFromSharedPref: Loading cache');

  try {
    final listJson = await asyncPrefs.getString('_allExpenses');
    final tagsJson = await asyncPrefs.getString('_tags');

    if (listJson == null) {
      print('loadHomeScreenStateFromSharedPref: No cache found');
      return null;
    }

    List<BaseExpense> allExpenses = await BaseExpense.jsonDecodeExpenseList(listJson);

    List<Tag> tags = [];
    if (tagsJson != null) {
      tags = Tag.jsonDecodeTagsList(tagsJson);
    }

    print('loadHomeScreenStateFromSharedPref: Loaded ${allExpenses.length} expenses, ${tags.length} tags');

    return {'allExpenses': allExpenses, 'tags': tags};
  } catch (e, stackTrace) {
    print('loadHomeScreenStateFromSharedPref: Error $e $stackTrace');
    return null;
  }
}

Future<List<Tag>?> getTagsFromCache() async {
  final tagsJson = await asyncPrefs.getString('_tags');
  if (tagsJson != null) {
    return Tag.jsonDecodeTagsList(tagsJson);
  }
  return null;
}

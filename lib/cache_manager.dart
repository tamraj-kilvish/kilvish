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

  // Sort by createdAt descending
  allExpenses.sort((a, b) => b.createdAt.compareTo(a.createdAt));

  // Get tags with unseen counts
  for (String tagId in user.accessibleTagIds) {
    try {
      final tag = await getTagData(tagId, includeMostRecentExpense: true);
      tag.unseenExpenseCount = await getUnseenExpenseCountForTag(tagId, user.unseenExpenseIds);
      tags.add(tag);
    } catch (e, stackTrace) {
      print('loadFromScratch: Error processing tag $tagId: $e $stackTrace');
    }
  }

  return {'allExpenses': allExpenses, 'tags': tags.toList()};
}

Future<Map<String, dynamic>> _loadDataFromSharedPref() async {
  final listJson = await asyncPrefs.getString('_allExpenses');
  final tagsJson = await asyncPrefs.getString('_tags');

  if (listJson != null) {
    List<BaseExpense> allExpenses = await BaseExpense.jsonDecodeExpenseList(listJson);
    List<Tag> tags = Tag.jsonDecodeTagsList(tagsJson!);
    return {"allExpenses": allExpenses, "tags": tags};
  } else {
    // No cache exists - build from scratch
    print('updateHomeScreenExpensesAndCache: No cache found, building from scratch');
    final user = await getLoggedInUserData();
    if (user == null) throw Error();

    final freshData = await loadFromScratch(user);
    return {"allExpenses": freshData['allExpenses'], "tags": freshData['tags']};
  }
}

/// Incrementally updates SharedPreferences cache
Future<Map<String, dynamic>?> updateHomeScreenExpensesAndCache({
  required String type,
  String? expenseId,
  String? wipExpenseId,
  String? tagId,
  List<BaseExpense>? allExpensesParam,
  List<Tag>? tagsParam,
}) async {
  print('updateHomeScreenExpensesAndCache: type=$type, expenseId=$expenseId, wipExpenseId=$wipExpenseId tagId=$tagId');

  if (expenseId == null && wipExpenseId == null && tagId == null) {
    print('updateHomeScreenExpensesAndCache: all parameters null .. exiting');
    return null;
  }
  List<BaseExpense> allExpenses = allExpensesParam ?? [];
  List<Tag> tags = tagsParam ?? [];

  try {
    if (allExpensesParam == null || tagsParam == null) {
      final cachedData = await _loadDataFromSharedPref();
      allExpenses = cachedData['allExpenses'];
      tags = cachedData['tags'];
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
      case "settlement_created":
      case "settlement_updated":
      case "settlement_deleted":
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
      return null;
    }

    // Fetch updated expense
    BaseExpense? updatedExpenseWipExpenseOrSettlement;

    if (expenseId != null && tagId != null) {
      updatedExpenseWipExpenseOrSettlement = await getTagExpense(
        tagId,
        expenseId,
        isSettlement: type.contains("settlement") ? true : false,
      );
    }

    if (wipExpenseId != null) {
      updatedExpenseWipExpenseOrSettlement = await getWIPExpense(wipExpenseId);
    }

    if (updatedExpenseWipExpenseOrSettlement == null && !type.contains("deleted")) {
      print('updateHomeScreenExpensesAndCache: Could not fetch expense $expenseId / $wipExpenseId for $type .. exiting');
      return null;
    }

    // Expense updates
    switch (type) {
      case 'expense_created':
      case 'expense_updated':
      case 'expense_deleted':
      case "settlement_created":
      case "settlement_updated":
      case "settlement_deleted":
        //if the expense still showing on home screen, remove it
        bool existsInCache = allExpenses.any((e) => e.id == baseExpenseId);
        if (existsInCache) {
          allExpenses.removeWhere((expense) => expense.id == baseExpenseId);
        }

        if (tagId != null) {
          await updateTagExpensesCache(tagId, type, baseExpenseId, updatedExpenseWipExpenseOrSettlement);
        }
        break;

      case 'wip_status_update':
        updatedExpenseWipExpenseOrSettlement = updatedExpenseWipExpenseOrSettlement!;

        if (updatedExpenseWipExpenseOrSettlement is WIPExpense) {
          bool existsInCache = allExpenses.any((e) => e.id == baseExpenseId);

          if (!existsInCache) {
            allExpenses.insert(0, updatedExpenseWipExpenseOrSettlement);
            print('updateHomeScreenExpensesAndCache: Inserted WIPExpense $baseExpenseId (was missing)');
          } else {
            allExpenses = allExpenses.map((e) => e.id == baseExpenseId ? updatedExpenseWipExpenseOrSettlement! : e).toList();
            print('updateHomeScreenExpensesAndCache: Updated WipExpense - $baseExpenseId');
          }
        }
        break;
    }

    // Save back to SharedPreferences
    await asyncPrefs.setString('_allExpenses', BaseExpense.jsonEncodeExpensesList(allExpenses));
    print('Expense Cache updated successfully');

    return {"allExpenses": allExpenses, "tags": tags};
  } catch (e, stackTrace) {
    print('updateHomeScreenExpensesAndCache: Error $e $stackTrace');
    return null;
  }
}

Future<void> updateTagExpensesCache(String tagId, String eventType, String baseExpenseId, BaseExpense? updatedExpense) async {
  String? tagExpensesJson = await asyncPrefs.getString('tag_${tagId}_expenses');

  if (tagExpensesJson == null) {
    print("No tagExpenses cache found for $tagId .. returning");
    return;
  }

  List<Expense> tagExpenses = await Expense.jsonDecodeExpenseList(tagExpensesJson);

  if (eventType.contains("deleted")) {
    tagExpenses.removeWhere((expense) => expense.id == baseExpenseId);
    await asyncPrefs.setString('tag_${tagId}_expenses', Expense.jsonEncodeExpensesList(tagExpenses));

    print('updateHomeScreenExpensesAndCache: Deleted Expense $baseExpenseId in tag $tagId cache');
    return;
  }

  bool existsInCache = tagExpenses.any((e) => e.id == baseExpenseId);
  if (!existsInCache) {
    tagExpenses.insert(0, updatedExpense as Expense);
    print('updateHomeScreenExpensesAndCache: Inserted Expense $baseExpenseId in tag $tagId cache');
  } else {
    tagExpenses = tagExpenses.map((e) => e.id == baseExpenseId ? updatedExpense! as Expense : e).toList();
    print('updateHomeScreenExpensesAndCache: Updated Expense $baseExpenseId in tag $tagId cache');
  }

  await asyncPrefs.setString('tag_${tagId}_expenses', Expense.jsonEncodeExpensesList(tagExpenses));
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

Future<List<Tag>> getUserTags() async {
  final tagsJson = await asyncPrefs.getString('_tags');
  if (tagsJson != null) {
    return Tag.jsonDecodeTagsList(tagsJson);
  }

  KilvishUser? user = await getLoggedInUserData();
  if (user == null) throw Error();

  List<Tag> allTags = [];
  for (String tagId in user.accessibleTagIds) {
    final tag = await getTagData(tagId);
    allTags.add(tag);
  }

  await asyncPrefs.setString('_tags', Tag.jsonEncodeTagsList(allTags));
  return allTags;
}

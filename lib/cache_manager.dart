import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:kilvish/background_worker.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/models_pending_import.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _asyncPrefs = SharedPreferencesAsync();

const _keyMyExpenses = '_myExpenses';
const _keyWIPExpenses = '_wipExpenses';
const _keyTags = '_tags';
const _keyKnownTagIds = '_knownTagIds';
const _keyProcessedReceipts = '_processedReceipts';
const _keyWebLastCacheWrite = '_webLastCacheWrite';
const _webCacheTTLHours = 1;
Set<String> _processedReceiptFilenames = {};

// ─── Per-cache streams ───

final _myExpensesStreamController = StreamController<void>.broadcast();
final _wipExpensesStreamController = StreamController<void>.broadcast();
final _tagListStreamController = StreamController<void>.broadcast();
final _tagExpensesStreamController = StreamController<String>.broadcast();

Stream<void> get myExpensesStream => _myExpensesStreamController.stream;
Stream<void> get wipExpensesStream => _wipExpensesStreamController.stream;
Stream<void> get tagListStream => _tagListStreamController.stream;
Stream<String> get tagExpensesStream => _tagExpensesStreamController.stream;

// ─── My Expenses ───

Future<List<Expense>> loadMyExpenses({bool forceReload = false}) async {
  if (!forceReload) {
    final json = await _asyncPrefs.getString(_keyMyExpenses);
    if (json != null) {
      try {
        final list = jsonDecode(json) as List<dynamic>;
        final userId = await getUserIdFromClaim();
        final ownerKilvishId = await getUserKilvishId(userId!);
        return Future.wait(list.map((m) => Expense.fromJson(m as Map<String, dynamic>, ownerKilvishId!)).toList());
      } catch (e, stackTrace) {
        print('loadMyExpenses cache decode error: $e');
        print('stackTrace: \n $stackTrace');
      }
    }
  }
  try {
    final user = await getLoggedInUserData();
    if (user == null) return [];
    final docs = await getExpenseDocsOfUser(user.id);
    final expenses = await Future.wait(
      docs.map((doc) async {
        return Expense.getExpenseFromFirestoreObject(doc.id, doc.data() as Map<String, dynamic>);
      }),
    );
    await saveMyExpenses(expenses);
    return expenses;
  } catch (e, stackTrace) {
    print('loadMyExpenses fetch error: $e');
    print('stackTrace: \n $stackTrace');
    return [];
  }
}

Future<void> saveMyExpenses(List<Expense> expenses) async {
  await _asyncPrefs.setString(_keyMyExpenses, jsonEncode(expenses.map((e) => e.toJson()).toList()));
  _myExpensesStreamController.add(null);
  _touchWebCacheTimestamp();
  print('[CacheManager] saveMyExpenses() - sending event for MyExpense update');
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

Future<List<WIPExpense>?> loadWIPExpenses({bool forceReload = false}) async {
  if (!forceReload) {
    final json = await _asyncPrefs.getString(_keyWIPExpenses);
    if (json != null) {
      final list = jsonDecode(json) as List<dynamic>;
      return Future.wait(list.map((m) => WIPExpense.fromJson(m as Map<String, dynamic>)).toList());
    }
  }

  final fresh = await getAllWIPExpenses();
  await saveWIPExpenses(fresh);
  return fresh;
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

Future<void> saveWIPExpenses(List<WIPExpense> wipExpenses) async {
  await _asyncPrefs.setString(_keyWIPExpenses, jsonEncode(wipExpenses.map((e) => e.toJson()).toList()));
  _wipExpensesStreamController.add(null);
  _touchWebCacheTimestamp();
  print('[CacheManager] saveWIPExpenses() - sending event for WIPExpense refresh, dear bulkimport do catch it & do needfull');
}

// ─── Tags ───

List<Tag> _sortedByUpdatedAt(List<Tag> tags) {
  tags.sort((a, b) {
    final aTime = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bTime = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return bTime.compareTo(aTime);
  });
  return tags;
}

Map<String, Tag> _tagCache = {};

Future<List<Tag>> loadTags() async {
  final json = await _asyncPrefs.getString(_keyTags);
  if (json != null) {
    try {
      List<Tag> tags = await Tag.jsonDecodeTagsList(json);
      _tagCache = Map.fromEntries(tags.map((tag) => MapEntry(tag.id, tag)));

      return _sortedByUpdatedAt(tags);
    } catch (e, stackTrace) {
      print('loadTags cache decode error: $e');
      print('stackTrace: \n $stackTrace');
    }
  }
  try {
    final user = await getLoggedInUserData();
    if (user == null) return [];
    final tags = <Tag>[];
    for (final tagId in user.accessibleTagIds) {
      try {
        Tag tag = await getTagData(tagId);
        tags.add(tag);
        _tagCache[tagId] = tag;

        //remove tagExpenseCache if present
        await removeTagExpenses(tagId);
      } catch (e, stackTrace) {
        print('loadTags: error fetching $tagId: $e');
        print('stackTrace: \n $stackTrace');
      }
    }
    await saveTags(tags);
    return _sortedByUpdatedAt(tags);
  } catch (e, stackTrace) {
    print('loadTags fetch error: $e');
    print('stackTrace: \n $stackTrace');
    return [];
  }
}

Future<void> saveTags(List<Tag> tags) async {
  print("saveTags: saving ${tags.length} tags");
  await _asyncPrefs.setString(_keyTags, Tag.jsonEncodeTagsList(tags));
  _tagListStreamController.add(null);
  _touchWebCacheTimestamp();
  print('[CacheManager] saveTags() - sending event for TagList update');
}

Future<void> addOrUpdateTag(Tag tag) async {
  final tags = await loadTags();
  final existingIdx = tags.indexWhere((t) => t.id == tag.id);
  if (existingIdx >= 0) tag.unseenCount = tags[existingIdx].unseenCount;
  tags.removeWhere((t) => t.id == tag.id);
  tags.insert(0, tag);
  await saveTags(tags);
}

Future<void> removeTag(String tagId) async {
  final tags = await loadTags();
  tags.removeWhere((t) => t.id == tagId);
  await saveTags(tags);
  // no need to refresh MyExpenses as this event is for someone else's tag
}

Tag? getTagFromCache(String tagId) {
  return _tagCache[tagId];
}

// ─── Tag Expenses ───

String _keyTagExpenses(String tagId) => 'tag_${tagId}_expenses';

Future<List<Expense>> loadTagExpenses(String tagId, {bool forceReload = false}) async {
  if (!forceReload) {
    final json = await _asyncPrefs.getString(_keyTagExpenses(tagId));
    if (json != null) {
      try {
        return await Expense.jsonDecodeExpenseListCacheForTagExpenses(json);
      } catch (e, stackTrace) {
        print('loadTagExpenses $tagId cache decode error: $e');
        print('stackTrace: \n $stackTrace');
      }
    }
  }
  try {
    final expenses = await getExpensesOfTag(tagId);
    await saveTagExpenses(tagId, expenses);
    return expenses;
  } catch (e, stackTrace) {
    print('loadTagExpenses $tagId fetch error: $e');
    print('stackTrace: \n $stackTrace');
    return [];
  }
}

Future<void> saveTagExpenses(String tagId, List<Expense> expenses) async {
  await _asyncPrefs.setString(_keyTagExpenses(tagId), Expense.jsonEncodeExpensesList(expenses));
  await _registerKnownTagId(tagId);
  _tagExpensesStreamController.add(tagId);
  _touchWebCacheTimestamp();
  print('[CacheManager] saveTagExpenses() - sending event for TagExpenses update for tagId $tagId');
}

Future<void> removeTagExpenses(String tagId) async {
  await _asyncPrefs.remove(_keyTagExpenses(tagId));
}

Future<void> updateTagExpensesIfCached(List<String> tagIds, String expenseId) async {
  for (final tagId in tagIds) {
    final json = await _asyncPrefs.getString(_keyTagExpenses(tagId));
    if (json == null) continue;

    Expense? expense = await getTagExpense(tagId, expenseId);
    await addOrUpdateTagExpense(tagId, expense!);
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
  expenses.sort((a, b) => b.timeOfTransaction.compareTo(a.timeOfTransaction));
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

// ─── Local Receipt File ───

Future<void> deleteLocalReceipt(String? localReceiptPath, {bool removeFilenameFromSet = false}) async {
  if (localReceiptPath == null) return;
  try {
    final file = File(localReceiptPath);
    if (file.existsSync()) {
      file.deleteSync();
      print('[Cache] Deleted local receipt: $localReceiptPath');
    }
  } catch (e) {
    print('[Cache] Error deleting local receipt $localReceiptPath: $e');
  }
  if (removeFilenameFromSet) {
    await _ensureProcessedReceiptsLoaded();
    _processedReceiptFilenames.remove(localReceiptPath.split('/').last);
    await _asyncPrefs.setString(_keyProcessedReceipts, jsonEncode(_processedReceiptFilenames.toList()));
  }
}

// ─── Processed Receipts ───

Future<void> _ensureProcessedReceiptsLoaded() async {
  if (_processedReceiptFilenames.isNotEmpty) return;
  final json = await _asyncPrefs.getString(_keyProcessedReceipts);
  if (json != null) {
    _processedReceiptFilenames = Set<String>.from(jsonDecode(json) as List);
  }
}

Future<bool> isProcessedReceipt(String filename) async {
  await _ensureProcessedReceiptsLoaded();
  return _processedReceiptFilenames.contains(filename);
}

Future<void> addProcessedReceiptFilename(String filename) async {
  await _ensureProcessedReceiptsLoaded();
  _processedReceiptFilenames.add(filename);
  await _asyncPrefs.setString(_keyProcessedReceipts, jsonEncode(_processedReceiptFilenames.toList()));
}

// ─── Clear All ───

Future<void> clearAllCache() async {
  _tagCache = {};
  await _asyncPrefs.remove(_keyMyExpenses);
  await _asyncPrefs.remove(_keyWIPExpenses);
  await _asyncPrefs.remove(_keyTags);
  final tagIds = await _getKnownTagIds();
  for (final tagId in tagIds) {
    await _asyncPrefs.remove(_keyTagExpenses(tagId));
  }
  await _asyncPrefs.remove(_keyKnownTagIds);
  _processedReceiptFilenames = {};
  await _asyncPrefs.remove(_keyProcessedReceipts);
  await _asyncPrefs.remove(_keyWebLastCacheWrite);
  if (!kIsWeb) await PendingImport.clearCache();
}

// ─── Web cache staleness ───

Future<void> _touchWebCacheTimestamp() async {
  if (!kIsWeb) return;
  await _asyncPrefs.setString(_keyWebLastCacheWrite, DateTime.now().toIso8601String());
}

/// On web: clears the local cache if it was last written more than [_webCacheTTLHours] ago.
/// Call at app startup before any cache reads so stale data is never served.
Future<void> clearStaleWebCacheIfNeeded() async {
  if (!kIsWeb) return;
  final raw = await _asyncPrefs.getString(_keyWebLastCacheWrite);
  if (raw == null) return;
  final lastWrite = DateTime.tryParse(raw);
  if (lastWrite == null) return;
  if (DateTime.now().difference(lastWrite).inHours >= _webCacheTTLHours) {
    await clearAllCache();
    print('[CacheManager] Web cache cleared — was ${DateTime.now().difference(lastWrite).inHours}h old');
  }
}

// ─── FCM lag detection ───

Future<bool> shouldClearCacheForFCMLag() async {
  try {
    final user = await getLoggedInUserData();
    if (user == null) return false;

    if (user.lastFCMSentAt == null) return false;
    if (user.lastFCMProcessedAt == null) return true;
    return user.lastFCMProcessedAt!.compareTo(user.lastFCMSentAt!) < 0;
  } catch (e, stackTrace) {
    print('shouldClearCacheForFCMLag error: $e');
    print('stackTrace:\n$stackTrace');
    return false;
  }
}

// ─── FCM-driven cache update ───

Future<void> updateHomeScreenExpensesAndCache({
  required String type,
  String? wipExpenseId,
  String? expenseId,
  String? tagId,
  String? actorId,
  void Function(int count)? onWIPNeedsAttention,
}) async {
  print(
    'updateHomeScreenExpensesAndCache: type=$type, wipExpenseId=$wipExpenseId, expenseId=$expenseId, tagId=$tagId, actorId=$actorId',
  );

  try {
    final currentUserId = await getUserIdFromClaim();
    switch (type) {
      case 'wip_status_update':
        if (wipExpenseId == null) {
          print('wip_status_update: wipExpenseId missing');
          break;
        }

        final updated = await getWIPExpense(wipExpenseId);

        if (updated == null) {
          await removeWIPExpense(wipExpenseId);
          print('updateHomeScreenExpensesAndCache: Removed $wipExpenseId from Home Screen cache');
          break;
        }

        if (updated.canAutoConvert()) {
          //convert to Expense if all conditions satisfy
          Expense? expense = await updated.convertToExpense();
          if (expense != null) {
            await removeWIPExpense(wipExpenseId);
            await deleteLocalReceipt(updated.localReceiptPath);

            await addOrUpdateMyExpense(expense);
            await updateTagExpensesIfCached(updated.tagIds, expense.id);

            print(
              'updateHomeScreenExpensesAndCache: converted $wipExpenseId to Expense & attached to ${updated.tagIds.length} tags',
            );
          } else {
            print('updateHomeScreenExpensesAndCache: could not convert WIPExpense $wipExpenseId to Expense');
          }
        } else {
          // just update the cache
          await addOrUpdateWIPExpense(updated);
          print('updateHomeScreenExpensesAndCache: Updated $wipExpenseId in Home Screen cache');
        }

        if (updated.status == ExpenseStatus.readyForReview) {
          // show notification for WIPExpense in ready for review.
          final allWips = await loadWIPExpenses() ?? [];
          final count = allWips.where((w) => w.status == ExpenseStatus.readyForReview).length;
          if (count > 0) onWIPNeedsAttention?.call(count);

          await processNextPendingImport();
          print('updateHomeScreenExpensesAndCache: Firing next pending import as WIPExpense with readyForReview status received');
        }

        break;

      case 'expense_created':
      case 'expense_updated':
      case 'expense_deleted':
        if (tagId == null) {
          print('$type: tagId missing');
          break;
        }

        if (expenseId != null) {
          if (type == 'expense_deleted') {
            await removeTagExpense(tagId, expenseId);
            print('updateHomeScreenExpensesAndCache: Removed $expenseId from tag');
          } else {
            // Update tag expense cache for all members
            final tagExpense = await getTagExpense(tagId, expenseId);
            if (tagExpense is Expense) {
              if (actorId != null && actorId != currentUserId) {
                final wasAlreadyUnseen = await _isExpenseAlreadyUnseenInTagCache(tagId, expenseId);
                tagExpense.isUnseen = true;
                if (!wasAlreadyUnseen) await _incrementTagUnseenCount(tagId);
              }
              await addOrUpdateTagExpense(tagId, tagExpense);
              print('updateHomeScreenExpensesAndCache: Updated $expenseId in tag $tagId expense cache');
            }
          }

          if (actorId == currentUserId) {
            final updatedMyExpense = await getExpense(expenseId);
            if (updatedMyExpense != null) {
              await addOrUpdateMyExpense(updatedMyExpense);
            } else {
              await removeMyExpense(expenseId);
            }
          }
        }
        break;

      case 'tag_shared':
      case 'tag_updated':
        if (tagId == null) {
          print('tag_shared: tagId missing');
          break;
        }
        final tag = await getTagData(tagId);
        await addOrUpdateTag(tag);
        print('updateHomeScreenExpensesAndCache: Tag ${tag.name} added to cache for event $type');
        break;

      case 'tag_removed':
        if (tagId == null) {
          print('tag_removed: tagId missing');
          break;
        }
        await removeTag(tagId);
        await removeTagExpenses(tagId);
        print('updateHomeScreenExpensesAndCache: Tag $tagId removed from cache');
        break;

      default:
        print('updateHomeScreenExpensesAndCache: Unhandled type $type');
    }

    await updateLastFCMProcessedAt();
  } catch (e, stackTrace) {
    print('updateHomeScreenExpensesAndCache: Error $e');
    print('stackTrace: \n $stackTrace');
  }
}

// ─── Unseen Expense Helpers ───

Future<bool> _isExpenseAlreadyUnseenInTagCache(String tagId, String expenseId) async {
  final json = await _asyncPrefs.getString(_keyTagExpenses(tagId));
  if (json == null) return false;
  try {
    final list = jsonDecode(json) as List;
    for (final item in list) {
      final map = item as Map<String, dynamic>;
      if (map['id'] == expenseId) return map['isUnseen'] as bool? ?? false;
    }
  } catch (_) {}
  return false;
}

Future<void> _incrementTagUnseenCount(String tagId) async {
  final tags = await loadTags();
  final idx = tags.indexWhere((t) => t.id == tagId);
  if (idx >= 0) {
    tags[idx].unseenCount++;
    await saveTags(tags);
  }
}

Future<void> _decrementTagUnseenCount(String tagId) async {
  final tags = await loadTags();
  final idx = tags.indexWhere((t) => t.id == tagId);
  if (idx >= 0 && tags[idx].unseenCount > 0) {
    tags[idx].unseenCount--;
    await saveTags(tags);
  }
}

/// Marks an expense as seen in all local caches and decrements unseenCount on its tags.
/// Call this when the user opens the expense detail screen.
Future<void> markExpenseSeen(Expense expense) async {
  if (!expense.isUnseen) return;

  for (final tagId in expense.tagLinks.map((t) => t.tagId)) {
    final json = await _asyncPrefs.getString(_keyTagExpenses(tagId));
    if (json == null) continue;
    final tagExpenses = await loadTagExpenses(tagId);
    final idx = tagExpenses.indexWhere((e) => e.id == expense.id);
    if (idx >= 0 && tagExpenses[idx].isUnseen) {
      tagExpenses[idx].isUnseen = false;
      await saveTagExpenses(tagId, tagExpenses);
      await _decrementTagUnseenCount(tagId);
    }
  }

  // Defensively clear from myExpenses too (owner's expenses are never unseen in practice)
  final myExpenses = await loadMyExpenses();
  final myIdx = myExpenses.indexWhere((e) => e.id == expense.id);
  if (myIdx >= 0 && myExpenses[myIdx].isUnseen) {
    myExpenses[myIdx].isUnseen = false;
    await saveMyExpenses(myExpenses);
  }
}

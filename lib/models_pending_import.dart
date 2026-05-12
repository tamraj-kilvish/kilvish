import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PendingImport {
  final String id;
  final String stagedPath; // appDir/pending/<id>.jpg — safe from UPI app temp cleanup
  final String? tagId;
  final String? tagName;
  final bool isLoanPayback;

  const PendingImport({required this.id, required this.stagedPath, this.tagId, this.tagName, this.isLoanPayback = false});

  Map<String, dynamic> toJson() => {
    'id': id,
    'stagedPath': stagedPath,
    if (tagId != null) 'tagId': tagId,
    if (tagName != null) 'tagName': tagName,
    'isLoanPayback': isLoanPayback,
  };

  factory PendingImport.fromJson(Map<String, dynamic> json) => PendingImport(
    id: json['id'] as String,
    stagedPath: json['stagedPath'] as String,
    tagId: json['tagId'] as String?,
    tagName: json['tagName'] as String?,
    isLoanPayback: json['isLoanPayback'] as bool? ?? false,
  );

  // ── In-memory cache ───────────────────────────────────────────────────────

  static List<PendingImport> _cache = [];
  static const _key = '_pendingImports';
  static final _prefs = SharedPreferencesAsync();

  static Future<List<PendingImport>> loadFromCache() async {
    if (_cache.isNotEmpty) {
      print('[PendingImport] loadFromCache: cache hit — ${_cache.length} items');
      return List.from(_cache);
    }
    final json = await _prefs.getString(_key);
    if (json == null) {
      print('[PendingImport] loadFromCache: no persisted data, returning []');
      return [];
    }
    _cache = (jsonDecode(json) as List).map((e) => PendingImport.fromJson(e as Map<String, dynamic>)).toList();
    print('[PendingImport] loadFromCache: loaded ${_cache.length} items from SharedPrefs');
    return List.from(_cache);
  }

  static Future<void> _persist() async {
    print('[PendingImport] _persist: writing ${_cache.length} items to SharedPrefs');
    await _prefs.setString(_key, jsonEncode(_cache.map((e) => e.toJson()).toList()));
  }

  static Future<void> addToCache(PendingImport pending) async {
    // Pre-load from SharedPrefs if cache is empty (e.g. fresh app start after kill)
    if (_cache.isEmpty) await loadFromCache();
    _cache.add(pending); // FIFO: first added = index 0 = processed first
    print('[PendingImport] addToCache: added id=${pending.id} tagId=${pending.tagId} — cache now has ${_cache.length} items');
    await _persist();
  }

  static Future<void> removeFromCache(String id) async {
    _cache.removeWhere((item) => item.id == id);
    print('[PendingImport] removeFromCache: removed id=$id — cache now has ${_cache.length} items');
    await _persist();
  }

  static Future<void> clearCache() async {
    print('[PendingImport] clearCache: clearing all ${_cache.length} items');
    _cache = [];
    await _prefs.remove(_key);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Returns true if this receipt has already been fully processed (final file exists).
  static Future<bool> isDuplicate(File receiptFile) async {
    final appDir = await getApplicationDocumentsDirectory();
    final finalPath = p.join(appDir.path, p.basename(receiptFile.path));
    return File(finalPath).existsSync();
  }

  /// Copies [receiptFile] to appDir/pending/<id>.jpg and returns the PendingImport.
  static Future<PendingImport> stageReceipt({
    required File receiptFile,
    String? tagId,
    String? tagName,
    bool isLoanPayback = false,
  }) async {
    final appDir = await getApplicationDocumentsDirectory();
    final stagingDir = Directory(p.join(appDir.path, 'pending'))..createSync(recursive: true);
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final stagedPath = p.join(stagingDir.path, '$id.jpg');
    print('[PendingImport] stageReceipt: copying ${receiptFile.path} → $stagedPath');
    await receiptFile.copy(stagedPath);
    final pendingImport = PendingImport(
      id: id,
      stagedPath: stagedPath,
      tagId: tagId,
      tagName: tagName,
      isLoanPayback: isLoanPayback,
    );

    await PendingImport.addToCache(pendingImport);
    return pendingImport;
  }
}

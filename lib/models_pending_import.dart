import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PendingImportStatus { pending, uploading, error }

class PendingImport {
  final String id;
  final String stagedPath; // appDir/pending/<id>.jpg — safe from UPI app temp cleanup
  final String? tagId;
  final String? tagName;
  final bool isLoanPayback;
  final DateTime createdAt;
  final PendingImportStatus status;

  const PendingImport({
    required this.id,
    required this.stagedPath,
    required this.createdAt,
    this.tagId,
    this.tagName,
    this.isLoanPayback = false,
    this.status = PendingImportStatus.pending,
  });

  PendingImport copyWith({
    String? id,
    String? stagedPath,
    String? tagId,
    String? tagName,
    bool? isLoanPayback,
    DateTime? createdAt,
    PendingImportStatus? status,
  }) => PendingImport(
    id: id ?? this.id,
    stagedPath: stagedPath ?? this.stagedPath,
    tagId: tagId ?? this.tagId,
    tagName: tagName ?? this.tagName,
    isLoanPayback: isLoanPayback ?? this.isLoanPayback,
    createdAt: createdAt ?? this.createdAt,
    status: status ?? this.status,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'stagedPath': stagedPath,
    if (tagId != null) 'tagId': tagId,
    if (tagName != null) 'tagName': tagName,
    'isLoanPayback': isLoanPayback,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'status': status.name,
  };

  factory PendingImport.fromJson(Map<String, dynamic> json) => PendingImport(
    id: json['id'] as String,
    stagedPath: json['stagedPath'] as String,
    tagId: json['tagId'] as String?,
    tagName: json['tagName'] as String?,
    isLoanPayback: json['isLoanPayback'] as bool? ?? false,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      json['createdAt'] as int? ?? int.parse(json['id'] as String),
    ),
    status: PendingImportStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => PendingImportStatus.pending,
    ),
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
    if (_cache.isEmpty) await loadFromCache();
    _cache.add(pending);
    print('[PendingImport] addToCache: added id=${pending.id} tagId=${pending.tagId} — cache now has ${_cache.length} items');
    await _persist();
  }

  static Future<void> removeFromCache(String id) async {
    _cache.removeWhere((item) => item.id == id);
    print('[PendingImport] removeFromCache: removed id=$id — cache now has ${_cache.length} items');
    await _persist();
  }

  static Future<void> markUploading(String id) async {
    _cache = _cache.map((p) => p.id == id ? p.copyWith(status: PendingImportStatus.uploading) : p).toList();
    print('[PendingImport] markUploading: id=$id');
    await _persist();
  }

  static Future<void> markError(String id) async {
    _cache = _cache.map((p) => p.id == id ? p.copyWith(status: PendingImportStatus.error) : p).toList();
    print('[PendingImport] markError: id=$id');
    await _persist();
  }

  static Future<void> resetToPending(String id) async {
    _cache = _cache.map((p) => p.id == id ? p.copyWith(status: PendingImportStatus.pending) : p).toList();
    print('[PendingImport] resetToPending: id=$id');
    await _persist();
  }

  static Future<void> clearCache() async {
    print('[PendingImport] clearCache: clearing all ${_cache.length} items');
    _cache = [];
    await _prefs.remove(_key);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static Future<Directory> get _stagingDir async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory(p.join(appDir.path, 'pending'))..createSync(recursive: true);
  }

  /// Returns true if this receipt filename has already been staged (persistent across restarts).
  static Future<bool> isDuplicate(File receiptFile) async {
    return await CacheManager.isProcessedReceipt(p.basename(receiptFile.path));
  }

  /// Copies [receiptFile] to appDir/pending/<original-filename> and returns the PendingImport.
  static Future<PendingImport> stageReceipt({
    required File receiptFile,
    String? tagId,
    String? tagName,
    bool isLoanPayback = false,
  }) async {
    final stagingDir = await _stagingDir;
    final now = DateTime.now();
    // Use Firestore's ID generator for uniqueness — this becomes the WIPExpense and Expense id
    final id = FirebaseFirestore.instance.collection('WIPExpenses').doc().id;
    final stagedPath = p.join(stagingDir.path, p.basename(receiptFile.path));
    print('[PendingImport] stageReceipt: copying ${receiptFile.path} → $stagedPath (id=$id)');
    await receiptFile.copy(stagedPath);
    await CacheManager.addProcessedReceiptFilename(p.basename(receiptFile.path));
    final pendingImport = PendingImport(
      id: id,
      stagedPath: stagedPath,
      createdAt: now,
      tagId: tagId,
      tagName: tagName,
      isLoanPayback: isLoanPayback,
    );

    return pendingImport;
  }
}

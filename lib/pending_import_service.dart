import 'package:flutter/foundation.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/models_pending_import.dart';

class PendingImportService extends ChangeNotifier {
  static final PendingImportService _instance = PendingImportService._internal();
  factory PendingImportService() => _instance;
  PendingImportService._internal();

  bool _hasPendingItems = false;
  bool get hasPendingItems => _hasPendingItems;

  Future<void> init() => refresh();

  Future<void> refresh() async {
    final pending = await PendingImport.loadFromCache();
    final wips = await CacheManager.loadWIPExpenses() ?? [];
    final has = pending.isNotEmpty || wips.isNotEmpty;
    if (has != _hasPendingItems) {
      _hasPendingItems = has;
      notifyListeners();
    }
  }
}

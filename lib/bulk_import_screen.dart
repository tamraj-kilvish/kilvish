import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kilvish/background_worker.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/expense_add_edit_screen.dart';
import 'package:kilvish/fcm_handler.dart';
import 'package:kilvish/home_screen.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/models_pending_import.dart';
import 'package:kilvish/pending_import_detail_screen.dart';
import 'package:kilvish/style.dart';

// ── Sealed union for the unified import list ────────────────────────────────

sealed class ImportItem {
  DateTime get createdAt;
}

class PendingItem extends ImportItem {
  final PendingImport data;
  PendingItem(this.data);
  @override
  DateTime get createdAt => data.createdAt;
}

class ProcessingItem extends ImportItem {
  final WIPExpense data;
  ProcessingItem(this.data);
  @override
  DateTime get createdAt => data.createdAt;
}

// ── Screen ──────────────────────────────────────────────────────────────────

class BulkImportScreen extends StatefulWidget {
  final PendingImport? newImport;

  const BulkImportScreen({super.key, this.newImport});

  @override
  State<BulkImportScreen> createState() => _BulkImportScreenState();
}

class _BulkImportScreenState extends State<BulkImportScreen> with WidgetsBindingObserver {
  List<ImportItem> _items = [];
  bool _showEnqueuedBanner = false;
  StreamSubscription<String>? _fcmSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAndStartProcessing();

    if (!kIsWeb) {
      if (!HomeScreen.isFcmServiceInitialized) {
        HomeScreen.isFcmServiceInitialized = true;
        FCMService.instance.initialize();
      }
      _fcmSub = FCMService.instance.refreshStream.listen((_) => _onFCMRefresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadData().then((_) => _startProcessing());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fcmSub?.cancel();
    _wipRefreshTimer?.cancel();
    super.dispose();
  }

  // ── Data loading ──────────────────────────────────────────────────────────

  Future<void> _initAndStartProcessing() async {
    if (widget.newImport != null) {
      await PendingImport.addToCache(widget.newImport!);
      if (mounted) setState(() => _showEnqueuedBanner = true);
    }
    await _loadData();
    await _startProcessing();
  }

  Future<void> _loadData() async {
    final pending = await PendingImport.loadFromCache();
    final wips = await CacheManager.loadWIPExpenses() ?? [];
    print('[BulkImport] _loadData: pending=${pending.length} wips=${wips.length}');
    final items = [...pending.map(PendingItem.new), ...wips.map(ProcessingItem.new)]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (!mounted) return;
    setState(() => _items = items);
  }

  // ── Processing ────────────────────────────────────────────────────────────

  Future<void> _startProcessing() => processNextPendingImport(
    onConverted: (pendingId, wip) {
      if (!mounted) return;
      setState(() {
        final idx = _items.indexWhere((i) => i is PendingItem && i.data.id == pendingId);
        if (idx >= 0) {
          _items[idx] = ProcessingItem(wip);
        }
      });
    },
    onUploading: (wip) {
      if (!mounted) return;
      setState(() {
        final idx = _items.indexWhere((i) => i is ProcessingItem && i.data.id == wip.id);
        if (idx >= 0) _items[idx] = ProcessingItem(wip);
      });
    },
    onDuplicate: (pendingId) {
      if (!mounted) return;
      setState(() => _items.removeWhere((i) => i is PendingItem && i.data.id == pendingId));
    },
  );

  Future<void> _onFCMRefresh() async {
    await _loadData();
    await _startProcessing();
    if (_items.isEmpty && mounted && ModalRoute.of(context)?.isCurrent == true) _goHome();
    FCMService.instance.markDataRefreshed();
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void _goHome() {
    if (_items.isNotEmpty) {
      showError(context, 'There are pending imports. Finish/discard them first');
      return;
    }
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const HomeScreen()), (route) => false);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kWhitecolor,
      appBar: AppBar(
        backgroundColor: primaryColor,
        automaticallyImplyLeading: false,
        title: Text(
          'Pending Imports',
          style: TextStyle(color: kWhitecolor, fontWeight: FontWeight.bold),
        ),
        actions: [
          TextButton(
            onPressed: _goHome,
            child: Text('Home', style: TextStyle(color: kWhitecolor)),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_showEnqueuedBanner)
            Container(
              width: double.infinity,
              color: Colors.green.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check_circle_outline, color: Colors.green.shade700, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      !kIsWeb && Platform.isIOS
                          ? 'Receipt is enqueued for processing. To add more receipts, tap the UPI app name with the back arrow at the top left of your screen.'
                          : 'Receipt is enqueued for processing, you can navigate back to UPI app to add more receipts.',
                      style: TextStyle(color: Colors.green.shade800, fontSize: smallFontSize),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_items.isNotEmpty)
                  ..._items.map(
                    (item) => switch (item) {
                      PendingItem(:final data) => _buildPendingTile(data),
                      ProcessingItem(:final data) => _buildWIPTile(data),
                    },
                  ),
                if (_items.isEmpty)
                  const Center(
                    child: Padding(padding: EdgeInsets.only(top: 48), child: Text('All done!')),
                  ),
              ],
            ),
          ),
          if (!kIsWeb && !Platform.isIOS && widget.newImport != null) _buildBottomBar(),
        ],
      ),
    );
  }

  // ── Tiles ─────────────────────────────────────────────────────────────────

  Widget _buildPendingTile(PendingImport p) {
    final label = p.tagName ?? (p.isLoanPayback ? 'Loan Payback' : 'Expense');
    return Column(
      children: [
        const Divider(height: 1),
        ListTile(
          tileColor: primaryColor.withOpacity(0.05),
          leading: CircleAvatar(
            backgroundColor: inactiveColor,
            child: const Icon(Icons.timer_outlined, color: kWhitecolor, size: 20),
          ),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PendingImportDetailScreen(pendingImport: p))),
          title: Text(
            label,
            style: TextStyle(fontSize: defaultFontSize, color: kTextColor, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            'Queued for processing',
            style: TextStyle(fontSize: smallFontSize, color: inactiveColor, fontWeight: FontWeight.w600),
          ),
          trailing: Text(
            '₹--',
            style: TextStyle(fontSize: largeFontSize, color: inactiveColor),
          ),
        ),
      ],
    );
  }

  Timer? _wipRefreshTimer;
  void _scheduleWIPExpensesRefresh() {
    if (_wipRefreshTimer?.isActive == true) _wipRefreshTimer?.cancel();
    _wipRefreshTimer = Timer(Duration(seconds: 30), () async {
      await _onFCMRefresh();
    });
  }

  void _openWIPExpenseDetail(WIPExpense wipExpense) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ExpenseAddEditScreen(baseExpense: wipExpense)),
    );

    if (result == null) return;

    if (result is Map && result["expense"] is Expense) {
      if (mounted) {
        setState(() => _items.removeWhere((i) => i is ProcessingItem && i.data.id == wipExpense.id));
      }
    }
    if (result is Map && result["expense"] is WIPExpense) {
      final updatedWipExpense = result["expense"] as WIPExpense;
      if (mounted) {
        setState(() {
          final idx = _items.indexWhere((i) => i is ProcessingItem && i.data.id == updatedWipExpense.id);
          if (idx >= 0) _items[idx] = ProcessingItem(updatedWipExpense);
        });
      }
    }
    if (result is Map && result["operation"] == "delete") {
      if (mounted) {
        setState(() => _items.removeWhere((i) => i is ProcessingItem && i.data.id == wipExpense.id));
      }
    }
  }

  Widget _buildWIPTile(WIPExpense wipExpense) {
    if (wipExpense.status != ExpenseStatus.readyForReview) _scheduleWIPExpensesRefresh();

    return Column(
      children: [
        const Divider(height: 1),
        ListTile(
          tileColor: primaryColor.withOpacity(0.1),
          leading: CircleAvatar(
            backgroundColor: wipExpense.getStatusColor(),
            child: wipExpense.errorMessage != null && wipExpense.errorMessage!.isNotEmpty
                ? const Icon(Icons.error, color: kWhitecolor, size: 20)
                : wipExpense.status == ExpenseStatus.waitingToStartProcessing ||
                      wipExpense.status == ExpenseStatus.uploadingReceipt ||
                      wipExpense.status == ExpenseStatus.extractingData
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kWhitecolor))
                : const Icon(Icons.receipt_long, color: kWhitecolor, size: 20),
          ),
          onTap: () => _openWIPExpenseDetail(wipExpense),
          title: Text(
            wipExpense.to != null ? 'To: ${truncateText(wipExpense.to!)}' : 'To: -',
            style: TextStyle(fontSize: defaultFontSize, color: kTextColor, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            wipExpense.errorMessage?.isNotEmpty == true ? wipExpense.errorMessage! : wipExpense.getStatusDisplayText(),
            style: TextStyle(fontSize: smallFontSize, color: wipExpense.getStatusColor(), fontWeight: FontWeight.w600),
          ),
          trailing: wipExpense.amount != null
              ? Text(
                  '₹${wipExpense.amount!.round()}',
                  style: TextStyle(fontSize: largeFontSize, color: kTextColor, fontWeight: FontWeight.bold),
                )
              : Text(
                  '₹--',
                  style: TextStyle(fontSize: largeFontSize, color: inactiveColor),
                ),
        ),
      ],
    );
  }

  Widget _buildBottomBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: TextButton(
          onPressed: SystemNavigator.pop,
          style: TextButton.styleFrom(backgroundColor: primaryColor, minimumSize: const Size.fromHeight(50)),
          child: const Text(
            'Import More',
            style: TextStyle(color: Colors.white, fontSize: defaultFontSize),
          ),
        ),
      ),
    );
  }
}

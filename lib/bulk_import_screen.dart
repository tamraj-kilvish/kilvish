import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kilvish/background_worker.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/common_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:kilvish/fcm_handler.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/models_pending_import.dart';
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
  StreamSubscription<void>? _wipSub;
  Timer? _wipRefreshTimer;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (widget.newImport != null) {
      if (mounted) setState(() => _showEnqueuedBanner = true);
    }

    if (!kIsWeb) {
      FCMService.instance.cancelNotification(200);
    }

    _wipSub = CacheManager.wipExpensesStream.listen((_) => _loadDataAndStartProcessing());

    _loadDataAndStartProcessing(
      forceReload: true,
    ); //not calling _reloadUIAndStartProcessing() here as forceWipReload will create wipWrite which wil call the stream below
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      if (!kIsWeb) {
        FCMService.instance.cancelNotification(200);
      }
      _loadDataAndStartProcessing(forceReload: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _wipSub?.cancel();
    _wipRefreshTimer?.cancel();
    super.dispose();
  }

  // ── Data loading ──────────────────────────────────────────────────────────

  Future<void> _loadDataAndStartProcessing({bool forceReload = false}) async {
    if (forceReload) {
      setState(() => _isLoading = true);
      await CacheManager.loadWIPExpenses(forceReload: true);
      //no need to set any items in UI, loadWIPExpenses will trigger cache save, which will trigger _wipSub which will call _loadData() again without forceReload
      return;
    }

    // Fast path: render immediately from cache
    final pending = await PendingImport.loadFromCache();
    final wips = (await CacheManager.loadWIPExpenses()) ?? [];
    print('[BulkImport] _loadData: pending=${pending.length} wips=${wips.length}');
    final items = [...pending.map(PendingItem.new), ...wips.map(ProcessingItem.new)]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    if (!mounted) return;
    setState(() {
      _items = items;
      _isLoading = false;
    });

    if (items.isEmpty && mounted && ModalRoute.of(context)?.isCurrent == true) {
      _goHome();
      return;
    }

    await _startProcessing();
  }

  // ── Processing ────────────────────────────────────────────────────────────

  Future<void> _startProcessing() => processNextPendingImport(
    onUploading: () {
      if (!mounted) return;
      _loadDataAndStartProcessing();
    },
    onError: (pendingId) {
      // PendingImport was marked error in background_worker; reload to reflect new status
      if (!mounted) return;
      _loadDataAndStartProcessing();
    },
  );

  // ── Navigation ────────────────────────────────────────────────────────────

  void _goHome() {
    if (_items.isNotEmpty) {
      showError(
        context,
        'There are pending expenses. If they are still processing, let them process. If they are Ready for Review, review them by tapping & filling missing fields or delete them',
      );
      return;
    }
    context.go('/');
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
          'Pending Expenses',
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
            child: _isLoading
                ? Center(child: CircularProgressIndicator(color: primaryColor))
                : ListView(
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
    final isError = p.status == PendingImportStatus.error;
    final isUploading = p.status == PendingImportStatus.uploading;
    final avatarColor = isError ? Colors.red.shade400 : inactiveColor;
    final subtitleText = isError
        ? 'Upload failed — tap to retry'
        : isUploading
        ? 'Uploading receipt...'
        : 'Queued for processing';
    final subtitleColor = isError ? Colors.red.shade600 : inactiveColor;

    return Column(
      children: [
        const Divider(height: 1),
        ListTile(
          tileColor: primaryColor.withOpacity(0.05),
          leading: CircleAvatar(
            backgroundColor: avatarColor,
            child: isUploading
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kWhitecolor))
                : Icon(isError ? Icons.error_outline : Icons.timer_outlined, color: kWhitecolor, size: 20),
          ),
          onTap: () => context.push('/pending-import', extra: p),
          title: Text(
            label,
            style: TextStyle(fontSize: defaultFontSize, color: kTextColor, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            subtitleText,
            style: TextStyle(fontSize: smallFontSize, color: subtitleColor, fontWeight: FontWeight.w600),
          ),
          trailing: Text(
            '₹--',
            style: TextStyle(fontSize: largeFontSize, color: inactiveColor),
          ),
        ),
      ],
    );
  }

  void _scheduleWIPExpensesRefresh() {
    if (_wipRefreshTimer?.isActive == true) _wipRefreshTimer?.cancel();
    _wipRefreshTimer = Timer(Duration(seconds: 10), () async {
      print('[BulkImportScreen] - triggering _scheduleWIPExpensesRefresh');
      await _loadDataAndStartProcessing(forceReload: true);
      // await _reloadUIAndStartProcessing(); - reloading UI will automatically happen from forceReload
    });
  }

  void _openWIPExpenseDetail(WIPExpense wipExpense) async {
    await context.push('/expenses/${wipExpense.id}/edit', extra: wipExpense);
    await _loadDataAndStartProcessing();
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

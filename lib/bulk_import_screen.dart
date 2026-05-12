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
import 'package:kilvish/firestore.dart';
import 'package:kilvish/home_screen.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/models_pending_import.dart';
import 'package:kilvish/style.dart';

class BulkImportScreen extends StatefulWidget {
  const BulkImportScreen({super.key});

  @override
  State<BulkImportScreen> createState() => _BulkImportScreenState();
}

class _BulkImportScreenState extends State<BulkImportScreen> {
  List<PendingImport> _pending = [];
  List<WIPExpense> _wipExpenses = [];
  bool _isProcessingStarted = false;
  StreamSubscription<String>? _fcmSub;
  Timer? _stuckDetectionTimer;

  @override
  void initState() {
    super.initState();
    _loadData();

    if (!kIsWeb) {
      if (!HomeScreen.isFcmServiceInitialized) {
        HomeScreen.isFcmServiceInitialized = true;
        FCMService.instance.initialize();
      }
      _fcmSub = FCMService.instance.refreshStream.listen((_) => _onFCMRefresh());
    }
  }

  @override
  void dispose() {
    _fcmSub?.cancel();
    _wipRefreshTimer?.cancel();
    _stuckDetectionTimer?.cancel();
    super.dispose();
  }

  Future<List<WIPExpense>> _loadWIPExpenses() async {
    final wips = await CacheManager.loadWIPExpenses() ?? [];
    if (mounted) {
      setState(() => _wipExpenses = wips);
    }
    return wips;
  }

  Future<void> _loadData() async {
    final pending = await PendingImport.loadFromCache();
    final wips = await CacheManager.loadWIPExpenses() ?? [];
    print('[BulkImport] _loadData: pending=${pending.length} wips=${wips.length}');
    if (!mounted) return;
    setState(() {
      _pending = pending;
      _wipExpenses = wips;
    });
  }

  Future<void> _onFCMRefresh() async {
    final wips = await _loadWIPExpenses();
    final allWIPProcessingDone =
        wips.isEmpty || wips.every((w) => w.status == ExpenseStatus.readyForReview || (w.errorMessage?.isNotEmpty == true));

    print(
      '[BulkImport] _onFCMRefresh: wips=${wips.length} pending=${_pending.length} isProcessingStarted=$_isProcessingStarted allWIPProcessingDone=$allWIPProcessingDone',
    );

    if (_isProcessingStarted && allWIPProcessingDone && _pending.isNotEmpty) await _processNext();
    if (wips.isEmpty && _pending.isEmpty) _goHome();

    FCMService.instance.markDataRefreshed();
  }

  bool _processNextInProgress = false;

  Future<void> _processNext() async {
    if (_processNextInProgress) return;
    _processNextInProgress = true;

    if (_pending.isEmpty) {
      print('[BulkImport] _processNext: _pending found empty, terminating ..');
      setState(() => _isProcessingStarted = false);
      return;
    }
    if (_wipExpenses.isNotEmpty) {
      print('[BulkImport] _processNext: WIP already in flight — skipping');
      return;
    }
    setState(() => _isProcessingStarted = true);

    final next = _pending.first;
    print('[BulkImport] _processNext: processing id=${next.id} tagId=${next.tagId} stagedPath=${next.stagedPath}');

    final wipExpense = await createWIPExpense(
      tagIds: next.tagId != null ? [next.tagId!] : null,
      loanPaybackTagName: next.isLoanPayback ? '' : null,
    );
    if (wipExpense == null) {
      print('[BulkImport] _processNext: createWIPExpense returned null — aborting');
      return;
    }

    await CacheManager.addOrUpdateWIPExpense(wipExpense);
    if (mounted) setState(() => _wipExpenses = [wipExpense, ..._wipExpenses]);

    WIPExpense? updatedWipExpense = await handleSharedReceipt(File(next.stagedPath), wipExpenseAsParam: wipExpense);
    print('[BulkImport] _processNext: handleSharedReceipt returned ${updatedWipExpense != null ? "ok" : "null (duplicate?)"}');

    if (updatedWipExpense != null && updatedWipExpense.localReceiptPath != null) {
      await CacheManager.addOrUpdateWIPExpense(updatedWipExpense);
      await PendingImport.removeFromCache(next.id);
      setState(() {
        _pending.removeWhere((p) => p.id == next.id);
        _wipExpenses = _wipExpenses.map((w) => w.id == updatedWipExpense.id ? updatedWipExpense : w).toList();
      });
      _processNextInProgress = false;
    } else {
      print(
        '[BulkImport][Error] _processNext: updatedExpense did not come proper, so did not remove pending item, triggering onFCMAgain',
      );
      _processNextInProgress = false;
      await _onFCMRefresh();
    }
  }

  void _goHome() {
    if (_pending.isNotEmpty || _wipExpenses.isNotEmpty) {
      showError(context, 'There are pending imports. Finish/discard them first');
      return;
    }
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const HomeScreen()), (route) => false);
  }

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
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_wipExpenses.isNotEmpty) ...[
                  renderPrimaryColorLabel(text: 'Processing'),
                  const SizedBox(height: 8),
                  ..._wipExpenses.map(_buildWIPTile),
                  const SizedBox(height: 16),
                ],
                if (_pending.isNotEmpty) ...[
                  renderPrimaryColorLabel(text: 'Queued'),
                  const SizedBox(height: 8),
                  ..._buildPendingSummaryTiles(),
                ],
                if (_pending.isEmpty && _wipExpenses.isEmpty)
                  const Center(
                    child: Padding(padding: EdgeInsets.only(top: 48), child: Text('All done!')),
                  ),
              ],
            ),
          ),
          if (_pending.isNotEmpty) _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: _isProcessingStarted ? null : _processNext,
                style: TextButton.styleFrom(backgroundColor: inactiveColor, minimumSize: const Size.fromHeight(50)),
                child: _isProcessingStarted
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: primaryColor))
                    : const Text(
                        'Process Imports',
                        style: TextStyle(color: primaryColor, fontSize: defaultFontSize),
                      ),
              ),
            ),
            Expanded(
              child: TextButton(
                onPressed: () {
                  setState(() => _isProcessingStarted = false);
                  SystemNavigator.pop();
                },
                style: TextButton.styleFrom(backgroundColor: primaryColor, minimumSize: const Size.fromHeight(50)),
                child: const Text(
                  'Import More',
                  style: TextStyle(color: Colors.white, fontSize: defaultFontSize),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Timer? _wipRefreshTimer;
  void _scheduleWIPExpensesRefresh() {
    //cancel timer if update happened
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
        setState(() {
          _wipExpenses.removeWhere((w) => w.id == wipExpense.id);
        });
      }
    }
    if (result is Map && result["expense"] is WIPExpense) {
      WIPExpense updatedWipExpense = result["expense"];
      if (mounted) {
        setState(() {
          _wipExpenses = _wipExpenses.map((w) => w.id == updatedWipExpense.id ? updatedWipExpense : w).toList();
        });
      }
    }

    if (result is Map && result["operation"] == "delete") {
      if (mounted) {
        setState(() {
          _wipExpenses.removeWhere((w) => w.id == wipExpense.id);
        });
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

  List<Widget> _buildPendingSummaryTiles() {
    final tagCounts = <String, int>{};
    final tagNames = <String, String>{};
    int loanCount = 0;
    int expenseCount = 0;

    for (final p in _pending) {
      if (p.tagId != null) {
        tagCounts[p.tagId!] = (tagCounts[p.tagId!] ?? 0) + 1;
        tagNames[p.tagId!] = p.tagName ?? p.tagId!;
      } else if (p.isLoanPayback) {
        loanCount++;
      } else {
        expenseCount++;
      }
    }

    return [
      ...tagCounts.entries.map((e) => _buildSummaryTile(icon: Icons.local_offer, label: tagNames[e.key]!, count: e.value)),
      if (loanCount > 0) _buildSummaryTile(icon: Icons.account_balance_wallet, label: 'Loan Payback', count: loanCount),
      if (expenseCount > 0) _buildSummaryTile(icon: Icons.receipt_long, label: 'Expense', count: expenseCount),
    ];
  }

  Widget _buildSummaryTile({required IconData icon, required String label, required int count}) {
    return Card(
      color: tileBackgroundColor,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: primaryColor),
        title: Text(
          label,
          style: TextStyle(fontSize: defaultFontSize, color: kTextColor),
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: primaryColor, borderRadius: BorderRadius.circular(12)),
          child: Text(
            '$count',
            style: const TextStyle(color: kWhitecolor, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}

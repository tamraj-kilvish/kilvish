import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/canny_app_scafold_wrapper.dart';
import 'package:kilvish/fcm_handler.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/pre_expense_add_edit_screen.dart';
import 'style.dart';
import 'common_widgets.dart';
import 'models.dart';

class TagDetailScreen extends StatefulWidget {
  final Tag? tag;
  final String? tagId;
  final String? highlightExpenseId;

  const TagDetailScreen({super.key, this.tag, this.tagId, this.highlightExpenseId})
    : assert(tag != null || tagId != null, 'Either tag or tagId must be provided');

  @override
  State<TagDetailScreen> createState() => _TagDetailScreenState();
}

class MonthwiseAggregatedExpenseView {
  num year;
  num month;
  String amount;
  MonthwiseAggregatedExpenseView({required this.year, required this.month, required this.amount});
}

class _TagDetailScreenState extends State<TagDetailScreen> with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late TabController _tabController;

  late Tag _tag;

  List<Expense> _expenses = [];
  late ValueNotifier<MonthwiseAggregatedExpenseView> _showExpenseOfMonth;
  bool _isLoading = true;
  bool _isLoadingExpenses = true;
  bool _hasError = false;
  bool _isOwner = false;
  bool _isTagUpdated = false;
  Map<String, UserMonetaryData> _userWiseTotal = {};
  String? _currentUserId;
  String? _highlightExpenseId;
  final Map<String, GlobalKey> _expenseKeys = {};

  Timer? _statsPendingTimer;
  StreamSubscription<void>? _tagListSub;
  StreamSubscription<String>? _tagExpensesSub;

  @override
  void initState() {
    super.initState();

    _highlightExpenseId = widget.highlightExpenseId;

    _tabController = TabController(length: 2, vsync: this);

    _showExpenseOfMonth = ValueNotifier(
      MonthwiseAggregatedExpenseView(year: DateTime.now().year, month: DateTime.now().month, amount: "0"),
    );

    _scrollController.addListener(() {
      const itemHeight = 100;
      final scrollOffset = _scrollController.offset;
      final topIndex = scrollOffset < itemHeight ? 0 : ((scrollOffset - itemHeight) / itemHeight).ceil();
      if (_expenses.isNotEmpty && topIndex < _expenses.length) {
        _populateShowExpenseOfMonth(topIndex);
      }
    });

    _initTag();

    if (!kIsWeb) {
      _tagListSub = CacheManager.tagListStream.listen((_) async {
        if (_isLoading) return;

        final tags = await CacheManager.loadTags();
        if (!mounted) return;

        setState(() => _tag = tags.firstWhere((t) => t.id == _tag.id, orElse: () => _tag));

        // Start a 30s fallback when stats are pending; cancel it once they resolve.
        if (_tag.statsPendingAfter != null && _statsPendingTimer == null) {
          _statsPendingTimer = Timer(const Duration(seconds: 30), () async {
            _statsPendingTimer = null;
            await CacheManager.updateHomeScreenExpensesAndCache(type: 'tag_updated', tagId: _tag.id);
          });
        } else if (_tag.statsPendingAfter == null) {
          _statsPendingTimer?.cancel();
          _statsPendingTimer = null;
        }

        _populateMonthWiseAndUserWiseTotalWithKilvishId();
      });

      _tagExpensesSub = CacheManager.tagExpensesStream.listen((tagId) async {
        if (_isLoading || tagId != _tag.id) return;

        final expenses = await CacheManager.loadTagExpenses(_tag.id);
        if (!mounted) return;

        setState(() => _expenses = expenses);
      });
    }
  }

  Future<void> _initTag() async {
    try {
      final userId = await getUserIdFromClaim();
      Tag? tag = widget.tag;

      if (widget.tag == null && widget.tagId != null && userId != null) {
        await joinTagCallable(widget.tagId!);
        tag = await getTagData(widget.tagId!, fromCache: false);
        await CacheManager.addOrUpdateTag(tag);
      }

      if (!mounted) return;

      setState(() {
        _tag = tag!;
        _isOwner = userId != null && tag.ownerId == userId;
        _currentUserId = userId;
        _isLoading = false;
      });

      _populateMonthWiseAndUserWiseTotalWithKilvishId();

      if (!kIsWeb) {
        FCMService.instance.cancelNotification(tag!.id.hashCode);
        if (widget.highlightExpenseId != null) {
          FCMService.instance.cancelNotification(widget.highlightExpenseId!.hashCode);
        }
      }

      _loadTagExpenses();
    } catch (e) {
      print('[TagDetailScreen] _initTag error: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  void _populateMonthWiseAndUserWiseTotalWithKilvishId() async {
    _userWiseTotal = {};
    for (var entry in _tag.total.userWise.entries) {
      String? kilvishId = await getUserKilvishId(entry.key);
      if (kilvishId != null && kilvishId.isNotEmpty) {
        _userWiseTotal[kilvishId] = entry.value;
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _statsPendingTimer?.cancel();
    _scrollController.dispose();
    _showExpenseOfMonth.dispose();
    _tabController.dispose();
    _tagListSub?.cancel();
    _tagExpensesSub?.cancel();
    super.dispose();
  }

  void _populateShowExpenseOfMonth(int index) {
    if (index >= _expenses.length) return;
    final date = _expenses[index].timeOfTransaction;
    final monthKey = '${date.year}-${date.month.toString().padLeft(2, '0')}';
    final expense = _tag.monthWiseTotal[monthKey]?.acrossUsers.expense ?? 0;
    _showExpenseOfMonth.value = MonthwiseAggregatedExpenseView(
      year: date.year,
      month: date.month,
      amount: expense.toStringAsFixed(0),
    );
  }

  void _navigateToMonthInExpenses(int year, int month) {
    _tabController.animateTo(1);
    final targetIndex = _expenses.indexWhere((e) {
      final date = e.timeOfTransaction;
      return date.year == year && date.month == month;
    });
    if (targetIndex == -1) return;
    Future.delayed(const Duration(milliseconds: 350), () {
      if (!mounted || !_scrollController.hasClients) return;
      final key = _expenseKeys[_expenses[targetIndex].id];
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(
          key!.currentContext!,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
          alignment: 0.0,
        );
      } else {
        _scrollController.animateTo(targetIndex * 100.0, duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
      }
    });
  }

  Widget? _buildGuidanceBanner() {
    if (_currentUserId == null) return null;
    final guidance = _tag.getActionGuidanceForViewingUser(_currentUserId!);
    if (guidance == null) return null;

    final message = guidance['message'] as String;
    final color = guidance['color'] as Color;
    final isSettlement = color == settlementCardColor;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isSettlement ? settlementCardColor : outstandingColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isSettlement ? settlementBorderColor : outstandingLightColor),
      ),
      child: Text(
        message,
        style: TextStyle(fontSize: smallFontSize, color: isSettlement ? settlementTextColor : outstandingColor),
      ),
    );
  }

  void _showFABOptions() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.receipt_long, color: primaryColor),
              title: const Text('New Expense'),
              onTap: () {
                Navigator.pop(ctx);
                _navigateToNewExpense(isSettlement: false);
              },
            ),
            ListTile(
              leading: Icon(Icons.handshake_outlined, color: settlementTextColor),
              title: const Text('Settlement'),
              onTap: () {
                Navigator.pop(ctx);
                _navigateToNewExpense(isSettlement: true);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _navigateToNewExpense({required bool isSettlement}) async {
    if (_currentUserId == null) return;

    if (isSettlement) {
      final settlementError = _tag.settlementCheck(_currentUserId!);
      if (settlementError['result'] == 'error') {
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Cannot Create Settlement'),
            content: Text(settlementError['message'] as String),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
          ),
        );
        return;
      }
      // recovery == 0: allow through — TagExpenseConfigScreen will show a warning.
    }

    final kilvishId = await getUserKilvishId(_currentUserId!);
    final wip = await WIPExpense.createWIPExpenseInMemory(
      currentUserId: _currentUserId!,
      currentUserKilvishId: kilvishId ?? '',
      tag: _tag,
      isSettlement: isSettlement,
    );
    if (!mounted) return;

    final dismissed = await hasUserChosenNotToSeePreExpenseCreateScreen();
    final route = dismissed ? '/expenses/new' : '/pre-expense-create';
    if (!mounted) return;

    final result = await context.push<Map<String, dynamic>>(route, extra: wip);
    if (result != null && result['expense'] is Expense && mounted) {
      setState(() => _expenses.insert(0, result['expense'] as Expense));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(leading: const BackButton()),
        body: Center(child: CircularProgressIndicator(color: primaryColor)),
      );
    }

    if (_hasError) {
      return Scaffold(
        appBar: AppBar(leading: const BackButton()),
        body: const Center(child: Text('Failed to load tag. Please try again.')),
      );
    }

    return AppScaffoldWrapper(
      floatingActionButton: kIsWeb
          ? FloatingActionButton(
              backgroundColor: primaryColor,
              onPressed: _showFABOptions,
              child: const Icon(Icons.add, color: kWhitecolor),
            )
          : null,
      appBar: AppBar(
        backgroundColor: primaryColor,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: kWhitecolor),
          onPressed: () {
            if (!Navigator.of(context).canPop()) {
              // Cold-loaded from a URL (no back stack) — use context.go() so
              // GoRouter's matchedLocation stays in sync (critical for logout redirect).
              context.go('/');
            } else {
              Navigator.pop(context, _isTagUpdated ? {'operation': 'update', "tag": _tag} : null);
            }
          },
        ),
        title: Row(
          children: [
            Container(margin: const EdgeInsets.only(right: 10), child: renderImageIcon(Icons.local_offer)),
            Text(
              _tag.name,
              style: TextStyle(color: kWhitecolor, fontSize: titleFontSize, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: <Widget>[
          appBarEditIcon(() async {
            final result = await context.push<Map<String, dynamic>>('/tags/${_tag.id}/edit', extra: _tag);
            if (result == null) return;

            if (result["tag"] is Tag) {
              setState(() {
                _tag = result["tag"] as Tag;
                _isTagUpdated = true;
              });
            }
          }),
          if (_isOwner) ...[
            IconButton(
              icon: Icon(Icons.delete, color: kWhitecolor),
              onPressed: () => _deleteTag(context),
            ),
          ],
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: kWhitecolor,
          labelColor: kWhitecolor,
          unselectedLabelColor: kWhitecolor.withOpacity(0.6),
          tabs: const [
            Tab(icon: Icon(Icons.bar_chart), text: 'Summary'),
            Tab(icon: Icon(Icons.receipt), text: 'Expenses'),
          ],
        ),
      ),
      body: TabBarView(controller: _tabController, children: [_buildSummaryTab(), _buildExpensesTab()]),
    );
  }

  Widget _buildExpensesTab() {
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        renderMonthAggregateHeader(),
        if (_isLoadingExpenses)
          SliverFillRemaining(
            child: Center(child: CircularProgressIndicator(color: primaryColor)),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate((BuildContext context, int index) {
              final expense = _expenses[index];
              final isHighlighted = expense.id == _highlightExpenseId;
              _expenseKeys[expense.id] ??= GlobalKey();
              return Container(
                key: _expenseKeys[expense.id],
                color: isHighlighted ? primaryColor.withOpacity(0.15) : null,
                child: renderExpenseTile(
                  expense: expense,
                  onTap: () => _openExpenseDetail(expense),
                  filterTagId: _tag.id,
                  showTags: false,
                ),
              );
            }, childCount: _expenses.length),
          ),
      ],
    );
  }

  Widget _buildSummaryTab() {
    final banner = _buildGuidanceBanner();
    final showMonthCards = _tag.monthWiseTotal.keys.length > 1;
    return CustomScrollView(
      slivers: [
        _buildSummaryHeaderSliver(),
        if (banner != null) SliverToBoxAdapter(child: banner),
        if (showMonthCards) _buildMonthlyBreakdown(),
      ],
    );
  }

  Widget _buildSummaryHeaderSliver() {
    final totalOutstanding = _tag.total.acrossUsers.outstanding;
    final hasRecovery = totalOutstanding > 0 && !_tag.dontShowOutstanding;
    final n = max(1, _userWiseTotal.length);
    //final expandedHeight = hasRecovery ? 164.0 + n * 46.0 : 112.0 + (n > 1 ? n * 22.0 : 0.0);
    final expandedHeight = 120.0 + (n > 1 ? 28 * n : 0);

    return SliverAppBar(
      automaticallyImplyLeading: false,
      pinned: true,
      floating: false,
      expandedHeight: expandedHeight,
      backgroundColor: primaryColor,
      flexibleSpace: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: _buildSummaryHeaderContent(totalOutstanding, hasRecovery),
        ),
      ),
    );
  }

  Widget _buildSummaryHeaderContent(num totalOutstanding, bool hasRecovery) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              backgroundColor: kWhitecolor.withOpacity(0.2),
              radius: 16,
              child: const Icon(Icons.bar_chart, color: kWhitecolor, size: 16),
            ),
            const SizedBox(width: 12),
            const Text(
              'Total',
              style: TextStyle(color: kWhitecolor, fontSize: defaultFontSize, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(left: (hasRecovery ? 16.0 : 0.0)), // Adjust the left margin here
                child: Column(
                  crossAxisAlignment: hasRecovery ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                  children: [
                    Text(
                      'Expense',
                      style: TextStyle(fontSize: smallFontSize, color: kWhitecolor.withOpacity(0.7)),
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.only(left: 16.0),
                      child: Text(
                        _tag.statsPendingAfter != null ? '—' : '₹${_tag.formattedExpense}',
                        style: const TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.bold, color: kWhitecolor),
                      ),
                    ),
                    if (_userWiseTotal.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ..._userWiseTotal.entries.map(
                        (e) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            _tag.statsPendingAfter == null
                                ? '@${e.key}: ₹${NumberFormat.compact().format(e.value.expense)}'
                                : '@${e.key}: -',
                            style: TextStyle(fontSize: xsmallFontSize, color: kWhitecolor.withOpacity(0.8)),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            if (hasRecovery) ...[
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Outstanding',
                      style: TextStyle(fontSize: smallFontSize, color: outstandingLightColor),
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.only(left: 16.0),
                      child: Text(
                        _tag.statsPendingAfter != null ? '—' : '₹${NumberFormat.compact().format(totalOutstanding)}',
                        style: TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.bold, color: outstandingLightColor),
                      ),
                    ),
                    if (_userWiseTotal.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ..._userWiseTotal.entries.map(
                        (e) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            _tag.statsPendingAfter == null
                                ? '@${e.key}: ₹${NumberFormat.compact().format(e.value.outstanding)}'
                                : '@${e.key}: -',
                            style: TextStyle(fontSize: xsmallFontSize, color: outstandingLightColor),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  static const List<String> _monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  SliverList _buildMonthlyBreakdown() {
    if (_tag.monthWiseTotal.isEmpty) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No expense data available', style: textStyleInactive),
          ),
          childCount: 1,
        ),
      );
    }

    final sortedKeys = _tag.monthWiseTotal.keys.toList()..sort((a, b) => b.compareTo(a));

    return SliverList(
      delegate: SliverChildBuilderDelegate((context, index) {
        final key = sortedKeys[index];
        final parts = key.split('-');
        final year = int.tryParse(parts[0]) ?? 0;
        final month = int.tryParse(parts[1]) ?? 0;
        final total = _tag.monthWiseTotal[key]!;
        final totalExpense = total.acrossUsers.expense;
        final totalOutstanding = total.acrossUsers.outstanding;

        return FutureBuilder<Map<String, Map<String, num>>>(
          future: _buildUserAmountsMap(total.userWise),
          builder: (context, snapshot) {
            final userAmounts = snapshot.data ?? {};
            return _buildMonthCard(year, month, totalExpense, totalOutstanding, userAmounts);
          },
        );
      }, childCount: sortedKeys.length),
    );
  }

  Future<Map<String, Map<String, num>>> _buildUserAmountsMap(Map<String, UserMonetaryData> userWise) async {
    final result = <String, Map<String, num>>{};
    for (var entry in userWise.entries) {
      final kilvishId = await getUserKilvishId(entry.key);
      if (kilvishId != null && kilvishId.isNotEmpty) {
        result[kilvishId] = {'expense': entry.value.expense, 'outstanding': entry.value.outstanding};
      }
    }
    return result;
  }

  Widget _buildMonthCard(int year, int month, num totalExpense, num totalOutstanding, Map<String, Map<String, num>> userAmounts) {
    final hasRecovery = totalOutstanding > 0 && !_tag.dontShowOutstanding;

    return Card(
      color: tileBackgroundColor,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _navigateToMonthInExpenses(year, month),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: primaryColor,
                    radius: 16,
                    child: Icon(Icons.calendar_month, color: kWhitecolor, size: 16),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${_monthNames[month - 1]} $year',
                    style: const TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (hasRecovery) ...[
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Expense',
                            style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '₹${NumberFormat.compact().format(totalExpense)}',
                            style: TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.bold, color: primaryColor),
                          ),
                          if (userAmounts.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            ...userAmounts.entries.map(
                              (e) => Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text(
                                  '@${e.key}: ₹${NumberFormat.compact().format(e.value['expense'] ?? 0)}',
                                  style: TextStyle(fontSize: xsmallFontSize, color: kTextMedium),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Outstanding',
                            style: TextStyle(fontSize: smallFontSize, color: outstandingColor),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '₹${NumberFormat.compact().format(totalOutstanding)}',
                            style: TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.bold, color: outstandingColor),
                          ),
                          if (userAmounts.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            ...userAmounts.entries.map(
                              (e) => Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text(
                                  '@${e.key}: ₹${NumberFormat.compact().format(e.value['outstanding'])}',
                                  style: TextStyle(fontSize: xsmallFontSize, color: outstandingColor),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ] else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (userAmounts.isNotEmpty)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: userAmounts.entries
                            .map(
                              (e) => Text(
                                '@${e.key}: ₹${NumberFormat.compact().format(e.value['expense'])}',
                                style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
                              ),
                            )
                            .toList(),
                      ),
                    Text(
                      '₹${NumberFormat.compact().format(totalExpense)}',
                      style: const TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget renderMonthAggregateHeader() {
    return ValueListenableBuilder<MonthwiseAggregatedExpenseView>(
      valueListenable: _showExpenseOfMonth,
      builder: (context, view, _) {
        return SliverPersistentHeader(
          pinned: true,
          delegate: _SliverAppBarDelegate(
            minHeight: 30.0,
            maxHeight: 30.0,
            child: Container(
              color: inactiveColor,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text('${_monthNames[view.month.toInt() - 1]} ${view.year}', style: const TextStyle(color: Colors.white)),
                  const Spacer(),
                  Text('₹${view.amount}', style: const TextStyle(color: Colors.white)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _loadTagExpenses() async {
    try {
      final expenses = await CacheManager.loadTagExpenses(_tag.id);
      if (mounted) {
        setState(() {
          _expenses = expenses;
          _isLoadingExpenses = false;
          if (_expenses.isNotEmpty) _populateShowExpenseOfMonth(0);
          _isLoading = false;
        });
        if (_highlightExpenseId != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToHighlighted());
        }
      }
    } catch (e, stackTrace) {
      print('Error loading tag expenses: $e $stackTrace');
      if (mounted)
        setState(() {
          _isLoading = false;
          _isLoadingExpenses = false;
        });
    }
  }

  void _scrollToHighlighted() {
    final key = _expenseKeys[_highlightExpenseId];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(key!.currentContext!, duration: Duration(milliseconds: 400), curve: Curves.easeInOut);
    }
    Future.delayed(Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _highlightExpenseId = null);
    });
  }

  void _openExpenseDetail(Expense expense) async {
    final result = await context.push<Map<String, dynamic>>('/tags/${_tag.id}/expenses/${expense.id}', extra: expense);
    if (result == null) return;

    if (result["expense"] is Expense && mounted) {
      final updated = result["expense"] as Expense;

      //check if expense is still eligible to be part of tag
      if (updated.tags.contains(widget.tag)) {
        setState(() => _expenses = _expenses.map((e) => e.id == updated.id ? updated : e).toList());
        print("TagDetailScreen: Back from Expense Detail, expense is updated");
      } else {
        setState(() {
          _expenses.removeWhere((e) => e.id == expense.id);
        });
        print("TagDetailScreen: Expense no more part of the tag");
      }
    }

    if (result["expense"] is WIPExpense && mounted) {
      //do nothing - send to parent
      print("TagDetailScreen - Back from Expense Detail, expense is no more Expense .. converted to WIPExpense");
      if (Navigator.of(context).canPop()) {
        Navigator.pop(context, result);
      } else {
        // Cold-loaded from a URL — use context.go() to keep GoRouter in sync.
        context.go('/');
      }
      return;
    }

    if (result["expense"] == null && mounted) {
      setState(() {
        _expenses.removeWhere((e) => e.id == expense.id);
      });
      print("TagDetailScreen: Back from Expense Detail, Expense is deleted, removed from _expenses");
    }
  }

  void _deleteTag(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Delete Tag', style: TextStyle(color: kTextColor)),
          content: Text('Are you sure you want to delete this tag?', style: TextStyle(color: kTextMedium)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: TextStyle(color: kTextMedium)),
            ),
            TextButton(
              onPressed: () async {
                final navigator = Navigator.of(context, rootNavigator: true);

                Navigator.pop(context); // Close confirmation dialog

                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (BuildContext loadingContext) {
                    return PopScope(
                      canPop: false,
                      child: AlertDialog(
                        content: Row(
                          children: [
                            CircularProgressIndicator(color: primaryColor),
                            SizedBox(width: 20),
                            Text('Deleting tag...'),
                          ],
                        ),
                      ),
                    );
                  },
                );

                try {
                  await deleteTag(_tag);
                  await CacheManager.removeTag(_tag.id);

                  if (mounted) navigator.pop(); // close the loading sign
                  if (mounted) navigator.pop({'operation': 'delete', 'tag': null}); //navigate to parent
                } catch (error, stackTrace) {
                  print("Error in delete tag $error, $stackTrace");
                  navigator.pop(context);

                  showError(context, "Error deleting tag: $error");
                }
              },
              child: Text('Delete', style: TextStyle(color: errorcolor)),
            ),
          ],
        );
      },
    );
  }
}

class _SliverAppBarDelegate extends SliverPersistentHeaderDelegate {
  _SliverAppBarDelegate({required this.minHeight, required this.maxHeight, required this.child});
  final double minHeight;
  final double maxHeight;
  final Widget child;

  @override
  double get minExtent => minHeight;

  @override
  double get maxExtent => max(maxHeight, minHeight);

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return SizedBox.expand(child: child);
  }

  @override
  bool shouldRebuild(_SliverAppBarDelegate oldDelegate) {
    return maxHeight != oldDelegate.maxHeight || minHeight != oldDelegate.minHeight || child != oldDelegate.child;
  }
}

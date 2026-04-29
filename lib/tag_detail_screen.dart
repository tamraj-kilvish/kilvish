import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:kilvish/cache_manager.dart';
import 'package:kilvish/canny_app_scafold_wrapper.dart';
import 'package:kilvish/fcm_handler.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/home_screen.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/tag_add_edit_screen.dart';
import 'style.dart';
import 'common_widgets.dart';
import 'dart:math';
import 'dart:developer';
import 'models.dart';

class TagDetailScreen extends StatefulWidget {
  final Tag tag;

  const TagDetailScreen({super.key, required this.tag});

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
  bool _isOwner = false;
  bool _isTagUpdated = false;
  Map<String, UserMonetaryData> _userWiseTotal = {};

  static StreamSubscription<String>? _refreshSubscription;

  @override
  void initState() {
    super.initState();

    _tag = widget.tag;
    _populateMonthWiseAndUserWiseTotalWithKilvishId();

    _tabController = TabController(length: 2, vsync: this);

    _showExpenseOfMonth = ValueNotifier(
      MonthwiseAggregatedExpenseView(year: DateTime.now().year, month: DateTime.now().month, amount: "0"),
    );

    _scrollController.addListener(() {
      int itemHeight = 100;
      double scrollOffset = _scrollController.offset;
      int topVisibleElementIndex = scrollOffset < itemHeight ? 0 : ((scrollOffset - itemHeight) / itemHeight).ceil();

      if (_expenses.isNotEmpty && topVisibleElementIndex < _expenses.length) {
        _populateShowExpenseOfMonth(topVisibleElementIndex);
      }
    });

    _loadTagExpenses();

    getUserIdFromClaim().then((String? userId) {
      if (userId == null) return;
      if (_tag.ownerId == userId) setState(() => _isOwner = true);
    });

    _refreshSubscription = FCMService.instance.refreshStream.listen((jsonEncodedData) async {
      Map<String, dynamic> data = jsonDecode(jsonEncodedData);
      if (data['tagId'] == null || data['tagId'] != _tag.id) return;

      print('HomeScreen: Received refresh event for tag: ${data['tagId']}');
      _tag = await getTagData(data['tagId']);
      _populateMonthWiseAndUserWiseTotalWithKilvishId();
    });
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
    _scrollController.dispose();
    _showExpenseOfMonth.dispose();
    _tabController.dispose();
    _refreshSubscription?.cancel();

    super.dispose();
  }

  void _populateShowExpenseOfMonth(int topExpenseOfMonthIndex) {
    if (topExpenseOfMonthIndex >= _expenses.length) return;

    Map<String, num>? monthYear = _getMonthYearFromTransaction(_expenses[topExpenseOfMonthIndex].timeOfTransaction);

    if (monthYear != null && monthYear['year'] != null && monthYear['month'] != null) {
      final year = monthYear['year']!.toInt();
      final month = monthYear['month']!.toInt();
      final monthKey = '$year-${month.toString().padLeft(2, '0')}';
      final expense = _tag.monthWiseTotal[monthKey]?.acrossUsers.expense ?? 0;

      _showExpenseOfMonth.value = MonthwiseAggregatedExpenseView(year: year, month: month, amount: expense.toStringAsFixed(0));
    }
  }

  Map<String, num>? _getMonthYearFromTransaction(dynamic timestamp) {
    Map<String, num> monthYear = {};

    if (timestamp == null) return null;

    DateTime date;
    if (timestamp is Timestamp) {
      date = timestamp.toDate();
    } else if (timestamp is DateTime) {
      date = timestamp;
    } else {
      return null;
    }

    monthYear['month'] = date.month;
    monthYear['year'] = date.year;

    return monthYear;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          leading: const BackButton(),
          title: Row(children: [renderImageIcon(Icons.local_offer), Text(_tag.name)]),
        ),
        body: Center(child: CircularProgressIndicator(color: primaryColor)),
      );
    }

    return AppScaffoldWrapper(
      appBar: AppBar(
        backgroundColor: primaryColor,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: kWhitecolor),
          onPressed: () {
            if (!Navigator.of(context).canPop()) {
              Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (context) => HomeScreen()));
            } else {
              Navigator.pop(context, _isTagUpdated ? _tag : null);
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
          if (_isOwner == true) ...[
            appBarEditIcon(() async {
              final Tag? updatedTag =
                  await Navigator.push(context, MaterialPageRoute(builder: (context) => TagAddEditScreen(tag: _tag))) as Tag?;

              if (updatedTag != null) {
                print("Rendering updated tag with name ${updatedTag.name}");
                setState(() {
                  _tag = updatedTag;
                  _isTagUpdated = true;
                });
              }
            }),
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
            Tab(icon: Icon(Icons.receipt), text: 'Expenses'),
            Tab(icon: Icon(Icons.account_balance), text: 'Monthwise Total'),
          ],
        ),
      ),
      body: TabBarView(controller: _tabController, children: [_buildExpensesTab(), _buildSummaryTab()]),
    );
  }

  Widget _buildSliverAppBar() {
    return SliverAppBar(
      automaticallyImplyLeading: false,
      pinned: true,
      floating: false,
      expandedHeight: 60 + _userWiseTotal.entries.length * 45,
      backgroundColor: primaryColor,
      flexibleSpace: SingleChildScrollView(child: renderTotalExpenseHeader()),
    );
  }

  Widget _buildExpensesTab() {
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        _buildSliverAppBar(),
        renderMonthAggregateHeader(),
        SliverList(
          delegate: SliverChildBuilderDelegate((BuildContext context, int index) {
            final expense = _expenses[index];

            return renderExpenseTile(
              expense: expense,
              onTap: () => _openExpenseDetail(expense),
              showTags: false,
              dateFormat: 'MMM d, h:mm a',
            );
          }, childCount: _expenses.length),
        ),
      ],
    );
  }

  Widget _buildSummaryTab() {
    return CustomScrollView(slivers: [_buildSliverAppBar(), _buildMonthlyBreakdown()]);
  }

  Widget renderTotalExpenseHeader() {
    final totalRecovery = _tag.total.acrossUsers.recovery;
    final hasRecovery = totalRecovery > 0;

    if (!hasRecovery) {
      return Container(
        margin: const EdgeInsets.only(top: 20, bottom: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              margin: const EdgeInsets.only(right: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: const Text(
                      'Total',
                      style: TextStyle(fontSize: titleFontSize, color: kWhitecolor),
                    ),
                  ),
                  if (_userWiseTotal.length > 1) ...[
                    ..._userWiseTotal.keys.map(
                      (kilvishId) => Text(
                        '@$kilvishId',
                        style: const TextStyle(color: kWhitecolor, fontSize: defaultFontSize),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    '₹${_tag.total.acrossUsers.expense.toStringAsFixed(0)}',
                    style: const TextStyle(fontSize: titleFontSize, color: kWhitecolor),
                  ),
                ),
                if (_userWiseTotal.length > 1) ...[
                  ..._userWiseTotal.entries.map(
                    (entry) => Text('₹${entry.value.expense.toStringAsFixed(0)}', style: const TextStyle(color: kWhitecolor)),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 20, bottom: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  'Expense',
                  style: TextStyle(fontSize: largeFontSize, color: kWhitecolor.withOpacity(0.8)),
                ),
                const SizedBox(height: 8),
                Text(
                  '₹${_tag.total.acrossUsers.expense.toStringAsFixed(0)}',
                  style: const TextStyle(fontSize: titleFontSize, color: kWhitecolor, fontWeight: FontWeight.bold),
                ),
                if (_userWiseTotal.length > 1) ...[
                  const SizedBox(height: 12),
                  ..._userWiseTotal.entries.map(
                    (entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '@${entry.key}: ₹${entry.value.expense.toStringAsFixed(0)}',
                        style: const TextStyle(color: kWhitecolor, fontSize: smallFontSize),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Container(
            height: 60 + (_userWiseTotal.length > 1 ? _userWiseTotal.length * 20.0 : 0),
            width: 1,
            color: kWhitecolor.withOpacity(0.3),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  'Outstanding',
                  style: TextStyle(fontSize: largeFontSize, color: Colors.orange.shade200),
                ),
                const SizedBox(height: 8),
                Text(
                  '₹${totalRecovery.toStringAsFixed(0)}',
                  style: TextStyle(fontSize: titleFontSize, color: Colors.orange.shade200, fontWeight: FontWeight.bold),
                ),
                if (_userWiseTotal.length > 1) ...[
                  const SizedBox(height: 12),
                  ..._userWiseTotal.entries.map(
                    (entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '@${entry.key}: ₹${entry.value.recovery.toStringAsFixed(0)}',
                        style: TextStyle(color: Colors.orange.shade200, fontSize: smallFontSize),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
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
        final totalExpense = total.acrossUsers.expense.toStringAsFixed(0);
        final totalRecovery = total.acrossUsers.recovery.toStringAsFixed(0);

        return FutureBuilder<Map<String, Map<String, String>>>(
          future: _buildUserAmountsMap(total.userWise),
          builder: (context, snapshot) {
            final userAmounts = snapshot.data ?? {};
            return _buildMonthCard(year, month, totalExpense, totalRecovery, userAmounts);
          },
        );
      }, childCount: sortedKeys.length),
    );
  }

  Future<Map<String, Map<String, String>>> _buildUserAmountsMap(Map<String, UserMonetaryData> userWise) async {
    final result = <String, Map<String, String>>{};
    for (var entry in userWise.entries) {
      final kilvishId = await getUserKilvishId(entry.key);
      if (kilvishId != null && kilvishId.isNotEmpty) {
        result[kilvishId] = {
          'expense': entry.value.expense.toStringAsFixed(0),
          'recovery': entry.value.recovery.toStringAsFixed(0),
        };
      }
    }
    return result;
  }

  Widget _buildMonthCard(
    int year,
    int month,
    String totalExpense,
    String totalRecovery,
    Map<String, Map<String, String>> userAmounts,
  ) {
    final hasRecovery = (double.tryParse(totalRecovery) ?? 0) > 0;

    return Card(
      color: tileBackgroundColor,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
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
                          '₹$totalExpense',
                          style: TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.bold, color: primaryColor),
                        ),
                        if (userAmounts.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          ...userAmounts.entries.map(
                            (e) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '@${e.key}: ₹${e.value['expense']}',
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
                          style: TextStyle(fontSize: smallFontSize, color: Colors.orange.shade700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '₹$totalRecovery',
                          style: TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.bold, color: Colors.orange.shade700),
                        ),
                        if (userAmounts.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          ...userAmounts.entries.map(
                            (e) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '@${e.key}: ₹${e.value['recovery']}',
                                style: TextStyle(fontSize: xsmallFontSize, color: Colors.orange.shade700),
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
                              '@${e.key}: ₹${e.value['expense']}',
                              style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
                            ),
                          )
                          .toList(),
                    ),
                  Text(
                    '₹$totalExpense',
                    style: const TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  ValueListenableBuilder<MonthwiseAggregatedExpenseView> renderMonthAggregateHeader() {
    return ValueListenableBuilder<MonthwiseAggregatedExpenseView>(
      builder: (BuildContext context, MonthwiseAggregatedExpenseView expense, Widget? child) {
        return SliverPersistentHeader(
          pinned: true,
          delegate: _SliverAppBarDelegate(
            minHeight: 30.0,
            maxHeight: 30.0,
            child: Container(
              color: inactiveColor,
              child: Container(
                margin: const EdgeInsets.only(left: 50, right: 25),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        "${_monthNames[expense.month.toInt() - 1]} ${expense.year}",
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    Text("₹${expense.amount}", style: const TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      valueListenable: _showExpenseOfMonth,
    );
  }

  Future<void> _loadTagExpenses() async {
    try {
      final cached = await loadTagExpenses(_tag.id);
      if (cached != null) {
        _expenses = cached;
        if (mounted) {
          setState(() {
            if (_expenses.isNotEmpty) _populateShowExpenseOfMonth(0);
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      print("Error in retrieving cached data - $e");
    }

    try {
      final user = await getLoggedInUserData();
      if (user == null) {
        setState(() => _isLoading = false);
        return;
      }

      List<Expense> expenses = await getExpensesOfTag(_tag.id);

      for (var expense in expenses) {
        expense.setUnseenStatus(user.unseenExpenseIds);
      }

      if (mounted) {
        setState(() {
          _expenses = expenses;
          if (_expenses.isNotEmpty) _populateShowExpenseOfMonth(0);
          if (_isLoading) _isLoading = false;
        });
      }

      await saveTagExpenses(_tag.id, _expenses);
    } catch (e, stackTrace) {
      print('Error loading tag expenses: $e $stackTrace');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _openExpenseDetail(Expense expense) async {
    final result = await openExpenseDetail(mounted, context, expense, _expenses, tag: _tag);

    if (result['expenses'] != null) {
      setState(() {
        print("TagDetailScreen - _openExpenseDetail setState");
        _expenses = (result['expenses'] as List<BaseExpense>).cast<Expense>();
      });
      await saveTagExpenses(_tag.id, _expenses);
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
                  if (mounted) navigator.pop();
                  if (mounted) navigator.pop({'deleted': true, 'tag': _tag});
                } catch (error, stackTrace) {
                  print("Error in delete tag $error, $stackTrace");
                  navigator.pop(context);

                  showError(context, "Error deleting expense: $error");
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

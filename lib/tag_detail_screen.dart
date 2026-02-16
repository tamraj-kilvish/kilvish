import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/canny_app_scafold_wrapper.dart';
import 'package:kilvish/expense_detail_screen.dart';
import 'package:kilvish/fcm_handler.dart';
import 'package:kilvish/firestore_tags.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/home_screen.dart';
import 'package:kilvish/model_expenses.dart';
import 'package:kilvish/model_tags.dart';
import 'package:kilvish/model_user.dart';
import 'package:kilvish/tag_add_edit_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'style.dart';
import 'common_widgets.dart';
import 'dart:math';
import 'dart:developer';

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
  Map<String, MonthlyMonetaryData> _monthWiseTotal = {};
  Map<String, UserMonetaryData> _userWiseTotal = {};

  final asyncPrefs = SharedPreferencesAsync();

  static StreamSubscription<String>? _refreshSubscription;

  List<BaseExpense> _updatedExpenseToRelayToHomeScreen = [];

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

      String? tagExpensesAsString = await asyncPrefs.getString('tag_${_tag.id}_expenses');
      if (tagExpensesAsString != null) {
        _expenses = await Expense.jsonDecodeExpenseList(tagExpensesAsString);
      }

      _populateMonthWiseAndUserWiseTotalWithKilvishId(); //this will refresh UI
    });
  }

  Future<void> _updateTagUnseenCount() async {
    KilvishUser? user = await getLoggedInUserData();
    if (user == null) return;

    _tag.unseenExpenseCount = await getUnseenExpenseCountForTag(_tag.id, user.unseenExpenseIds);
  }

  void _populateMonthWiseAndUserWiseTotalWithKilvishId() async {
    _monthWiseTotal = _tag.monthWiseTotal;

    // Build user-wise totals with kilvish IDs
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
      final year = monthYear['year']!;
      final month = monthYear['month']!;
      final monthKey = '$year-${month.toString().padLeft(2, '0')}';
      final amount = _tag.monthWiseTotal[monthKey]?.acrossUsers.expense.toStringAsFixed(0) ?? "0";

      _showExpenseOfMonth.value = MonthwiseAggregatedExpenseView(year: year, month: month, amount: amount);
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
              Navigator.pop(context, {"tag": _tag, "updatedExpenses": _updatedExpenseToRelayToHomeScreen});
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
      snap: true,
      floating: false,
      expandedHeight: 60 + _userWiseTotal.entries.length * 40,
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

            // Check if this is a settlement (has settlement data)
            if (expense.settlements.isNotEmpty) {
              return _renderSettlementTile(expense);
            }

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
      // Original layout - single column for expense only
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
                    child: const Text("Total", style: TextStyle(fontSize: 20.0, color: kWhitecolor)),
                  ),
                  if (_userWiseTotal.entries.length > 1) ...[
                    ..._userWiseTotal.entries.map((entry) {
                      return Text(_getUserDisplayName(entry.key), style: TextStyle(color: kWhitecolor));
                    }),
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
                    "₹${_tag.total.acrossUsers.expense.toStringAsFixed(0)}",
                    style: TextStyle(fontSize: 20.0, color: kWhitecolor),
                  ),
                ),
                if (_userWiseTotal.entries.length > 1) ...[
                  ..._userWiseTotal.entries.map((entry) {
                    return Text("₹${entry.value.expense.toStringAsFixed(0)}", style: TextStyle(color: kWhitecolor));
                  }),
                ],
              ],
            ),
          ],
        ),
      );
    }

    // NEW: Two-column layout for expense + recovery
    return Container(
      margin: const EdgeInsets.only(top: 20, bottom: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Left side - Expense
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text("Expense", style: TextStyle(fontSize: 16.0, color: kWhitecolor.withOpacity(0.8))),
                SizedBox(height: 8),
                Text(
                  "₹${_tag.total.acrossUsers.expense.toStringAsFixed(0)}",
                  style: TextStyle(fontSize: 20.0, color: kWhitecolor, fontWeight: FontWeight.bold),
                ),
                if (_userWiseTotal.entries.length > 1) ...[
                  SizedBox(height: 12),
                  ..._userWiseTotal.entries.map((entry) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        "${_getUserDisplayName(entry.key)}: ₹${entry.value.expense.toStringAsFixed(0)}",
                        style: TextStyle(color: kWhitecolor, fontSize: 14),
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),

          // Divider
          Container(
            height: 60 + (_userWiseTotal.entries.length > 1 ? _userWiseTotal.entries.length * 20 : 0),
            width: 1,
            color: kWhitecolor.withOpacity(0.3),
          ),

          // Right side - Recovery
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text("Recovery", style: TextStyle(fontSize: 16.0, color: Colors.orange.shade200)),
                SizedBox(height: 8),
                Text(
                  "₹${totalRecovery.toStringAsFixed(0)}",
                  style: TextStyle(fontSize: 20.0, color: Colors.orange.shade200, fontWeight: FontWeight.bold),
                ),
                if (_userWiseTotal.entries.length > 1) ...[
                  SizedBox(height: 12),
                  ..._userWiseTotal.entries.map((entry) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        "${_getUserDisplayName(entry.key)}: ₹${entry.value.recovery.toStringAsFixed(0)}",
                        style: TextStyle(color: Colors.orange.shade200, fontSize: 14),
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  SliverList _buildMonthlyBreakdown() {
    List<MapEntry<String, MonthlyMonetaryData>> monthlyData = [];

    if (_monthWiseTotal.isEmpty) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text("No expense data available", style: textStyleInactive),
          ),
          childCount: 1,
        ),
      );
    }

    monthlyData = _monthWiseTotal.entries.toList();
    monthlyData.sort((a, b) => b.key.compareTo(a.key)); // Sort by "YYYY-MM" descending

    return SliverList(
      delegate: SliverChildBuilderDelegate((context, index) {
        final entry = monthlyData[index];
        final monthKey = entry.key;
        final parts = monthKey.split('-');
        final year = int.tryParse(parts[0]) ?? 0;
        final month = int.tryParse(parts[1]) ?? 0;
        final monetaryData = entry.value;

        final totalExpense = monetaryData.acrossUsers.expense.toStringAsFixed(0);
        final totalRecovery = monetaryData.acrossUsers.recovery.toStringAsFixed(0);

        return FutureBuilder<Map<String, Map<String, String>>>(
          future: _buildUserAmountsMap(monetaryData.userWise),
          builder: (context, snapshot) {
            final userAmounts = snapshot.data ?? {};
            return _buildMonthCard(year, month, totalExpense, totalRecovery, userAmounts);
          },
        );
      }, childCount: monthlyData.length),
    );
  }

  Future<Map<String, Map<String, String>>> _buildUserAmountsMap(Map<String, UserMonetaryData> userWise) async {
    final userAmounts = <String, Map<String, String>>{};

    for (var entry in userWise.entries) {
      String? kilvishId = await getUserKilvishId(entry.key);
      if (kilvishId != null && kilvishId.isNotEmpty) {
        userAmounts[kilvishId] = {
          'expense': entry.value.expense.toStringAsFixed(0),
          'recovery': entry.value.recovery.toStringAsFixed(0),
        };
      }
    }

    return userAmounts;
  }

  List<String> monthNames = [
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

  Widget _buildMonthCard(
    num year,
    num month,
    String totalExpense,
    String totalRecovery,
    Map<String, Map<String, String>> userAmounts,
  ) {
    final hasRecovery = (double.tryParse(totalRecovery) ?? 0) > 0;

    return Card(
      color: tileBackgroundColor,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Month title
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: primaryColor,
                  radius: 16,
                  child: Icon(Icons.calendar_month, color: kWhitecolor, size: 16),
                ),
                SizedBox(width: 12),
                Text(
                  "${monthNames[month.toInt() - 1]} $year",
                  style: const TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.w600),
                ),
              ],
            ),

            SizedBox(height: 12),

            // Two-column layout if recovery exists
            if (hasRecovery) ...[
              Row(
                children: [
                  // Expense column
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Expense",
                          style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
                        ),
                        SizedBox(height: 4),
                        Text(
                          "₹$totalExpense",
                          style: TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.bold, color: primaryColor),
                        ),
                        if (userAmounts.isNotEmpty) ...[
                          SizedBox(height: 8),
                          ...userAmounts.entries.map((entry) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                "${_getUserDisplayName(entry.key)}: ₹${entry.value['expense']}",
                                style: TextStyle(fontSize: xsmallFontSize, color: kTextMedium),
                              ),
                            );
                          }),
                        ],
                      ],
                    ),
                  ),

                  SizedBox(width: 16),

                  // Recovery column
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Recovery",
                          style: TextStyle(fontSize: smallFontSize, color: Colors.orange.shade700),
                        ),
                        SizedBox(height: 4),
                        Text(
                          "₹$totalRecovery",
                          style: TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.bold, color: Colors.orange.shade700),
                        ),
                        if (userAmounts.isNotEmpty) ...[
                          SizedBox(height: 8),
                          ...userAmounts.entries.map((entry) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                "${_getUserDisplayName(entry.key)}: ₹${entry.value['recovery']}",
                                style: TextStyle(fontSize: xsmallFontSize, color: Colors.orange.shade700),
                              ),
                            );
                          }),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ] else ...[
              // Original single-column layout for expense only
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (userAmounts.isNotEmpty)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: userAmounts.entries.map((entry) {
                        return Text(
                          "${_getUserDisplayName(entry.key)}: ₹${entry.value['expense']}",
                          style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
                        );
                      }).toList(),
                    ),
                  Text(
                    "₹$totalExpense",
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

  String _getUserDisplayName(String kilvishId) {
    return "@$kilvishId";
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
                        "${monthNames[expense.month.toInt() - 1]} ${expense.year}",
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
      String? tagExpensesAsString = await asyncPrefs.getString('tag_${_tag.id}_expenses');
      if (tagExpensesAsString != null) {
        _expenses = await Expense.jsonDecodeExpenseList(tagExpensesAsString);
        _expenses.sort((a, b) => b.timeOfTransaction.compareTo(a.timeOfTransaction));

        if (mounted) {
          setState(() {
            if (_expenses.isNotEmpty) {
              _populateShowExpenseOfMonth(0);
            }
            _isLoading = false;
          });
          print("Init State - Loaded Tag Expenses from cache");
        }
        return; //not loading from DB to preserve the tags of the expense
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

      // Fetch both regular expenses and settlements
      List<Expense> expenses = await getExpensesOfTag(_tag.id);
      List<Expense> settlements = await getExpensesOfTag(_tag.id, isSettlement: true);

      print("TagDetailScreen - _loadTagExpenses - got ${expenses.length} expenses & ${settlements.length} settlements");

      // Combine and sort by timeOfTransaction
      List<Expense> allExpenses = [...expenses, ...settlements];
      allExpenses.sort((a, b) => b.timeOfTransaction.compareTo(a.timeOfTransaction));

      for (var expense in allExpenses) {
        expense.setUnseenStatus(user.unseenExpenseIds);
      }

      if (mounted) {
        setState(() {
          _expenses = allExpenses;
          if (_expenses.isNotEmpty) {
            _populateShowExpenseOfMonth(0);
          }
          if (_isLoading) _isLoading = false;
        });
      }

      asyncPrefs.setString('tag_${_tag.id}_expenses', BaseExpense.jsonEncodeExpensesList(allExpenses));
    } catch (e, stackTrace) {
      print('Error loading tag expenses: $e $stackTrace');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _openExpenseDetail(Expense expense) async {
    Map<String, dynamic>? result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ExpenseDetailScreen(expense: expense)),
    );
    print("Back from Expense Detail with result $result");

    if (result == null) {
      //user pressed back too quickly.
      return;
    }

    BaseExpense? returnedExpense = result['expense'];
    await _updateTagUnseenCount();

    if (returnedExpense == null) {
      //Expense deleted
      _expenses.removeWhere((e) => e.id == expense.id);

      setState(() {
        _expenses = [..._expenses];
      });

      await asyncPrefs.setString('tag_${_tag.id}_expenses', BaseExpense.jsonEncodeExpensesList(_expenses));
      print("Updated TagDetailScreen expenses cache with ${expense.id} removed");

      return;
    }

    if (returnedExpense is WIPExpense || (returnedExpense is Expense && !returnedExpense.isAssociatedWithTag(_tag))) {
      //this tag is removed .. remove from the list .. or if it WIPExpense, show it in home screen & remove here
      _expenses.removeWhere((e) => e.id == expense.id);
      _updatedExpenseToRelayToHomeScreen.add(returnedExpense);

      setState(() {
        _expenses = [..._expenses];
      });

      await asyncPrefs.setString('tag_${_tag.id}_expenses', BaseExpense.jsonEncodeExpensesList(_expenses));
      print("Updated TagDetailScreen expenses cache with ${expense.id} removed");

      return;
    }

    //expense might be updated
    if (returnedExpense is Expense) {
      List<Expense> newExpenses = _expenses.map((exp) => exp.id == returnedExpense.id ? returnedExpense : exp).toList();

      setState(() {
        _expenses = newExpenses;
      });

      await asyncPrefs.setString('tag_${_tag.id}_expenses', BaseExpense.jsonEncodeExpensesList(_expenses));
      print("Updated TagDetailScreen expenses cache with ${expense.id} updated");

      return;
    }

    setState(() {}); //for apply _tag.unSeenExpenseCount refresh
  }

  Widget _renderSettlementTile(Expense settlement) {
    final settlementEntry = settlement.settlements.first;
    final monthName = DateFormat.MMM().format(DateTime(settlementEntry.year, settlementEntry.month));

    return FutureBuilder<String?>(
      future: getUserKilvishId(settlementEntry.to),
      builder: (context, snapshot) {
        final recipientKilvishId = snapshot.data ?? 'Unknown';

        return Column(
          children: [
            const Divider(height: 1),
            ListTile(
              tileColor: settlement.isUnseen ? primaryColor.withOpacity(0.15) : tileBackgroundColor,
              leading: Stack(
                children: [
                  Image.asset('assets/icons/settlement_icon.png', width: 36, height: 36),
                  if (settlement.isUnseen)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: errorcolor, shape: BoxShape.circle),
                      ),
                    ),
                ],
              ),
              onTap: () => _openExpenseDetail(settlement),
              title: Container(
                margin: const EdgeInsets.only(bottom: 5),
                child: Text(
                  '@${settlement.ownerKilvishId} → @$recipientKilvishId',
                  style: TextStyle(
                    fontSize: defaultFontSize,
                    color: kTextColor,
                    fontWeight: settlement.isUnseen ? FontWeight.bold : FontWeight.w500,
                  ),
                ),
              ),
              subtitle: Text(
                'Settled in $monthName ${settlementEntry.year}',
                style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '₹${settlement.amount.round()}',
                    style: TextStyle(fontSize: largeFontSize, color: primaryColor, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '📅 ${formatRelativeTime(settlement.timeOfTransaction)}',
                    style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
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
                  if (mounted) navigator.pop({'tag': null, 'updatedExpenses': _updatedExpenseToRelayToHomeScreen});
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

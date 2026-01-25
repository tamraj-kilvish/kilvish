import 'dart:math' as Math;

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:kilvish/canny_app_scafold_wrapper.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/home_screen.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/tag_add_edit_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  final asyncPrefs = SharedPreferencesAsync();

  @override
  void initState() {
    super.initState();
    _tag = widget.tag;
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
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _showExpenseOfMonth.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _populateShowExpenseOfMonth(int topExpenseOfMonthIndex) {
    if (topExpenseOfMonthIndex >= _expenses.length) return;

    Map<String, num>? monthYear = _getMonthYearFromTransaction(_expenses[topExpenseOfMonthIndex].timeOfTransaction);

    if (monthYear != null && monthYear['year'] != null && monthYear['month'] != null) {
      final year = monthYear['year']!;
      final month = monthYear['month']!;
      final amount = _tag.monthWiseTotal[year]?[month]?["total"] ?? "0";

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

  // String _getMonthExpense(num year, num month) {
  //   return _tag.monthWiseTotal[year]?[month]?["total"] ?? "0";
  // }

  // String _getThisMonthExpenses() {
  //   DateTime now = DateTime.now();
  //   return _getMonthExpense(now.year, now.month);
  // }

  // String _getLastMonthExpenses() {
  //   DateTime now = DateTime.now();
  //   int lastMonth = now.month - 1;
  //   int lastYear = now.year;

  //   if (lastMonth == 0) {
  //     lastMonth = 12;
  //     lastYear = now.year - 1;
  //   }

  //   return _getMonthExpense(lastYear, lastMonth);
  // }

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

  Widget _buildExpensesTab() {
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverAppBar(
          automaticallyImplyLeading: false,
          pinned: true,
          snap: false,
          floating: false,
          expandedHeight: 120.0,
          backgroundColor: Colors.white,
          flexibleSpace: SingleChildScrollView(child: renderTotalExpenseHeader()),
        ),
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
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          automaticallyImplyLeading: false,
          pinned: true,
          snap: true,
          floating: false,
          expandedHeight: 80 + (Math.min((_tag.userWiseTotalTillDate.entries.length - 1), 0) * 40),
          backgroundColor: Colors.white,
          flexibleSpace: SingleChildScrollView(child: renderTotalExpenseHeader()),
        ),
        _buildMonthlyBreakdown(),
      ],
    );
  }

  Widget renderTotalExpenseHeader() {
    Map<String, String> userWiseTotals = _tag.userWiseTotalTillDate;

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
                  child: const Text("Total", style: TextStyle(fontSize: 20.0, color: inactiveColor)),
                ),
                if (userWiseTotals.entries.length > 1) ...[
                  ...userWiseTotals.entries.map((entry) {
                    return Text(_getUserDisplayName(entry.key), style: textStyleInactive);
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
                child: Text("₹${_tag.totalAmountTillDate}", style: const TextStyle(fontSize: 20.0)),
              ),
              if (userWiseTotals.entries.length > 1) ...[
                ...userWiseTotals.entries.map((entry) {
                  return Text("₹${entry.value}");
                }),
              ],
            ],
          ),
        ],
      ),
    );
  }

  SliverList _buildMonthlyBreakdown() {
    List<MapEntry<num, Map<num, Map<String, String>>>> monthlyData = [];

    final monthWiseTotal = _tag.monthWiseTotal;
    if (monthWiseTotal.isEmpty) {
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

    monthWiseTotal.forEach((year, monthData) {
      monthData.forEach((month, totalAmounts) {
        monthlyData.add(MapEntry(year * 100 + month, {month: totalAmounts}));
      });
    });

    monthlyData.sort((a, b) => b.key.compareTo(a.key));

    return SliverList(
      delegate: SliverChildBuilderDelegate((context, index) {
        final entry = monthlyData[index];
        final year = entry.key ~/ 100;
        final monthMap = entry.value;
        final month = monthMap.keys.first;
        final amounts = monthMap[month]!;

        final totalAmount = amounts["total"] ?? "0";
        final userAmounts = Map<String, String>.from(amounts)..remove("total");

        return _buildMonthCard(year, month, totalAmount, userAmounts);
      }, childCount: monthlyData.length),
    );
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

  Widget _buildMonthCard(num year, num month, String totalAmount, Map<String, String> userAmounts) {
    return Card(
      color: tileBackgroundColor,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: primaryColor,
          child: Icon(Icons.calendar_month, color: kWhitecolor, size: 20),
        ),
        title: Text(
          "${monthNames[month.toInt() - 1]} $year",
          style: const TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.w500),
        ),
        subtitle: userAmounts.isNotEmpty
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: userAmounts.entries.map((entry) {
                  return Text("${_getUserDisplayName(entry.key)}: ₹${entry.value}", style: textStyleInactive);
                }).toList(),
              )
            : null,
        trailing: Text(
          "₹$totalAmount",
          style: const TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  String _getUserDisplayName(String userId) {
    if (userId == _tag.ownerId) return "You";
    return userId.length > 8 ? "${userId.substring(0, 8)}..." : userId;
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
        setState(() {
          if (_expenses.isNotEmpty) {
            _populateShowExpenseOfMonth(0);
          }
          _isLoading = false;
        });
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

      setState(() {
        _expenses = expenses;
        if (_expenses.isNotEmpty) {
          _populateShowExpenseOfMonth(0);
        }
        if (_isLoading) _isLoading = false;
      });

      asyncPrefs.setString('tag_${_tag.id}_expenses', BaseExpense.jsonEncodeExpensesList(_expenses));
    } catch (e, stackTrace) {
      print('Error loading tag expenses: $e $stackTrace');
      setState(() => _isLoading = false);
    }
  }

  void _openExpenseDetail(Expense expense) async {
    final result = await openExpenseDetail(mounted, context, expense, _expenses, tag: _tag);

    if (result['expenses'] != null) {
      setState(() {
        print("TagDetailScreen - _openExpenseDetail setState");
        _expenses = (result['expenses'] as List<BaseExpense>).cast<Expense>();
      });
      asyncPrefs.setString('tag_${_tag.id}_expenses', BaseExpense.jsonEncodeExpensesList(_expenses));
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

                Navigator.pop(context);

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

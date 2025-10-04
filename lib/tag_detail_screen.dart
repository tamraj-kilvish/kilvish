import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:kilvish/firestore.dart';
import 'style.dart';
import 'common_widgets.dart';
import 'expense_detail_screen.dart';
import 'dart:math';
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
  num amount;
  MonthwiseAggregatedExpenseView({
    required this.year,
    required this.month,
    required this.amount,
  });
}

class _TagDetailScreenState extends State<TagDetailScreen> {
  final ScrollController _scrollController = ScrollController();

  List<Expense> _expenses = [];
  late ValueNotifier<MonthwiseAggregatedExpenseView> _showExpenseOfMonth;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      int itemHeight = 100;
      double scrollOffset = _scrollController.offset;
      int topVisibleElementIndex = scrollOffset < itemHeight
          ? 0
          : ((scrollOffset - itemHeight) / itemHeight).ceil();

      if (_expenses.isNotEmpty && topVisibleElementIndex <= _expenses.length) {
        _populateShowExpenseOfMonth(topVisibleElementIndex);
      }
    });
    _loadTagExpenses();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _populateShowExpenseOfMonth(int topExpenseOfMonthIndex) {
    Map<String, num>? monthYear = _getMonthYearFromTransaction(
      _expenses[topExpenseOfMonthIndex].timeOfTransaction,
    );

    if (monthYear != null &&
        monthYear['year'] != null &&
        monthYear['month'] != null) {
      _showExpenseOfMonth.value = MonthwiseAggregatedExpenseView(
        year: monthYear['year'] ?? 0,
        month: monthYear['month'] ?? 0,
        amount:
            widget.tag.monthWiseTotal[monthYear['year']]?[monthYear['month']] ??
            0,
      );
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

  num _getMonthExpense(num year, num month) {
    return widget.tag.monthWiseTotal[year]?[month] ?? 0;
  }

  num _getThisMonthExpenses() {
    DateTime now = DateTime.now();
    return _getMonthExpense(now.year, now.month);
  }

  num _getLastMonthExpenses() {
    DateTime now = DateTime.now();
    DateTime endOfLastMonth = DateTime(
      now.year,
      now.month,
      1,
    ).subtract(Duration(days: 1));
    return _getMonthExpense(endOfLastMonth.year, endOfLastMonth.month);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          leading: const BackButton(),
          title: Row(
            children: [
              renderImageIcon(Icons.local_offer),
              Text(widget.tag.name),
            ],
          ),
        ),
        body: Center(child: CircularProgressIndicator(color: primaryColor)),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Row(
          children: [renderImageIcon(Icons.local_offer), Text(widget.tag.name)],
        ),
        actions: <Widget>[
          appBarSearchIcon(null),
          appBarEditIcon(() {
            // TODO: Navigate to tag edit screen
          }),
        ],
      ),
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverAppBar(
            pinned: true,
            snap: false,
            floating: false,
            expandedHeight: 120.0,
            backgroundColor: Colors.white,
            flexibleSpace: SingleChildScrollView(
              child: renderTotalExpenseHeader(),
            ),
          ),
          renderMonthAggregateHeader(),
          SliverList(
            delegate: SliverChildBuilderDelegate((
              BuildContext context,
              int index,
            ) {
              return Column(
                children: [
                  const Divider(height: 1),
                  ListTile(
                    tileColor: tileBackgroundColor,
                    leading: const Icon(
                      Icons.currency_rupee,
                      color: Colors.black,
                    ),
                    onTap: () {
                      _openExpenseDetail(_expenses[index]);
                    },
                    title: Container(
                      margin: const EdgeInsets.only(bottom: 5),
                      child: Text('To: ${_expenses[index].to}'),
                    ),
                    subtitle: Text(
                      _formatRelativeTime(_expenses[index].timeOfTransaction),
                    ),
                    trailing: Text(
                      "₹${_expenses[index].amount ?? 0}",
                      style: const TextStyle(
                        fontSize: 14.0,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              );
            }, childCount: _expenses.length),
          ),
        ],
      ),
      bottomNavigationBar: BottomAppBar(
        child: renderMainBottomButton('Add Expense', _addNewExpenseToTag),
      ),
    );
  }

  Widget renderTotalExpenseHeader() {
    return Container(
      margin: const EdgeInsets.only(top: 20, bottom: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            margin: const EdgeInsets.only(right: 20),
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: const Text(
                    "Total Expense",
                    style: TextStyle(fontSize: 20.0),
                  ),
                ),
                const Text("This Month", style: textStyleInactive),
                const Text("Past Month", style: textStyleInactive),
              ],
            ),
          ),
          Column(
            children: [
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                child: Text(
                  "₹${widget.tag.totalAmountTillDate.toStringAsFixed(0)}",
                  style: TextStyle(fontSize: 20.0),
                ),
              ),
              Text(
                "₹${_getThisMonthExpenses().toStringAsFixed(0)}",
                style: textStyleInactive,
              ),
              Text(
                "₹${_getLastMonthExpenses().toStringAsFixed(0)}",
                style: textStyleInactive,
              ),
            ],
          ),
        ],
      ),
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

  ValueListenableBuilder<MonthwiseAggregatedExpenseView>
  renderMonthAggregateHeader() {
    return ValueListenableBuilder<MonthwiseAggregatedExpenseView>(
      builder:
          (
            BuildContext context,
            MonthwiseAggregatedExpenseView expense,
            Widget? child,
          ) {
            return SliverPersistentHeader(
              pinned: true,
              delegate: _SliverAppBarDelegate(
                minHeight: 30.0,
                maxHeight: 30.0,
                child: Container(
                  color: inactiveColor,
                  child: Container(
                    margin: const EdgeInsets.only(left: 70, right: 15),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            "${monthNames[expense.month.toInt() - 1]} ${expense.year}",
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        Text(
                          "₹${expense.amount.toStringAsFixed(0)}",
                          style: const TextStyle(color: Colors.white),
                        ),
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
      List<Expense> expenses = await getExpensesOfTag(widget.tag.id);

      setState(() {
        _expenses = expenses;
        _populateShowExpenseOfMonth(0);
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading tag expenses: $e');
      setState(() => _isLoading = false);
    }
  }

  String _formatRelativeTime(dynamic timestamp) {
    if (timestamp == null) return '';

    DateTime date;
    if (timestamp is Timestamp) {
      date = timestamp.toDate();
    } else if (timestamp is DateTime) {
      date = timestamp;
    } else {
      return '';
    }

    Duration difference = DateTime.now().difference(date);

    if (difference.inDays > 0) {
      return '${difference.inDays} days ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours} hours ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes} minutes ago';
    } else {
      return 'Just now';
    }
  }

  void _openExpenseDetail(Expense expense) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ExpenseDetailScreen(expense: expense),
      ),
    );
  }

  void _addNewExpenseToTag() {
    // TODO: Implement add expense functionality
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Add expense functionality coming soon')),
    );
  }
}

// MonthwiseAggregatedExpense class
class MonthwiseAggregatedExpense {
  final String month;
  final String year;
  final double amount;

  const MonthwiseAggregatedExpense({
    required this.month,
    required this.year,
    required this.amount,
  });
}

// SliverPersistentHeaderDelegate implementation
class _SliverAppBarDelegate extends SliverPersistentHeaderDelegate {
  _SliverAppBarDelegate({
    required this.minHeight,
    required this.maxHeight,
    required this.child,
  });
  final double minHeight;
  final double maxHeight;
  final Widget child;

  @override
  double get minExtent => minHeight;

  @override
  double get maxExtent => max(maxHeight, minHeight);

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return SizedBox.expand(child: child);
  }

  @override
  bool shouldRebuild(_SliverAppBarDelegate oldDelegate) {
    return maxHeight != oldDelegate.maxHeight ||
        minHeight != oldDelegate.minHeight ||
        child != oldDelegate.child;
  }
}

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/tag_add_edit_screen.dart';
import 'style.dart';
import 'common_widgets.dart';
import 'expense_detail_screen.dart';
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
  num amount;
  MonthwiseAggregatedExpenseView({required this.year, required this.month, required this.amount});
}

class _TagDetailScreenState extends State<TagDetailScreen> {
  final ScrollController _scrollController = ScrollController();

  late Tag _tag;
  List<Expense> _expenses = [];
  late ValueNotifier<MonthwiseAggregatedExpenseView> _showExpenseOfMonth;
  bool _isLoading = true;
  bool _isOwner = false;

  @override
  void initState() {
    super.initState();
    _tag = widget.tag;

    _showExpenseOfMonth = ValueNotifier(
      MonthwiseAggregatedExpenseView(year: DateTime.now().year, month: DateTime.now().month, amount: 0),
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
    super.dispose();
  }

  void _populateShowExpenseOfMonth(int topExpenseOfMonthIndex) {
    if (topExpenseOfMonthIndex >= _expenses.length) return;

    Map<String, num>? monthYear = _getMonthYearFromTransaction(_expenses[topExpenseOfMonthIndex].timeOfTransaction);

    if (monthYear != null && monthYear['year'] != null && monthYear['month'] != null) {
      final year = monthYear['year']!;
      final month = monthYear['month']!;
      final amount = _tag.monthWiseTotal[year]?[month] ?? 0;

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

  num _getMonthExpense(num year, num month) {
    return _tag.monthWiseTotal[year]?[month] ?? 0;
  }

  num _getThisMonthExpenses() {
    DateTime now = DateTime.now();
    return _getMonthExpense(now.year, now.month);
  }

  num _getLastMonthExpenses() {
    DateTime now = DateTime.now();
    int lastMonth = now.month - 1;
    int lastYear = now.year;

    if (lastMonth == 0) {
      lastMonth = 12;
      lastYear = now.year - 1;
    }

    return _getMonthExpense(lastYear, lastMonth);
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

    return Scaffold(
      appBar: AppBar(
        backgroundColor: primaryColor,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: kWhitecolor),
          onPressed: () => Navigator.pop(context, _tag),
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
          appBarSearchIcon(null),
          if (_isOwner == true) ...[
            appBarEditIcon(() async {
              final Tag? updatedTag =
                  await Navigator.push(context, MaterialPageRoute(builder: (context) => TagAddEditScreen(tag: _tag))) as Tag?;

              if (updatedTag != null && mounted) {
                // take user back to home screen for refreshing tag data
                print("Rendering updated tag with name ${updatedTag.name}");
                setState(() {
                  _tag = updatedTag;
                });
              }
            }),
          ],
        ],
      ),
      body: CustomScrollView(
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
      ),
      //bottomNavigationBar: BottomAppBar(child: renderMainBottomButton('Add Expense', _addNewExpenseToTag)),
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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: const Text("Total Expense", style: TextStyle(fontSize: 20.0)),
                ),
                const Text("This Month", style: textStyleInactive),
                const Text("Past Month", style: textStyleInactive),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                child: Text("₹${_tag.totalAmountTillDate.toStringAsFixed(0)}", style: const TextStyle(fontSize: 20.0)),
              ),
              Text("₹${_getThisMonthExpenses().toStringAsFixed(0)}", style: textStyleInactive),
              Text("₹${_getLastMonthExpenses().toStringAsFixed(0)}", style: textStyleInactive),
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
                    Text("₹${expense.amount.toStringAsFixed(0)}", style: const TextStyle(color: Colors.white)),
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
      // Get user data to access unseenExpenseIds
      final user = await getLoggedInUserData();
      if (user == null) {
        setState(() => _isLoading = false);
        return;
      }

      // Get expenses for this tag
      List<Expense> expenses = await getExpensesOfTag(_tag.id);

      // Set unseen status for each expense
      for (var expense in expenses) {
        expense.setUnseenStatus(user.unseenExpenseIds);
      }

      setState(() {
        _expenses = expenses;
        if (_expenses.isNotEmpty) {
          _populateShowExpenseOfMonth(0);
        }
        _isLoading = false;
      });
    } catch (e, stackTrace) {
      print('Error loading tag expenses: $e $stackTrace');
      setState(() => _isLoading = false);
    }
  }

  void _openExpenseDetail(Expense expense) async {
    // Mark this expense as seen in Firestor

    if (mounted) {
      //await Navigator.push(context, MaterialPageRoute(builder: (context) => ExpenseDetailScreen(expense: expense)));

      final result = await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => ExpenseDetailScreen(expense: expense)),
      );

      // Check if expense was deleted
      if (result != null && result is Map && result['deleted'] == true) {
        setState(() {
          _expenses.removeWhere((e) => e.id == expense.id);
        });

        if (mounted) {
          showSuccess(context, "Expense successfully deleted");
        }
      } else {
        if (expense.isUnseen) {
          try {
            await markExpenseAsSeen(expense.id);

            // Update local state
            setState(() {
              expense.markAsSeen();
            });
          } catch (error, stackTrace) {
            print("Could not mark expense seen $error, $stackTrace");
            //ignore as of now.
          }
        }
      }
    }
  }

  void _addNewExpenseToTag() {
    // TODO: Implement add expense functionality
    if (mounted) showInfo(context, 'Add expense functionality coming soon');
  }
}

// SliverPersistentHeaderDelegate implementation
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

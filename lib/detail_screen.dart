import 'package:flutter/material.dart';
import 'models.dart';
import 'style.dart';
import 'common_widgets.dart';
import 'dart:math';
import 'package:jiffy/jiffy.dart';

class TagDetailPage extends StatefulWidget {
  final String title;

  const TagDetailPage({Key? key, required this.title}) : super(key: key);

  @override
  State<TagDetailPage> createState() => _TagDetailState();
}

class _TagDetailState extends State<TagDetailPage> {
  late List<Expense> _expenses;
  late Map<String, MonthwiseAggregatedExpense> _monthwiseAggregatedExpenses;
  late ValueNotifier<MonthwiseAggregatedExpense> _showExpenseOfMonth;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      // TODO - get the height of each list view item post rendering
      int itemHeight = 100;
      double scrollOffset = _scrollController.offset;
      int topVisibleElementIndex = scrollOffset < itemHeight
          ? 0
          : ((scrollOffset - itemHeight) / itemHeight).ceil();
      print(topVisibleElementIndex);
      assignValueToShowExpenseOfMonth(topVisibleElementIndex);
    });
    // TODO - subscribe to changes/updates
    // TODO - build list of Expenses from local DB
    //pseudo code - get the tag from the id & get all expenses of the tag order by transaction date desc

    _expenses = [
      Expense(
        fromUid: 'Ashish',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(minutes: 2)),
        amount: 100,
      ),
      Expense(
        fromUid: 'Lakshmi',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(days: 35)),
        amount: 100,
      ),
      Expense(
        fromUid: 'Lakshmi',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(days: 2)),
        amount: 100,
      ),
      Expense(
        fromUid: 'Lakshmi',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(days: 2)),
        amount: 100,
      ),
      Expense(
        fromUid: 'Lakshmi',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(days: 2)),
        amount: 100,
      ),
      Expense(
        fromUid: 'Lakshmi',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(days: 2)),
        amount: 100,
      ),
      Expense(
        fromUid: 'Lakshmi',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(days: 2)),
        amount: 100,
      ),
      Expense(
        fromUid: 'Lakshmi',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(days: 38)),
        amount: 50,
      ),
      Expense(
        fromUid: 'Lakshmi',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(days: 38)),
        amount: 50,
      ),
      Expense(
        fromUid: 'Lakshmi',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(days: 38)),
        amount: 50,
      ),
    ];

    _monthwiseAggregatedExpenses = {
      "June-2022": const MonthwiseAggregatedExpense(
          month: "June", year: "2022", amount: 1000),
      "May-2022": const MonthwiseAggregatedExpense(
          month: "May", year: "2022", amount: 800)
    };

    //assignValueToShowExpenseOfMonth(0);
    // Could not call this function as it threw some error. hence had to replicate the code below
    String monthYearHash =
        Jiffy(_expenses[0].timeOfTransaction).format("MMMM-yyyy");
    _showExpenseOfMonth = ValueNotifier(
        _monthwiseAggregatedExpenses[monthYearHash] ??
            const MonthwiseAggregatedExpense(month: "-", year: "-", amount: 0));
  }

  void assignValueToShowExpenseOfMonth(int expenseIndex) {
    String monthYearHash =
        Jiffy(_expenses[expenseIndex].timeOfTransaction).format("MMMM-yyyy");
    _showExpenseOfMonth.value = _monthwiseAggregatedExpenses[monthYearHash] ??
        const MonthwiseAggregatedExpense(month: "-", year: "-", amount: 0);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Row(children: [
          renderImageIcon('assets/images/tag.png'),
          Text(widget.title)
        ]),
        actions: <Widget>[
          appBarSearchIcon(null),
          appBarEditIcon(null),
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
            delegate:
                SliverChildBuilderDelegate((BuildContext context, int index) {
              return Column(
                children: [
                  const Divider(height: 1),
                  ListTile(
                    tileColor: tileBackgroundColor,
                    leading: const Icon(Icons.face, color: Colors.black),
                    onTap: () {
                      //moveToTagDetailScreen(_homePageItems[index].title);
                    },
                    title: Container(
                      //this margin aligns the title to the expense on the left
                      margin: const EdgeInsets.only(bottom: 5),
                      child: Text('To: ${_expenses[index].toUid}'),
                    ),
                    subtitle: Text(relativeTimeFromNow(
                        _expenses[index].timeOfTransaction)),
                    trailing: Text(
                      "${_expenses[index].amount}",
                      style: const TextStyle(
                          fontSize: 14.0, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              );
            }, childCount: _expenses.length),
          ),
        ],
      ),
      bottomNavigationBar: BottomAppBar(
        child: renderMainBottomButton('Add Expense', null),
      ),
    );
  }

  Widget renderTotalExpenseHeader() {
    return Container(
      margin: const EdgeInsets.only(top: 20, bottom: 20),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          margin: const EdgeInsets.only(right: 20),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                child: const Text("Total Expense",
                    style: TextStyle(fontSize: 20.0)),
              ),
              const Text(
                "This Month",
                style: textStyleInactive,
              ),
              const Text("Past Month", style: textStyleInactive),
            ],
          ),
        ),
        Column(
          children: [
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              child: const Text("1800", style: TextStyle(fontSize: 20.0)),
            ),
            const Text("60", style: textStyleInactive),
            const Text("120", style: textStyleInactive),
          ],
        ),
      ]),
    );
  }

  ValueListenableBuilder<MonthwiseAggregatedExpense>
      renderMonthAggregateHeader() {
    return ValueListenableBuilder<MonthwiseAggregatedExpense>(
      builder: (BuildContext context, MonthwiseAggregatedExpense expense,
          Widget? child) {
        print("re-rendering monthly aggregate");
        return SliverPersistentHeader(
          pinned: true,
          delegate: _SliverAppBarDelegate(
            minHeight: 30.0,
            maxHeight: 30.0,
            child: Container(
              color: inactiveColor,
              child: Container(
                margin: const EdgeInsets.only(left: 70, right: 15),
                child: Row(children: [
                  Expanded(
                      child: Text(expense.month,
                          style: const TextStyle(color: Colors.white))),
                  Text("${expense.amount}",
                      style: const TextStyle(color: Colors.white)),
                ]),
              ),
            ),
          ),
        );
      },
      valueListenable: _showExpenseOfMonth,
    );
  }
}

// copy pasted this class as SliverPersistentHeaderDelegate has to be extended. Not much details in here. Skip it.
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
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return SizedBox.expand(child: child);
  }

  @override
  bool shouldRebuild(_SliverAppBarDelegate oldDelegate) {
    return maxHeight != oldDelegate.maxHeight ||
        minHeight != oldDelegate.minHeight ||
        child != oldDelegate.child;
  }
}

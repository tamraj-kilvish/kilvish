import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'style.dart';
import 'common_widgets.dart';
import 'expense_detail_screen.dart';
import 'dart:math';

class TagDetailScreen extends StatefulWidget {
  final Map<String, dynamic> tag;

  const TagDetailScreen({Key? key, required this.tag}) : super(key: key);

  @override
  _TagDetailScreenState createState() => _TagDetailScreenState();
}

class _TagDetailScreenState extends State<TagDetailScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final ScrollController _scrollController = ScrollController();
  
  List<Map<String, dynamic>> _expenses = [];
  Map<String, MonthwiseAggregatedExpense> _monthwiseAggregatedExpenses = {};
  late ValueNotifier<MonthwiseAggregatedExpense> _showExpenseOfMonth;
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
      _assignValueToShowExpenseOfMonth(topVisibleElementIndex);
    });
    _loadTagExpenses();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _assignValueToShowExpenseOfMonth(int expenseIndex) {
    if (_expenses.isEmpty || expenseIndex >= _expenses.length) return;
    
    String monthYearHash = _getMonthYearHash(_expenses[expenseIndex]['date']);
    _showExpenseOfMonth.value = _monthwiseAggregatedExpenses[monthYearHash] ??
        const MonthwiseAggregatedExpense(month: "-", year: "-", amount: 0);
  }

  String _getMonthYearHash(dynamic timestamp) {
    if (timestamp == null) return 'Unknown-0000';
    
    DateTime date;
    if (timestamp is Timestamp) {
      date = timestamp.toDate();
    } else if (timestamp is DateTime) {
      date = timestamp;
    } else {
      return 'Unknown-0000';
    }
    
    List<String> months = ['January', 'February', 'March', 'April', 'May', 'June',
                          'July', 'August', 'September', 'October', 'November', 'December'];
    return '${months[date.month - 1]}-${date.year}';
  }

  double _getTotalExpenses() {
    return _expenses.fold(0.0, (sum, expense) => sum + (expense['amount'] ?? 0));
  }

  double _getThisMonthExpenses() {
    DateTime now = DateTime.now();
    DateTime startOfMonth = DateTime(now.year, now.month, 1);
    
    return _expenses.where((expense) {
      if (expense['date'] == null) return false;
      DateTime expenseDate;
      if (expense['date'] is Timestamp) {
        expenseDate = (expense['date'] as Timestamp).toDate();
      } else if (expense['date'] is DateTime) {
        expenseDate = expense['date'];
      } else {
        return false;
      }
      return expenseDate.isAfter(startOfMonth.subtract(Duration(days: 1)));
    }).fold(0.0, (sum, expense) => sum + (expense['amount'] ?? 0));
  }

  double _getLastMonthExpenses() {
    DateTime now = DateTime.now();
    DateTime startOfLastMonth = DateTime(now.year, now.month - 1, 1);
    DateTime endOfLastMonth = DateTime(now.year, now.month, 1).subtract(Duration(days: 1));
    
    return _expenses.where((expense) {
      if (expense['date'] == null) return false;
      DateTime expenseDate;
      if (expense['date'] is Timestamp) {
        expenseDate = (expense['date'] as Timestamp).toDate();
      } else if (expense['date'] is DateTime) {
        expenseDate = expense['date'];
      } else {
        return false;
      }
      return expenseDate.isAfter(startOfLastMonth.subtract(Duration(days: 1))) && 
             expenseDate.isBefore(endOfLastMonth.add(Duration(days: 1)));
    }).fold(0.0, (sum, expense) => sum + (expense['amount'] ?? 0));
  }

  void _buildMonthwiseAggregatedExpenses() {
    Map<String, double> monthlyTotals = {};
    
    for (var expense in _expenses) {
      String monthYearHash = _getMonthYearHash(expense['date']);
      monthlyTotals[monthYearHash] = (monthlyTotals[monthYearHash] ?? 0) + (expense['amount'] ?? 0);
    }
    
    _monthwiseAggregatedExpenses = monthlyTotals.map((key, value) {
      List<String> parts = key.split('-');
      return MapEntry(key, MonthwiseAggregatedExpense(
        month: parts[0], 
        year: parts[1], 
        amount: value
      ));
    });
    
    if (_expenses.isNotEmpty) {
      String firstMonthYearHash = _getMonthYearHash(_expenses[0]['date']);
      _showExpenseOfMonth = ValueNotifier(
        _monthwiseAggregatedExpenses[firstMonthYearHash] ??
        const MonthwiseAggregatedExpense(month: "-", year: "-", amount: 0)
      );
    } else {
      _showExpenseOfMonth = ValueNotifier(
        const MonthwiseAggregatedExpense(month: "-", year: "-", amount: 0)
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          leading: const BackButton(),
          title: Row(children: [
            renderImageIcon(Icons.local_offer), 
            Text(widget.tag['name'] ?? 'Tag')
          ]),
        ),
        body: Center(
          child: CircularProgressIndicator(color: primaryColor),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Row(children: [
          renderImageIcon(Icons.local_offer), 
          Text(widget.tag['name'] ?? 'Tag')
        ]),
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
            delegate: SliverChildBuilderDelegate((BuildContext context, int index) {
              return Column(
                children: [
                  const Divider(height: 1),
                  ListTile(
                    tileColor: tileBackgroundColor,
                    leading: const Icon(Icons.currency_rupee, color: Colors.black),
                    onTap: () {
                      _openExpenseDetail(_expenses[index]);
                    },
                    title: Container(
                      margin: const EdgeInsets.only(bottom: 5),
                      child: Text('To: ${_expenses[index]['to'] ?? 'N/A'}'),
                    ),
                    subtitle: Text(_formatRelativeTime(_expenses[index]['date'])),
                    trailing: Text(
                      "₹${_expenses[index]['amount'] ?? 0}",
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
        child: renderMainBottomButton('Add Expense', _addNewExpenseToTag),
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
              child: Text("₹${_getTotalExpenses().toStringAsFixed(0)}", 
                  style: TextStyle(fontSize: 20.0)),
            ),
            Text("₹${_getThisMonthExpenses().toStringAsFixed(0)}", 
                style: textStyleInactive),
            Text("₹${_getLastMonthExpenses().toStringAsFixed(0)}", 
                style: textStyleInactive),
          ],
        ),
      ]),
    );
  }

  ValueListenableBuilder<MonthwiseAggregatedExpense> renderMonthAggregateHeader() {
    return ValueListenableBuilder<MonthwiseAggregatedExpense>(
      builder: (BuildContext context, MonthwiseAggregatedExpense expense, Widget? child) {
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
                      child: Text("${expense.month} ${expense.year}",
                          style: const TextStyle(color: Colors.white))),
                  Text("₹${expense.amount.toStringAsFixed(0)}",
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

  Future<void> _loadTagExpenses() async {
    try {
      User? user = _auth.currentUser;
      if (user != null) {
        QuerySnapshot expensesSnapshot = await _firestore
            .collection('User')
            .doc(user.uid)
            .collection('Tags')
            .doc(widget.tag['id'])
            .collection('Expenses')
            .orderBy('date', descending: true)
            .get();

        List<Map<String, dynamic>> expenses = [];
        
        for (QueryDocumentSnapshot expenseDoc in expensesSnapshot.docs) {
          Map<String, dynamic> expenseData = expenseDoc.data() as Map<String, dynamic>;
          expenses.add({
            'id': expenseDoc.id,
            'tagId': widget.tag['id'],
            'tagName': widget.tag['name'],
            ...expenseData,
          });
        }
        
        setState(() {
          _expenses = expenses;
          _buildMonthwiseAggregatedExpenses();
          _isLoading = false;
        });
      }
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

  void _openExpenseDetail(Map<String, dynamic> expense) {
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

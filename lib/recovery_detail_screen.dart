import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/expense_detail_screen.dart';
import 'package:kilvish/firestore_recoveries.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/models_tags.dart';
import 'package:kilvish/style.dart';
import 'package:kilvish/deep_link_handler.dart';

class RecoveryDetailScreen extends StatefulWidget {
  final Recovery recovery;

  const RecoveryDetailScreen({super.key, required this.recovery});

  @override
  State<RecoveryDetailScreen> createState() => _RecoveryDetailScreenState();
}

class _RecoveryDetailScreenState extends State<RecoveryDetailScreen> with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late TabController _tabController;

  late Recovery _recovery;
  List<Expense> _expenses = [];
  List<Expense> _settlements = [];
  bool _isLoading = true;
  bool _isOwner = false;

  @override
  void initState() {
    super.initState();
    _recovery = widget.recovery;
    _tabController = TabController(length: 2, vsync: this);
    _loadRecoveryData();

    getUserIdFromClaim().then((String? userId) {
      if (userId == null) return;
      if (_recovery.ownerId == userId) setState(() => _isOwner = true);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadRecoveryData() async {
    setState(() => _isLoading = true);

    try {
      final expenses = await getExpensesOfRecovery(_recovery.id);
      final settlements = await getSettlementsOfRecovery(_recovery.id);

      setState(() {
        _expenses = expenses;
        _settlements = settlements;
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading recovery data: $e');
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kWhitecolor,
      appBar: AppBar(
        backgroundColor: kWhitecolor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: kTextColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          _recovery.name,
          style: TextStyle(color: kTextColor, fontSize: largeFontSize, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.share, color: primaryColor),
            onPressed: _shareRecovery,
          ),
        ],
      ),
      body: Column(
        children: [
          // Header with totals
          _buildHeader(),

          // Tabs
          TabBar(
            controller: _tabController,
            labelColor: primaryColor,
            unselectedLabelColor: kTextMedium,
            indicatorColor: primaryColor,
            tabs: [
              Tab(text: 'All'),
              Tab(text: 'Monthly'),
            ],
          ),

          // Tab views
          Expanded(
            child: TabBarView(controller: _tabController, children: [_buildAllExpensesView(), _buildMonthlyView()]),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: primaryColor.withOpacity(0.05),
        border: Border(bottom: BorderSide(color: kBorderColor)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildHeaderColumn('Total Expense', _recovery.totalTillDate['expense'] ?? '0'),
          Container(width: 1, height: 40, color: kBorderColor),
          _buildHeaderColumn('Pending Recovery', _recovery.totalTillDate['recovery'] ?? '0', color: errorcolor),
        ],
      ),
    );
  }

  Widget _buildHeaderColumn(String label, String value, {Color? color}) {
    return Column(
      children: [
        customText(label, kTextMedium, smallFontSize, FontWeight.normal),
        SizedBox(height: 4),
        customText(value, color ?? primaryColor, largeFontSize, FontWeight.bold),
      ],
    );
  }

  Widget _buildAllExpensesView() {
    if (_isLoading) {
      return Center(child: CircularProgressIndicator(color: primaryColor));
    }

    final allItems = [..._expenses, ..._settlements]..sort((a, b) => b.timeOfTransaction.compareTo(a.timeOfTransaction));

    if (allItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long_outlined, size: 64, color: kTextLight),
            SizedBox(height: 16),
            customText('No expenses yet', kTextMedium, defaultFontSize, FontWeight.normal),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.all(16),
      itemCount: allItems.length,
      itemBuilder: (context, index) {
        final expense = allItems[index];
        final isSettlement = expense.settlements.isNotEmpty;

        return GestureDetector(
          onTap: () => _openExpenseDetail(expense),
          child: Container(
            margin: EdgeInsets.only(bottom: 12),
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kWhitecolor,
              border: Border.all(color: kBorderColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          customText(expense.to, kTextColor, defaultFontSize, FontWeight.w600),
                          if (isSettlement) ...[
                            SizedBox(width: 8),
                            Container(
                              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: successcolor.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: customText('Settlement', successcolor, xsmallFontSize, FontWeight.normal),
                            ),
                          ],
                        ],
                      ),
                      SizedBox(height: 4),
                      customText(
                        DateFormat('MMM d, yyyy • h:mm a').format(expense.timeOfTransaction),
                        kTextMedium,
                        smallFontSize,
                        FontWeight.normal,
                      ),
                    ],
                  ),
                ),
                customText('₹${expense.amount}', kTextColor, defaultFontSize, FontWeight.bold),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMonthlyView() {
    if (_isLoading) {
      return Center(child: CircularProgressIndicator(color: primaryColor));
    }

    final monthlyData = _recovery.monthWiseTotal;
    if (monthlyData.isEmpty) {
      return Center(child: customText('No monthly data available', kTextMedium, defaultFontSize, FontWeight.normal));
    }

    final sortedMonths = monthlyData.keys.toList()..sort((a, b) => b.compareTo(a)); // Newest first

    return ListView.builder(
      padding: EdgeInsets.all(16),
      itemCount: sortedMonths.length,
      itemBuilder: (context, index) {
        final monthKey = sortedMonths[index];
        final data = monthlyData[monthKey]!;

        return Container(
          margin: EdgeInsets.only(bottom: 16),
          padding: EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: kWhitecolor,
            border: Border.all(color: kBorderColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              customText(_formatMonthKey(monthKey), kTextColor, largeFontSize, FontWeight.bold),
              SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildMonthlyColumn('Expense', data['totalExpense']?.toString() ?? '0'),
                  Container(width: 1, height: 30, color: kBorderColor),
                  _buildMonthlyColumn('Recovery', data['totalRecovery']?.toString() ?? '0', color: errorcolor),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMonthlyColumn(String label, String value, {Color? color}) {
    return Column(
      children: [
        customText(label, kTextMedium, smallFontSize, FontWeight.normal),
        SizedBox(height: 4),
        customText(value, color ?? primaryColor, defaultFontSize, FontWeight.bold),
      ],
    );
  }

  String _formatMonthKey(String monthKey) {
    final parts = monthKey.split('-');
    if (parts.length != 2) return monthKey;

    final year = parts[0];
    final month = int.tryParse(parts[1]) ?? 1;
    final monthName = DateFormat.MMMM().format(DateTime(2000, month));

    return '$monthName $year';
  }

  void _openExpenseDetail(Expense expense) {
    Navigator.push(context, MaterialPageRoute(builder: (context) => ExpenseDetailScreen(expense: expense)));
  }

  void _shareRecovery() {
    final link = DeepLinkHandler.generateRecoveryLink(_recovery.id);

    Clipboard.setData(ClipboardData(text: link));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Recovery link copied to clipboard!'),
        backgroundColor: successcolor,
        duration: Duration(seconds: 2),
        action: SnackBarAction(label: 'OK', textColor: kWhitecolor, onPressed: () {}),
      ),
    );
  }
}

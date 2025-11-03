import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:kilvish/add_edit_expense_screen.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/signup_screen.dart';
import 'style.dart';
import 'expense_detail_screen.dart';
import 'tag_detail_screen.dart';
import 'models.dart';
import 'fcm_hanlder.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  List<Tag> _tags = [];
  Map<String, Expense> _mostRecentTransactionUnderTag = {};
  List<Expense> _expenses = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadData();

    FCMService().initialize();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kWhitecolor,
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: Text(
          'Kilvish',
          style: TextStyle(
            color: kWhitecolor,
            fontSize: titleFontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.logout, color: kWhitecolor),
            onPressed: _logout,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: kWhitecolor,
          labelColor: kWhitecolor,
          unselectedLabelColor: kWhitecolor.withOpacity(0.7),
          tabs: [
            Tab(icon: Icon(Icons.receipt_long), text: 'Expenses'),
            Tab(icon: Icon(Icons.local_offer), text: 'Tags'),
          ],
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: primaryColor))
          : TabBarView(
              controller: _tabController,
              children: [_buildExpensesTab(), _buildTagsTab()],
            ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: primaryColor,
        onPressed: _addNewExpense,
        child: Icon(Icons.add, color: kWhitecolor),
      ),
    );
  }

  Widget _buildExpensesTab() {
    if (_expenses.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long_outlined, size: 64, color: inactiveColor),
            SizedBox(height: 16),
            Text(
              'No expenses yet',
              style: TextStyle(fontSize: largeFontSize, color: kTextMedium),
            ),
            SizedBox(height: 8),
            Text(
              'Tap + to add your first expense',
              style: TextStyle(fontSize: defaultFontSize, color: inactiveColor),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.all(16),
      itemCount: _expenses.length,
      itemBuilder: (context, index) {
        final expense = _expenses[index];
        return Card(
          color: tileBackgroundColor,
          margin: EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: primaryColor,
              child: Icon(Icons.currency_rupee, color: kWhitecolor, size: 20),
            ),
            title: Text(
              expense.to,
              style: TextStyle(
                fontSize: defaultFontSize,
                color: kTextColor,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: renderTagGroup(tags: expense.tags),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '₹${expense.amount}',
                  style: TextStyle(
                    fontSize: largeFontSize,
                    color: kTextColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  _formatDate(expense.timeOfTransaction),
                  style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
                ),
              ],
            ),
            onTap: () => _openExpenseDetail(expense),
          ),
        );
      },
    );
  }

  // ADD THIS: Helper function to get unread count for a tag
  Future<int> _getUnreadCount(Tag tag) async {
    try {
      // Get last seen time for this tag
      final lastSeenTime = await getLastSeenTime(tag.id);

      // Get all expenses for this tag
      final expenses = await getExpensesOfTag(tag.id);

      // Count unread expenses
      int unreadCount = 0;
      for (var expense in expenses) {
        if (isExpenseUnread(expense, lastSeenTime)) {
          unreadCount++;
        }
      }

      return unreadCount;
    } catch (e, stackTrace) {
      log('Error getting unread count: $e', error: e, stackTrace: stackTrace);
      return 0;
    }
  }

  Widget _buildTagsTab() {
    if (_tags.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.local_offer_outlined, size: 64, color: inactiveColor),
            SizedBox(height: 16),
            Text(
              'No tags yet',
              style: TextStyle(fontSize: largeFontSize, color: kTextMedium),
            ),
            SizedBox(height: 8),
            Text(
              'Tags will appear when you add expenses',
              style: TextStyle(fontSize: defaultFontSize, color: inactiveColor),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.all(16),
      itemCount: _tags.length,
      itemBuilder: (context, index) {
        final tag = _tags[index];
        return Card(
          color: tileBackgroundColor,
          margin: EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: primaryColor,
              child: Icon(Icons.local_offer, color: kWhitecolor, size: 20),
            ),
            title: Text(
              tag.name,
              style: TextStyle(
                fontSize: defaultFontSize,
                color: kTextColor,
                fontWeight: FontWeight.w500,
              ),
            ),
            // UPDATED: Add unread count badge
            subtitle: FutureBuilder<int>(
              future: _getUnreadCount(tag),
              builder: (context, snapshot) {
                final unreadCount = snapshot.data ?? 0;

                return Row(
                  children: [
                    Text(
                      'To: ${_mostRecentTransactionUnderTag[tag.id]?.to ?? 'N/A'}',
                      style: TextStyle(
                        fontSize: smallFontSize,
                        color: kTextMedium,
                      ),
                    ),
                    if (unreadCount > 0) ...[
                      SizedBox(width: 8),
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: primaryColor,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$unreadCount',
                          style: TextStyle(
                            color: kWhitecolor,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '₹${tag.totalAmountTillDate}',
                  style: TextStyle(
                    fontSize: largeFontSize,
                    color: kTextColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  _formatDate(
                    _mostRecentTransactionUnderTag[tag.id]?.timeOfTransaction,
                  ),
                  style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
                ),
              ],
            ),
            onTap: () => _openTagDetail(tag),
          ),
        );
      },
    );
  }

  void _loadData() async {
    try {
      final KilvishUser? user = await getLoggedInUserData();
      if (user != null) {
        await _loadTags(user);
        await _loadExpenses(user);
      }
    } catch (e, stackTrace) {
      log('Error loading data: $e', error: e, stackTrace: stackTrace);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadTags(KilvishUser user) async {
    Set<Tag> tags = {};

    try {
      for (String tagId in user.accessibleTagIds) {
        tags.add(await getTagData(tagId));
        _mostRecentTransactionUnderTag[tagId] =
            await getMostRecentExpenseFromTag(tagId);
      }

      setState(() => _tags = tags.toList());
    } catch (e, stackTrace) {
      log('Error loading tags', error: e, stackTrace: stackTrace);
    }
  }

  Future<void> _loadExpenses(KilvishUser user) async {
    List<Expense> allExpenses = [];
    try {
      //TODO - no need to get direct user Expense as they will come from tags anyway

      if (user.accessibleTagIds.isEmpty) {
        return;
      }

      // For each tag, get its expenses
      for (String tagId in user.accessibleTagIds.toList()) {
        Map<String, Expense> allExpensesMap = {};

        List<QueryDocumentSnapshot<Object?>> expensesSnapshotDocs =
            await getExpenseDocsUnderTag(tagId);

        for (QueryDocumentSnapshot expenseDoc in expensesSnapshotDocs) {
          Expense? expense = allExpensesMap[expenseDoc.id];

          if (expense == null) {
            expense = Expense.fromFirestoreObject(
              expenseDoc.id,
              expenseDoc.data() as Map<String, dynamic>,
            );
            allExpensesMap[expenseDoc.id] = expense;
          }

          final Tag tag = await getTagData(tagId);
          expense.addTagToExpense(tag);
        }

        allExpenses = allExpensesMap.values.toList();
      }

      // Sort all expenses by date (most recent first)
      allExpenses.sort((a, b) {
        DateTime dateA = a.updatedAt;
        DateTime dateB = b.updatedAt;

        return dateB.compareTo(dateA);
      });

      setState(() => _expenses = allExpenses);
    } catch (e, stackTrace) {
      log('Error loading expenses', error: e, stackTrace: stackTrace);
    }
  }

  String _formatDate(dynamic timestamp) {
    if (timestamp == null) return '';

    DateTime date;
    if (timestamp is Timestamp) {
      date = timestamp.toDate();
    } else if (timestamp is DateTime) {
      date = timestamp;
    } else {
      return '';
    }

    return '${date.day}/${date.month}/${date.year}';
  }

  void _openExpenseDetail(Expense expense) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ExpenseDetailScreen(expense: expense),
      ),
    );
  }

  void _openTagDetail(Tag tag) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => TagDetailScreen(tag: tag)),
    );
  }

  void _addNewExpense() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => AddEditExpenseScreen()),
    );
  }

  void _logout() async {
    await _auth.signOut();
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => SignupScreen()),
      );
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }
}

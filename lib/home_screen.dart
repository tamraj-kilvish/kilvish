import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:kilvish/expense_add_edit_screen.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/signup_screen.dart';
import 'package:kilvish/tag_add_edit_screen.dart';
import 'style.dart';
import 'expense_detail_screen.dart';
import 'tag_detail_screen.dart';
import 'models.dart';
import 'fcm_hanlder.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  List<Tag> _tags = [];
  Map<String, Expense?> _mostRecentTransactionUnderTag = {};
  List<Expense> _expenses = [];
  bool _isLoading = true;
  StreamSubscription<Map<String, String>>? _navigationSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadData(); // here await is not needed as there is loading sign which will go away when _loadData is done

    if (!kIsWeb) {
      FCMService.instance.initialize();
      _navigationSubscription = FCMService.instance.navigationStream.listen((navData) {
        print('home_screen - inside navigationStream.listen');
        if (mounted) {
          print('home_screen - Executing _navigationSubscription to $navData');
          _handleFCMNavigation(navData);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kWhitecolor,
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: Text(
          'Kilvish',
          style: TextStyle(color: kWhitecolor, fontSize: titleFontSize, fontWeight: FontWeight.bold),
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
          : TabBarView(controller: _tabController, children: [_buildExpensesTab(), _buildTagsTab()]),
      floatingActionButton: FloatingActionButton(
        backgroundColor: primaryColor,
        onPressed: _floatingButtonPressed,
        child: Icon(Icons.add, color: kWhitecolor),
      ),
    );
  }

  void _floatingButtonPressed() {
    if (_tabController.index == 0) {
      Navigator.push(context, MaterialPageRoute(builder: (context) => AddEditExpenseScreen())).then((value) {
        Expense? expense = value as Expense?;
        if (expense != null) {
          setState(() => _expenses.add(expense));
        }
      });
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (context) => TagAddEditScreen())).then((value) {
        Tag? tag = value as Tag?;
        if (tag != null) {
          setState(() => _tags.add(tag));
        }
      });
    }
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
      //padding: EdgeInsets.all(16),
      itemCount: _expenses.length,
      itemBuilder: (context, index) {
        final expense = _expenses[index];

        return renderExpenseTile(expense: expense, onTap: () => _openExpenseDetail(expense), showTags: true);
      },
    );
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
              'Create a tag to organize expenses',
              style: TextStyle(fontSize: defaultFontSize, color: inactiveColor),
            ),
            SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _addNewTag,
              icon: Icon(Icons.add, color: kWhitecolor),
              label: Text('Add Tag', style: TextStyle(color: kWhitecolor)),
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryColor,
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
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
        final unreadCount = _getUnseenCountForTag(tag, _expenses);

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
              style: TextStyle(fontSize: defaultFontSize, color: kTextColor, fontWeight: FontWeight.w500),
            ),
            subtitle: _mostRecentTransactionUnderTag[tag.id] != null
                ? Row(
                    children: [
                      Text(
                        'To: ${_mostRecentTransactionUnderTag[tag.id]?.to ?? 'N/A'}',
                        style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
                      ),
                      if (unreadCount > 0) ...[
                        SizedBox(width: 8),
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: primaryColor, borderRadius: BorderRadius.circular(10)),
                          child: Text(
                            '$unreadCount',
                            style: TextStyle(color: kWhitecolor, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  )
                : null,
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '₹${tag.totalAmountTillDate}',
                  style: TextStyle(fontSize: largeFontSize, color: kTextColor, fontWeight: FontWeight.bold),
                ),
                Text(
                  formatRelativeTime(_mostRecentTransactionUnderTag[tag.id]?.timeOfTransaction),
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

  Future<void> _loadData() async {
    if (!mounted) return;

    try {
      final KilvishUser? user = await getLoggedInUserData();
      if (user != null) {
        await _loadTags(user);
        await _loadExpenses(user);
      }
    } catch (e, stackTrace) {
      print('Error loading data: $e, $stackTrace');
    } finally {
      setState(() => _isLoading = false);

      // Check for pending navigation from FCM notification tap
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final pendingNav = FCMService.getPendingNavigation();
        if (pendingNav != null && mounted) {
          _handleFCMNavigation(pendingNav);
        }
      });
    }
  }

  void _handleFCMNavigation(Map<String, String> navData) async {
    try {
      final navType = navData['type'];

      final user = await getLoggedInUserData();
      if (user != null && mounted) {
        await _loadTags(user);
        await _loadExpenses(user);
      }

      // Handle tag access removal
      if (navType == 'home') {
        final message = navData['message'];
        if (mounted && message != null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message), duration: Duration(seconds: 3), backgroundColor: errorcolor));
        }
        return;
      }

      // Handle all other notifications (expense & tag) â†’ Navigate to Tag Detail
      if (navType == 'tag') {
        final tagId = navData['tagId'];
        if (tagId == null) return;

        print('_handleFCMNavigation - Navigating to tag id - $tagId');

        // Find the tag
        final tag = _tags.firstWhere((t) => t.id == tagId, orElse: () => throw Exception('Tag not found'));

        // Navigate to Tag Detail Screen
        if (mounted) {
          await Navigator.push(context, MaterialPageRoute(builder: (context) => TagDetailScreen(tag: tag)));
          // Refresh after returning
          await _loadData();
        }
      }
    } catch (e, stackTrace) {
      log('Error handling FCM navigation: $e', error: e, stackTrace: stackTrace);
      if (mounted) showError(context, 'Could not open notification');
    }
  }

  Future<void> _loadTags(KilvishUser user) async {
    Set<Tag> tags = {};

    try {
      for (String tagId in user.accessibleTagIds) {
        tags.add(await getTagData(tagId));
        _mostRecentTransactionUnderTag[tagId] = await getMostRecentExpenseFromTag(tagId);
      }

      setState(() => _tags = tags.toList());
    } catch (e, stackTrace) {
      print('Error loading tags - $e, $stackTrace');
    }
  }

  Future<void> _loadExpenses(KilvishUser user) async {
    try {
      // if (user.accessibleTagIds.isEmpty) {
      //   print("_loadExpenses returning as no accessibleTagIds found for user");
      //   return;
      // }

      Map<String, Expense> allExpensesMap = {};

      // Get user own expenses
      List<QueryDocumentSnapshot<Object?>> expensesSnapshotDocs = await getExpenseDocsOfUser(user.id);

      print("Got ${expensesSnapshotDocs.length} own expenses of user");

      for (QueryDocumentSnapshot expenseDoc in expensesSnapshotDocs) {
        Expense? expense = allExpensesMap[expenseDoc.id];

        if (expense == null) {
          expense = Expense.fromFirestoreObject(expenseDoc.id, expenseDoc.data() as Map<String, dynamic>);
          // Set unseen status based on user's unseenExpenseIds
          expense.setUnseenStatus(user.unseenExpenseIds);
          allExpensesMap[expenseDoc.id] = expense;
        }
      }

      // For each tag, get its expenses
      if (user.accessibleTagIds.isNotEmpty) {
        for (String tagId in user.accessibleTagIds.toList()) {
          final Tag tag = await getTagData(tagId);

          List<QueryDocumentSnapshot<Object?>> expensesSnapshotDocs = await getExpenseDocsUnderTag(tagId);

          print("Got ${expensesSnapshotDocs.length} expenses from $tagId");

          for (QueryDocumentSnapshot expenseDoc in expensesSnapshotDocs) {
            Expense? expense = allExpensesMap[expenseDoc.id];

            if (expense == null) {
              expense = Expense.fromFirestoreObject(expenseDoc.id, expenseDoc.data() as Map<String, dynamic>);
              // Set unseen status based on user's unseenExpenseIds
              expense.setUnseenStatus(user.unseenExpenseIds);
              allExpensesMap[expenseDoc.id] = expense;
            }

            expense.addTagToExpense(tag);
          }
        }
      }

      List<Expense> allExpenses = allExpensesMap.values.toList();

      // Sort all expenses by date (most recent first)
      allExpenses.sort((a, b) {
        DateTime dateA = a.updatedAt;
        DateTime dateB = b.updatedAt;

        return dateB.compareTo(dateA);
      });

      setState(() => _expenses = allExpenses);
    } catch (e, stackTrace) {
      print('Error loading expenses - $e, $stackTrace');
    }
  }

  void _openExpenseDetail(Expense expense) async {
    await Navigator.push(context, MaterialPageRoute(builder: (context) => ExpenseDetailScreen(expense: expense)));

    await _loadData();
  }

  void _openTagDetail(Tag tag) async {
    await Navigator.push(context, MaterialPageRoute(builder: (context) => TagDetailScreen(tag: tag)));

    // Refresh data after viewing tag
    //setState(() {
    await _loadData();
    //});
  }

  void _addNewTag() async {
    final result = await Navigator.push(context, MaterialPageRoute(builder: (context) => TagAddEditScreen()));

    if (result == true) {
      // Refresh data after adding tag
      await _loadData();
    }
  }

  void _addNewExpense() {
    Navigator.push(context, MaterialPageRoute(builder: (context) => AddEditExpenseScreen()));
  }

  void _logout() async {
    await _auth.signOut();
    if (mounted) {
      Navigator.push(context, MaterialPageRoute(builder: (context) => SignupScreen()));
    }
  }

  /// Call in home screen to render list of Tags & show unseen count
  int _getUnseenCountForTag(Tag tag, List<Expense> expenses) {
    try {
      return expenses.where((expense) => expense.tags.any((t) => t.id == tag.id) && expense.isUnseen).length;
    } catch (e, stackTrace) {
      log('Error getting unseen count for tag: $e', error: e, stackTrace: stackTrace);
      return 0;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _navigationSubscription?.cancel();

    super.dispose();
  }
}

import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:kilvish/canny_app_scafold_wrapper.dart';
import 'package:kilvish/expense_add_edit_screen.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/signup_screen.dart';
import 'package:kilvish/tag_add_edit_screen.dart';
import 'style.dart';
import 'tag_detail_screen.dart';
import 'models.dart';
import 'fcm_hanlder.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:package_info_plus/package_info_plus.dart';

class HomeScreen extends StatefulWidget {
  final String? messageOnLoad;
  const HomeScreen({super.key, this.messageOnLoad});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  late String? _messageOnLoad = widget.messageOnLoad;

  List<Tag> _tags = [];
  Map<String, Expense?> _mostRecentTransactionUnderTag = {};
  List<Expense> _expenses = [];
  bool _isLoading = true;
  String _kilvishId = "";
  String _version = "";

  StreamSubscription<String>? _refreshSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadData(); // here await is not needed as there is loading sign which will go away when _loadData is done

    if (!kIsWeb) {
      FCMService.instance.initialize();

      // ✅ Stream for immediate updates
      _refreshSubscription = FCMService.instance.refreshStream.listen((eventType) {
        print('HomeScreen: Received refresh event: $eventType');
        if (mounted) {
          _loadData();
          FCMService.instance.markDataRefreshed(); // Clear flag
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // ✅ Flag check as backup when returning from navigation
    if (state == AppLifecycleState.resumed && !kIsWeb) {
      if (FCMService.instance.needsDataRefresh) {
        print('HomeScreen: Refresh needed on resume, reloading...');
        FCMService.instance.markDataRefreshed();
        _loadData();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffoldWrapper(
      //backgroundColor: kWhitecolor,
      appBar: AppBar(
        backgroundColor: primaryColor,
        leading: Padding(
          padding: EdgeInsets.only(left: 10, top: 10),
          child: Column(
            children: [
              Icon(Icons.settings, color: kWhitecolor),
              Text(
                'Ver $_version',
                style: TextStyle(color: kWhitecolor, fontSize: xsmallFontSize, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        title: Text(
          'Hello @$_kilvishId',
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
      Navigator.push(context, MaterialPageRoute(builder: (context) => ExpenseAddEditScreen())).then((value) {
        Expense? expense = value as Expense?;
        print("Got expense ${expense?.to}");
        if (expense != null) {
          setState(() {
            _expenses = [expense, ..._expenses]; // ✅ Create new list
          });
        }
      });
    } else {
      _addNewTag();
    }
  }

  Widget _buildExpensesTab() {
    if (_expenses.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            //Icon(Icons.receipt_long_outlined, size: 64, color: inactiveColor),
            Text(
              'No expenses yet',
              style: TextStyle(fontSize: largeFontSize, color: kTextMedium),
            ),
            SizedBox(height: 16),

            Image.asset(
              "assets/images/insert-expense-lifecycle.png",
              width: double.infinity, // Takes up the full width of its container
              height: 300, // A fixed height to prevent it from dominating the screen
              fit: BoxFit.contain,
            ),

            SizedBox(height: 8),
            Padding(
              padding: EdgeInsetsGeometry.only(left: 20, right: 20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '1. Navigate to UPI app',
                    style: TextStyle(fontSize: smallFontSize, color: inactiveColor),
                  ),
                  Text(
                    '2. Select a transaction from history',
                    style: TextStyle(fontSize: smallFontSize, color: inactiveColor),
                  ),
                  Text(
                    '3. Click on Share Receipt',
                    style: TextStyle(fontSize: smallFontSize, color: inactiveColor),
                  ),
                  Text(
                    '4. Select Kilvish by going to More (3 dots at the end)',
                    style: TextStyle(fontSize: smallFontSize, color: inactiveColor),
                  ),
                  Text(
                    '5. Kilvish will extract details using OCR & it will show as Expense here',
                    style: TextStyle(fontSize: smallFontSize, color: inactiveColor),
                  ),
                ],
              ),
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

    final info = await PackageInfo.fromPlatform();
    _version = info.version;

    try {
      final KilvishUser? user = await getLoggedInUserData();
      if (user != null) {
        _kilvishId = user.kilvishId ?? "noname";
        await _loadTags(user);
        await _loadExpenses(user);
      }
    } catch (e, stackTrace) {
      print('Error loading data: $e, $stackTrace');
    } finally {
      setState(() => _isLoading = false);

      if (_messageOnLoad != null) {
        if (mounted) showError(context, _messageOnLoad!);
        _messageOnLoad = null;
      }
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
    final result = await openExpenseDetail(mounted, context, expense, _expenses);

    if (result != null) {
      setState(() {
        _expenses = result;
      });
    }
  }

  Future<void> _openTagDetail(Tag tag) async {
    Tag? updatedTag = await Navigator.push(context, MaterialPageRoute(builder: (context) => TagDetailScreen(tag: tag)));

    if (updatedTag != null) {
      List<Tag> newTags = _tags.map((tag) => tag.id == updatedTag.id ? updatedTag : tag).toList();
      setState(() {
        // _tags.removeWhere((e) => e.id == tag.id);
        // _tags = [updatedTag, ..._tags];
        _tags = newTags;
      });
    }

    // Refresh data after viewing tag
    //setState(() {
    // await _loadData();
    //});
  }

  void _addNewTag() async {
    Navigator.push(context, MaterialPageRoute(builder: (context) => TagAddEditScreen())).then((value) {
      Tag? tag = value as Tag?;
      if (tag != null) {
        setState(() {
          _tags = [tag, ..._tags]; // ✅ Create new list
        });
      }
    });
  }

  void _logout() async {
    await _auth.signOut();
    if (mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => SignupScreen()));
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
    _refreshSubscription?.cancel();

    super.dispose();
  }
}

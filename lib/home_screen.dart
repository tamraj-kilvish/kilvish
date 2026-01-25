import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:kilvish/cache_manager.dart';
import 'package:kilvish/canny_app_scafold_wrapper.dart';
import 'package:kilvish/expense_add_edit_screen.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/signup_screen.dart';
import 'package:kilvish/tag_add_edit_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'style.dart';
import 'tag_detail_screen.dart';
import 'models.dart';
import 'fcm_handler.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:package_info_plus/package_info_plus.dart';

//final GlobalKey<HomeScreenState> homeScreenKey = GlobalKey<HomeScreenState>();

class HomeScreen extends StatefulWidget {
  final String? messageOnLoad;
  final WIPExpense? expenseAsParam;
  const HomeScreen({super.key, this.messageOnLoad, this.expenseAsParam});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  late String? _messageOnLoad = widget.messageOnLoad;

  List<Tag> _tags = [];
  Map<String, BaseExpense> _allExpensesMap = {}; // NEW
  List<BaseExpense> _allExpenses = []; // Changed from separate _expenses/_wipExpenses
  bool _isLoading = true;
  KilvishUser? _user;
  String _version = "";
  WIPExpense? _expenseAsParam;

  KilvishUser? kilvishUser;

  static StreamSubscription<String>? _refreshSubscription;
  final asyncPrefs = SharedPreferencesAsync();

  static bool isFcmServiceInitialized = false;

  // NEW: Sync from SharedPreferences cache
  Future<bool> _syncFromCache() async {
    print('_syncFromCache: Loading from SharedPreferences');
    final cached = await loadHomeScreenStateFromSharedPref();

    if (cached != null) {
      if (mounted) {
        setState(() {
          _allExpensesMap = cached['allExpensesMap'];
          _allExpenses = cached['allExpenses'];
          _tags = cached['tags'];
          _isLoading = false;
        });
      }
      return true;
    }
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed && !kIsWeb) {
      asyncPrefs.getBool('needHomeScreenRefresh').then((needRefresh) {
        if (needRefresh == true) {
          print("Loading cached data in homescreen");
          _syncFromCache().then((_) {
            asyncPrefs.setBool('needHomeScreenRefresh', false);
          });
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (widget.expenseAsParam != null) _expenseAsParam = widget.expenseAsParam;

    _tabController = TabController(length: 2, vsync: this);

    if (_messageOnLoad != null && mounted) {
      showError(context, _messageOnLoad!);
      _messageOnLoad = null;
    }

    _syncFromCache().then((isLoadedFromCache) async {
      if (isLoadedFromCache == true && _expenseAsParam != null) {
        // this check ensures that allExpenseMap etc are populated & expenseAsParam will be appended correctly
        _updateLocalState(_expenseAsParam!, isNew: true); //this will re-render screen with expenseAsParam appended
        _expenseAsParam = null;
      }

      _version = (await PackageInfo.fromPlatform()).version;
      _user = await getLoggedInUserData();
      await _loadData();
    });

    if (!kIsWeb) {
      if (!isFcmServiceInitialized) {
        isFcmServiceInitialized = true;
        FCMService.instance.initialize();

        startListeningToFCMEvent();
      } else {
        _refreshSubscription?.cancel().whenComplete(() {
          startListeningToFCMEvent();
        });
      }
    }
  }

  void startListeningToFCMEvent() {
    _refreshSubscription = FCMService.instance.refreshStream.listen((eventType) {
      print('HomeScreen: Received refresh event: $eventType');
      _syncFromCache().then((_) {
        FCMService.instance.markDataRefreshed();
      });
    });
  }

  // NEW: Update local state after user action
  void _updateLocalState(BaseExpense expense, {bool isNew = false, bool isDeleted = false}) {
    if (isDeleted) {
      _allExpensesMap.remove(expense.id);
      _allExpenses.removeWhere((e) => e.id == expense.id);
    } else if (isNew) {
      _allExpensesMap[expense.id] = expense;
      _allExpenses.insert(0, expense);
    } else {
      // Update existing
      _allExpensesMap[expense.id] = expense;
      _allExpenses = _allExpenses.map((e) => e.id == expense.id ? expense : e).toList();
    }

    setState(() {});
    _saveExpensesToCacheInBackground();
  }

  Timer? timer;
  void _scheduleWIPExpensesRefresh() {
    if (timer != null && timer!.isActive) timer!.cancel();

    timer = Timer(Duration(seconds: 30), () async {
      List<WIPExpense> wipExpenses = await getAllWIPExpenses();

      bool updatesFound = false;

      for (var wip in wipExpenses) {
        _allExpensesMap[wip.id] = wip;

        _allExpenses = _allExpenses.map((e) {
          if (e is Expense) return e;

          if (e.id == wip.id) {
            WIPExpense wipExpense = e as WIPExpense;
            if (wipExpense.status != wip.status || wipExpense.errorMessage != wip.errorMessage) updatesFound = true;
            return wipExpense;
          }

          return e;
        }).toList();
      }

      if (updatesFound) {
        setState(() {});
        _saveExpensesToCacheInBackground();
      }
    });
  }

  Future<void> _saveExpensesToCacheInBackground() async {
    try {
      await asyncPrefs.setString('_allExpensesMap', jsonEncode(_allExpensesMap.map((k, v) => MapEntry(k, v.toJson()))));
      await asyncPrefs.setString('_allExpenses', BaseExpense.jsonEncodeExpensesList(_allExpenses));

      print('_saveToCacheInBackground: Cache saved');
    } catch (e) {
      print('_saveToCacheInBackground: Error $e');
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
              Icon(Icons.settings, color: kWhitecolor, size: smallFontSize),
              Text(
                'Version',
                style: TextStyle(color: kWhitecolor, fontSize: xsmallFontSize, fontWeight: FontWeight.bold),
              ),
              Text(
                _version,
                style: TextStyle(color: kWhitecolor, fontSize: xsmallFontSize, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        title: Text(
          'Hello @${_user?.kilvishId}',
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

  void _floatingButtonPressed() async {
    if (_tabController.index == 0) {
      WIPExpense? wipExpense = await createWIPExpense();
      if (wipExpense == null) {
        showError(context, "Failed to create WIPExpense");
        return;
      }
      final result = await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => ExpenseAddEditScreen(baseExpense: wipExpense)),
      );

      if (result != null) {
        _updateLocalState(result, isNew: true);
      }
    } else {
      _addNewTag();
    }
  }

  // Update _buildExpensesTab to show WIPExpenses at top:
  Widget _buildExpensesTab() {
    return ListView.builder(
      itemCount: /*_wipExpenses.length + */ _allExpenses.length /*+ (_wipExpenses.isEmpty && _expenses.isEmpty ? 1 : 0)*/,
      itemBuilder: (context, index) {
        // Show empty state
        if ( /*_wipExpenses.isEmpty &&*/ _allExpenses.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'No expenses yet',
                  style: TextStyle(fontSize: largeFontSize, color: kTextMedium),
                ),
                SizedBox(height: 16),
                Image.asset(
                  "assets/images/insert-expense-lifecycle.png",
                  width: double.infinity,
                  height: 300,
                  fit: BoxFit.contain,
                ),
                SizedBox(height: 8),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
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

        final expense = _allExpenses[index];
        if (expense is WIPExpense) {
          return _renderWIPExpenseTile(expense);
        } else {
          return renderExpenseTile(expense: expense as Expense, onTap: () => _openExpenseDetail(expense), showTags: true);
        }
      },
    );
  }

  // Add method to render WIPExpense tile:
  Widget _renderWIPExpenseTile(WIPExpense wipExpense) {
    if (wipExpense.status != ExpenseStatus.readyForReview) _scheduleWIPExpensesRefresh();

    return Column(
      children: [
        const Divider(height: 1),
        ListTile(
          tileColor: primaryColor.withOpacity(0.1),
          leading: Stack(
            children: [
              CircleAvatar(
                backgroundColor: wipExpense.getStatusColor(),
                child: wipExpense.errorMessage != null && wipExpense.errorMessage!.isNotEmpty
                    ? Icon(Icons.error, color: kWhitecolor, size: 20)
                    : wipExpense.status == ExpenseStatus.uploadingReceipt || wipExpense.status == ExpenseStatus.extractingData
                    ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kWhitecolor))
                    : Icon(Icons.receipt_long, color: kWhitecolor, size: 20),
              ),
            ],
          ),
          onTap: () => _openWIPExpenseDetail(wipExpense),
          title: Container(
            margin: const EdgeInsets.only(bottom: 5),
            child: Text(
              wipExpense.to != null ? 'To: ${truncateText(wipExpense.to!)}' : 'To: -',
              style: TextStyle(fontSize: defaultFontSize, color: kTextColor, fontWeight: FontWeight.w500),
            ),
          ),
          subtitle: Text(
            wipExpense.errorMessage != null && wipExpense.errorMessage!.isNotEmpty
                ? wipExpense.errorMessage!
                : wipExpense.getStatusDisplayText(),
            style: TextStyle(fontSize: smallFontSize, color: wipExpense.getStatusColor(), fontWeight: FontWeight.w600),
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (wipExpense.amount != null)
                Text(
                  '₹${wipExpense.amount!.round()}',
                  style: TextStyle(fontSize: largeFontSize, color: kTextColor, fontWeight: FontWeight.bold),
                )
              else
                Text(
                  '₹--',
                  style: TextStyle(fontSize: largeFontSize, color: inactiveColor),
                ),
            ],
          ),
        ),
      ],
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
        final unreadCount = _getUnseenCountForTag(tag, _allExpenses);

        return Card(
          color: tileBackgroundColor,
          margin: EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: primaryColor,
              child: Icon(Icons.local_offer, color: kWhitecolor, size: 20),
            ),
            title: Text(
              truncateText(tag.name, 20),
              style: TextStyle(fontSize: defaultFontSize, color: kTextColor, fontWeight: FontWeight.w500),
            ),
            subtitle: tag.mostRecentExpense != null
                ? Row(
                    children: [
                      Text(
                        'To: ${truncateText(tag.mostRecentExpense!.to)}',
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
                  style: TextStyle(fontSize: defaultFontSize, color: kTextColor, fontWeight: FontWeight.bold),
                ),
                if (tag.mostRecentExpense != null) ...[
                  Text(
                    formatRelativeTime(tag.mostRecentExpense?.timeOfTransaction),
                    style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
                  ),
                ],
              ],
            ),
            onTap: () => _openTagDetail(tag),
          ),
        );
      },
    );
  }

  // Updated _loadData
  bool loadDataRunning = false;

  Future<void> _loadData() async {
    if (loadDataRunning) return;
    loadDataRunning = true;

    print('Loading fresh data in Home Screen');
    try {
      // List<Tag> tags = await Tag.loadTags(_user!);
      // _tags = tags;
      // asyncPrefs.setString('_tags', Tag.jsonEncodeTagsList(_tags));

      final freshData = await loadFromScratch(_user!);

      if (mounted) {
        setState(() {
          _allExpensesMap = freshData['allExpensesMap'];
          _allExpenses = freshData['allExpenses'];
          _tags = freshData['tags'];
          _isLoading = false;
        });
      }

      // Save to cache
      _saveExpensesToCacheInBackground();
      asyncPrefs.setString('_tags', Tag.jsonEncodeTagsList(_tags));
    } catch (e, stackTrace) {
      print('Error loading data: $e, $stackTrace');
    } finally {
      loadDataRunning = false;
    }
  }

  void _openExpenseDetail(Expense expense) async {
    final result = await openExpenseDetail(mounted, context, expense, _allExpenses);

    if (result['updatedExpense'] == null) {
      _updateLocalState(expense, isDeleted: true);
    } else {
      _updateLocalState(result['updatedExpense'] as Expense);
    }
  }

  void _openWIPExpenseDetail(WIPExpense wipExpense) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ExpenseAddEditScreen(baseExpense: wipExpense)),
    );

    if (result != null && result is Map && result['deleted'] == true) {
      _updateLocalState(wipExpense, isDeleted: true);
      return;
    }

    if (result is Expense) {
      // WIPExpense converted to Expense - replace in list
      _updateLocalState(result, isNew: false);
    }
  }

  Future<void> _openTagDetail(Tag tag) async {
    final result = await Navigator.push(context, MaterialPageRoute(builder: (context) => TagDetailScreen(tag: tag)));

    if (result != null && result is Map && result['deleted'] == true) {
      _tags.removeWhere((e) => e.id == tag.id);
      //showSuccess(context, "Expense successfully deleted");
      setState(() {
        updateTagsAndCache([..._tags]);
        //_tags = [..._tags];
      });
      return;
    }
    if (result != null && result is Tag) {
      List<Tag> newTags = _tags.map((tag) => tag.id == result.id ? result : tag).toList();
      setState(() {
        updateTagsAndCache(newTags);
        //_tags = newTags;
      });
      return;
    }
  }

  void _addNewTag() async {
    Navigator.push(context, MaterialPageRoute(builder: (context) => TagAddEditScreen())).then((value) {
      Tag? tag = value as Tag?;
      if (tag != null) {
        setState(() {
          updateTagsAndCache([tag, ..._tags]);
          //_tags = [tag, ..._tags];
        });
      }
    });
  }

  void _logout() async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Logout action', style: TextStyle(color: kTextColor)),
          content: Text(
            'Usually, on the app, there is no need to logout, to save you hassle of logging in again. Are you sure you want to logout ?',
            style: TextStyle(color: kTextMedium),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: TextStyle(color: kTextMedium)),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context); // Close confirmation dialog

                final userId = await getUserIdFromClaim();
                await _auth.signOut();
                try {
                  asyncPrefs.remove('_tags');
                  asyncPrefs.remove('_allExpenses');
                  asyncPrefs.remove('_allExpensesMap');
                  if (userId != null) userIdKilvishIdHash.remove(userId);
                } catch (e) {
                  print("Error removing _tags/_expenses from asyncPrefs - $e");
                }
                Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => SignupScreen()));
              },
              child: Text('Yes', style: TextStyle(color: errorcolor)),
            ),
          ],
        );
      },
    );
  }

  /// Call in home screen to render list of Tags & show unseen count
  int _getUnseenCountForTag(Tag tag, List<BaseExpense> expenses) {
    try {
      return expenses
          .where((expense) => expense.tags.any((t) => t.id == tag.id) && expense is Expense && expense.isUnseen)
          .length;
    } catch (e, stackTrace) {
      log('Error getting unseen count for tag: $e', error: e, stackTrace: stackTrace);
      return 0;
    }
  }

  void updateTagsAndCache(List<Tag> tags) {
    _tags = tags;
    asyncPrefs.setString('_tags', Tag.jsonEncodeTagsList(_tags));
  }

  @override
  void dispose() {
    _tabController.dispose();
    _refreshSubscription?.cancel();

    super.dispose();
  }
}

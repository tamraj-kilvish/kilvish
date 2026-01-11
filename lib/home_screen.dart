import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
  Map<String, Expense?> _mostRecentTransactionUnderTag = {};
  List<Expense> _expenses = [];
  List<WIPExpense> _wipExpenses = [];
  List<BaseExpense> _allExpenses = [];
  bool _isLoading = true;
  KilvishUser? _user;
  String _version = "";

  KilvishUser? kilvishUser;

  static StreamSubscription<String>? _refreshSubscription;
  final asyncPrefs = SharedPreferencesAsync();

  static bool isFcmServiceInitialized = false;

  // Add to _HomeScreenState class variables:
  // List<WIPExpense> _wipExpenses = [];

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed && !kIsWeb) {
      asyncPrefs.getBool('needHomeScreenRefresh').then((needHomeScreenRefresh) {
        if (needHomeScreenRefresh != null && needHomeScreenRefresh == true) {
          print("loading cached data in homescreen");

          _loadDataFromSharedPreference().then((value) async {
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

    _tabController = TabController(length: 2, vsync: this);

    _loadDataFromSharedPreference();

    PackageInfo.fromPlatform().then((info) {
      _version = info.version;
    });

    getLoggedInUserData().then((user) {
      if (user != null) {
        //setState(() {
        _user = user;
        //});

        // this can only be called once _user is set
        _loadData();
      }
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
      if (eventType == 'wip_status_update') {
        // Just reload WIPExpenses
        _reloadWIPExpensesOnly().then((value) {
          FCMService.instance.markDataRefreshed();
        });
        return;
      }
      //TODO - only replace/append/remove the new data that has come from upstream
      _loadData().then((value) {
        FCMService.instance.markDataRefreshed(); // Clear flag
      });
    });
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
      final expense = await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => ExpenseAddEditScreen(baseExpense: wipExpense)),
      );

      if (expense != null) {
        if (expense is Expense) {
          _expenses = [expense, ..._expenses];
        }
        if (expense is WIPExpense) {
          //_wipExpenses are sorted by createdAt ascending, new expense should be last in the list
          _wipExpenses = [..._wipExpenses, expense];
        }
        setState(() {
          updateAllExpenseAndCache();
          //_expenses = [expense, ..._expenses];
        });
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
            subtitle: _mostRecentTransactionUnderTag[tag.id] != null
                ? Row(
                    children: [
                      Text(
                        'To: ${truncateText(_mostRecentTransactionUnderTag[tag.id]?.to ?? 'N/A')}',
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
                  '₹${tag.totalAmountTillDate.round()}',
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

  Future<void> _reloadWIPExpensesOnly() async {
    _wipExpenses = await getAllWIPExpenses();
    setState(() {
      updateAllExpenseAndCache();
    });
  }

  bool loadDataRunning = false;

  // Update _loadData method to also load WIPExpenses:
  Future<void> _loadData() async {
    if (loadDataRunning) return;
    loadDataRunning = true;

    print('Loading fresh data in Home Screen');
    try {
      List<Tag> tags = await Tag.loadTags(_user!);
      updateTagsAndCache(tags);

      _wipExpenses = await getAllWIPExpenses();
      print('Got ${_wipExpenses.length} wipExpenses');

      List<Expense>? expenses = await Expense.getHomeScreenExpenses(_user!);
      if (expenses != null) _expenses = expenses;
      updateAllExpenseAndCache();

      // NEW
    } catch (e, stackTrace) {
      print('Error loading data: $e, $stackTrace');
    } finally {
      if (mounted) {
        setState(() {
          print("inside setState of loadData");
          _isLoading = false;
        });
      }

      if (_messageOnLoad != null) {
        if (mounted) showError(context, _messageOnLoad!);
        _messageOnLoad = null;
      }

      loadDataRunning = false;
    }
  }

  void _openExpenseDetail(BaseExpense expense) async {
    final result = await openExpenseDetail(mounted, context, expense, _expenses);

    if (result != null) {
      _expenses = result;
      setState(() {
        updateAllExpenseAndCache();
        //_expenses = result;
      });
    }
  }

  void _openWIPExpenseDetail(WIPExpense wipExpense) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ExpenseAddEditScreen(baseExpense: wipExpense)),
    );

    // Check if WIPExpense is deleted
    if (result != null && result is Map && result['deleted'] == true) {
      _wipExpenses.removeWhere((e) => e.id == wipExpense.id);
      setState(() => updateAllExpenseAndCache());
      return;
    }

    //WIPExpense is saved as Expense
    if (result is Expense) {
      //replace WIPExpense with Expense .. this will show to user as what expense got updated inplace
      // after loadData() kicks from FCM update, it will take the updated expense down
      List<BaseExpense> wipExpenseListWithExpense = _wipExpenses.map((exp) => exp.id == result.id ? result : exp).toList();
      setState(() {
        updateAllExpenseAndCache(overwriteList: [...wipExpenseListWithExpense, ..._expenses]);
      });
    }

    //no other change in WIPExpense possible .. so nothing else required
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
                  asyncPrefs.remove('_expenses');
                  asyncPrefs.remove('_wipExpenses');
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

  Future<bool> _loadDataFromSharedPreference() async {
    final String? tagJsonString = await asyncPrefs.getString('_tags');
    final String? expenseJsonString = await asyncPrefs.getString('_expenses');
    final String? wipExpenseJsonString = await asyncPrefs.getString('_wipExpenses');

    // if (tagJsonString == null || expenseJsonString == null) {
    //   return false;
    // }

    if (tagJsonString != null) _tags = Tag.jsonDecodeTagsList(tagJsonString);
    if (expenseJsonString != null) _expenses = await Expense.jsonDecodeExpenseList(expenseJsonString);
    if (wipExpenseJsonString != null) {
      _wipExpenses = await WIPExpense.jsonDecodeWIPExpenseList(wipExpenseJsonString);
    }

    if (widget.expenseAsParam != null) {
      //List<BaseExpense> newList = searchAndReplaceExpenseOrAppendIfNotFound(widget.expenseAsParam!);
      _wipExpenses = [..._wipExpenses, widget.expenseAsParam!];
      updateAllExpenseAndCache();
    }

    if (mounted) {
      setState(() {
        print("inside setState of loadDataFromSharedPreference");
        _isLoading = false;
      });
    }

    return true;
  }

  void updateAllExpenseAndCache({List<BaseExpense>? overwriteList}) {
    if (overwriteList != null) {
      _allExpenses = overwriteList;
    } else {
      _allExpenses = [..._wipExpenses, ..._expenses];
    }
    asyncPrefs.setString('_expenses', BaseExpense.jsonEncodeExpensesList(_expenses));
    asyncPrefs.setString('_wipExpenses', BaseExpense.jsonEncodeExpensesList(_wipExpenses));
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

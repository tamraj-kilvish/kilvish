import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:kilvish/cache_manager.dart';
import 'package:kilvish/canny_app_scafold_wrapper.dart';
import 'package:kilvish/expense_add_edit_screen.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/expense_detail_screen.dart';
import 'package:kilvish/firestore_expenses.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/models_tags.dart';
import 'package:kilvish/signup_screen.dart';
import 'package:kilvish/tag_add_edit_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'style.dart';
import 'tag_detail_screen.dart';
import 'models.dart';
import 'fcm_handler.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:package_info_plus/package_info_plus.dart';

class HomeScreen extends StatefulWidget {
  final String? messageOnLoad;
  final WIPExpense? expenseAsParam;
  const HomeScreen({super.key, this.messageOnLoad, this.expenseAsParam});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  late String? _messageOnLoad = widget.messageOnLoad;

  List<Tag> _tags = [];
  List<BaseExpense> _allExpenses = []; // WIPExpenses + Untagged Expenses only
  bool _isLoading = true;
  KilvishUser? _user;
  String _version = "";
  WIPExpense? _expenseAsParam;

  static StreamSubscription<String>? _refreshSubscription;
  final asyncPrefs = SharedPreferencesAsync();

  static bool isFcmServiceInitialized = false;

  // Sync from SharedPreferences cache
  Future<bool> _syncFromCache() async {
    print('_syncFromCache: Loading from SharedPreferences');
    final cached = await loadHomeScreenStateFromSharedPref();

    if (cached != null) {
      _allExpenses = cached['allExpenses'];
      _tags = cached['tags'];

      if (_expenseAsParam != null) {
        _allExpenses.insert(0, _expenseAsParam as BaseExpense);
        _expenseAsParam = null;
      }

      if (mounted) {
        setState(() {
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

    if (_messageOnLoad != null && mounted) {
      showError(context, _messageOnLoad!);
      _messageOnLoad = null;
    }

    getLoggedInUserData().then((KilvishUser? user) async {
      if (user == null) {
        await _logout();
        return;
      }
      setState(() {
        _user = user;
      });
      await _syncFromCache();
      await _loadData();
    });

    PackageInfo.fromPlatform().then((value) {
      setState(() {
        _version = value.version;
      });
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
    _refreshSubscription = FCMService.instance.refreshStream.listen((jsonEncodedData) {
      Map<String, dynamic> data = jsonDecode(jsonEncodedData);
      print('HomeScreen: Received refresh eventType: ${data['type']}');

      _syncFromCache().then((_) {
        FCMService.instance.markDataRefreshed();
      });
    });
  }

  // Update local state after user action
  void _updateLocalState(BaseExpense expense, {bool isNew = false, bool isDeleted = false}) {
    if (isDeleted) {
      _allExpenses.removeWhere((e) => e.id == expense.id);
    } else if (isNew) {
      _allExpenses.insert(0, expense);
    } else {
      _allExpenses = _allExpenses.map((e) => e.id == expense.id ? expense : e).toList();
    }

    setState(() {});
    _saveExpensesToCacheInBackground();
  }

  Timer? timer;
  bool rescheduleWIPExpenseRefreshOnceMore = false;
  void _scheduleWIPExpensesRefresh() {
    // if already scheduled, simply return .. do not reschedule for later
    if (timer != null && timer!.isActive) {
      rescheduleWIPExpenseRefreshOnceMore = true;
      return;
    }

    timer = Timer(Duration(seconds: 30), () async {
      List<WIPExpense> freshWIPExpenses = await getAllWIPExpenses();
      bool updatesFound = false;

      Map<String, WIPExpense> freshWIPMap = {for (var wip in freshWIPExpenses) wip.id: wip};

      _allExpenses = _allExpenses.map((expense) {
        if (expense is! WIPExpense) return expense;

        WIPExpense? freshWIPExpense = freshWIPMap[expense.id];
        if (freshWIPExpense == null) return expense; // WIPExpense no longer exists

        if (expense.status != freshWIPExpense.status || expense.errorMessage != freshWIPExpense.errorMessage) {
          updatesFound = true;
          return freshWIPExpense;
        }

        return expense;
      }).toList();

      if (updatesFound && mounted) {
        setState(() {});
        _saveExpensesToCacheInBackground();
      }

      if (rescheduleWIPExpenseRefreshOnceMore) {
        rescheduleWIPExpenseRefreshOnceMore = false;
        _scheduleWIPExpensesRefresh();
      }
    });
  }

  Future<void> _saveExpensesToCacheInBackground() async {
    try {
      await asyncPrefs.setString('_allExpenses', BaseExpense.jsonEncodeExpensesList(_allExpenses));
      print('_saveToCacheInBackground: Cache saved');
    } catch (e) {
      print('_saveToCacheInBackground: Error $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffoldWrapper(
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
            onPressed: () async {
              await _logout();
            },
          ),
        ],
      ),
      body: _isLoading ? Center(child: CircularProgressIndicator(color: primaryColor)) : _buildHomeList(),
      floatingActionButton: FloatingActionButton(
        backgroundColor: primaryColor,
        onPressed: () => _showAddOptions(context),
        child: Icon(Icons.add, color: kWhitecolor),
      ),
    );
  }

  void _showAddOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return SafeArea(
          child: Wrap(
            // Wrap makes the height fit the content
            children: [
              ListTile(
                leading: Icon(Icons.receipt_long, color: primaryColor),
                title: const Text('Add Expense'),
                onTap: () {
                  Navigator.pop(context); // Close sheet
                  _addNewExpense(); // Move your expense logic here
                },
              ),
              ListTile(
                leading: Icon(Icons.local_offer, color: primaryColor),
                title: const Text('Add Tag'),
                onTap: () {
                  Navigator.pop(context); // Close sheet
                  _addNewTag();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _addNewTag() async {
    Navigator.push(context, MaterialPageRoute(builder: (context) => TagAddEditScreen())).then((value) {
      Tag? tag = value as Tag?;
      if (tag != null) {
        setState(() {
          updateTagsAndCache([tag, ..._tags]);
        });
      }
    });
  }

  void _addNewExpense() async {
    WIPExpense? wipExpense = await createWIPExpense();
    if (wipExpense == null) {
      showError(context, "Failed to create WIPExpense");
      return;
    }
    Map<String, dynamic>? result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ExpenseAddEditScreen(baseExpense: wipExpense)),
    );

    if (result != null && result['expense'] is BaseExpense) {
      _updateLocalState(result['expense'] as BaseExpense, isNew: true);
    }
  }

  Widget _buildHomeList() {
    if (_allExpenses.isEmpty && _tags.isEmpty) {
      return _buildEmptyState();
    }

    // Separate expenses by type
    final wipExpenses = _allExpenses.whereType<WIPExpense>().toList();
    final untaggedExpenses = _allExpenses.whereType<Expense>().toList();

    return ListView.builder(
      itemCount: wipExpenses.length + untaggedExpenses.length + _tags.length,
      itemBuilder: (context, index) {
        // WIPExpenses section
        if (index < wipExpenses.length) {
          return _renderWIPExpenseTile(wipExpenses[index]);
        }

        // Untagged Expenses section
        int untaggedIndex = index - wipExpenses.length;
        if (untaggedIndex < untaggedExpenses.length) {
          return renderExpenseTile(
            expense: untaggedExpenses[untaggedIndex],
            onTap: () => _openExpenseDetail(untaggedExpenses[untaggedIndex]),
            showTags: true,
          );
        }

        // Tags section (includes recovery tags with allowRecovery=true)
        if (_tags.isEmpty) return SizedBox.shrink();

        int tagIndex = index - wipExpenses.length - untaggedExpenses.length;
        return renderTagTile(tag: _tags[tagIndex]);
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'No expenses yet',
              style: TextStyle(fontSize: largeFontSize, color: primaryColor, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            Image.asset("assets/images/insert-expense-lifecycle.png", width: double.infinity, height: 250, fit: BoxFit.contain),
            const SizedBox(height: 32),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildStep('1', 'Navigate to UPI app'),
                  _buildStep('2', 'Select a transaction from history'),
                  _buildStep('3', 'Click on Share Receipt'),
                  _buildStep('4', 'Select Kilvish by going to More (3 dots)'),
                  _buildStep('5', 'Kilvish will extract details and show them here'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _renderWIPExpenseTile(WIPExpense wipExpense) {
    if (wipExpense.status != ExpenseStatus.readyForReview) _scheduleWIPExpensesRefresh();

    // Get all tag names from both regular tags and settlement tags
    Set<Tag> tags = {};
    for (var tag in wipExpense.tags) {
      tags.add(tag);
    }
    for (var settlement in wipExpense.settlements) {
      final tag = _tags.firstWhere(
        (t) => t.id == settlement.tagId,
        orElse: () => Tag(
          id: settlement.tagId!,
          name: 'Unknown Tag',
          ownerId: '',
          totalTillDate: {},
          userWiseTotal: {},
          monthWiseTotal: {},
          link: "kilvish://tag/${settlement.tagId!}",
        ),
      );
      tags.add(tag);
    }

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
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              renderAttachmentsDisplay(
                expenseTags: wipExpense.tags,
                settlements: wipExpense.settlements,
                allUserTags: _tags,
                showEmptyState: false,
              ),
              Text(
                wipExpense.errorMessage != null && wipExpense.errorMessage!.isNotEmpty
                    ? wipExpense.errorMessage!
                    : wipExpense.getStatusDisplayText(),
                style: TextStyle(fontSize: smallFontSize, color: wipExpense.getStatusColor(), fontWeight: FontWeight.w600),
              ),
            ],
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (wipExpense.amount != null)
                Text(
                  'Ã¢â€šÂ¹${wipExpense.amount!.round()}',
                  style: TextStyle(fontSize: largeFontSize, color: kTextColor, fontWeight: FontWeight.bold),
                )
              else
                Text(
                  'Ã¢â€šÂ¹--',
                  style: TextStyle(fontSize: largeFontSize, color: inactiveColor),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget renderTagTile({required Tag tag}) {
    final unreadCount = _getUnseenCountForTag(tag);

    // Different styling for Recovery vs Tag
    final bool isRecovery = tag.isRecovery;
    final backgroundColor = isRecovery ? errorcolor : primaryColor;
    final icon = isRecovery ? Icons.account_balance_wallet : Icons.local_offer;
    final amountToShow = isRecovery ? tag.totalTillDate['recovery'] ?? '0' : tag.totalAmountTillDate;
    final amountLabel = isRecovery ? 'pending' : null;

    return Column(
      children: [
        const Divider(height: 1),
        ListTile(
          tileColor: tileBackgroundColor,
          leading: Stack(
            children: [
              CircleAvatar(
                backgroundColor: backgroundColor,
                radius: 20,
                child: Icon(icon, color: kWhitecolor, size: 20),
              ),
              if (unreadCount > 0)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: errorcolor,
                      shape: BoxShape.circle,
                      border: Border.all(color: tileBackgroundColor, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$unreadCount',
                      style: TextStyle(color: kWhitecolor, fontSize: 8, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
            ],
          ),
          onTap: () => _openTagDetail(tag),
          title: Container(
            margin: const EdgeInsets.only(bottom: 5),
            child: Text(
              tag.name,
              style: TextStyle(fontSize: defaultFontSize, color: kTextColor, fontWeight: FontWeight.w500),
            ),
          ),
          subtitle: tag.mostRecentExpense != null
              ? Text(
                  'Last: ${truncateText(tag.mostRecentExpense!.to)}',
                  style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
                )
              : null,
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '₹$amountToShow',
                style: TextStyle(
                  fontSize: largeFontSize,
                  color: isRecovery ? errorcolor : kTextColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (amountLabel != null)
                Text(
                  amountLabel,
                  style: TextStyle(fontSize: xsmallFontSize, color: kTextMedium),
                ),
              if (tag.mostRecentExpense != null && !isRecovery)
                Text(
                  '🕐 ${formatRelativeTime(tag.mostRecentExpense!.timeOfTransaction)}',
                  style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStep(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$number. ',
            style: TextStyle(fontSize: smallFontSize, color: primaryColor, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: smallFontSize, color: inactiveColor, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  bool loadDataRunning = false;

  Future<void> _loadData() async {
    if (loadDataRunning) return;
    loadDataRunning = true;

    print('Loading fresh data in Home Screen');
    try {
      final freshData = await loadFromScratch(_user!);

      if (mounted) {
        setState(() {
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
    //User can potentially convert an Expense to WIPExpense via ExpenseDetail -> AddEditExpense
    // hence return type is put as BaseExpense & not Expense
    Map<String, dynamic>? result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ExpenseDetailScreen(expense: expense)),
    );

    if (result == null) {
      //user clicked back too quickly
      return;
    }

    BaseExpense? returnedExpense = result['expense'];

    if (returnedExpense == null) {
      //expense deleted
      _updateLocalState(expense, isDeleted: true);
      return;
    }

    // If expense now has tags, remove from untagged list
    if (returnedExpense is Expense && returnedExpense.tags.isNotEmpty) {
      _updateLocalState(expense, isDeleted: true);

      // updating in Tag's expense cache so that the expense is visible as soon as user navigate to the tag.
      for (Tag tag in returnedExpense.tags) {
        updateTagExpensesCache(tag.id, "expense_created", returnedExpense.id, returnedExpense);
      }
      return;
    }

    // user converted Expense to WIPExpense to edit.
    if (returnedExpense is WIPExpense) {
      _updateLocalState(returnedExpense, isNew: true);
      return;
    }

    //expense maybe updated .. re-render
    _updateLocalState(returnedExpense);
  }

  void _openWIPExpenseDetail(WIPExpense wipExpense) async {
    Map<String, dynamic>? result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ExpenseAddEditScreen(baseExpense: wipExpense)),
    );
    if (result == null) {
      //user pressed back too soon
      return;
    }

    BaseExpense? newExpense = result['expense'];

    if (newExpense == null) {
      //expense is deleted
      _updateLocalState(wipExpense, isDeleted: true);
      return;
    }

    if (newExpense is Expense) {
      // Check if new expense has tags
      if (newExpense.tags.isNotEmpty) {
        // Has tags - just remove WIPExpense from list
        _updateLocalState(wipExpense, isDeleted: true);

        // updating in Tag's expense cache so that the expense is visible as soon as user navigate to the tag.
        for (Tag tag in newExpense.tags) {
          updateTagExpensesCache(tag.id, "expense_created", newExpense.id, newExpense);
        }
      } else {
        // No tags - replace WIPExpense with Expense
        _updateLocalState(newExpense, isNew: false);
      }
    }

    if (newExpense is WIPExpense) {
      //mostly user has pressed back button .. save WIPExpense data
      _updateLocalState(newExpense);
    }
  }

  Future<void> _openTagDetail(Tag tag) async {
    Map<String, dynamic>? result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => TagDetailScreen(tag: tag)),
    );

    if (result == null) {
      //user came back too quickly .. do nothing
      return;
    }

    if (result['tag'] == null) {
      // _tags.removeWhere((e) => e.id == tag.id);
      // setState(() {
      //   updateTagsAndCache([..._tags]);
      // });

      //load data from scratch as tag's expenses may become available on home screen
      setState(() {
        _isLoading = true;
      });
      await _loadData();
      return;
    }

    Tag updatedTag = result['tag'];
    List<Tag> newTags = _tags.map((tag) => tag.id == updatedTag.id ? updatedTag : tag).toList();

    setState(() {
      updateTagsAndCache(newTags);
    });

    if (result['updatedExpenses'] != null &&
        result['updatedExpenses'] is List<BaseExpense> &&
        (result['updatedExpenses'] as List<BaseExpense>).isNotEmpty) {
      print("Got updated expenses in home screen from TagDetail");

      for (BaseExpense baseExpense in result['updatedExpenses']) {
        if (baseExpense is Expense && baseExpense.isAttachedAnywhere) {
          // if visible, then remove
          _allExpenses.removeWhere((expense) => expense.id == baseExpense.id);
        }
        if (baseExpense is Expense && !baseExpense.isAttachedAnywhere) {
          //if not visible, add to the list
          if (!_allExpenses.any((e) => e.id == baseExpense.id)) {
            _allExpenses.insert(0, baseExpense);
          }
        }
      }
      setState(() {
        _allExpenses = [..._allExpenses];
      });
      _saveExpensesToCacheInBackground();
    }
  }

  Future<void> _logout() async {
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
                Navigator.pop(context);
                setState(() {
                  _isLoading = true;
                });

                final userId = await getUserIdFromClaim();
                await _auth.signOut();
                try {
                  asyncPrefs.remove('_tags');
                  asyncPrefs.remove('_allExpenses');
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

  int _getUnseenCountForTag(Tag tag) {
    try {
      return tag.unseenExpenseCount;
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
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    _refreshSubscription?.cancel();
    super.dispose();
  }
}

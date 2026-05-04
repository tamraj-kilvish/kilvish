import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
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
  List<WIPExpense> _wipExpenses = [];
  List<Expense> _myExpenses = [];
  Map<String, Map<String, UserMonetaryData>> _resolvedTagUserWise = {};

  bool _isTagsLoading = true;
  bool _isExpensesLoading = true;
  KilvishUser? _user;
  String _version = '';

  static StreamSubscription<String>? _refreshSubscription;
  final _asyncPrefs = SharedPreferencesAsync();
  static bool isFcmServiceInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _tabController = TabController(length: 2, vsync: this);

    if (_messageOnLoad != null && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showError(context, _messageOnLoad!);
        _messageOnLoad = null;
      });
    }

    _init();

    if (!kIsWeb) {
      if (!isFcmServiceInitialized) {
        isFcmServiceInitialized = true;
        FCMService.instance.initialize();
        _startListeningToFCM();
      } else {
        _refreshSubscription?.cancel().whenComplete(_startListeningToFCMListener);
      }
    }
  }

  Future<void> _init() async {
    _version = (await PackageInfo.fromPlatform()).version;
    _user = await getLoggedInUserData();

    // Handle expenseAsParam (from import flow)
    if (widget.expenseAsParam != null) {
      await CacheManager.addOrUpdateWIPExpense(widget.expenseAsParam!);
    }

    await _loadTags();
    await Future.wait([_loadMyExpenses(), _loadWIPExpenses()]);
  }

  Future<void> _loadTags() async {
    try {
      final tags = await CacheManager.loadTags();
      final resolved = <String, Map<String, UserMonetaryData>>{};
      for (final tag in tags) {
        final userWise = <String, UserMonetaryData>{};
        for (final entry in tag.total.userWise.entries) {
          final kilvishId = await getUserKilvishId(entry.key);
          if (kilvishId != null && kilvishId.isNotEmpty) {
            userWise[kilvishId] = entry.value;
          }
        }
        resolved[tag.id] = userWise;
      }
      if (mounted)
        setState(() {
          _tags = tags;
          _resolvedTagUserWise = resolved;
          _isTagsLoading = false;
        });
    } catch (e) {
      print('_loadTags error: $e');
      if (mounted) setState(() => _isTagsLoading = false);
    }
  }

  Future<void> _loadMyExpenses() async {
    try {
      final expenses = await CacheManager.loadMyExpenses();
      _hydrateTagsRuntimeField(expenses, _tags);
      if (mounted)
        setState(() {
          _myExpenses = expenses;
          _isExpensesLoading = false;
        });
    } catch (e) {
      print('_loadMyExpenses error: $e');
      if (mounted) setState(() => _isExpensesLoading = false);
    }
  }

  Future<void> _loadWIPExpenses() async {
    final cached = await CacheManager.loadWIPExpenses();
    if (cached != null && mounted) {
      setState(() => _wipExpenses = cached);
      return;
    }
    try {
      final fresh = await getAllWIPExpenses();
      await CacheManager.saveWIPExpenses(fresh);
      if (mounted) setState(() => _wipExpenses = fresh);
    } catch (e) {
      print('_loadWIPExpenses error: $e');
    }
  }

  void _hydrateTagsRuntimeField(List<BaseExpense> expenses, List<Tag> tagsCache) {
    final tagMap = {for (final t in tagsCache) t.id: t};
    for (final e in expenses) {
      e.tags = e.tagIds.map((id) => tagMap[id]).whereType<Tag>().toSet();
    }
  }

  Future<void> _syncFromCache() async {
    final wipExpenses = await CacheManager.loadWIPExpenses();
    final tags = await CacheManager.loadTags();
    final myExpenses = await CacheManager.loadMyExpenses();
    if (mounted) {
      setState(() {
        _tags = tags;
        if (wipExpenses != null) {
          _hydrateTagsRuntimeField(wipExpenses, tags);
          _wipExpenses = wipExpenses;
        }
        _hydrateTagsRuntimeField(myExpenses, tags);
        _myExpenses = myExpenses;
      });
    }
  }

  void _startListeningToFCM() => _startListeningToFCMListener();

  void _startListeningToFCMListener() {
    _refreshSubscription = FCMService.instance.refreshStream.listen((jsonEncodedData) async {
      print('HomeScreen: Received FCM refresh event');
      await _syncFromCache();
      FCMService.instance.markDataRefreshed();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && !kIsWeb) {
      _asyncPrefs.getBool('needHomeScreenRefresh').then((needRefresh) {
        if (needRefresh == true) {
          _syncFromCache();
          _asyncPrefs.setBool('needHomeScreenRefresh', false);
        }
      });
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
            onPressed: _logout,
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: kWhitecolor,
          labelColor: kWhitecolor,
          unselectedLabelColor: kWhitecolor.withOpacity(0.7),
          tabs: [
            Tab(icon: Icon(Icons.local_offer), text: 'Tags'),
            Tab(icon: Icon(Icons.receipt_long), text: 'My Expenses'),
          ],
        ),
      ),
      body: TabBarView(controller: _tabController, children: [_buildTagsTab(), _buildMyExpensesTab()]),
      floatingActionButton: FloatingActionButton(
        backgroundColor: primaryColor,
        onPressed: _floatingButtonPressed,
        child: Icon(Icons.add, color: kWhitecolor),
      ),
    );
  }

  void _floatingButtonPressed() async {
    if (_tabController.index == 0) {
      _addNewTag();
    } else {
      WIPExpense? wipExpense = await createWIPExpense();
      if (wipExpense == null) {
        showError(context, 'Failed to create expense');
        return;
      }
      await CacheManager.addOrUpdateWIPExpense(wipExpense);
      if (mounted) setState(() => _wipExpenses.insert(0, wipExpense));

      final result = await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => ExpenseAddEditScreen(baseExpense: wipExpense)),
      );
      if (result is Expense) {
        await CacheManager.removeWIPExpense(wipExpense.id);
        await CacheManager.addOrUpdateMyExpense(result);
        if (mounted) {
          setState(() {
            _wipExpenses.removeWhere((w) => w.id == wipExpense.id);
            _myExpenses.insert(0, result);
          });
        }
      }
    }
  }

  Widget _buildTagsTab() {
    return _isTagsLoading && _wipExpenses.isEmpty && _tags.isEmpty
        ? Center(child: CircularProgressIndicator(color: primaryColor))
        : ListView(
            padding: EdgeInsets.all(16),
            children: [
              // WIPExpenses always at top
              ..._wipExpenses.map(_renderWIPExpenseTile),
              if (_wipExpenses.isNotEmpty && _tags.isNotEmpty) SizedBox(height: 8),

              if (_tags.isEmpty && !_isTagsLoading) _buildEmptyTagsPlaceholder() else ..._tags.map((tag) => _buildTagTile(tag)),
            ],
          );
  }

  Widget _buildEmptyTagsPlaceholder() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(
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
      ),
    );
  }

  Widget _buildTagTile(Tag tag) {
    final unreadCount = _myExpenses.where((e) => e.tagIds.contains(tag.id) && e.isUnseen).length;
    final totalRecovery = tag.total.acrossUsers.recovery;
    final hasRecovery = totalRecovery > 0 && !tag.dontShowOutstanding;
    final userWise = _resolvedTagUserWise[tag.id] ?? {};

    Widget? subtitleWidget;
    if (hasRecovery) {
      final participants = userWise.entries
          .where((e) => e.value.recovery != 0)
          .toList()
        ..sort((a, b) => a.value.recovery.compareTo(b.value.recovery)); // owing (negative) first
      if (participants.isNotEmpty) {
        final shown = participants.take(3).map((e) {
          final r = e.value.recovery;
          final amt = NumberFormat.compact().format(r.abs().round());
          return r < 0 ? '@${e.key} owes ₹$amt' : '@${e.key} is owed ₹$amt';
        }).join(', ');
        final suffix = participants.length > 3 ? ' & more' : '';
        subtitleWidget = Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '$shown$suffix',
            style: const TextStyle(fontSize: smallFontSize, color: kTextMedium),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        );
      }
    } else {
      final entries = userWise.entries.toList();
      if (entries.isNotEmpty) {
        final rows = <Widget>[];
        for (int i = 0; i < entries.length && i < 2; i++) {
          final userExpense = NumberFormat.compact().format(entries[i].value.expense.round());
          rows.add(Text('@${entries[i].key}: ₹$userExpense', style: const TextStyle(fontSize: smallFontSize, color: kTextMedium)));
        }
        if (entries.length > 2) {
          rows.add(const Text('& more', style: TextStyle(fontSize: smallFontSize, color: kTextMedium)));
        }
        subtitleWidget = Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
        );
      }
    }

    return Card(
      color: tileBackgroundColor,
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Stack(
          clipBehavior: Clip.none,
          children: [
            CircleAvatar(
              backgroundColor: primaryColor,
              child: Icon(Icons.local_offer, color: kWhitecolor, size: 20),
            ),
            if (unreadCount > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                  child: Text(
                    '$unreadCount',
                    style: const TextStyle(color: kWhitecolor, fontSize: 9, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
          ],
        ),
        title: Text(
          truncateText(tag.name, 20),
          style: TextStyle(fontSize: defaultFontSize, color: kTextColor, fontWeight: FontWeight.w500),
        ),
        subtitle: subtitleWidget,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '₹${tag.formattedExpense}',
              style: const TextStyle(fontSize: smallFontSize, color: kTextColor, fontWeight: FontWeight.bold),
            ),
            if (hasRecovery)
              Text(
                '₹${NumberFormat.compact().format(totalRecovery.round())}',
                style: TextStyle(fontSize: smallFontSize, color: Colors.orange.shade700, fontWeight: FontWeight.w600),
              ),
          ],
        ),
        onTap: () => _openTagDetail(tag),
      ),
    );
  }

  Widget _renderWIPExpenseTile(WIPExpense wipExpense) {
    if (wipExpense.status != ExpenseStatus.readyForReview) _scheduleWIPExpensesRefresh();
    return Column(
      children: [
        const Divider(height: 1),
        ListTile(
          tileColor: primaryColor.withOpacity(0.1),
          leading: CircleAvatar(
            backgroundColor: wipExpense.getStatusColor(),
            child: wipExpense.errorMessage != null && wipExpense.errorMessage!.isNotEmpty
                ? Icon(Icons.error, color: kWhitecolor, size: 20)
                : wipExpense.status == ExpenseStatus.waitingToStartProcessing ||
                      wipExpense.status == ExpenseStatus.uploadingReceipt ||
                      wipExpense.status == ExpenseStatus.extractingData
                ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kWhitecolor))
                : Icon(Icons.receipt_long, color: kWhitecolor, size: 20),
          ),
          onTap: () => _openWIPExpenseDetail(wipExpense),
          title: Text(
            wipExpense.to != null ? 'To: ${truncateText(wipExpense.to!)}' : 'To: -',
            style: TextStyle(fontSize: defaultFontSize, color: kTextColor, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            wipExpense.errorMessage?.isNotEmpty == true ? wipExpense.errorMessage! : wipExpense.getStatusDisplayText(),
            style: TextStyle(fontSize: smallFontSize, color: wipExpense.getStatusColor(), fontWeight: FontWeight.w600),
          ),
          trailing: wipExpense.amount != null
              ? Text(
                  '₹${wipExpense.amount!.round()}',
                  style: TextStyle(fontSize: largeFontSize, color: kTextColor, fontWeight: FontWeight.bold),
                )
              : Text(
                  '₹--',
                  style: TextStyle(fontSize: largeFontSize, color: inactiveColor),
                ),
        ),
      ],
    );
  }

  Widget _buildMyExpensesTab() {
    if (_isExpensesLoading) return Center(child: CircularProgressIndicator(color: primaryColor));

    if (_myExpenses.isEmpty) {
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
              Image.asset('assets/images/insert-expense-lifecycle.png', width: double.infinity, height: 250, fit: BoxFit.contain),
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

    return ListView.builder(
      itemCount: _myExpenses.length,
      itemBuilder: (context, index) {
        final expense = _myExpenses[index];
        return ExpenseTile(expense: expense, onTap: () => _openExpenseDetail(expense));
      },
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

  Timer? _wipRefreshTimer;
  void _scheduleWIPExpensesRefresh() {
    if (_wipRefreshTimer?.isActive == true) return;
    _wipRefreshTimer = Timer(Duration(seconds: 30), () async {
      final fresh = await getAllWIPExpenses();
      await CacheManager.saveWIPExpenses(fresh);
      if (mounted) setState(() => _wipExpenses = fresh);
    });
  }

  void _openExpenseDetail(Expense expense) async {
    final result = await openExpenseDetail(mounted, context, expense, _myExpenses);
    if (result['updatedExpense'] == null) {
      await CacheManager.removeMyExpense(expense.id);
      if (mounted) setState(() => _myExpenses.removeWhere((e) => e.id == expense.id));
    } else {
      final updated = result['updatedExpense'] as Expense;
      await CacheManager.addOrUpdateMyExpense(updated);
      if (mounted) setState(() => _myExpenses = _myExpenses.map((e) => e.id == updated.id ? updated : e).toList());
    }
  }

  void _openWIPExpenseDetail(WIPExpense wipExpense) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ExpenseAddEditScreen(baseExpense: wipExpense)),
    );

    if (result is Map && result['deleted'] == true) {
      await CacheManager.removeWIPExpense(wipExpense.id);
      if (mounted) setState(() => _wipExpenses.removeWhere((w) => w.id == wipExpense.id));
      return;
    }

    if (result is Expense) {
      await CacheManager.removeWIPExpense(wipExpense.id);
      await CacheManager.addOrUpdateMyExpense(result);
      if (mounted) {
        setState(() {
          _wipExpenses.removeWhere((w) => w.id == wipExpense.id);
          _myExpenses.insert(0, result);
        });
      }
      // Reload tags in case a loan payback tag was created during save
      await _loadTags();
    }
  }

  Future<void> _openTagDetail(Tag tag) async {
    final result = await Navigator.push(context, MaterialPageRoute(builder: (context) => TagDetailScreen(tag: tag)));

    if (result is Map && result['deleted'] == true) {
      await CacheManager.removeTag(tag.id);
      final updatedExpenses = await CacheManager.loadMyExpenses(forceReload: true);
      if (mounted) {
        setState(() {
          _tags.removeWhere((t) => t.id == tag.id);
          _hydrateTagsRuntimeField(updatedExpenses, _tags);
          _myExpenses = updatedExpenses;
        });
      }
      return;
    }
    if (result is Tag) {
      await CacheManager.addOrUpdateTag(result);
      final userWise = <String, UserMonetaryData>{};
      for (final entry in result.total.userWise.entries) {
        final kilvishId = await getUserKilvishId(entry.key);
        if (kilvishId != null && kilvishId.isNotEmpty) userWise[kilvishId] = entry.value;
      }
      if (mounted)
        setState(() {
          _tags = _tags.map((t) => t.id == result.id ? result : t).toList();
          _resolvedTagUserWise[result.id] = userWise;
        });
    }
  }

  void _addNewTag() async {
    final result = await Navigator.push(context, MaterialPageRoute(builder: (context) => TagAddEditScreen()));
    final tag = result as Tag?;
    if (tag != null) {
      await CacheManager.addOrUpdateTag(tag);
      if (mounted) setState(() => _tags.insert(0, tag));
    }
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
                Navigator.pop(context);
                await CacheManager.clearAllCache();
                await _auth.signOut();
                Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => SignupScreen()));
              },
              child: Text('Yes', style: TextStyle(color: errorcolor)),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _refreshSubscription?.cancel();
    _wipRefreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

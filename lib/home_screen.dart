import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:kilvish/app_router.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/main.dart';
import 'package:kilvish/web_url.dart';
import 'package:kilvish/canny_app_scafold_wrapper.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models_expense.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'style.dart';
import 'models.dart';
import 'package:package_info_plus/package_info_plus.dart';

class HomeScreen extends StatefulWidget {
  final String? messageOnLoad;

  /// Which tab to show on first render.
  /// 0 = Tags (default), 1 = My Expenses.
  /// Used by the /tags and /expenses GoRoutes so web deep-links land on
  /// the right tab without rebuilding the screen on every tab switch.
  final int initialTabIndex;

  const HomeScreen({super.key, this.messageOnLoad, this.initialTabIndex = 0});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  late TabController _tabController;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  late String? _messageOnLoad = widget.messageOnLoad;

  List<Tag> _tags = [];
  List<Expense> _myExpenses = [];

  bool _isTagsLoading = true;
  bool _isExpensesLoading = true;
  bool _isLoggingOut = false;
  KilvishUser? _user;
  String _version = '';

  StreamSubscription<void>? _myExpensesSub;
  StreamSubscription<void>? _tagListSub;
  final _asyncPrefs = SharedPreferencesAsync();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _tabController = TabController(length: 2, vsync: this, initialIndex: widget.initialTabIndex);

    // Web: keep browser address bar in sync with the active tab.
    // Uses replaceState (not pushState) so tab switching doesn't pollute history.
    if (kIsWeb) {
      _tabController.addListener(_onTabChanged);
    }

    if (_messageOnLoad != null && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showError(context, _messageOnLoad!);
        _messageOnLoad = null;
      });
    }

    _init();

    if (!kIsWeb) {
      _myExpensesSub = CacheManager.myExpensesStream.listen((_) => _loadMyExpenses());
      _tagListSub = CacheManager.tagListStream.listen((_) => _loadTags());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  // ── Web tab ↔ URL sync ────────────────────────────────────────────────────

  /// Called by TabController on every animation tick.
  /// Only updates the URL when the tab has fully settled (not mid-swipe).
  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    _syncTabUrl();
  }

  void _syncTabUrl() {
    setWebUrl(_tabController.index == 0 ? '/tags' : '/expenses');
  }

  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _init() async {
    _version = (await PackageInfo.fromPlatform()).version;

    _user = await getLoggedInUserData();

    // Redirect to signup if kilvish ID not set (e.g. incomplete signup)
    if (_user == null || (_user!.kilvishId?.isEmpty ?? true)) {
      if (mounted) context.go('/signup');
      return;
    }

    updateLastLoginOfUser(_user!.id);

    final stale = await CacheManager.shouldClearCacheForFCMLag();
    if (stale) {
      print('HomeScreen - _init - FCM lag detected, fresh data will be loaded');
      await CacheManager.clearAllCache();
    }

    await _loadTags();
    await _loadMyExpenses();

    if (stale) {
      await updateLastFCMProcessedAt();
    }
  }

  Future<void> _loadTags() async {
    try {
      final tags = await CacheManager.loadTags();

      if (mounted) {
        setState(() {
          _tags = tags;
          _isTagsLoading = false;
        });
      }
    } catch (e) {
      print('_loadTags error: $e');
      if (mounted) setState(() => _isTagsLoading = false);
    }
  }

  Future<void> _loadMyExpenses() async {
    try {
      final expenses = await CacheManager.loadMyExpenses();
      if (mounted) {
        setState(() {
          _myExpenses = expenses;
          _isExpensesLoading = false;
        });
      }
    } catch (e) {
      print('_loadMyExpenses error: $e');
      if (mounted) setState(() => _isExpensesLoading = false);
    }
  }

  Future<void> _syncFromCache() async {
    final tags = await CacheManager.loadTags();
    final myExpenses = await CacheManager.loadMyExpenses();
    if (mounted) {
      setState(() {
        _tags = tags;
        _myExpenses = myExpenses;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed && !kIsWeb) {
      _asyncPrefs.getBool('needHomeScreenRefresh').then((needRefresh) {
        if (needRefresh == true) {
          _syncFromCache().whenComplete(() {
            _asyncPrefs.setBool('needHomeScreenRefresh', false);
          });
        }
      });
    }
  }

  /// Called by GoRouter's RouteObserver when a screen pushed on top of HomeScreen is popped.
  /// (1) Check if there are pending WIP expenses or pending imports — if so, send to BulkImport.
  /// (2) Otherwise, check for FCM lag and refresh from Firestore only if stale.
  @override
  void didPopNext() async {
    //we need this as if user navigates to AddEditExpense screen, does not complete, press back & come back to home, they should be sent to bulk-import screen
    if (!mounted) return;

    if (await navigateToBulkImportIfRequired()) return;

    final stale = await CacheManager.shouldClearCacheForFCMLag();
    if (stale) {
      print('HomeScreen - didPopNext() - FCM lag detected, fresh data will be loaded');
      await CacheManager.clearAllCache();
      await _loadTags();
      await _loadMyExpenses();
      await updateLastFCMProcessedAt();
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
          if (_isLoggingOut)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: kWhitecolor, strokeWidth: 2)),
              ),
            )
          else
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

      final result = await context.push<Map<String, dynamic>>('/expenses/${wipExpense.id}/edit', extra: wipExpense);

      if (result != null && result["expense"] is Expense && mounted) {
        setState(() => _myExpenses.insert(0, result["expense"] as Expense));
        await _loadTags();
      }
    }
  }

  Widget _buildTagsTab() {
    return _isTagsLoading && _tags.isEmpty
        ? Center(child: CircularProgressIndicator(color: primaryColor))
        : ListView(
            padding: EdgeInsets.all(16),
            children: [
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
    final unreadCount = tag.unseenCount;
    final totalRecovery = tag.total.acrossUsers.recovery;
    final hasRecovery = totalRecovery > 0 && !tag.dontShowOutstanding;

    Widget? subtitleWidget = Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        tag.getTagTileSummary(),
        style: const TextStyle(fontSize: smallFontSize, color: kTextMedium),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );

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
                    style: const TextStyle(color: kWhitecolor, fontSize: xsmallFontSize, fontWeight: FontWeight.bold),
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
                style: TextStyle(fontSize: smallFontSize, color: outstandingColor, fontWeight: FontWeight.w600),
              ),
          ],
        ),
        onTap: () => _openTagDetail(tag),
      ),
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
        return renderExpenseTile(expense: expense, onTap: () => _openExpenseDetail(expense), showTags: true);
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

  void _openExpenseDetail(Expense expense) async {
    final result = await context.push<Map<String, dynamic>>('/expenses/${expense.id}', extra: expense);
    if (result == null) return;

    if (result["expense"] is Expense && mounted) {
      final updated = result["expense"] as Expense;
      setState(() => _myExpenses = _myExpenses.map((e) => e.id == updated.id ? updated : e).toList());
    } else if (result["expense"] is WIPExpense && mounted) {
      setState(() => _myExpenses.removeWhere((e) => e.id == expense.id));
      context.go('/bulk-import');
    } else if (result["expense"] == null && mounted) {
      setState(() => _myExpenses.removeWhere((e) => e.id == expense.id));
    }
  }

  Future<void> _openTagDetail(Tag tag) async {
    final result = await context.push<Map<String, dynamic>>('/tags/${tag.id}', extra: tag);
    if (result == null) return;

    // Fix: tag detail pops with {'operation': 'delete', 'tag': null} on delete
    if (result['operation'] == 'delete') {
      final updatedExpenses = await CacheManager.loadMyExpenses(forceReload: true);
      if (mounted) {
        setState(() {
          _tags.removeWhere((t) => t.id == tag.id);
          _myExpenses = updatedExpenses;
        });
      }
      return;
    }
    if (result['tag'] is Tag) {
      await _loadTags();
    }
  }

  void _addNewTag() async {
    final result = await context.push<Map<String, dynamic>>('/tags/new');
    if (result == null) return;

    if (result["tag"] is Tag) {
      await _loadTags();
    }
  }

  void _logout() async {
    final confirmed = await showDialog<bool>(
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
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancel', style: TextStyle(color: kTextMedium)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Yes', style: TextStyle(color: errorcolor)),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    setState(() => _isLoggingOut = true);
    await CacheManager.clearAllCache();
    await clearFirestorePersistence();
    // signOut() triggers _AuthNotifier → GoRouter redirects to '/signup'.
    // No explicit navigation needed here.
    await _auth.signOut();
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    if (kIsWeb) _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _myExpensesSub?.cancel();
    _tagListSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/canny_app_scafold_wrapper.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/receipt_section.dart';
import 'package:kilvish/tag_links_section.dart';
import 'style.dart';

class ExpenseDetailScreen extends StatefulWidget {
  /// Expense object — provided for in-app navigation (always available).
  final Expense? expense;

  /// Expense ID — provided for GoRouter cold-load (e.g. /expenses/:id).
  final String? expenseId;

  /// Tag ID — provided when navigated from a TagDetailScreen, or for
  /// /tags/:tagId/expense/:expenseId cold-load. Determines which Firestore
  /// path is used when fetching and affects the browser URL.
  final String? tagId;

  const ExpenseDetailScreen({super.key, this.expense, this.expenseId, this.tagId})
    : assert(expense != null || expenseId != null, 'Either expense or expenseId must be provided');

  @override
  State<ExpenseDetailScreen> createState() => _ExpenseDetailScreenState();
}

class _ExpenseDetailScreenState extends State<ExpenseDetailScreen> {
  Expense? _expense;
  bool _isLoading = false;
  bool _hasError = false;
  bool _isExpenseOwner = false;
  String? _currentUserId;
  bool _isExpenseUpdated = false;

  @override
  void initState() {
    super.initState();
    if (widget.expense != null) {
      _expense = widget.expense;
      _runSideEffects();
    } else {
      _isLoading = true;
      _fetchExpense();
    }
  }

  /// Fetches the expense from Firestore for GoRouter cold-load paths.
  /// Uses the tag sub-collection when [widget.tagId] is present so that
  /// tagLink data is correctly hydrated.
  Future<void> _fetchExpense() async {
    try {
      final expense = widget.tagId != null
          ? await getTagExpense(widget.tagId!, widget.expenseId!)
          : await getExpense(widget.expenseId!);
      if (!mounted) return;
      if (expense == null) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
        return;
      }
      setState(() {
        _expense = expense;
        _isLoading = false;
      });
      _runSideEffects();
    } catch (e) {
      if (mounted)
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
    }
  }

  /// Side effects that run once [_expense] is available — mark seen,
  /// resolve ownership, resolve current user ID.
  void _runSideEffects() {
    if (_expense!.isUnseen) {
      CacheManager.markExpenseSeen(_expense!).then((_) {
        if (mounted) setState(() => _expense!.isUnseen = false);
      });
    }

    _expense!.isExpenseOwner().then((bool isOwner) {
      if (isOwner && mounted) setState(() => _isExpenseOwner = true);
    });

    getUserIdFromClaim().then((id) {
      if (mounted) setState(() => _currentUserId = id);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(backgroundColor: primaryColor, leading: const BackButton()),
        body: Center(child: CircularProgressIndicator(color: primaryColor)),
      );
    }

    if (_hasError || _expense == null) {
      return Scaffold(
        appBar: AppBar(backgroundColor: primaryColor, leading: const BackButton()),
        body: const Center(child: Text('Failed to load expense. You might not have permission to view this Expense.')),
      );
    }

    return AppScaffoldWrapper(
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: Text(
          'Expense Details',
          style: TextStyle(color: kWhitecolor, fontSize: titleFontSize, fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: kWhitecolor),
          onPressed: () {
            print("Sending user from ExpenseDetail to parent with _expense copy");
            if (_isExpenseUpdated) {
              Navigator.pop(context, {"operation": "update", "expense": _expense});
            } else {
              Navigator.pop(context);
            }
          },
        ),
        actions: [
          if (_isExpenseOwner == true) ...[
            IconButton(
              icon: Icon(Icons.edit, color: kWhitecolor),
              onPressed: () => _editExpense(context),
            ),
            IconButton(
              icon: Icon(Icons.delete, color: kWhitecolor),
              onPressed: () => _deleteExpense(context),
            ),
          ],
        ],
      ),
      body: SingleChildScrollView(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(30.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(color: primaryColor.withOpacity(0.1), shape: BoxShape.circle),
                  child: Center(
                    child: Text(
                      _getInitial(_expense!.ownerKilvishId),
                      style: TextStyle(fontSize: avatarFontSize, color: primaryColor, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),

                SizedBox(height: 16),

                Text(
                  'Logged By: ${_expense!.ownerKilvishId}',
                  style: TextStyle(fontSize: titleFontSize, color: kTextColor, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),

                SizedBox(height: 16),

                Text(
                  'To: ${_expense!.to}',
                  style: TextStyle(fontSize: largeFontSize, color: kTextMedium),
                  textAlign: TextAlign.center,
                ),

                SizedBox(height: 24),

                Text(
                  '₹${_expense!.amount}',
                  style: TextStyle(fontSize: displayFontSize, color: primaryColor, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),

                SizedBox(height: 16),

                Text(
                  _formatDateTime(_expense!.timeOfTransaction),
                  style: TextStyle(fontSize: largeFontSize, color: kTextMedium),
                  textAlign: TextAlign.center,
                ),

                SizedBox(height: 32),

                // Tags section – cards per tagLink + Add Tag button
                TagLinksSection(
                  expense: _expense!,
                  isExpenseOwner: _isExpenseOwner,
                  currentUserId: _currentUserId,
                  onExpenseUpdated: (newTagLinks) {
                    setState(() {
                      _expense!.tagLinks = newTagLinks;
                      _isExpenseUpdated = true;
                    });
                    print(
                      "ExpenseDetailScreen: Expense updated from TagLinkSection/TagExpenseConfig with taglink count ${newTagLinks.length}",
                    );
                  },
                ),

                SizedBox(height: 32),

                if (_expense!.notes != null && _expense!.notes!.isNotEmpty) ...[
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(color: tileBackgroundColor, borderRadius: BorderRadius.circular(8)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Notes',
                          style: TextStyle(fontSize: defaultFontSize, color: kTextMedium, fontWeight: FontWeight.w600),
                        ),
                        SizedBox(height: 8),
                        Text(
                          _expense!.notes!,
                          style: TextStyle(fontSize: largeFontSize, color: kTextColor),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 32),
                ],

                ReceiptSection(expense: _expense!, isOwner: _isExpenseOwner, isExpenseEdit: false),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _getInitial(String name) {
    if (name.isEmpty) return '?';
    return name[0].toUpperCase();
  }

  String _formatDateTime(dynamic timestamp) {
    if (timestamp == null) return 'No date';

    DateTime date;
    if (timestamp is Timestamp) {
      date = timestamp.toDate();
    } else if (timestamp is DateTime) {
      date = timestamp;
    } else {
      return 'Invalid date';
    }

    return DateFormat('MMM d, yyyy, h:mm a').format(date);
  }

  void _editExpense(BuildContext context) async {
    final path = widget.tagId != null
        ? '/tags/${widget.tagId}/expenses/${_expense!.id}/edit'
        : '/expenses/${_expense!.id}/edit';
    final result = await context.push<Map<String, dynamic>>(path, extra: _expense!);

    if (result == null) return;

    if (result is Map && result["expense"] is Expense) {
      setState(() {
        _expense = result["expense"];
        _isExpenseUpdated = true;
      });
      print("ExpenseDetailScreen: Expense object updated after coming from AddEditExpense screen");
      return;
    }

    if (Navigator.of(context).canPop()) {
      print(
        "ExpenseDetailScreen: Returning from AddEditExpense but expense is either deleted or converted to WIP .. sending user to parent",
      );
      Navigator.pop(context, result);
      return;
    }

    showError(context, "Something went wrong, sending you home");
    context.go('/');
  }

  void _deleteExpense(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Delete Expense', style: TextStyle(color: kTextColor)),
          content: Text('Are you sure you want to delete this expense?', style: TextStyle(color: kTextMedium)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: TextStyle(color: kTextMedium)),
            ),
            TextButton(
              onPressed: () async {
                final navigator = Navigator.of(context, rootNavigator: true);

                Navigator.pop(context);

                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (BuildContext loadingContext) {
                    return PopScope(
                      canPop: false,
                      child: AlertDialog(
                        content: Row(
                          children: [
                            CircularProgressIndicator(color: primaryColor),
                            SizedBox(width: 20),
                            Text('Deleting expense...'),
                          ],
                        ),
                      ),
                    );
                  },
                );

                try {
                  await deleteExpense(_expense!);
                  await CacheManager.removeMyExpense(_expense!.id);
                  await CacheManager.removeExpenseFromTagCachesIfCached(_expense!.tagIds, _expense!.id);
                  print(
                    '[ExpenseDetailScreen] deleteExpense - removed ${_expense!.id} from MyExpense & Tag expense cache of tagids - ${inspect(_expense!.tagIds)} ',
                  );

                  if (mounted) navigator.pop();
                  if (mounted) navigator.pop({'operation': 'delete', 'expense': null});
                } catch (error, stackTrace) {
                  print("Error in delete expense $error, $stackTrace");
                  if (mounted) navigator.pop(context);
                  if (mounted) showError(context, "Error deleting expense: $error");
                }
              },
              child: Text('Delete', style: TextStyle(color: errorcolor)),
            ),
          ],
        );
      },
    );
  }
}

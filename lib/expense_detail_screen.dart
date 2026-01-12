import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/canny_app_scafold_wrapper.dart';
import 'package:kilvish/expense_add_edit_screen.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/home_screen.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/tag_selection_screen.dart';
import 'style.dart';

class ExpenseDetailScreen extends StatefulWidget {
  final Expense expense;

  const ExpenseDetailScreen({super.key, required this.expense});

  @override
  State<ExpenseDetailScreen> createState() => _ExpenseDetailScreenState();
}

class _ExpenseDetailScreenState extends State<ExpenseDetailScreen> {
  late Expense _expense;
  bool _isExpenseOwner = false;
  bool _areTagsUpdated = false;
  String? _receiptUrl;

  @override
  void initState() {
    super.initState();
    _expense = widget.expense;
    // If tags are empty, fetch them
    if (_expense.tags.isEmpty) {
      getExpenseTags(_expense.id).then(
        (List<Tag>? tags) => {
          if (tags != null && tags.isNotEmpty) {setState(() => _expense.tags.addAll(tags))},
        },
      );
    }
    _expense.isExpenseOwner().then((bool isOwner) {
      if (isOwner == true) setState(() => _isExpenseOwner = true);
    });
  }

  Future<void> _openTagSelection() async {
    if (_isExpenseOwner == false) {
      if (mounted) showError(context, "Tag editing is only for the owner of the expense");
      return;
    }

    print("Calling TagSelectionScreen with ${_expense.id}");
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TagSelectionScreen(initialSelectedTags: _expense.tags, expense: _expense),
      ),
    );
    print("ExpenseDetailScreen: Back from TagSelection with result $result");

    if (result != null && result is Set<Tag>) {
      _areTagsUpdated = true;
      setState(() {
        _expense.tags = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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
            print("Sending user from ExpenseDetail to parent with _expense $_expense");
            Navigator.pop(context, _expense);
          }, //if expense is updated, pass updated expense to home screen
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
                // Recipient name with icon
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(color: primaryColor.withOpacity(0.1), shape: BoxShape.circle),
                  child: Center(
                    child: Text(
                      _getInitial(_expense.ownerKilvishId!),
                      style: TextStyle(fontSize: 32, color: primaryColor, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),

                SizedBox(height: 16),

                // To field
                Text(
                  'Logged By: ${_expense.ownerKilvishId!}',
                  style: TextStyle(fontSize: 20, color: kTextColor, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),

                SizedBox(height: 16),
                // Date and time
                Text(
                  'To: ${_expense.to}',
                  style: TextStyle(fontSize: 16, color: kTextMedium),
                  textAlign: TextAlign.center,
                ),

                SizedBox(height: 24),

                // Amount (big font)
                Text(
                  '₹${_expense.amount}',
                  style: TextStyle(fontSize: 48, color: primaryColor, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),

                SizedBox(height: 16),

                // Date and time
                Text(
                  _formatDateTime(_expense.timeOfTransaction),
                  style: TextStyle(fontSize: 16, color: kTextMedium),
                  textAlign: TextAlign.center,
                ),

                SizedBox(height: 32),

                // Tags
                Text(
                  'Tags (tap to edit)',
                  style: TextStyle(fontSize: 14, color: kTextMedium, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 8),
                Align(
                  alignment: Alignment.center,
                  child: GestureDetector(
                    onTap: _openTagSelection,
                    child: renderTagGroup(tags: _expense.tags),
                  ),
                ),
                SizedBox(height: 32),
                // Notes (if any)
                if (_expense.notes != null && _expense.notes!.isNotEmpty) ...[
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(color: tileBackgroundColor, borderRadius: BorderRadius.circular(8)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Notes',
                          style: TextStyle(fontSize: 14, color: kTextMedium, fontWeight: FontWeight.w600),
                        ),
                        SizedBox(height: 8),
                        Text(_expense.notes!, style: TextStyle(fontSize: 16, color: kTextColor)),
                      ],
                    ),
                  ),
                  SizedBox(height: 32),
                ],

                // Receipt image (if any)
                if (_expense.receiptUrl != null && _expense.receiptUrl!.isNotEmpty) ...[
                  buildReceiptSection(
                    initialText: "Tap to load receipt",
                    processingText: "loading receipt ..",
                    receiptUrl: _receiptUrl,
                    mainFunction: () {
                      setState(() {
                        _receiptUrl = _expense.receiptUrl;
                      });
                    },
                    isProcessingImage: false,
                  ),
                ],
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

    // Format: Dec 9, 2021, 6:27 PM
    return DateFormat('MMM d, yyyy, h:mm a').format(date);
  }

  void _editExpense(BuildContext context) async {
    BaseExpense? updatedExpense = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ExpenseAddEditScreen(baseExpense: _expense)),
    );

    if (updatedExpense != null) {
      if (updatedExpense is Expense) {
        setState(() {
          _expense = updatedExpense;
        });
        return;
      }
      // possibly WIPExpense, send to parent
      if (Navigator.of(context).canPop()) {
        Navigator.pop(context, updatedExpense);
        return;
      }

      showError(context, "Something is wrong, you should not be here, sending you to home screen");
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => HomeScreen()));
      return;
    }
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

                Navigator.pop(context); // Close confirmation dialog

                // Show non-dismissible loading dialog
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
                  await deleteExpense(widget.expense);

                  // Close loading dialog
                  if (mounted) navigator.pop();
                  // Close expense detail screen with result
                  if (mounted) navigator.pop({'deleted': true, 'expense': _expense});
                } catch (error, stackTrace) {
                  print("Error in delete expense $error, $stackTrace");
                  // Close loading dialog
                  if (mounted) navigator.pop(context);

                  // Show error
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

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:kilvish/expense_add_edit_screen.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/tag_selection_screen.dart';
import 'style.dart';

class ExpenseDetailScreen extends StatefulWidget {
  final Expense expense;

  const ExpenseDetailScreen({Key? key, required this.expense}) : super(key: key);

  @override
  State<ExpenseDetailScreen> createState() => _ExpenseDetailScreenState();
}

class _ExpenseDetailScreenState extends State<ExpenseDetailScreen> {
  late Expense _expense;

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
  }

  Future<void> _openTagSelection() async {
    print("Calling TagSelectionScreen with ${_expense.id}");
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TagSelectionScreen(initialSelectedTags: _expense.tags, expenseId: _expense.id),
      ),
    );

    if (result != null && result is Set<Tag>) {
      setState(() {
        _expense.tags = result;
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
          'Expense Details',
          style: TextStyle(color: kWhitecolor, fontSize: titleFontSize, fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: kWhitecolor),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.edit, color: kWhitecolor),
            onPressed: () => _editExpense(context),
          ),
          IconButton(
            icon: Icon(Icons.delete, color: kWhitecolor),
            onPressed: () => _deleteExpense(context),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(30.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Recipient name with icon
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(color: primaryColor.withOpacity(0.1), shape: BoxShape.circle),
                  child: Center(
                    child: Text(
                      _getInitial(_expense.to),
                      style: TextStyle(fontSize: 32, color: primaryColor, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),

                SizedBox(height: 16),

                // To field
                Text(
                  'To ${_expense.to}',
                  style: TextStyle(fontSize: 20, color: kTextColor, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),

                SizedBox(height: 24),

                // Amount (big font)
                Text(
                  '₹${_expense.amount}',
                  style: TextStyle(fontSize: 48, color: primaryColor, fontWeight: FontWeight.bold),
                ),

                SizedBox(height: 16),

                // Date and time
                Text(_formatDateTime(_expense.timeOfTransaction), style: TextStyle(fontSize: 16, color: kTextMedium)),

                SizedBox(height: 32),

                // Tags
                Text(
                  'Tags',
                  style: TextStyle(fontSize: 14, color: kTextMedium, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 8),
                GestureDetector(
                  onTap: _openTagSelection,
                  child: renderTagGroup(tags: _expense.tags),
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
                  Text(
                    'Receipt',
                    style: TextStyle(fontSize: 14, color: kTextMedium, fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: primaryColor, // Border color
                        width: 2.0, // Border width
                      ),
                      borderRadius: BorderRadius.circular(10.0), // Optional: for rounded corners
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        _expense.receiptUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            height: 200,
                            color: Colors.grey[300],
                            child: Center(child: Icon(Icons.error, color: Colors.red)),
                          );
                        },
                      ),
                    ),
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

  void _editExpense(BuildContext context) {
    Navigator.push(context, MaterialPageRoute(builder: (context) => AddEditExpenseScreen(expense: _expense)));
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
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context); // Go back to previous screen
                if (mounted) {
                  showInfo(context, 'Delete expense feature coming soon');
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

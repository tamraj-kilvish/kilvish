import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'style.dart';

class ExpenseDetailScreen extends StatelessWidget {
  final Map<String, dynamic> expense;

  const ExpenseDetailScreen({Key? key, required this.expense}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kWhitecolor,
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: Text(
          'Expense Details',
          style: TextStyle(
            color: kWhitecolor,
            fontSize: titleFontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: kWhitecolor),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              color: tileBackgroundColor,
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Amount',
                          style: TextStyle(
                            fontSize: largeFontSize,
                            color: kTextMedium,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          '₹${expense['amount'] ?? '0'}',
                          style: TextStyle(
                            fontSize: titleFontSize,
                            color: primaryColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 20),
                    
                    _buildDetailRow('Description', expense['description'] ?? 'No description'),
                    _buildDetailRow('Tag', expense['tagName'] ?? 'No tag'),
                    _buildDetailRow('To', expense['to'] ?? 'N/A'),
                    _buildDetailRow('Date', _formatDate(expense['date'])),
                    
                    if (expense['notes'] != null && expense['notes'].toString().isNotEmpty)
                      _buildDetailRow('Notes', expense['notes']),
                  ],
                ),
              ),
            ),
            
            SizedBox(height: 30),
            
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _editExpense(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryColor,
                      padding: EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    icon: Icon(Icons.edit, color: kWhitecolor),
                    label: Text(
                      'Edit',
                      style: TextStyle(
                        color: kWhitecolor,
                        fontSize: defaultFontSize,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _deleteExpense(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: errorcolor,
                      padding: EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    icon: Icon(Icons.delete, color: kWhitecolor),
                    label: Text(
                      'Delete',
                      style: TextStyle(
                        color: kWhitecolor,
                        fontSize: defaultFontSize,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '$label:',
              style: TextStyle(
                fontSize: defaultFontSize,
                color: kTextMedium,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: defaultFontSize,
                color: kTextColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(dynamic timestamp) {
    if (timestamp == null) return 'No date';
    
    DateTime date;
    if (timestamp is Timestamp) {
      date = timestamp.toDate();
    } else if (timestamp is DateTime) {
      date = timestamp;
    } else {
      return 'Invalid date';
    }
    
    return '${date.day}/${date.month}/${date.year}';
  }

  void _editExpense(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Edit expense feature coming soon')),
    );
  }

  void _deleteExpense(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(
            'Delete Expense',
            style: TextStyle(color: kTextColor),
          ),
          content: Text(
            'Are you sure you want to delete this expense?',
            style: TextStyle(color: kTextMedium),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'Cancel',
                style: TextStyle(color: kTextMedium),
              ),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Delete expense feature coming soon')),
                );
              },
              child: Text(
                'Delete',
                style: TextStyle(color: errorcolor),
              ),
            ),
          ],
        );
      },
    );
  }
}

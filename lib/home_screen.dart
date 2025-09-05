import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'style.dart';
import 'common_widgets.dart';
import 'expense_detail_screen.dart';
import 'tag_detail_screen.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'kilvish');
  
  List<Map<String, dynamic>> _tags = [];
  List<Map<String, dynamic>> _expenses = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kWhitecolor,
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: Text(
          'Kilvish',
          style: TextStyle(
            color: kWhitecolor,
            fontSize: titleFontSize,
            fontWeight: FontWeight.bold,
          ),
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
            Tab(
              icon: Icon(Icons.receipt_long),
              text: 'Expenses',
            ),
            Tab(
              icon: Icon(Icons.local_offer),
              text: 'Tags',
            ),
          ],
        ),
      ),
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(color: primaryColor),
            )
          : TabBarView(
              controller: _tabController,
              children: [
                _buildExpensesTab(),
                _buildTagsTab(),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: primaryColor,
        onPressed: _addNewExpense,
        child: Icon(Icons.add, color: kWhitecolor),
      ),
    );
  }

  Widget _buildExpensesTab() {
    if (_expenses.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 64,
              color: inactiveColor,
            ),
            SizedBox(height: 16),
            Text(
              'No expenses yet',
              style: TextStyle(
                fontSize: largeFontSize,
                color: kTextMedium,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Tap + to add your first expense',
              style: TextStyle(
                fontSize: defaultFontSize,
                color: inactiveColor,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.all(16),
      itemCount: _expenses.length,
      itemBuilder: (context, index) {
        final expense = _expenses[index];
        return Card(
          color: tileBackgroundColor,
          margin: EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: primaryColor,
              child: Icon(
                Icons.currency_rupee,
                color: kWhitecolor,
                size: 20,
              ),
            ),
            title: Text(
              expense['description'] ?? 'Expense',
              style: TextStyle(
                fontSize: defaultFontSize,
                color: kTextColor,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              expense['tagName'] ?? 'No tag',
              style: TextStyle(
                fontSize: smallFontSize,
                color: kTextMedium,
              ),
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '₹${expense['amount']}',
                  style: TextStyle(
                    fontSize: largeFontSize,
                    color: kTextColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  _formatDate(expense['date']),
                  style: TextStyle(
                    fontSize: smallFontSize,
                    color: kTextMedium,
                  ),
                ),
              ],
            ),
            onTap: () => _openExpenseDetail(expense),
          ),
        );
      },
    );
  }

  Widget _buildTagsTab() {
    if (_tags.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.local_offer_outlined,
              size: 64,
              color: inactiveColor,
            ),
            SizedBox(height: 16),
            Text(
              'No tags yet',
              style: TextStyle(
                fontSize: largeFontSize,
                color: kTextMedium,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Tags will appear when you add expenses',
              style: TextStyle(
                fontSize: defaultFontSize,
                color: inactiveColor,
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
        return Card(
          color: tileBackgroundColor,
          margin: EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: primaryColor,
              child: Icon(
                Icons.local_offer,
                color: kWhitecolor,
                size: 20,
              ),
            ),
            title: Text(
              tag['name'] ?? 'Tag',
              style: TextStyle(
                fontSize: defaultFontSize,
                color: kTextColor,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              'To: ${tag['lastTransactionTo'] ?? 'N/A'}',
              style: TextStyle(
                fontSize: smallFontSize,
                color: kTextMedium,
              ),
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '₹${tag['totalSum']}',
                  style: TextStyle(
                    fontSize: largeFontSize,
                    color: kTextColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  _formatDate(tag['lastTransactionDate']),
                  style: TextStyle(
                    fontSize: smallFontSize,
                    color: kTextMedium,
                  ),
                ),
              ],
            ),
            onTap: () => _openTagDetail(tag),
          ),
        );
      },
    );
  }

  void _loadData() async {
    try {
      User? user = _auth.currentUser;
      if (user != null) {
        await _loadTags(user.uid);
        await _loadExpenses(user.uid);
      }
    } catch (e) {
      print('Error loading data: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadTags(String userId) async {
    try {
      QuerySnapshot tagsSnapshot = await _firestore
          .collection('User')
          .doc(userId)
          .collection('Tags')
          .get();

      List<Map<String, dynamic>> tags = [];
      
      for (QueryDocumentSnapshot tagDoc in tagsSnapshot.docs) {
        Map<String, dynamic> tagData = tagDoc.data() as Map<String, dynamic>;
        
        // Get expenses for this tag to calculate totals
        QuerySnapshot expensesSnapshot = await tagDoc.reference
            .collection('Expenses')
            .orderBy('date', descending: true)
            .get();
            
        double totalSum = 0;
        String? lastTransactionTo;
        Timestamp? lastTransactionDate;
        
        if (expensesSnapshot.docs.isNotEmpty) {
          for (var expenseDoc in expensesSnapshot.docs) {
            Map<String, dynamic> expenseData = expenseDoc.data() as Map<String, dynamic>;
            totalSum += (expenseData['amount'] ?? 0).toDouble();
          }
          
          // Get last transaction details
          Map<String, dynamic> lastExpense = expensesSnapshot.docs.first.data() as Map<String, dynamic>;
          lastTransactionTo = lastExpense['to'];
          lastTransactionDate = lastExpense['date'];
        }
        
        tags.add({
          'id': tagDoc.id,
          'name': tagData['name'],
          'totalSum': totalSum,
          'lastTransactionTo': lastTransactionTo,
          'lastTransactionDate': lastTransactionDate,
          ...tagData,
        });
      }
      
      setState(() => _tags = tags);
    } catch (e) {
      print('Error loading tags: $e');
    }
  }

  Future<void> _loadExpenses(String userId) async {
    try {
      List<Map<String, dynamic>> allExpenses = [];
      
      // Get all tags first
      QuerySnapshot tagsSnapshot = await _firestore
          .collection('User')
          .doc(userId)
          .collection('Tags')
          .get();
      
      // For each tag, get its expenses
      for (QueryDocumentSnapshot tagDoc in tagsSnapshot.docs) {
        String tagName = (tagDoc.data() as Map<String, dynamic>)['name'] ?? 'Unknown';
        
        QuerySnapshot expensesSnapshot = await tagDoc.reference
            .collection('Expenses')
            .orderBy('date', descending: true)
            .get();
            
        for (QueryDocumentSnapshot expenseDoc in expensesSnapshot.docs) {
          Map<String, dynamic> expenseData = expenseDoc.data() as Map<String, dynamic>;
          allExpenses.add({
            'id': expenseDoc.id,
            'tagId': tagDoc.id,
            'tagName': tagName,
            ...expenseData,
          });
        }
      }
      
      // Sort all expenses by date (most recent first)
      allExpenses.sort((a, b) {
        Timestamp dateA = a['date'] ?? Timestamp.now();
        Timestamp dateB = b['date'] ?? Timestamp.now();
        return dateB.compareTo(dateA);
      });
      
      setState(() => _expenses = allExpenses);
    } catch (e) {
      print('Error loading expenses: $e');
    }
  }

  String _formatDate(dynamic timestamp) {
    if (timestamp == null) return '';
    
    DateTime date;
    if (timestamp is Timestamp) {
      date = timestamp.toDate();
    } else if (timestamp is DateTime) {
      date = timestamp;
    } else {
      return '';
    }
    
    return '${date.day}/${date.month}/${date.year}';
  }

  void _openExpenseDetail(Map<String, dynamic> expense) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ExpenseDetailScreen(expense: expense),
      ),
    );
  }

  void _openTagDetail(Map<String, dynamic> tag) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TagDetailScreen(tag: tag),
      ),
    );
  }

  void _addNewExpense() {
    // TODO: Implement add expense screen
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Add expense screen coming soon')),
    );
  }

  void _logout() async {
    await _auth.signOut();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }
}

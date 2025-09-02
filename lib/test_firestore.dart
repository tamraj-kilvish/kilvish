import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(FirestoreTestApp());
}

class FirestoreTestApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: FirestoreTestScreen(),
    );
  }
}

class FirestoreTestScreen extends StatefulWidget {
  @override
  _FirestoreTestScreenState createState() => _FirestoreTestScreenState();
}

class _FirestoreTestScreenState extends State<FirestoreTestScreen> {
  String output = "Loading...";

  @override
  void initState() {
    super.initState();
    fetchFirestoreData();
  }

  Future<void> fetchFirestoreData() async {
    try {
      StringBuffer buffer = StringBuffer();
      buffer.writeln("=== FIRESTORE DATA STRUCTURE ===\n");

      // Fetch Users collection
      QuerySnapshot usersSnapshot = await FirebaseFirestore.instance
          .collection('User')
          .limit(3)
          .get();

      buffer.writeln("Users Collection (${usersSnapshot.docs.length} documents):");
      
      for (var userDoc in usersSnapshot.docs) {
        buffer.writeln("\n--- User: ${userDoc.id} ---");
        Map<String, dynamic> userData = userDoc.data() as Map<String, dynamic>;
        userData.forEach((key, value) {
          buffer.writeln("  $key: $value");
        });

        // Fetch Tags subcollection for this user
        QuerySnapshot tagsSnapshot = await userDoc.reference
            .collection('Tags')
            .limit(5)
            .get();

        buffer.writeln("\n  Tags Subcollection (${tagsSnapshot.docs.length} documents):");
        
        for (var tagDoc in tagsSnapshot.docs) {
          buffer.writeln("    --- Tag: ${tagDoc.id} ---");
          Map<String, dynamic> tagData = tagDoc.data() as Map<String, dynamic>;
          tagData.forEach((key, value) {
            buffer.writeln("      $key: $value");
          });

          // Fetch Expenses subcollection for this tag
          QuerySnapshot expensesSnapshot = await tagDoc.reference
              .collection('Expenses')
              .limit(3)
              .get();

          buffer.writeln("\n      Expenses Subcollection (${expensesSnapshot.docs.length} documents):");
          
          for (var expenseDoc in expensesSnapshot.docs) {
            buffer.writeln("        --- Expense: ${expenseDoc.id} ---");
            Map<String, dynamic> expenseData = expenseDoc.data() as Map<String, dynamic>;
            expenseData.forEach((key, value) {
              buffer.writeln("          $key: $value");
            });
          }
        }
        buffer.writeln("\n" + "="*50);
      }

      setState(() {
        output = buffer.toString();
      });

    } catch (e) {
      setState(() {
        output = "Error fetching data: $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Firestore Data Test'),
        backgroundColor: Colors.blue,
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: Text(
          output,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

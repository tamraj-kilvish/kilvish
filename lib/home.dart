import 'package:flutter/material.dart';
import 'package:kilvish/src/widgets/expense_info.dart';

const MaterialColor primaryColor = Colors.pink;
const TextStyle textStylePrimaryColor = TextStyle(color: primaryColor);
const Color tileBackgroundColor = Color.fromARGB(255, 229, 227, 227);


class HomePage extends StatefulWidget {
  const HomePage({Key? key, required this.title}) : super(key: key);

  final String title;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<ExpenseItem> expenseItems = [
    ExpenseItem(
        message: 'To: Newspaper Amount: 80',
        date: DateTime.now(),
        amount: '1800'),
    ExpenseItem(
        message: 'To: Newspaper Amount: 80',
        date: DateTime.now(),
        amount: '1800'),
    ExpenseItem(
        message: 'To: Ashish Amount: 80', date: DateTime.now(), amount: '950'),
  ];
  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () {},
          ),
          title: Text('Kilvish'),
          actions: const <Widget>[
            IconButton(
              icon: Icon(
                Icons.search,
                color: Colors.white,
              ),
              onPressed: null,
            ),
            IconButton(
              icon: Icon(
                Icons.more_vert,
                color: Colors.white,
              ),
              onPressed: null,
            ),
          ],
        ),
        body: Stack(
          children: [
            ListView.separated(
              separatorBuilder: (context, index) {
                return const Divider(height: 1);
              },
              itemCount: expenseItems.length,
              itemBuilder: (context, index) {
                return ListTile(
                  tileColor: tileBackgroundColor,
                  leading: const FlutterLogo(size: 56.0),
                  onTap: () {},
                  title: const Text('Football'),
                  subtitle: Text(expenseItems[index].message),
                  trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Text(
                          expenseItems[index].amount,
                          style: const TextStyle(
                              fontSize: 14.0, fontWeight: FontWeight.bold),
                        ),
                        const Text(
                          'Yesterday',
                          style: TextStyle(
                              fontSize: 14.0,
                              color: Colors.grey,
                              fontWeight: FontWeight.bold),
                        ),
                      ]),
                );
              },
            ),
            Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  margin: EdgeInsets.symmetric(horizontal: 10, vertical: 20),
                  width: double.infinity,
                  child: TextButton(
                    child: Text('Add Expenses',
                        style: TextStyle(color: Colors.white)),
                    onPressed: () => {},
                    style: TextButton.styleFrom(backgroundColor: primaryColor),
                  ),
                ))
          ],
        ));
  }
}

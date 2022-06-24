import 'package:flutter/material.dart';
import 'models.dart';
import 'style.dart';
import 'common_widgets.dart';

class TagDetailPage extends StatefulWidget {
  final String title;

  const TagDetailPage({Key? key, required this.title}) : super(key: key);

  @override
  State<TagDetailPage> createState() => _TagDetailState();
}

class _TagDetailState extends State<TagDetailPage> {
  late List<Expense> _expenses;

  @override
  void initState() {
    super.initState();
    // TODO - subscribe to changes/updates
    // TODO - build list of Expenses from local DB
    //pseudo code - get the tag from the id & get all expenses of the tag order by transaction date desc

    _expenses = [
      Expense(
        fromUid: 'Ashish',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(days: 1)),
        amount: 100,
      ),
      Expense(
        fromUid: 'Lakshmi',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(days: 2)),
        amount: 100,
      ),
      Expense(
        fromUid: 'Lakshmi',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(days: 2)),
        amount: 100,
      ),
      Expense(
        fromUid: 'Lakshmi',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(days: 2)),
        amount: 100,
      ),
      Expense(
        fromUid: 'Lakshmi',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(days: 2)),
        amount: 100,
      ),
      Expense(
        fromUid: 'Lakshmi',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(days: 2)),
        amount: 100,
      ),
      Expense(
        fromUid: 'Lakshmi',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(days: 2)),
        amount: 100,
      ),
      Expense(
        fromUid: 'Lakshmi',
        toUid: 'Car Cleaner',
        timeOfTransaction: DateTime.now().subtract(const Duration(days: 2)),
        amount: 50,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Row(
            children: [renderImageIcon('images/tag.png'), Text(widget.title)]),
        actions: <Widget>[
          appBarSearch(null),
          appBarEdit(null),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            snap: false,
            floating: false,
            expandedHeight: 120.0,
            backgroundColor: Colors.white,
            flexibleSpace: SingleChildScrollView(
              child: Container(
                margin: const EdgeInsets.only(top: 20, bottom: 20),
                child:
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Container(
                    margin: const EdgeInsets.only(right: 20),
                    child: Column(
                      children: [
                        Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: const Text("Total Expense",
                              style: TextStyle(fontSize: 20.0)),
                        ),
                        const Text(
                          "This Month",
                          style: textStyleInactive,
                        ),
                        const Text("Past Month", style: textStyleInactive),
                      ],
                    ),
                  ),
                  Column(
                    children: [
                      Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: const Text("1800",
                            style: TextStyle(fontSize: 20.0)),
                      ),
                      const Text("60", style: textStyleInactive),
                      const Text("120", style: textStyleInactive),
                    ],
                  ),
                ]),
              ),
            ),
          ),
          /*Container(
              margin: const EdgeInsets.only(top: 20, bottom: 20),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  margin: const EdgeInsets.only(right: 20),
                  child: Column(
                    children: [
                      Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: const Text("Total Expense",
                            style: TextStyle(fontSize: 20.0)),
                      ),
                      const Text(
                        "This Month",
                        style: textStyleInactive,
                      ),
                      const Text("Past Month", style: textStyleInactive),
                    ],
                  ),
                ),
                Column(
                  children: [
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      child:
                          const Text("1800", style: TextStyle(fontSize: 20.0)),
                    ),
                    const Text("60", style: textStyleInactive),
                    const Text("120", style: textStyleInactive),
                  ],
                ),
              ]),
            ),
            Expanded(
              child:
            ListView.separated(
              separatorBuilder: (context, index) {
                return const Divider(height: 1);
              },
              itemCount: _expenses.length,
              itemBuilder: (context, index) {*/
          SliverList(
            delegate:
                SliverChildBuilderDelegate((BuildContext context, int index) {
              return Column(
                children: [
                  const Divider(height: 1),
                  ListTile(
                    tileColor: tileBackgroundColor,
                    leading: const Icon(Icons.face, color: Colors.black),
                    onTap: () {
                      //moveToTagDetailScreen(_homePageItems[index].title);
                    },
                    title: Container(
                      //this margin aligns the title to the expense on the left
                      margin: const EdgeInsets.only(bottom: 5),
                      child: Text('To: ${_expenses[index].toUid}'),
                    ),
                    subtitle: Text(relativeTimeFromNow(
                        _expenses[index].timeOfTransaction)),
                    trailing: Text(
                      "${_expenses[index].amount}",
                      style: const TextStyle(
                          fontSize: 14.0, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              );
            }, childCount: _expenses.length),
          ),
        ],
      ),
      bottomNavigationBar: BottomAppBar(
        child: renderMainBottomButton('Add Expense', null),
      ),
    );
  }
}

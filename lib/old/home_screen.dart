import 'dart:io';

import 'package:flutter/material.dart';
import 'package:kilvish/import_expense_screen.dart';
import 'models.dart';
import 'style.dart';
import 'common_widgets.dart';
import 'detail_screen.dart';

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);

  final String title = 'Kilvish';

  @override
  State<HomePage> createState() => _HomePageState();
}

class HomePageItem {
  final String title;
  final String lastTransactionActor;
  final num lastTransactionAmount;
  final DateTime lastTransactionDate;
  final num balance;
  final HomePageItemType type;

  const HomePageItem({
    required this.title,
    required this.lastTransactionActor,
    required this.lastTransactionAmount,
    required this.lastTransactionDate,
    required this.balance,
    required this.type,
  });
}

class _HomePageState extends State<HomePage> {
  late List<HomePageItem> _homePageItems;

  @override
  void initState() {
    super.initState();
    // TODO - subscribe to changes/updates
    // TODO - build list of HomePageItems from local DB
    /* pseudo code 
    List<HomePageItem> homePageItems = [];
    for (expense in most_recent_expenses()) { //
      name,type = get_type(expense); // type could be tag or url, name is tag/url name
      homePageItems.add (
        HomePageItem(
          title: name,
          lastTransactionActor: get_actor(expense)
          lastTransactionAmount: get_amount(expense)
          lastTransactionDate: get_date(expense)
          balance: get_balance_from_tag_or_url(name)
        )
      );
    }*/
    _homePageItems = [
      HomePageItem(
        title: "Newspaper",
        lastTransactionActor: "Vendor",
        lastTransactionAmount: 100,
        lastTransactionDate: DateTime.now().subtract(const Duration(days: 1)),
        balance: 180,
        type: HomePageItemType.tag,
      ),
      HomePageItem(
        title: "Household",
        lastTransactionActor: "Ashish",
        lastTransactionAmount: 100,
        lastTransactionDate: DateTime.now().subtract(const Duration(days: 2)),
        balance: 180,
        type: HomePageItemType.tag,
      ),
      HomePageItem(
        title: "Football",
        lastTransactionActor: "Pratik",
        lastTransactionAmount: 80,
        lastTransactionDate: DateTime.now().subtract(const Duration(days: 5)),
        balance: 180,
        type: HomePageItemType.url,
      ),
    ];
  }

  @override
  void dispose() {
    //TODO - dispose the subscription to changes
    super.dispose();
  }

  void moveToTagDetailScreen(String title) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) {
          return TagDetailPage(title: title);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: appBarMenu(null),
        title: appBarTitleText('Kilvish'),
        actions: <Widget>[appBarSearchIcon(null), appBarRightMenu(null)],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.separated(
              separatorBuilder: (context, index) {
                return const Divider(height: 1);
              },
              itemCount: _homePageItems.length,
              itemBuilder: (context, index) {
                return ListTile(
                  tileColor: tileBackgroundColor,
                  leading: renderImageIcon(
                    _homePageItems[index].type == HomePageItemType.tag
                        ? Icons.turned_in
                        : Icons.link,
                  ),
                  onTap: () {
                    moveToTagDetailScreen(_homePageItems[index].title);
                  },
                  title: Container(
                    //this margin aligns the title to the expense on the left
                    margin: const EdgeInsets.only(bottom: 5),
                    child: Text(_homePageItems[index].title),
                  ),
                  subtitle: Text(
                    "To: ${_homePageItems[index].lastTransactionActor}, Amount: ${_homePageItems[index].lastTransactionAmount}",
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        "${_homePageItems[index].balance}",
                        style: const TextStyle(
                          fontSize: 14.0,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        relativeTimeFromNow(
                          _homePageItems[index].lastTransactionDate,
                        ),
                        style: const TextStyle(
                          fontSize: 14.0,
                          color: Colors.grey,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: BottomAppBar(
        child: renderMainBottomButton('Add Expense', () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const ImportExpensePage()),
          );
        }),
      ),
    );
  }
}

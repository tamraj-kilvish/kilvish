import 'package:flutter/material.dart';
import 'package:jiffy/jiffy.dart';

const MaterialColor primaryColor = Colors.pink;
const TextStyle textStylePrimaryColor = TextStyle(color: primaryColor);
const Color tileBackgroundColor = Color.fromARGB(255, 229, 227, 227);

class HomePage extends StatefulWidget {
  const HomePage({Key? key, required this.title}) : super(key: key);

  final String title;

  @override
  State<HomePage> createState() => _HomePageState();
}

enum HomePageItemType { tag, url }

class HomePageItem {
  final String title;
  final String lastTransactionActor;
  final num lastTransactionAmount;
  final DateTime lastTransactionDate;
  final num balance;
  final HomePageItemType type;

  const HomePageItem(
      {required this.title,
      required this.lastTransactionActor,
      required this.lastTransactionAmount,
      required this.lastTransactionDate,
      required this.balance,
      required this.type});
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
          type: HomePageItemType.tag),
      HomePageItem(
          title: "Household",
          lastTransactionActor: "Ashish",
          lastTransactionAmount: 100,
          lastTransactionDate: DateTime.now().subtract(const Duration(days: 2)),
          balance: 180,
          type: HomePageItemType.tag),
      HomePageItem(
          title: "Football",
          lastTransactionActor: "Pratik",
          lastTransactionAmount: 80,
          lastTransactionDate: DateTime.now().subtract(const Duration(days: 5)),
          balance: 180,
          type: HomePageItemType.url),
    ];
  }

  @override
  void dispose() {
    //TODO - dispose the subscription to changes
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () {},
          ),
          title: const Text('Kilvish'),
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
                    leading: renderImage(_homePageItems[index].type),
                    onTap: () {},
                    title: Container(
                      margin: const EdgeInsets.only(bottom: 5),
                      child: Text(_homePageItems[index].title),
                    ),
                    subtitle: Text(
                        "To: ${_homePageItems[index].lastTransactionActor}, Amount: ${_homePageItems[index].lastTransactionAmount}"),
                    trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          Text(
                            "${_homePageItems[index].balance}",
                            style: const TextStyle(
                                fontSize: 14.0, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            relativeTimeFromNow(
                                _homePageItems[index].lastTransactionDate),
                            style: const TextStyle(
                                fontSize: 14.0,
                                color: Colors.grey,
                                fontWeight: FontWeight.bold),
                          ),
                        ]),
                  );
                },
              ),
            ),
            Row(children: [
              Expanded(
                child: TextButton(
                  onPressed: () => {},
                  style: TextButton.styleFrom(
                      backgroundColor: primaryColor,
                      minimumSize: const Size.fromHeight(50)),
                  child: const Text('Add Expenses',
                      style: TextStyle(color: Colors.white, fontSize: 15)),
                ),
              ),
            ]),
          ],
        ));
  }

  String relativeTimeFromNow(DateTime d) {
    return Jiffy(d).fromNow();
  }

  Image renderImage(HomePageItemType type) {
    return Image.asset(
      (type == HomePageItemType.tag) ? 'images/tag.png' : 'images/link.png',
      width: 30,
      height: 30,
      fit: BoxFit.fitWidth,
    );
  }
}

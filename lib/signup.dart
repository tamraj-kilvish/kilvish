import 'package:flutter/material.dart';
import 'constants.dart';

class SignUpPage extends StatefulWidget {
  const SignUpPage({Key? key}) : super(key: key);

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  //int _counter = 0;

  void _incrementCounter() {
    setState(() {
      // This call to setState tells the Flutter framework that something has
      // changed in this State, which causes it to rerun the build method below
      // so that the display can reflect the updated values. If we changed
      // _counter without calling setState(), then the build method would not be
      // called again, and so nothing would appear to happen.
      //_counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      body: Container(
        padding: const EdgeInsets.all(50),
        child: ListView(
          children: <Widget>[
            Center(
              child: Column(
                children: [
                  Image.asset(
                    'images/kilvish.png',
                    width: 100,
                    height: 100,
                    fit: BoxFit.fitWidth,
                  ),
                  FittedBox(
                    fit: BoxFit.fitWidth,
                    child: Container(
                      margin: const EdgeInsets.only(top: 10),
                      child: const Text("Kilvish in 3 steps",
                          style: TextStyle(fontSize: 50.0)),
                    ),
                  ),
                  FittedBox(
                    fit: BoxFit.fitWidth,
                    child: Container(
                      margin: const EdgeInsets.only(top: 30),
                      child: const Text(
                          "A better way to track & recover expenses",
                          style: TextStyle(fontSize: 20.0)),
                    ),
                  ),
                ],
              ),
            ),
            homepageForm("1", "Phone Number", "Get OTP", "7019316063"),
            homepageForm("2", "Enter OTP", "Verify OTP", "1234"),
            homepageForm(
                "3", "Setup Kilvish Id", "Get Started", "crime-master-gogo"),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }
}

Column homepageForm(
    String stepNumber, String textLabel, String buttonLabel, String hint) {
  return Column(children: [
    const Divider(height: 50),
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.fitWidth,
          child: Container(
            margin: const EdgeInsets.only(right: 50),
            child: Text(stepNumber,
                style: const TextStyle(fontSize: 50.0, color: Colors.grey)),
          ),
        ),
        Expanded(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(textLabel, style: textStylePrimaryColor),
              ),
              TextField(
                decoration: InputDecoration(
                  hintText: hint,
                ),
              ),
              Container(
                margin: const EdgeInsets.only(top: 10),
                child: TextButton(
                  style: TextButton.styleFrom(
                      backgroundColor: primaryColor,
                      minimumSize: const Size.fromHeight(50)),
                  onPressed: null,
                  child: Text(buttonLabel,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 15)),
                ),
              )
            ],
          ),
        ),
      ],
    ),
  ]);
}

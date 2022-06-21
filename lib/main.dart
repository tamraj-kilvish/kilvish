import 'package:flutter/material.dart';
import 'src/widgets/form_field.dart';

const MaterialColor primaryColor = Colors.pink;
const TextStyle textStylePrimaryColor = TextStyle(color: primaryColor);

void main() {
  runApp(const Kilvish());
}

class Kilvish extends StatelessWidget {
  const Kilvish({Key? key}) : super(key: key);

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kilvish',
      theme: ThemeData(
        primarySwatch: primaryColor,
      ),
      home: const SignupPage(title: 'Welcome to Kilvish'),
    );
  }
}

class SignupPage extends StatefulWidget {
  const SignupPage({Key? key, required this.title}) : super(key: key);

  final String title;

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  @override
  Widget build(BuildContext context) {
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
                  const CustomFormField(
                    "1",
                    fieldLabel: "Phone Number",
                    buttonLabel: "Get OTP",
                    hint: "Your contact number",
                  ),
                  const CustomFormField("2",
                      fieldLabel: "Enter OTP",
                      buttonLabel: "Verify OTP",
                      hint: "Enter OTP"),
                  const CustomFormField("3",
                      fieldLabel: "Setup Kilvish Id",
                      buttonLabel: "Get Started",
                      onPressed: true,
                      hint: "Your unique kilvish id"),
                  // ExpenseItem(
                  //     message: 'Hello this is expense message',
                  //     date: DateTime.now(),
                  //     amount: "200")
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

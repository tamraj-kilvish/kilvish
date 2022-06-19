import 'package:flutter/material.dart';

// To : message, time , amount, date

class ExpenseItem extends StatelessWidget {
  const ExpenseItem({
    required this.message,
    required this.date,
    required this.amount,
    super.key,
  });

  final String message;
  final DateTime date;
  final String amount;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: Colors.grey[300],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Wrap(
                direction: Axis.horizontal,
                spacing: 25,
                children: [
                  IconButton(
                    onPressed: () {},
                    //padding: const EdgeInsets.all(5.0),
                    icon: const Icon(
                      Icons.account_circle_rounded,
                      size: 30,
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'To: $message',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4.0),
                      Text(
                        'Time: ${date.year.toString()}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                        ),
                      )
                    ],
                  ),
                ],
              ),
            ],
          ),
          Column(
            children: [
              Text(amount,
                  style: const TextStyle(
                    fontSize: 16,
                  )),
              const SizedBox(height: 4.0),
              Text(date.month.toString(),
                  style: const TextStyle(
                    fontSize: 16,
                  )),
            ],
          ),
        ],
      ),
    );
  }
}

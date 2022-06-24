enum HomePageItemType { tag, url }

class Expense {
  final String fromUid;
  final String toUid;
  final DateTime timeOfTransaction;
  final num amount;

  const Expense({
    required this.fromUid,
    required this.toUid,
    required this.timeOfTransaction,
    required this.amount,
  });
}

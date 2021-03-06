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

class MonthwiseAggregatedExpense {
  final String month;
  final String year;
  final num amount;

  const MonthwiseAggregatedExpense(
      {required this.month, required this.year, required this.amount});
}

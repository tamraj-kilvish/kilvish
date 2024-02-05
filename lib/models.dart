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

class Tag {
  final String name;
  const Tag({required this.name});
}

enum TagStatus { selected, unselected }

class ExpenseTag {
  final Tag tag;
  final Expense expense;
  final bool isSaved;
  const ExpenseTag(
      {required this.tag, required this.expense, this.isSaved = true});
}

class ContactModel {
  ContactModel({required this.name, required this.phoneNumber, this.kilvishId});

  final String name;
  final String? kilvishId;
  final String phoneNumber;
}
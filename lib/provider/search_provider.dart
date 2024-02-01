import 'package:flutter/material.dart';
import 'package:kilvish/models/ContactModel.dart';

class SearchNotifier {
  ValueNotifier<List<ContactModel>> contactNotifier = ValueNotifier([]);
  ValueNotifier<bool> contactStateNotifier = ValueNotifier<bool>(false);

  /// Update list search item
  void updateSearchValue(List<ContactModel> list) {
    contactNotifier.value = list;
  }

  /// Update state of search bar
  void updateSearchState(bool isSearch) {
    contactStateNotifier.value = isSearch;
  }
}

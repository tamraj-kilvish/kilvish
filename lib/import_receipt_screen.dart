import 'package:flutter/material.dart';
import 'package:kilvish/background_worker.dart';
import 'package:kilvish/cache_manager.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore_expenses.dart';
import 'package:kilvish/firestore_user.dart';
import 'package:kilvish/home_screen.dart';
import 'package:kilvish/model_expenses.dart';
import 'package:kilvish/model_tags.dart';
import 'package:kilvish/style.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ImportReceiptScreen extends StatefulWidget {
  final WIPExpense wipExpense;

  const ImportReceiptScreen({super.key, required this.wipExpense});

  @override
  State<ImportReceiptScreen> createState() => _ImportReceiptScreenState();
}

class _ImportReceiptScreenState extends State<ImportReceiptScreen> {
  bool _isLoading = true;
  Tag? _expandedTag;
  // Tracks the order of tag accordions; most recently interacted floats to top
  List<Tag> _tagOrder = [];
  static const _prefKey = 'import_screen_tag_order';
  late SharedPreferences prefs;

  @override
  void initState() {
    super.initState();
    _loadUserTags();
  }

  Future<void> _loadUserTags() async {
    try {
      Map<String, Tag> tagMap = await getUserAccessibleTagsMap();
      prefs = await SharedPreferences.getInstance();
      final savedOrder = prefs.getStringList(_prefKey) ?? [];

      // Sort tags: saved order first
      final orderedTags = savedOrder.map((String tagId) {
        Tag tag = tagMap[tagId]!;
        tagMap.remove(tagId);
        return tag;
      }).toList();

      // add tags that could be added newly after the last sorting & storing
      orderedTags.addAll(tagMap.entries.map((e) => e.value));

      setState(() {
        _tagOrder = orderedTags;
        _isLoading = false;
      });
    } catch (e, stackTrace) {
      print('Error loading tags: $e $stackTrace');
      setState(() => _isLoading = false);
    }
  }

  void _onTagInteracted(Tag tag) {
    setState(() {
      _tagOrder.remove(tag);
      _tagOrder.insert(0, tag);
    });
    prefs.setStringList(_prefKey, _tagOrder.map((t) => t.id).toList());
  }

  Future<void> _selectOption(String option, {Tag? tag}) async {
    String? userId = await getUserIdFromClaim();
    if (userId == null) throw 'Logged in user is null, cant proceed';

    try {
      if (option == 'expense' && tag != null) {
        widget.wipExpense.tags.add(tag);
      } else if (option == 'settlement' && tag != null) {
        String recipientId = tag.sharedWith.firstWhere((userid) => userid != userId);
        final date = widget.wipExpense.timeOfTransaction ?? DateTime.now();
        widget.wipExpense.settlements.add(SettlementEntry(to: recipientId, month: date.month, year: date.year, tagId: tag.id));
      } else if (option == 'recovery' && tag != null) {
        widget.wipExpense.tags.add(tag);
      } else if (option == 'recovery' && tag == null) {
        widget.wipExpense.isRecoveryExpense = true;
      }

      WIPExpense updatedExpense = widget.wipExpense;
      await updateWIPExpenseWithTagsAndSettlement(updatedExpense, widget.wipExpense.tags.toList(), widget.wipExpense.settlements);
      updatedExpense = await startReceiptUploadViaBackgroundTask(updatedExpense);

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => HomeScreen(expenseAsParam: updatedExpense)),
          (route) => false,
        );
      }
    } catch (e, stackTrace) {
      print('Error in _selectOption: $e $stackTrace');
      if (mounted) showError(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) {
          await cleanupReceiptFile(widget.wipExpense.localReceiptPath);
          await deleteWIPExpense(widget.wipExpense);
        }
      },
      child: Scaffold(
        backgroundColor: kWhitecolor,
        appBar: AppBar(backgroundColor: primaryColor, title: appBarTitleText('Import Receipt'), automaticallyImplyLeading: false),
        body: _isLoading
            ? Center(child: CircularProgressIndicator(color: primaryColor))
            : SingleChildScrollView(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    renderPrimaryColorLabel(text: 'How would you like to import this receipt?'),
                    SizedBox(height: 20),

                    // Top-level cards (always visible)
                    _buildOptionTile(
                      icon: Icons.receipt_long,
                      title: 'Add Expense',
                      subtitle: 'Add to your expenses list',
                      onTap: () => _selectOption('expense'),
                    ),
                    SizedBox(height: 16),
                    _buildOptionTile(
                      icon: Icons.money_off,
                      title: 'Add Expense to track paybacks',
                      subtitle: 'Expense you expect to recover later',
                      onTap: () => _selectOption('recovery'),
                      tileColor: Colors.orange.withOpacity(0.05),
                      iconColor: Colors.orange,
                    ),

                    // Tag accordions
                    if (_tagOrder.isNotEmpty) ...[
                      SizedBox(height: 24),
                      renderPrimaryColorLabel(text: 'Or add to a specific tag:'),
                      SizedBox(height: 12),
                      ..._tagOrder.map((tag) => _buildTagAccordion(tag)).toList(),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildTagAccordion(Tag tag) {
    final isExpanded = _expandedTag == tag;
    return GestureDetector(
      onTap: () {
        setState(() => _expandedTag = isExpanded ? null : tag);
      },
      child: AnimatedContainer(
        duration: Duration(milliseconds: 200),
        margin: EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: tileBackgroundColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isExpanded ? primaryColor : bordercolor, width: isExpanded ? 1.5 : 1),
        ),
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: tag.isRecoveryExpense ? Colors.orange : primaryColor,
                    radius: 16,
                    child: Icon(tag.isRecoveryExpense ? Icons.money_off : Icons.local_offer, color: kWhitecolor, size: 16),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      tag.name,
                      style: TextStyle(fontSize: defaultFontSize, fontWeight: FontWeight.w600, color: kTextColor),
                    ),
                  ),
                  Icon(isExpanded ? Icons.expand_less : Icons.expand_more, color: kTextMedium),
                ],
              ),
            ),
            if (isExpanded) ...[
              Divider(height: 1),
              Padding(
                padding: EdgeInsets.all(12),
                child: Column(
                  children: [
                    _buildTagOptionCard(
                      icon: Icons.receipt_long,
                      title: 'Add Expense',
                      onTap: () {
                        _onTagInteracted(tag);
                        _selectOption(tag.isRecoveryExpense ? 'recovery' : 'expense', tag: tag);
                      },
                    ),
                    SizedBox(height: 8),
                    _buildTagOptionCard(
                      icon: Icons.money_off,
                      title: 'Add Expense to track paybacks',
                      iconColor: Colors.orange,
                      onTap: () {
                        _onTagInteracted(tag);
                        _selectOption('recovery', tag: tag);
                      },
                    ),
                    if (tag.sharedWith.isNotEmpty) ...[
                      SizedBox(height: 8),
                      _buildTagOptionCard(
                        icon: Icons.account_balance_wallet,
                        title: 'Settle pending payment',
                        onTap: () {
                          _onTagInteracted(tag);
                          _selectOption('settlement', tag: tag);
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTagOptionCard({required IconData icon, required String title, required VoidCallback onTap, Color? iconColor}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: kWhitecolor,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: bordercolor),
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor ?? primaryColor, size: 20),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(fontSize: smallFontSize, color: kTextColor, fontWeight: FontWeight.w500),
              ),
            ),
            Icon(Icons.arrow_forward_ios, color: kTextMedium, size: 14),
          ],
        ),
      ),
    );
  }

  Widget _buildOptionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color? tileColor,
    Color? iconColor,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: tileColor ?? tileBackgroundColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: bordercolor),
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor ?? primaryColor, size: 32),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontSize: defaultFontSize, color: kTextColor, fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, color: kTextMedium, size: 16),
          ],
        ),
      ),
    );
  }
}

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

class ImportReceiptScreen extends StatefulWidget {
  final WIPExpense wipExpense;

  const ImportReceiptScreen({super.key, required this.wipExpense});

  @override
  State<ImportReceiptScreen> createState() => _ImportReceiptScreenState();
}

class _ImportReceiptScreenState extends State<ImportReceiptScreen> {
  List<Tag> _userTags = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadUserTags();
  }

  Future<void> _loadUserTags() async {
    try {
      List<Tag> tags = await getUserAccessibleTags();
      setState(() {
        _userTags = tags;
        _isLoading = false;
      });
    } catch (e, stackTrace) {
      print('Error loading tags: $e $stackTrace');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _selectOption(String option, {Tag? tag}) async {
    String? userId = await getUserIdFromClaim();
    if (userId == null) throw 'Logged in user is null, cant proceed';

    try {
      // Update WIPExpense based on selection
      if (option == 'expense' && tag != null) {
        // Add to regular expense tags
        widget.wipExpense.tags.add(tag);
      } else if (option == 'settlement' && tag != null) {
        String recipientId = tag.sharedWith.firstWhere((userid) => userid != userId);

        // Use timeOfTransaction or current date for month/year
        final date = widget.wipExpense.timeOfTransaction ?? DateTime.now();

        widget.wipExpense.settlements.add(SettlementEntry(to: recipientId, month: date.month, year: date.year, tagId: tag.id));
      } else if (option == 'recovery' && tag != null) {
        // NEW: Just add the recovery tag - recovery amount will be specified in tag selection
        widget.wipExpense.tags.add(tag);
      } else if (option == 'recovery' && tag == null) {
        // NEW: Top-level recovery option - mark entire expense for recovery
        widget.wipExpense.isRecoveryExpense = true;
      }

      // Save WIPExpense with updated data
      WIPExpense updatedExpense = widget.wipExpense;

      await updateWIPExpenseWithTagsAndSettlement(updatedExpense, widget.wipExpense.tags.toList(), widget.wipExpense.settlements);

      updatedExpense = await startReceiptUploadViaBackgroundTask(updatedExpense);

      // Navigate to home
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => HomeScreen(expenseAsParam: updatedExpense)),
          (route) => false,
        );
      }
    } catch (e, stackTrace) {
      print('Error in _selectOption: $e $stackTrace');
      if (mounted) {
        showError(context, e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) {
          // Cleanup receipt file when user presses back
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

                    // Add Expense (no tag)
                    _buildOptionTile(
                      icon: Icons.receipt_long,
                      title: 'Add Expense',
                      subtitle: 'Add to your expenses list',
                      onTap: () => _selectOption('expense'),
                    ),

                    SizedBox(height: 16),

                    // Track for Recovery (no tag yet)
                    _buildOptionTile(
                      icon: Icons.money_off,
                      title: 'Track for Recovery',
                      subtitle: 'Expense you expect to recover later',
                      onTap: () => _selectOption('recovery'),
                      tileColor: Colors.orange.withOpacity(0.05),
                      iconColor: Colors.orange,
                    ),

                    SizedBox(height: 16),

                    // Tag options
                    if (_userTags.isNotEmpty) ...[
                      renderPrimaryColorLabel(text: 'Or add to a specific tag:', topSpacing: 10),
                      SizedBox(height: 16),

                      ..._userTags.map((tag) {
                        return Column(
                          children: [
                            _buildOptionTile(
                              icon: Icons.local_offer,
                              title: 'Add Expense to ${tag.name}',
                              subtitle: tag.isRecoveryExpense ? 'Track recovery for this expense' : 'Regular expense in this tag',
                              onTap: () => tag.isRecoveryExpense
                                  ? _selectOption('recovery', tag: tag)
                                  : _selectOption('expense', tag: tag),
                              tileColor: tag.isRecoveryExpense ? Colors.orange.withOpacity(0.05) : null,
                              iconColor: tag.isRecoveryExpense ? Colors.orange : primaryColor,
                            ),
                            if (tag.sharedWith.isNotEmpty) ...[
                              SizedBox(height: 12),
                              _buildOptionTile(
                                icon: Icons.account_balance_wallet,
                                title: 'Add Settlement to ${tag.name}',
                                subtitle: 'Record a settlement payment',
                                onTap: () => _selectOption('settlement', tag: tag),
                                tileColor: primaryColor.withOpacity(0.05),
                              ),
                            ],
                            SizedBox(height: 16),
                          ],
                        );
                      }).toList(),
                    ],
                  ],
                ),
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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:kilvish/background_worker.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/home_screen.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/style.dart';

class ImportReceiptScreen extends StatefulWidget {
  final File receiptFile;

  const ImportReceiptScreen({super.key, required this.receiptFile});

  @override
  State<ImportReceiptScreen> createState() => _ImportReceiptScreenState();
}

class _ImportReceiptScreenState extends State<ImportReceiptScreen> {
  List<Tag> _userTags = [];
  bool _isLoading = true;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _loadUserTags();
  }

  Future<void> _loadUserTags() async {
    try {
      final tags = await CacheManager.loadTags();
      setState(() { _userTags = tags; _isLoading = false; });
    } catch (e) {
      print('Error loading tags: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _selectOption({Tag? tag, bool isLoanPayback = false}) async {
    setState(() => _isProcessing = true);
    try {
      final wipExpense = await createWIPExpense();
      if (wipExpense == null) throw Exception('Failed to create expense');

      if (tag != null) {
        wipExpense.tagIds.add(tag.id);
        wipExpense.tags.add(tag);
        await updateWIPExpenseTags(wipExpense.id, wipExpense.tagIds);
      }

      if (isLoanPayback) {
        await markWIPExpenseAsLoanPayback(wipExpense.id);
      }

      // Kick off background upload (moves file, enqueues upload, sets status to uploadingReceipt)
      final result = await handleSharedReceipt(widget.receiptFile, wipExpenseAsParam: wipExpense);

      if (result == null) {
        // Duplicate — this receipt was already imported
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => HomeScreen(messageOnLoad: "Receipt already imported")),
            (route) => false,
          );
        }
        return;
      }

      // Fetch updated object (has localReceiptPath + status set)
      final updated = await getWIPExpense(wipExpense.id) ?? wipExpense;
      await CacheManager.addOrUpdateWIPExpense(updated);

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => HomeScreen(expenseAsParam: updated)),
          (route) => false,
        );
      }
    } catch (e) {
      print('Error in _selectOption: $e');
      if (mounted) {
        showError(context, 'Something went wrong, please try again');
        setState(() => _isProcessing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) {
          try { widget.receiptFile.deleteSync(); } catch (_) {}
        }
      },
      child: Scaffold(
        backgroundColor: kWhitecolor,
        appBar: AppBar(
          backgroundColor: primaryColor,
          automaticallyImplyLeading: false,
          title: Text('Import Receipt', style: TextStyle(color: kWhitecolor, fontWeight: FontWeight.bold)),
        ),
        body: _isLoading || _isProcessing
            ? Center(child: CircularProgressIndicator(color: primaryColor))
            : SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    renderPrimaryColorLabel(text: 'How would you like to import this receipt?'),
                    const SizedBox(height: 20),
                    _buildOptionTile(
                      icon: Icons.receipt_long,
                      title: 'Add Expense',
                      subtitle: 'Add to your personal expenses',
                      onTap: () => _selectOption(),
                    ),
                    const SizedBox(height: 12),
                    _buildOptionTile(
                      icon: Icons.account_balance_wallet,
                      title: 'Track Loan Payback',
                      subtitle: 'Record a payment towards a loan',
                      onTap: () => _selectOption(isLoanPayback: true),
                    ),
                    if (_userTags.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      renderPrimaryColorLabel(text: 'Add to a tag:'),
                      const SizedBox(height: 12),
                      ..._userTags.map((tag) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _buildOptionTile(
                          icon: Icons.local_offer,
                          title: 'Add Expense to ${tag.name}',
                          subtitle: 'Attach to this tag',
                          onTap: () => _selectOption(tag: tag),
                        ),
                      )),
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
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: tileBackgroundColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: bordercolor),
        ),
        child: Row(
          children: [
            Icon(icon, color: primaryColor, size: 32),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: defaultFontSize, color: kTextColor, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: const TextStyle(fontSize: smallFontSize, color: kTextMedium)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios, color: kTextMedium, size: 16),
          ],
        ),
      ),
    );
  }
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:kilvish/cache_manager.dart' as CacheManager;
import 'package:kilvish/share_service.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models_pending_import.dart';
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
  bool _isDuplicate = false;

  @override
  void initState() {
    super.initState();
    _checkForDuplicateAndLoadTags();
  }

  Future<void> _checkForDuplicateAndLoadTags() async {
    try {
      final isDuplicate = await PendingImport.isDuplicate(widget.receiptFile);
      if (isDuplicate) {
        if (mounted)
          setState(() {
            _isDuplicate = true;
            _isLoading = false;
          });
        return;
      }

      final tags = await CacheManager.loadTags();
      if (mounted) {
        setState(() {
          _userTags = tags;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('Error in _checkForDuplicateAndLoadTags: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _overrideDuplicateAndImport() async {
    setState(() => _isLoading = true);
    final tags = await CacheManager.loadTags();
    if (mounted)
      setState(() {
        _isDuplicate = false;
        _userTags = tags;
        _isLoading = false;
      });
  }

  Future<void> _selectOption({Tag? tag, bool isLoanPayback = false}) async {
    setState(() => _isProcessing = true);
    try {
      if (tag != null) {
        CacheManager.addOrUpdateTag(tag); // fire-and-forget: updates memory + persists in background
        touchTagUpdatedAt(tag.id);
      }
      final pendingImport = await PendingImport.stageReceipt(
        receiptFile: widget.receiptFile,
        tagId: tag?.id,
        tagName: tag?.name,
        isLoanPayback: isLoanPayback,
      );
      await PendingImport.addToCache(pendingImport);

      if (mounted) {
        ShareService().clearPendingMedia();
        context.go('/bulk-import', extra: pendingImport);
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
          ShareService().clearPendingMedia();
          try {
            widget.receiptFile.deleteSync();
          } catch (_) {}
        }
      },
      child: Scaffold(
        backgroundColor: kWhitecolor,
        appBar: AppBar(
          backgroundColor: primaryColor,
          automaticallyImplyLeading: false,
          title: Text(
            'Import Receipt',
            style: TextStyle(color: kWhitecolor, fontWeight: FontWeight.bold),
          ),
        ),
        body: _isLoading || _isProcessing
            ? Center(child: CircularProgressIndicator(color: primaryColor))
            : _isDuplicate
            ? _buildDuplicateScreen()
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
                      ..._userTags.map(
                        (tag) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _buildOptionTile(
                            icon: Icons.local_offer,
                            title: tag.name,
                            subtitle: 'Attach to this tag',
                            onTap: () => _selectOption(tag: tag),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildDuplicateScreen() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline, size: 64, color: primaryColor),
            const SizedBox(height: 24),
            const Text(
              'Already imported',
              style: TextStyle(fontSize: largeFontSize, fontWeight: FontWeight.bold, color: kTextColor),
            ),
            const SizedBox(height: 12),
            const Text(
              'This receipt has already been imported. You can go back to the UPI app.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: defaultFontSize, color: kTextMedium),
            ),
            if (!Platform.isIOS) ...[
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: SystemNavigator.pop,
                  style: TextButton.styleFrom(backgroundColor: primaryColor, minimumSize: const Size.fromHeight(50)),
                  child: const Text(
                    'OK',
                    style: TextStyle(color: kWhitecolor, fontSize: defaultFontSize),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: _overrideDuplicateAndImport,
                child: const Text('Import anyway', style: TextStyle(color: kTextMedium)),
              ),
            ),
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
                  Text(
                    title,
                    style: const TextStyle(fontSize: defaultFontSize, color: kTextColor, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: smallFontSize, color: kTextMedium),
                  ),
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

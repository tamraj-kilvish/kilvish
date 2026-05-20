import 'dart:io';

import 'package:flutter/material.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/models_pending_import.dart';
import 'package:kilvish/style.dart';

class PendingImportDetailScreen extends StatelessWidget {
  final PendingImport pendingImport;

  const PendingImportDetailScreen({super.key, required this.pendingImport});

  @override
  Widget build(BuildContext context) {
    final label = pendingImport.tagName ?? (pendingImport.isLoanPayback ? 'Loan Payback' : 'Personal Expense');
    final icon = pendingImport.tagId != null
        ? Icons.local_offer
        : pendingImport.isLoanPayback
            ? Icons.account_balance_wallet
            : Icons.receipt_long;

    return Scaffold(
      backgroundColor: kWhitecolor,
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: Text('Queued Receipt', style: TextStyle(color: kWhitecolor, fontWeight: FontWeight.bold)),
        iconTheme: IconThemeData(color: kWhitecolor),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            buildReceiptSection(
              initialText: 'Receipt',
              processingText: '',
              mainFunction: () {},
              isProcessingImage: false,
              receiptImage: File(pendingImport.stagedPath),
              receiptUrl: null,
              webImageBytes: null,
              onCloseFunction: null,
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: tileBackgroundColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: bordercolor),
              ),
              child: Row(
                children: [
                  Icon(icon, color: primaryColor, size: 28),
                  const SizedBox(width: 12),
                  Text(label, style: TextStyle(fontSize: defaultFontSize, color: kTextColor, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: outstandingColor.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: outstandingLightColor),
              ),
              child: Row(
                children: [
                  Icon(Icons.timer_outlined, color: outstandingColor, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Queued for processing',
                    style: TextStyle(color: outstandingColor, fontSize: smallFontSize, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

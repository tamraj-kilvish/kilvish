import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/style.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const String _prefKey = 'pre_expense_screen_dismissed';

/// Education screen shown before ExpenseAddEditScreen for FAB-initiated expenses.
/// Teaches the user to make the UPI payment first, then log it here.
/// If user taps "Don't show this again", subsequent FAB taps skip directly to /expenses/new.
class PreExpenseAddEditScreen extends StatefulWidget {
  final WIPExpense wipExpense;

  const PreExpenseAddEditScreen({super.key, required this.wipExpense});

  @override
  State<PreExpenseAddEditScreen> createState() => _PreExpenseAddEditScreenState();
}

class _PreExpenseAddEditScreenState extends State<PreExpenseAddEditScreen> {
  bool _dontShowAgain = false;

  bool get _isSettlement => widget.wipExpense.tagLinks.any((l) => l.isSettlement);

  Future<void> _openUpiApp() async {
    final uri = Uri.parse('upi://pay');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No UPI app found. Please open your UPI app manually.')));
      }
    }
  }

  Future<void> _proceed() async {
    if (_dontShowAgain) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, true);
    }
    if (!mounted) return;
    // Push (not replace) so the saved Expense result is relayed back to the
    // original caller (TagDetailScreen / HomeScreen).
    // context.replace would abandon the caller's push completer — the await
    // would hang forever and the expense result would be lost.
    final result = await context.push('/expenses/new', extra: widget.wipExpense);
    if (!mounted) return;
    context.pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final title = _isSettlement ? 'Log a Settlement' : 'Log an Expense';
    final bodyText = _isSettlement
        ? 'First, pay the person via your UPI app (GPay, PhonePe, Paytm, etc.), '
              'then come back here to record it as a Settlement in Kilvish.'
        : 'First, make the payment using your UPI app (GPay, PhonePe, Paytm, etc.), '
              'then come back here to log it in Kilvish.';

    return Scaffold(
      backgroundColor: kWhitecolor,
      appBar: AppBar(
        backgroundColor: primaryColor,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: kWhitecolor),
          onPressed: () => context.pop(),
        ),
        title: Text(
          title,
          style: const TextStyle(color: kWhitecolor, fontWeight: FontWeight.bold),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 32),
            Icon(Icons.smartphone, size: 72, color: primaryColor.withOpacity(0.8)),
            const SizedBox(height: 24),
            Text(
              bodyText,
              style: const TextStyle(fontSize: defaultFontSize, color: kTextColor, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: primaryColor.withOpacity(0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: primaryColor.withOpacity(0.2)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lightbulb_outline, color: primaryColor, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Tip: Install the Kilvish app to share receipts directly from your '
                      'UPI app — no manual entry needed.',
                      style: TextStyle(fontSize: smallFontSize, color: kTextMedium),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: _openUpiApp,
                style: TextButton.styleFrom(backgroundColor: primaryColor, minimumSize: const Size.fromHeight(50)),
                child: const Text(
                  'Open UPI App',
                  style: TextStyle(color: kWhitecolor, fontSize: defaultFontSize),
                ),
              ),
            ),
            const Divider(height: 50),
            Text(
              'Done with transaction & want to log it manually ?',
              style: const TextStyle(fontSize: smallFontSize, color: kTextColor, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: _proceed,
                style: TextButton.styleFrom(
                  backgroundColor: kWhitecolor,
                  side: BorderSide(color: primaryColor),
                  minimumSize: const Size.fromHeight(50),
                ),
                child: const Text(
                  'Continue with Manual Entry',
                  style: TextStyle(color: primaryColor, fontSize: defaultFontSize),
                ),
              ),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: _dontShowAgain,
              onChanged: (v) => setState(() => _dontShowAgain = v ?? false),
              title: const Text("Don't show this again", style: TextStyle(fontSize: smallFontSize)),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              activeColor: primaryColor,
            ),
          ],
        ),
      ),
    );
  }
}

/// Checks the stored preference. Returns true if the user has dismissed
/// the pre-expense education screen and FAB should skip directly to /expenses/new.
Future<bool> hasUserChosenNotToSeePreExpenseCreateScreen() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_prefKey) ?? false;
}

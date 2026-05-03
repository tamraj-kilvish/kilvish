import 'package:flutter/material.dart';
import 'package:kilvish/common_widgets.dart';
import 'package:kilvish/firestore.dart';
import 'package:kilvish/models.dart';
import 'package:kilvish/models_expense.dart';
import 'package:kilvish/style.dart';

/// Screen for configuring a single tag's relationship to an expense —
/// either as a normal expense (with recipients) or as a settlement.
class TagExpenseConfigScreen extends StatefulWidget {
  final Tag tag;
  final BaseExpense expense;
  final bool isExpenseOwner;
  final TagExpenseConfig? initialConfig;
  final String? currentUserId;

  const TagExpenseConfigScreen({
    super.key,
    required this.tag,
    required this.expense,
    required this.isExpenseOwner,
    this.initialConfig,
    this.currentUserId,
  });

  @override
  State<TagExpenseConfigScreen> createState() => _TagExpenseConfigScreenState();
}

class _TagExpenseConfigScreenState extends State<TagExpenseConfigScreen> {
  bool _isSettlement = false;
  String? _settlementMonth;
  String? _settlementCounterpartyId;
  final Map<String, num> _recipientAmounts = {};
  late final TextEditingController _ownerShareController;
  num _ownerShare = 0;

  List<String> _tagMemberIds = [];
  final Map<String, String> _userIdToKilvishId = {};
  bool _isLoading = true;

  String get _expenseOwnerId => widget.expense.ownerId ?? '';
  num get _expenseAmount => widget.expense.amount ?? 0;

  @override
  void initState() {
    super.initState();
    final config = widget.initialConfig;
    _isSettlement = config?.isSettlement ?? false;
    _settlementMonth = config?.settlementMonth;
    _settlementCounterpartyId = config?.settlementCounterpartyId;
    _ownerShare = config?.ownerShare ?? 0;
    _ownerShareController = TextEditingController(
      text: _ownerShare > 0 ? _ownerShare.toStringAsFixed(0) : '',
    );
    if (config != null) _recipientAmounts.addAll(config.recipientAmounts);
    _loadTagMembers();
  }

  @override
  void dispose() {
    _ownerShareController.dispose();
    super.dispose();
  }

  Future<void> _loadTagMembers() async {
    final ids = <String>{widget.tag.ownerId, ...widget.tag.sharedWith}.toList();
    _tagMemberIds = ids;
    for (final userId in ids) {
      final kilvishId = await getUserKilvishId(userId);
      if (kilvishId != null && mounted) {
        setState(() => _userIdToKilvishId[userId] = kilvishId);
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  num get _outstanding => _expenseAmount - _ownerShare;

  String _labelFor(String userId) {
    final k = _userIdToKilvishId[userId];
    return k != null ? '@$k' : userId;
  }

  String _formatMonth(String monthKey) {
    final parts = monthKey.split('-');
    if (parts.length != 2) return monthKey;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    if (year == null || month == null) return monthKey;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[month - 1]} $year';
  }

  void _done() {
    Navigator.pop(
      context,
      TagExpenseConfig(
        tagId: widget.tag.id,
        isSettlement: _isSettlement,
        settlementMonth: _isSettlement ? _settlementMonth : null,
        settlementCounterpartyId: _isSettlement ? _settlementCounterpartyId : null,
        recipientAmounts: _isSettlement ? const {} : Map.from(_recipientAmounts),
        ownerShare: _isSettlement ? 0 : _ownerShare,
      ),
    );
  }

  void _remove() {
    Navigator.pop(context, TagExpenseConfig(tagId: widget.tag.id, removed: true));
  }

  Future<void> _pickSettlementMonth() async {
    final now = DateTime.now();
    int year = now.year;
    int month = now.month;
    if (_settlementMonth != null) {
      final parts = _settlementMonth!.split('-');
      if (parts.length == 2) {
        year = int.tryParse(parts[0]) ?? year;
        month = int.tryParse(parts[1]) ?? month;
      }
    }
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _MonthYearPickerDialog(initialYear: year, initialMonth: month),
    );
    if (result != null && mounted) setState(() => _settlementMonth = result);
  }

  void _showAmountDialog(String userId) {
    final current = _recipientAmounts[userId] ?? 0;
    final controller = TextEditingController(
      text: current > 0 ? current.toStringAsFixed(0) : '',
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_labelFor(userId)),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(prefixText: '₹', labelText: 'Amount'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final amount = num.tryParse(controller.text) ?? 0;
              setState(() => _recipientAmounts[userId] = amount);
              Navigator.pop(ctx);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kWhitecolor,
      appBar: AppBar(
        backgroundColor: primaryColor,
        title: Text(
          widget.tag.name,
          style: TextStyle(color: kWhitecolor, fontSize: titleFontSize, fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: primaryColor))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildModeSelector(),
                  const SizedBox(height: 20),
                  if (_isSettlement) _buildSettlementBody() else _buildExpenseBody(),
                  const SizedBox(height: 32),
                ],
              ),
            ),
      bottomNavigationBar: BottomAppBar(
        child: Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: _remove,
                style: TextButton.styleFrom(
                  foregroundColor: errorcolor,
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('Remove Tag'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextButton(
                onPressed: _done,
                style: TextButton.styleFrom(
                  backgroundColor: primaryColor,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        renderPrimaryColorLabel(text: 'Type'),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border.all(color: widget.isExpenseOwner ? primaryColor : inactiveColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButton<bool>(
            value: _isSettlement,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: false, child: Text('Expense Distribution')),
              DropdownMenuItem(value: true, child: Text('Settlement')),
            ],
            onChanged: widget.isExpenseOwner ? (v) => setState(() => _isSettlement = v ?? false) : null,
          ),
        ),
      ],
    );
  }

  Widget _buildExpenseBody() {
    final otherIds = _tagMemberIds.where((id) => id != _expenseOwnerId).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.orange.shade50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.orange.shade200),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Outstanding', style: TextStyle(color: Colors.orange.shade800)),
              Text(
                '₹${_outstanding.toStringAsFixed(0)}',
                style: TextStyle(
                  color: Colors.orange.shade800,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        renderPrimaryColorLabel(text: 'Members'),
        const SizedBox(height: 8),
        _buildOwnerShareRow(),
        if (otherIds.isNotEmpty) const Divider(height: 20),
        ...otherIds.map((uid) {
          final canEdit = widget.isExpenseOwner || uid == widget.currentUserId;
          return _buildMemberRow(uid, canEdit);
        }),
      ],
    );
  }

  Widget _buildOwnerShareRow() {
    final label = _labelFor(_expenseOwnerId);
    if (!widget.isExpenseOwner) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: defaultFontSize))),
            Text(
              _ownerShare > 0 ? '₹${_ownerShare.toStringAsFixed(0)}' : '—',
              style: TextStyle(color: inactiveColor),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: Text('$label (you)', style: const TextStyle(fontSize: defaultFontSize))),
          SizedBox(
            width: 110,
            child: TextField(
              controller: _ownerShareController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                prefixText: '₹',
                hintText: 'My share',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _ownerShare = num.tryParse(v) ?? 0),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemberRow(String userId, bool isEditable) {
    final amount = _recipientAmounts[userId] ?? 0;
    final label = _labelFor(userId);

    return InkWell(
      onTap: isEditable ? () => _showAmountDialog(userId) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: defaultFontSize,
                  color: isEditable ? kTextColor : inactiveColor,
                ),
              ),
            ),
            Text(
              amount > 0 ? '₹${amount.toStringAsFixed(0)}' : '—',
              style: TextStyle(
                color: amount > 0 ? kTextColor : inactiveColor,
                fontWeight: amount > 0 ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
            if (isEditable) ...[
              const SizedBox(width: 6),
              Icon(Icons.edit, size: 14, color: inactiveColor),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSettlementBody() {
    final counterpartyIds = _tagMemberIds.where((id) => id != _expenseOwnerId).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        renderPrimaryColorLabel(text: 'Settle for month'),
        const SizedBox(height: 8),
        InkWell(
          onTap: _pickSettlementMonth,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              border: Border.all(color: primaryColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _settlementMonth != null ? _formatMonth(_settlementMonth!) : 'Select month',
                  style: TextStyle(color: _settlementMonth != null ? kTextColor : inactiveColor),
                ),
                Icon(Icons.calendar_month, color: primaryColor),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        renderPrimaryColorLabel(text: 'Settle with'),
        const SizedBox(height: 8),
        widget.isExpenseOwner
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: primaryColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButton<String>(
                  value: _settlementCounterpartyId,
                  hint: const Text('Select user'),
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: counterpartyIds
                      .map((id) => DropdownMenuItem(value: id, child: Text(_labelFor(id))))
                      .toList(),
                  onChanged: (v) => setState(() => _settlementCounterpartyId = v),
                ),
              )
            : Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                decoration: BoxDecoration(
                  border: Border.all(color: inactiveColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _settlementCounterpartyId != null ? _labelFor(_settlementCounterpartyId!) : '—',
                  style: TextStyle(color: kTextMedium),
                ),
              ),
        const SizedBox(height: 20),
        renderPrimaryColorLabel(text: 'Amount'),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            color: tileBackgroundColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '₹$_expenseAmount',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}

class _MonthYearPickerDialog extends StatefulWidget {
  final int initialYear;
  final int initialMonth;

  const _MonthYearPickerDialog({required this.initialYear, required this.initialMonth});

  @override
  State<_MonthYearPickerDialog> createState() => _MonthYearPickerDialogState();
}

class _MonthYearPickerDialogState extends State<_MonthYearPickerDialog> {
  late int _year;
  late int _month;

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  @override
  void initState() {
    super.initState();
    _year = widget.initialYear;
    _month = widget.initialMonth;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select Month'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => setState(() => _year--)),
              Text('$_year', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => setState(() => _year++)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: List.generate(12, (i) {
              final selected = _month == i + 1;
              return GestureDetector(
                onTap: () => setState(() => _month = i + 1),
                child: Container(
                  width: 64,
                  height: 32,
                  decoration: BoxDecoration(
                    color: selected ? primaryColor : tileBackgroundColor,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _months[i],
                    style: TextStyle(
                      color: selected ? kWhitecolor : kTextColor,
                      fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          onPressed: () {
            final key = '$_year-${_month.toString().padLeft(2, '0')}';
            Navigator.pop(context, key);
          },
          child: const Text('OK'),
        ),
      ],
    );
  }
}
